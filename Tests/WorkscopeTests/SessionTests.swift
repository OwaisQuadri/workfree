import Darwin
import Foundation
import XCTest

@testable import Workscope

final class SessionTests: XCTestCase {
  func testUnknownIdentityBlocksAndPIDReuseDoesNotKeepDeadClaim() {
    let claim = ConversationClaim(
      sessionID: "parent", processID: 123, bootIdentity: "boot", startSeconds: 10,
      startMicroseconds: 5)
    XCTAssertTrue(isConversationBlocking(claim, snapshot: { _ in .unknown }))
    XCTAssertFalse(isConversationBlocking(claim, snapshot: { _ in .absent }))
    XCTAssertTrue(
      isConversationBlocking(
        claim,
        snapshot: { _ in
          .running(bootIdentity: "boot", seconds: 10, microseconds: 5)
        }))
    XCTAssertFalse(
      isConversationBlocking(
        claim,
        snapshot: { _ in
          .running(bootIdentity: "boot", seconds: 11, microseconds: 5)
        }))
    XCTAssertFalse(
      isConversationBlocking(
        claim,
        snapshot: { _ in
          .running(bootIdentity: "new-boot", seconds: 10, microseconds: 5)
        }))
    XCTAssertTrue(
      isConversationBlocking(
        claim,
        snapshot: { _ in
          .running(bootIdentity: "", seconds: 0, microseconds: 0)
        }))
  }

  func testIdleConversationProtectsPolicyCheckoutAcrossReloadAndOwnerRelease() throws {
    let fixture = try Fixture()
    let allocation = try fixture.registry.start(
      branch: "idle", repository: fixture.repository, provider: .git)
    _ = try fixture.registry.authorizeCleanup(allocation.id, graceSeconds: 0)
    let context = try ConversationContext(
      sessionID: "idle", processID: getpid(), cwd: allocation.path)
    let conversation = try Registry(
      stateDirectory: fixture.registry.stateDirectory, conversation: context)
    _ = try conversation.sweep()
    let claimed = try fixture.registry.inspect(allocation.id)
    XCTAssertEqual(claimed.conversationClaims?.count, 1)
    XCTAssertEqual(try fixture.registry.finish(allocation.id).phase, .blocked)
    let reloaded = try Registry(stateDirectory: fixture.registry.stateDirectory)
    _ = try reloaded.sweep()
    XCTAssertTrue(try isPresent(allocation.path))
    XCTAssertTrue(
      try reloaded.preview(allocation.id)[0].reasons.contains("Retained conversation: idle"))
    XCTAssertEqual(
      try reloaded.inspect(allocation.id).conversationClaims, claimed.conversationClaims)
  }

  func testChildTerminationCannotReleaseParentOrLegacyOwners() throws {
    let fixture = try Fixture()
    let allocation = try fixture.registry.start(
      branch: "shared", repository: fixture.repository, provider: .git)
    _ = try fixture.registry.authorizeCleanup(allocation.id, graceSeconds: 0)
    _ = try fixture.registry.retain(allocation.id, owner: "workspace", kind: .workspace)
    let parent = try Registry(
      stateDirectory: fixture.registry.stateDirectory,
      conversation: ConversationContext(sessionID: "parent", processID: getpid()))
    _ = try parent.claim(allocation.id)
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/cat")
    let input = Pipe()
    child.standardInput = input
    child.standardOutput = FileHandle.nullDevice
    try child.run()
    defer {
      if child.isRunning {
        child.terminate()
        child.waitUntilExit()
      }
    }
    let childRegistry = try Registry(
      stateDirectory: fixture.registry.stateDirectory,
      conversation: ConversationContext(sessionID: "child", processID: child.processIdentifier))
    _ = try childRegistry.claim(allocation.id)
    XCTAssertEqual(try fixture.registry.inspect(allocation.id).conversationClaims?.count, 2)
    try input.fileHandleForWriting.close()
    child.waitUntilExit()
    _ = try fixture.registry.sweep()
    let retained = try fixture.registry.inspect(allocation.id)
    XCTAssertEqual(retained.conversationClaims?.map(\.sessionID), ["parent"])
    XCTAssertNotNil(retained.owners["workspace"])
    XCTAssertNotNil(retained.owners["task:" + allocation.id])
    XCTAssertTrue(try isPresent(allocation.path))
  }

  func testInvalidSavedAssignmentDoesNotBlockNewWorkAndRemainsProtected() throws {
    let fixture = try Fixture()
    let old = try fixture.registry.start(
      branch: "old", repository: fixture.repository, provider: .git)
    _ = try fixture.registry.authorizeCleanup(old.id, graceSeconds: 0)
    try fixture.inject(old, overrides: ["repositoryIdentity": "changed-device"])
    let conversation = try Registry(
      stateDirectory: fixture.registry.stateDirectory,
      conversation: ConversationContext(
        sessionID: "resumed", processID: getpid(), allocationIDs: [old.id]))
    let created = try conversation.start(
      branch: "new", repository: fixture.repository, provider: .git)
    XCTAssertEqual(created.conversationClaims?.map(\.sessionID), ["resumed"])
    XCTAssertEqual(
      try fixture.registry.inspect(old.id).conversationClaims?.map(\.sessionID), ["resumed"])
    XCTAssertThrowsError(try conversation.claim(old.id))
    _ = try fixture.registry.sweep()
    XCTAssertTrue(try isPresent(old.path))
  }

  func testStartAndRestoreReturnAlreadyClaimedAndRejectPendingAcquisition() throws {
    let fixture = try Fixture()
    let conversation = try Registry(
      stateDirectory: fixture.registry.stateDirectory,
      conversation: ConversationContext(sessionID: "new", processID: getpid()))
    let created = try conversation.start(
      branch: "created", repository: fixture.repository, provider: .git)
    XCTAssertEqual(created.conversationClaims?.map(\.sessionID), ["new"])
    let unclaimed = try fixture.registry.start(
      branch: "restore", repository: fixture.repository, provider: .git)
    _ = try fixture.registry.authorizeCleanup(unclaimed.id, graceSeconds: 0)
    _ = try fixture.registry.sweep()
    XCTAssertEqual(try fixture.registry.inspect(unclaimed.id).phase, .removed)
    let restoring = try Registry(
      stateDirectory: fixture.registry.stateDirectory,
      conversation: ConversationContext(
        sessionID: "restoring", processID: getpid(), allocationIDs: [unclaimed.id]))
    let restored = try restoring.restore(unclaimed.id)
    XCTAssertEqual(restored.conversationClaims?.map(\.sessionID), ["restoring"])
    _ = try fixture.registry.sweep()
    XCTAssertTrue(try isPresent(restored.path))
    try fixture.inject(created, overrides: ["isRemovalPending": true, "phase": "removing"])
    XCTAssertThrowsError(try conversation.claim(created.id))
    XCTAssertThrowsError(try fixture.registry.recover(created.id))
    XCTAssertTrue(try isPresent(created.path))
  }

  func testConversationAcquisitionContendsWithRemovalWithoutReturningDeletedPath() throws {
    let fixture = try Fixture()
    let allocation = try fixture.start()
    let remover = try fixture.cli(
      ["finish", allocation.id], environment: fixture.wrapper(isAfterRemoval: false))
    try fixture.awaitFile(fixture.root + "/provider.ready")
    let acquirer = try fixture.cli([
      "--session-id", "late", "--session-pid", String(getpid()), "claim", allocation.id,
    ])
    try Data().write(to: URL(fileURLWithPath: fixture.root + "/provider.continue"))
    XCTAssertEqual(fixture.wait(remover), 0)
    XCTAssertNotEqual(fixture.wait(acquirer), 0)
    XCTAssertEqual(try fixture.registry.inspect(allocation.id).phase, .removed)
    XCTAssertFalse(try isPresent(allocation.path))
  }

  func testProvenDeadClaimsArePrunedWithoutRetiringLegacyOwners() throws {
    let fixture = try Fixture()
    var allocation = try fixture.registry.start(
      branch: "dead", repository: fixture.repository, provider: .git)
    let context = try ConversationContext(sessionID: "past", processID: getpid())
    allocation.conversationClaims = [
      ConversationClaim(
        sessionID: "past", processID: getpid(), bootIdentity: context.claim.bootIdentity,
        startSeconds: context.claim.startSeconds + 1,
        startMicroseconds: context.claim.startMicroseconds)
    ]
    try fixture.inject(allocation)
    _ = try fixture.registry.sweep()
    let pruned = try fixture.registry.inspect(allocation.id)
    XCTAssertEqual(pruned.conversationClaims, [])
    XCTAssertNotNil(pruned.owners["task:" + allocation.id])
    XCTAssertTrue(try isPresent(allocation.path))
  }
}
