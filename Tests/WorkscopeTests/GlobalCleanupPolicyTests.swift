import CSQLite
import Foundation
import XCTest

@testable import Workscope

final class GlobalCleanupPolicyTests: XCTestCase {
  func testGlobalAuthorityCoversUnlistedRepositoriesButNotExclusions() throws {
    let fixture = try Fixture()
    let other = try Fixture()
    let policy = try fixture.registry.enableGlobalCleanupPolicy().policy!
    let allocation = try fixture.registry.start(
      branch: "global", repository: other.repository, provider: .git)
    XCTAssertEqual(allocation.cleanupPolicySourceID, policy.id)
    XCTAssertTrue(allocation.cleanupPolicy!.disposablePaths.isEmpty)
    _ = try fixture.registry.excludeRepositoryFromCleanup(repository: other.repository)
    XCTAssertNil(try fixture.registry.inspect(allocation.id).cleanupPolicy)
    let excluded = try fixture.registry.start(
      branch: "excluded", repository: other.repository, provider: .git)
    XCTAssertNil(excluded.cleanupPolicy)
    _ = try fixture.registry.excludeRepositoryFromCleanup(
      repository: other.repository, isExcluded: false)
    let included = try fixture.registry.start(
      branch: "included", repository: other.repository, provider: .git)
    XCTAssertEqual(included.cleanupPolicySourceID, policy.id)
    XCTAssertNil(try fixture.registry.inspect(excluded.id).cleanupPolicy)
    let reloaded = try Registry(stateDirectory: fixture.registry.stateDirectory)
    XCTAssertEqual(try reloaded.globalCleanupPolicy().policy?.id, policy.id)
    XCTAssertEqual(try reloaded.enableGlobalCleanupPolicy().policy?.id, policy.id)
  }

  func testMigrationNeverReenrollsRevocationsOrOverridesExplicitGrants() throws {
    let fixture = try Fixture()
    let existing = try fixture.registry.start(
      branch: "existing", repository: fixture.repository, provider: .git)
    let revoked = try fixture.registry.start(
      branch: "revoked", repository: fixture.repository, provider: .git)
    _ = try fixture.registry.revokeCleanup(revoked.id)
    let explicit = try fixture.registry.start(
      branch: "explicit", repository: fixture.repository, provider: .git)
    _ = try fixture.registry.authorizeCleanup(explicit.id, graceSeconds: 120)
    let policy = try fixture.registry.enableGlobalCleanupPolicy(graceSeconds: 0).policy!
    XCTAssertNil(try fixture.registry.inspect(existing.id).cleanupPolicy)
    XCTAssertEqual(try fixture.registry.migrateGlobalCleanupPolicy().map(\.id), [existing.id])
    XCTAssertTrue(try fixture.registry.migrateGlobalCleanupPolicy().isEmpty)
    XCTAssertEqual(try fixture.registry.inspect(existing.id).cleanupPolicySourceID, policy.id)
    XCTAssertNil(try fixture.registry.inspect(existing.id).eligibleSince)
    XCTAssertNil(try fixture.registry.inspect(revoked.id).cleanupPolicy)
    XCTAssertEqual(try fixture.registry.inspect(explicit.id).cleanupPolicy?.graceSeconds, 120)
    _ = try fixture.registry.sweep()
    let removed = try fixture.registry.inspect(existing.id)
    XCTAssertEqual(removed.phase, .removed, removed.reason ?? "")
    XCTAssertNotNil(removed.recovery)
    XCTAssertNotNil(removed.owners["task:" + existing.id])
    XCTAssertTrue(try isPresent(revoked.path))
    let restored = try fixture.registry.restore(existing.id)
    XCTAssertEqual(try git(restored.path, ["rev-parse", "HEAD"]), removed.recovery?.commit)
  }

  func testGlobalRevokePreservesIndependentPoliciesAndRefusesPendingRemoval() throws {
    let fixture = try Fixture()
    _ = try fixture.registry.enableGlobalCleanupPolicy()
    let global = try fixture.registry.start(
      branch: "global", repository: fixture.repository, provider: .git)
    _ = try fixture.registry.enableRepositoryCleanupPolicy(
      repository: fixture.repository, graceSeconds: 120)
    let repository = try fixture.registry.start(
      branch: "repository", repository: fixture.repository, provider: .git)
    var pending = global
    pending.isRemovalPending = true
    try fixture.inject(pending)
    XCTAssertThrowsError(try fixture.registry.revokeGlobalCleanupPolicy())
    XCTAssertNotNil(try fixture.registry.globalCleanupPolicy().policy)
    XCTAssertThrowsError(
      try fixture.registry.excludeRepositoryFromCleanup(repository: fixture.repository))
    XCTAssertTrue(try fixture.registry.globalCleanupPolicy().excludedRepositories.isEmpty)
    pending.isRemovalPending = false
    try fixture.inject(pending)
    _ = try fixture.registry.revokeGlobalCleanupPolicy()
    XCTAssertNil(try fixture.registry.inspect(global.id).cleanupPolicy)
    XCTAssertEqual(try fixture.registry.inspect(repository.id).cleanupPolicy?.graceSeconds, 120)
    _ = try fixture.registry.enableGlobalCleanupPolicy()
    XCTAssertTrue(try fixture.registry.migrateGlobalCleanupPolicy().isEmpty)
  }

  func testCommandLineRejectsAmbiguousScopeAndPersistsExclusions() throws {
    let fixture = try Fixture()
    for arguments in [
      ["cleanup-policy", "enable", "--global", "--repo", fixture.repository],
      ["cleanup-policy", "exclude", "--global"],
      ["cleanup-policy", "migrate", "--repo", fixture.repository],
      ["cleanup-policy", "show", "--global", "--grace-seconds", "0"],
    ] {
      XCTAssertNotEqual(fixture.wait(try fixture.cli(arguments)), 0)
    }
    for arguments in [
      ["cleanup-policy", "enable", "--global"],
      ["cleanup-policy", "exclude", "--repo", fixture.repository],
      ["cleanup-policy", "show", "--global"],
      ["cleanup-policy", "migrate", "--global"],
    ] {
      XCTAssertEqual(fixture.wait(try fixture.cli(arguments)), 0)
    }
    XCTAssertEqual(
      try fixture.registry.globalCleanupPolicy().excludedRepositories, [fixture.repository])
  }

  func testMigrationRollsBackEveryGrantWhenOneIdentityFails() throws {
    let fixture = try Fixture()
    let first = try fixture.registry.start(
      branch: "first", repository: fixture.repository, provider: .git)
    let second = try fixture.registry.start(
      branch: "second", repository: fixture.repository, provider: .git)
    let ordered = [first, second].sorted { $0.id < $1.id }
    _ = try fixture.registry.enableGlobalCleanupPolicy()
    try Data("invalid".utf8).write(
      to: URL(fileURLWithPath: ordered[1].admin! + "/workfree-allocation"))
    XCTAssertThrowsError(try fixture.registry.migrateGlobalCleanupPolicy())
    let reloaded = try Registry(stateDirectory: fixture.registry.stateDirectory)
    for allocation in ordered {
      let saved = try reloaded.inspect(allocation.id)
      XCTAssertNil(saved.cleanupPolicy)
      XCTAssertNil(saved.cleanupPolicySourceID)
      XCTAssertNil(saved.eligibleSince)
      XCTAssertNil(saved.cleanupAttempts)
      XCTAssertTrue(try isPresent(saved.path))
    }
  }

  func testGlobalFormatNeverDowngradesAndFailedSetupRollsBack() throws {
    let fixture = try Fixture()
    _ = try fixture.registry.list()
    try sql(fixture, "CREATE TABLE global_cleanup_policy (singleton INTEGER PRIMARY KEY)")
    XCTAssertThrowsError(try fixture.registry.enableGlobalCleanupPolicy())
    XCTAssertEqual(try sql(fixture, "PRAGMA user_version"), 1)
    try sql(fixture, "DROP TABLE global_cleanup_policy")
    _ = try fixture.registry.excludeRepositoryFromCleanup(repository: fixture.repository)
    XCTAssertEqual(try sql(fixture, "PRAGMA user_version"), 4)
    _ = try fixture.registry.enableGlobalCleanupPolicy()
    _ = try fixture.registry.enableRepositoryCleanupPolicy(repository: fixture.repository)
    _ = try fixture.registry.excludeRepositoryFromCleanup(
      repository: fixture.repository, isExcluded: false)
    _ = try fixture.registry.revokeGlobalCleanupPolicy()
    _ = try fixture.registry.revokeRepositoryCleanupPolicy(repository: fixture.repository)
    let allocation = try fixture.registry.start(
      branch: "conversation", repository: fixture.repository, provider: .git)
    let conversation = try Registry(
      stateDirectory: fixture.registry.stateDirectory,
      conversation: ConversationContext(
        sessionID: "global-format", processID: ProcessInfo.processInfo.processIdentifier))
    _ = try conversation.claim(allocation.id)
    _ = try fixture.registry.sweep()
    XCTAssertEqual(try sql(fixture, "PRAGMA user_version"), 4)
    XCTAssertNil(try fixture.registry.globalCleanupPolicy().policy)
  }

  func testVersionThreeBinaryRejectsGlobalPolicyBeforeCleanupOrMutation() throws {
    guard let legacy = ProcessInfo.processInfo.environment["WORKFREE_V3_EXECUTABLE"] else {
      throw XCTSkip("Set WORKFREE_V3_EXECUTABLE to a verified version-3 wf build")
    }
    let fixture = try Fixture()
    _ = try fixture.registry.enableRepositoryCleanupPolicy(repository: fixture.repository)
    let allocation = try fixture.registry.start(
      branch: "compatible", repository: fixture.repository, provider: .git)
    _ = try command(
      legacy, ["--state-dir", fixture.registry.stateDirectory, "inspect", allocation.id])
    _ = try fixture.registry.enableGlobalCleanupPolicy()
    for arguments in [
      ["sweep"], ["finish", allocation.id],
      ["retain", allocation.id, "--owner", "old", "--kind", "workspace"],
    ] {
      let errors = Pipe()
      let process = Process()
      process.executableURL = URL(fileURLWithPath: legacy)
      process.arguments = ["--state-dir", fixture.registry.stateDirectory, "--json"] + arguments
      process.standardOutput = FileHandle.nullDevice
      process.standardError = errors
      try process.run()
      process.waitUntilExit()
      XCTAssertNotEqual(process.terminationStatus, 0)
      let error = String(
        decoding: try errors.fileHandleForReading.readToEnd() ?? Data(), as: UTF8.self)
      XCTAssertTrue(error.contains("Unsupported registry version"), error)
      XCTAssertNotNil(try fixture.registry.inspect(allocation.id).owners["task:" + allocation.id])
      XCTAssertNil(try fixture.registry.inspect(allocation.id).owners["old"])
      XCTAssertTrue(try isPresent(allocation.path))
    }
  }

  @discardableResult
  private func sql(_ fixture: Fixture, _ query: String) throws -> Int32 {
    var database: OpaquePointer?
    try require(
      sqlite3_open(fixture.registry.stateDirectory + "/registry.sqlite", &database) == SQLITE_OK,
      "Cannot open test registry")
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    try require(
      sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
      "Cannot prepare test statement")
    defer { sqlite3_finalize(statement) }
    let result = sqlite3_step(statement)
    try require(result == SQLITE_ROW || result == SQLITE_DONE, "Cannot execute test statement")
    return sqlite3_column_int(statement, 0)
  }
}
