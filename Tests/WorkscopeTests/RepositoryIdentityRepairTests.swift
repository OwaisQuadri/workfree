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
      fixture.wait(try fixture.cli([
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
    XCTAssertThrowsError(try fixture.registry.repositoryCleanupPolicy(repository: fixture.repository))
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

  private func legacyAllocation(_ fixture: Fixture, isChangedInode: Bool = false) throws -> Allocation {
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
