import Darwin
import Foundation
import XCTest

@testable import Workscope

final class RepositoryIdentityRepairTests: XCTestCase {
  func testDeviceChangeRequiresExplicitRepairBeforeMigrationAndPreservesMarker() throws {
    let fixture = try Fixture()
    let allocation = try legacyAllocation(fixture)
    let marker = URL(fileURLWithPath: allocation.admin! + "/workfree-allocation")
    let original = try Data(contentsOf: marker)
    let policy = try fixture.registry.enableGlobalCleanupPolicy().policy!
    XCTAssertThrowsError(try fixture.registry.migrateGlobalCleanupPolicy(allocation.id))
    XCTAssertNil(try fixture.registry.inspect(allocation.id).repositoryVolumeUUID)
    XCTAssertEqual(fixture.wait(try fixture.cli(["repair-identity", allocation.id])), 0)
    let repaired = try fixture.registry.inspect(allocation.id)
    XCTAssertEqual(repaired.repositoryVolumeUUID, try repositoryVolumeUUID(fixture.repository))
    XCTAssertEqual(repaired.repositoryIdentity, allocation.repositoryIdentity)
    XCTAssertEqual(try Data(contentsOf: marker), original)
    XCTAssertNil(repaired.cleanupPolicy)
    XCTAssertNil(repaired.eligibleSince)
    XCTAssertEqual(
      fixture.wait(
        try fixture.cli([
          "cleanup-policy", "migrate", "--global", "--allocation", allocation.id,
        ])), 0)
    XCTAssertEqual(try fixture.registry.inspect(allocation.id).cleanupPolicySourceID, policy.id)
    let reloaded = try Registry(stateDirectory: fixture.registry.stateDirectory)
    try verifyIdentity(reloaded.inspect(allocation.id))
    _ = try reloaded.repairRepositoryIdentity(allocation.id)
  }

  func testRepairRejectsChangedInodeMarkerAndPinnedVolumeWithoutSaving() throws {
    for change in ["inode", "marker", "volume"] {
      let fixture = try Fixture()
      var allocation = try legacyAllocation(fixture, isChangedInode: change == "inode")
      if change == "marker" {
        try Data("replaced".utf8).write(
          to: URL(fileURLWithPath: allocation.admin! + "/workfree-allocation"))
      }
      if change == "volume" {
        allocation.repositoryVolumeUUID = "other-volume"
        try fixture.inject(allocation)
      }
      XCTAssertThrowsError(try fixture.registry.repairRepositoryIdentity(allocation.id), change)
      let saved = try fixture.registry.inspect(allocation.id)
      XCTAssertEqual(saved.repositoryVolumeUUID, allocation.repositoryVolumeUUID, change)
      XCTAssertNil(saved.cleanupAttempts, change)
      XCTAssertTrue(try isPresent(allocation.path), change)
    }
  }

  func testExplicitReplacementRepairPreservesOriginalAllocationAndEnablesMigration() throws {
    let fixture = try Fixture()
    let allocation = try legacyAllocation(fixture, isChangedInode: true)
    let oldMarker = try Data(
      contentsOf: URL(fileURLWithPath: allocation.admin! + "/workfree-allocation"))
    _ = try fixture.registry.enableGlobalCleanupPolicy()
    XCTAssertThrowsError(try fixture.registry.repairRepositoryIdentity(allocation.id))
    XCTAssertNotEqual(fixture.wait(try fixture.cli(["repair-identity", allocation.id])), 0)
    XCTAssertEqual(
      fixture.wait(
        try fixture.cli([
          "repair-identity", allocation.id, "--accept-replaced-repository",
        ])), 0)
    let repaired = try fixture.registry.inspect(allocation.id)
    XCTAssertEqual(repaired.repositoryIdentity, try repositoryIdentity(fixture.repository))
    XCTAssertEqual(repaired.path, allocation.path)
    XCTAssertNotEqual(
      try Data(contentsOf: URL(fileURLWithPath: repaired.admin! + "/workfree-allocation")),
      oldMarker)
    try verifyIdentity(repaired)
    XCTAssertEqual(
      try fixture.registry.migrateGlobalCleanupPolicy(allocation.id).map(\.id), [allocation.id])
    XCTAssertEqual(try fixture.registry.inspect(allocation.id).phase, .retained)
  }

  func testReplacementDoesNotTransferOldCleanupAuthority() throws {
    let fixture = try Fixture()
    var allocation = try legacyAllocation(fixture, isChangedInode: true)
    let policy = RepositoryCleanupPolicy(
      id: "old-repository-policy", repository: fixture.repository,
      repositoryIdentity: allocation.repositoryIdentity, grantedAt: Date(),
      cleanupPolicy: CleanupPolicy(graceSeconds: 60, disposablePaths: []))
    try withConversationRegistry(fixture.registry.stateDirectory, conversation: nil) {
      try $0.saveRepositoryCleanupPolicy(policy)
    }
    allocation.isCleanupAuthorized = true
    allocation.cleanupPolicy = policy.cleanupPolicy
    allocation.cleanupPolicySourceID = policy.id
    try fixture.inject(allocation)

    let repaired = try fixture.registry.repairRepositoryIdentity(
      allocation.id, isRepositoryReplacementAllowed: true)
    try verifyIdentity(repaired)
    XCTAssertFalse(repaired.isCleanupAuthorized)
    XCTAssertNil(repaired.cleanupPolicy)
    XCTAssertNil(repaired.cleanupPolicySourceID)
    try withConversationRegistry(fixture.registry.stateDirectory, conversation: nil) {
      XCTAssertEqual(
        try $0.repositoryCleanupPolicy(policy.repositoryIdentity, isExact: true)?.id, policy.id)
      XCTAssertNil(try $0.repositoryCleanupPolicy(repaired.repositoryIdentity, isExact: true))
    }
    let new = try fixture.registry.start(
      branch: UUID().uuidString, repository: fixture.repository, provider: .git)
    XCTAssertNil(new.cleanupPolicy)
    let global = try fixture.registry.enableGlobalCleanupPolicy().policy!
    let inherited = try fixture.registry.start(
      branch: UUID().uuidString, repository: fixture.repository, provider: .git)
    XCTAssertEqual(inherited.cleanupPolicySourceID, global.id)
  }

  func testReplacementRepairRefusesWrongMarkerAndRetriesReplacedMarker() throws {
    let fixture = try Fixture()
    let invalid = try legacyAllocation(fixture, isChangedInode: true)
    let markerPath = invalid.admin! + "/workfree-allocation"
    try Data("wrong".utf8).write(to: URL(fileURLWithPath: markerPath))
    XCTAssertThrowsError(
      try fixture.registry.repairRepositoryIdentity(
        invalid.id, isRepositoryReplacementAllowed: true))
    XCTAssertEqual(
      try fixture.registry.inspect(invalid.id).repositoryIdentity, invalid.repositoryIdentity)

    let retry = try legacyAllocation(fixture, isChangedInode: true)
    var rebound = retry
    rebound.repositoryIdentity = try repositoryIdentity(fixture.repository)
    try JSONEncoder().encode([rebound.id, rebound.repositoryIdentity, rebound.path]).write(
      to: URL(fileURLWithPath: retry.admin! + "/workfree-allocation"))
    _ = try fixture.registry.repairRepositoryIdentity(
      retry.id, isRepositoryReplacementAllowed: true)
    try verifyIdentity(fixture.registry.inspect(retry.id))
  }

  func testTargetedMigrationLeavesInvalidAllocationBlockedAndStillHonorsExclusions() throws {
    let fixture = try Fixture()
    let valid = try legacyAllocation(fixture)
    let invalid = try legacyAllocation(fixture, isChangedInode: true)
    _ = try fixture.registry.enableGlobalCleanupPolicy()
    _ = try fixture.registry.repairRepositoryIdentity(valid.id)
    XCTAssertThrowsError(try fixture.registry.migrateGlobalCleanupPolicy())
    XCTAssertEqual(try fixture.registry.migrateGlobalCleanupPolicy(valid.id).map(\.id), [valid.id])
    XCTAssertNil(try fixture.registry.inspect(invalid.id).cleanupPolicy)
    XCTAssertThrowsError(try fixture.registry.migrateGlobalCleanupPolicy("missing"))
    _ = try fixture.registry.excludeRepositoryFromCleanup(repository: fixture.repository)
    XCTAssertTrue(try fixture.registry.migrateGlobalCleanupPolicy(valid.id).isEmpty)
  }

  func testNewIdentityUsesVolumeUUIDAndRepairedLegacyCanBeRecovered() throws {
    let fixture = try Fixture()
    let stable = try fixture.registry.start(
      branch: "stable", repository: fixture.repository, provider: .git)
    let uuid = try repositoryVolumeUUID(fixture.repository)
    XCTAssertTrue(stable.repositoryIdentity.contains(":" + uuid + ":"))
    try verifyIdentity(stable)
    let legacy = try legacyAllocation(fixture)
    _ = try fixture.registry.repairRepositoryIdentity(legacy.id)
    _ = try fixture.registry.authorizeCleanup(legacy.id, graceSeconds: 0)
    _ = try fixture.registry.sweep()
    let removed = try fixture.registry.inspect(legacy.id)
    XCTAssertEqual(removed.phase, .removed, removed.reason ?? "")
    let restored = try fixture.registry.restore(legacy.id)
    try verifyIdentity(restored)
    XCTAssertEqual(try git(restored.path, ["rev-parse", "HEAD"]), removed.recovery?.commit)
  }

  func testRepairPreservesRepositoryPolicyGenerationAndRevocation() throws {
    let fixture = try Fixture()
    let allocation = try legacyAllocation(fixture)
    let policy = RepositoryCleanupPolicy(
      id: "legacy-policy", repository: fixture.repository,
      repositoryIdentity: allocation.repositoryIdentity, grantedAt: Date(),
      cleanupPolicy: CleanupPolicy(graceSeconds: 60, disposablePaths: []))
    try withConversationRegistry(fixture.registry.stateDirectory, conversation: nil) {
      try $0.saveRepositoryCleanupPolicy(policy)
    }
    XCTAssertNil(
      try fixture.registry.repositoryCleanupPolicy(repository: fixture.repository).policy)
    _ = try fixture.registry.repairRepositoryIdentity(allocation.id)
    let saved = try fixture.registry.repositoryCleanupPolicy(repository: fixture.repository).policy
    XCTAssertEqual(saved?.id, policy.id)
    XCTAssertEqual(saved?.grantedAt, policy.grantedAt)
    _ = try fixture.registry.enableGlobalCleanupPolicy()
    _ = try fixture.registry.migrateGlobalCleanupPolicy(allocation.id)
    XCTAssertEqual(try fixture.registry.inspect(allocation.id).cleanupPolicySourceID, policy.id)
    _ = try fixture.registry.revokeRepositoryCleanupPolicy(repository: fixture.repository)
    XCTAssertNil(try fixture.registry.inspect(allocation.id).cleanupPolicy)
    XCTAssertTrue(try fixture.registry.inspect(allocation.id).isStandingCleanupDeclined == true)
  }

  func testObsoleteStablePoliciesDoNotBlockRepeatedReplacementOrGlobalFallback() throws {
    let fixture = try Fixture()
    let common = try canonical(
      git(fixture.repository, ["rev-parse", "--path-format=absolute", "--git-common-dir"]))
    try withConversationRegistry(fixture.registry.stateDirectory, conversation: nil) { store in
      for suffix in ["old-volume-a:1", "old-volume-b:2"] {
        try store.saveRepositoryCleanupPolicy(
          RepositoryCleanupPolicy(
            id: suffix, repository: fixture.repository,
            repositoryIdentity: common + ":" + suffix, grantedAt: Date(),
            cleanupPolicy: CleanupPolicy(graceSeconds: 60, disposablePaths: [])))
      }
    }
    XCTAssertNil(
      try fixture.registry.repositoryCleanupPolicy(repository: fixture.repository).policy)
    let global = try fixture.registry.enableGlobalCleanupPolicy().policy!
    let allocation = try fixture.registry.start(
      branch: "replacement", repository: fixture.repository, provider: .git)
    XCTAssertEqual(allocation.cleanupPolicySourceID, global.id)
    let policy = try fixture.registry.enableRepositoryCleanupPolicy(repository: fixture.repository)
      .policy!
    XCTAssertEqual(
      try fixture.registry.repositoryCleanupPolicy(repository: fixture.repository).policy?.id,
      policy.id)
  }

  func testVersionFourBinaryRejectsStableIdentityBeforeMutation() throws {
    guard let legacy = ProcessInfo.processInfo.environment["WORKFREE_V4_EXECUTABLE"] else {
      throw XCTSkip("Set WORKFREE_V4_EXECUTABLE to a verified version-4 wf build")
    }
    let fixture = try Fixture()
    let allocation = try fixture.registry.start(
      branch: "format-five", repository: fixture.repository, provider: .git)
    for arguments in [["sweep"], ["finish", allocation.id]] {
      let process = Process()
      let errors = Pipe()
      process.executableURL = URL(fileURLWithPath: legacy)
      process.arguments = ["--state-dir", fixture.registry.stateDirectory] + arguments
      process.standardOutput = FileHandle.nullDevice
      process.standardError = errors
      try process.run()
      process.waitUntilExit()
      XCTAssertNotEqual(process.terminationStatus, 0)
      XCTAssertTrue(
        String(decoding: try errors.fileHandleForReading.readToEnd() ?? Data(), as: UTF8.self)
          .contains("Unsupported registry version"))
      XCTAssertNotNil(try fixture.registry.inspect(allocation.id).owners["task:" + allocation.id])
      XCTAssertTrue(try isPresent(allocation.path))
    }
  }

  private func legacyAllocation(_ fixture: Fixture, isChangedInode: Bool = false) throws
    -> Allocation
  {
    let allocation = try fixture.registry.start(
      branch: UUID().uuidString, repository: fixture.repository, provider: .git)
    let common = try canonical(
      git(fixture.repository, ["rev-parse", "--path-format=absolute", "--git-common-dir"]))
    var info = stat()
    XCTAssertEqual(stat(common, &info), 0)
    let inode = isChangedInode ? info.st_ino + 1 : info.st_ino
    let identity = "\(common):\(info.st_dev + 1):\(inode)"
    try fixture.inject(allocation, overrides: ["repositoryIdentity": identity])
    let legacy = try fixture.registry.inspect(allocation.id)
    try JSONEncoder().encode([legacy.id, identity, legacy.path]).write(
      to: URL(fileURLWithPath: legacy.admin! + "/workfree-allocation"))
    return legacy
  }
}
