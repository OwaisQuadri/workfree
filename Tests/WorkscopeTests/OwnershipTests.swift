import Foundation
import XCTest

@testable import Workscope

final class OwnershipTests: XCTestCase {
  func testDuplicateReleaseCannotRemoveAnotherOwnerOrReuseRetiredTokens() throws {
    let fixture = try Fixture()
    let allocation = try fixture.start("owned-result")
    _ = try fixture.registry.retain(allocation.id, owner: "reader", kind: .workspace)
    let duplicate = try fixture.registry.retain(allocation.id, owner: "reader", kind: .workspace)
    XCTAssertEqual(duplicate.owners.count, 2)
    _ = try fixture.registry.finish(allocation.id)
    let remaining = try fixture.registry.finish(allocation.id)
    XCTAssertEqual(Set(remaining.owners.keys), ["reader"])
    XCTAssertTrue(FileManager.default.fileExists(atPath: allocation.path))
    XCTAssertThrowsError(
      try fixture.registry.retain(allocation.id, owner: "task:\(allocation.id)", kind: .task))
    XCTAssertEqual(try fixture.registry.release(allocation.id, owner: "reader").phase, .removed)
    XCTAssertFalse(FileManager.default.fileExists(atPath: allocation.path))
    XCTAssertFalse(try registeredPaths(fixture.repository).contains(allocation.path))
    XCTAssertEqual(try fixture.registry.finish(allocation.id).phase, .removed)
    XCTAssertFalse(
      try git(fixture.repository, ["show-ref", "--verify", "refs/heads/owned-result"]).isEmpty)
    let other = try fixture.start()
    XCTAssertThrowsError(try fixture.registry.retain(other.id, owner: "reader", kind: .workspace))
  }

  func testWorkspaceFinishPinAndExecutionLifetimesStayDistinct() throws {
    let fixture = try Fixture()
    let allocation = try fixture.start()
    _ = try fixture.registry.retain(allocation.id, owner: "window", kind: .workspace)
    _ = try fixture.registry.retain(allocation.id, owner: "scope", kind: .execution)
    _ = try fixture.registry.keep(allocation.id)
    XCTAssertThrowsError(try fixture.registry.finish(allocation.id, owner: "window"))
    XCTAssertThrowsError(try fixture.registry.closeScope(allocation.id, owner: "window"))
    _ = try fixture.registry.release(allocation.id, owner: "window")
    _ = try fixture.registry.finish(allocation.id)
    _ = try fixture.registry.entryExit(allocation.id, owner: "scope", status: 19)
    XCTAssertThrowsError(try fixture.registry.release(allocation.id, owner: "scope"))
    let retained = try fixture.registry.recover(allocation.id)
    XCTAssertEqual(retained.owners["scope"]?.entryStatus, 19)
    XCTAssertEqual(retained.owners.count, 2)
    _ = try fixture.registry.closeScope(allocation.id, owner: "scope")
    let removed = try fixture.registry.unkeep(allocation.id)
    XCTAssertEqual(removed.phase, .removed)
    XCTAssertEqual(removed.retiredOwners["scope"]?.isCooperativelyClosed, true)
    XCTAssertThrowsError(try fixture.registry.keep(allocation.id))
  }

  func testKeepUnkeepKeepUsesFreshDefaultPinWithoutReleasingUnrelatedPins() throws {
    let fixture = try Fixture()
    let allocation = try fixture.registry.start(
      branch: "reversible-pin", repository: fixture.repository, isCleanupAuthorized: true,
      provider: .git)
    _ = try fixture.registry.retain(allocation.id, owner: "personal-pin", kind: .pin)
    let first = try fixture.registry.keep(allocation.id)
    let firstToken = try XCTUnwrap(first.defaultPinToken)
    XCTAssertEqual(firstToken, "pin:\(allocation.id)")
    _ = try fixture.registry.unkeep(allocation.id)
    let second = try fixture.registry.keep(allocation.id)
    let secondToken = try XCTUnwrap(second.defaultPinToken)
    XCTAssertNotEqual(firstToken, secondToken)
    XCTAssertEqual(try fixture.registry.keep(allocation.id).defaultPinToken, secondToken)
    XCTAssertNotNil(second.owners["task:\(allocation.id)"])
    XCTAssertNotNil(second.owners["personal-pin"])
    XCTAssertEqual(second.owners.count, 3)
    XCTAssertThrowsError(try fixture.registry.retain(allocation.id, owner: firstToken, kind: .pin))
    _ = try fixture.registry.unkeep(allocation.id)
    let remaining = try fixture.registry.unkeep(allocation.id)
    XCTAssertEqual(Set(remaining.owners.keys), ["task:\(allocation.id)", "personal-pin"])
    XCTAssertEqual(try fixture.registry.finish(allocation.id).phase, .retained)
    XCTAssertEqual(
      try fixture.registry.release(allocation.id, owner: "personal-pin").phase, .removed)
  }

  func testOmittedAndInvalidPermissionNeverAuthorizeDeletion() throws {
    let fixture = try Fixture()
    let allocation = try fixture.registry.start(branch: "default", repository: fixture.repository)
    XCTAssertFalse(allocation.isCleanupAuthorized)
    let blocked = try fixture.registry.finish(allocation.id)
    XCTAssertEqual(blocked.phase, .blocked)
    XCTAssertEqual(blocked.reason, "Cleanup is not authorized")
    XCTAssertTrue(FileManager.default.fileExists(atPath: allocation.path))
    let invalid = try fixture.cli([
      "start", "invalid", "--repo", fixture.repository, "--allow-cleanup=true",
    ])
    XCTAssertNotEqual(fixture.wait(invalid), 0)
    let invalidValue = try fixture.cli([
      "start", "invalid", "--repo", fixture.repository, "--allow-cleanup", "typo",
    ])
    XCTAssertNotEqual(fixture.wait(invalidValue), 0)
    XCTAssertEqual(try fixture.registry.list().count, 1)
  }

  func testExplicitExistingPathAndTombstoneCannotAdoptAnotherCheckout() throws {
    let fixture = try Fixture()
    let path = fixture.root + "/unmanaged"
    _ = try command(
      "/usr/bin/env", ["simgit", "add", "unmanaged", "--path", path, "--require-cow"],
      at: fixture.repository)
    XCTAssertThrowsError(
      try fixture.registry.start(branch: "wrong", repository: fixture.repository, path: path))
    XCTAssertTrue(try fixture.registry.list().isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    let allocation = try fixture.start()
    _ = try fixture.registry.finish(allocation.id)
    XCTAssertThrowsError(
      try fixture.registry.start(
        branch: "reuse", repository: fixture.repository, path: allocation.path))
    XCTAssertThrowsError(
      try fixture.registry.start(
        branch: "inside", repository: fixture.repository, path: fixture.repository + "/inside"))
  }

  func testMissingCaseAliasCannotBypassAnEarlierPathReservation() throws {
    let fixture = try Fixture()
    let path = fixture.root + "/Reserved-Target"
    XCTAssertThrowsError(
      try fixture.registry.start(
        branch: "failed", repository: fixture.repository, base: "missing-ref", path: path))
    XCTAssertThrowsError(
      try fixture.registry.start(
        branch: "collision", repository: fixture.repository, path: fixture.root + "/reserved-target"
      ))
    XCTAssertEqual(try fixture.registry.list().count, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: path))
  }

  func testCreationFailureKeepsReservationAndTaskForInspection() throws {
    let fixture = try Fixture()
    XCTAssertThrowsError(
      try fixture.registry.start(
        branch: "bad", repository: fixture.repository, base: "does-not-exist"))
    let allocations = try fixture.registry.list()
    XCTAssertEqual(allocations.count, 1)
    XCTAssertEqual(allocations[0].phase, .failed)
    XCTAssertEqual(allocations[0].owners.count, 1)
    XCTAssertEqual(try fixture.registry.recover(allocations[0].id).phase, .failed)
    XCTAssertThrowsError(
      try fixture.registry.start(
        branch: "retry", repository: fixture.repository, path: allocations[0].path))
  }
}
