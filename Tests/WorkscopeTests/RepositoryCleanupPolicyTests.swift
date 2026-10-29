import CSQLite
import Darwin
import Foundation
import XCTest

@testable import Workscope

final class RepositoryCleanupPolicyTests: XCTestCase {
  func testMissingPolicyNeverSynthesizesAuthorityOrReservesRequiredStart() throws {
    let fixture = try Fixture()
    XCTAssertNil(
      try fixture.registry.repositoryCleanupPolicy(repository: fixture.repository).policy)
    XCTAssertThrowsError(
      try fixture.registry.start(
        branch: "requires-policy", repository: fixture.repository, provider: .git,
        isCleanupPolicyRequired: true)
    ) { XCTAssertTrue(String(describing: $0).contains("wf cleanup-policy enable --repo PATH")) }
    XCTAssertTrue(try fixture.registry.list().isEmpty)
    let allocation = try start(fixture)
    _ = try fixture.registry.finish(allocation.id)
    _ = try fixture.registry.sweep()
    let retained = try fixture.registry.inspect(allocation.id)
    XCTAssertNil(retained.cleanupPolicy)
    XCTAssertNil(retained.cleanupPolicySourceID)
    XCTAssertFalse(retained.isCleanupAuthorized)
    XCTAssertNil(retained.eligibleSince)
    XCTAssertTrue(try isPresent(retained.path))
    XCTAssertTrue(
      try fixture.registry.preview(retained.id)[0].reasons.contains("Cleanup is not authorized"))
  }

  func testCreationSnapshotSurvivesReloadGraceAndExactDetachedRestore() throws {
    let fixture = try Fixture()
    let policy = try fixture.registry.enableRepositoryCleanupPolicy(repository: fixture.repository)
      .policy!
    XCTAssertEqual(policy.cleanupPolicy.graceSeconds, 60)
    XCTAssertTrue(policy.cleanupPolicy.disposablePaths.isEmpty)
    let allocation = try start(fixture)
    XCTAssertEqual(allocation.cleanupPolicySourceID, policy.id)
    XCTAssertFalse(allocation.isCleanupAuthorized)
    _ = try git(allocation.path, ["checkout", "--detach"])
    try Data("saved result".utf8).write(to: URL(fileURLWithPath: allocation.path + "/tracked"))
    _ = try git(allocation.path, ["commit", "-am", "Saved result"])
    let commit = try git(allocation.path, ["rev-parse", "HEAD"])
    let reloaded = try Registry(stateDirectory: fixture.registry.stateDirectory)
    _ = try reloaded.sweep()
    var eligible = try reloaded.inspect(allocation.id)
    XCTAssertNotNil(eligible.eligibleSince)
    XCTAssertTrue(try isPresent(allocation.path))
    eligible.eligibleSince = Date().addingTimeInterval(-61)
    try fixture.inject(eligible)
    _ = try reloaded.sweep()
    let removed = try reloaded.inspect(allocation.id)
    XCTAssertEqual(removed.phase, .removed, removed.reason ?? "")
    XCTAssertEqual(removed.recovery?.commit, commit)
    XCTAssertEqual(try git(fixture.repository, ["rev-parse", removed.recovery!.reference]), commit)
    XCTAssertNotNil(removed.owners["task:" + allocation.id])
    let restored = try reloaded.restore(allocation.id)
    XCTAssertEqual(try git(restored.path, ["rev-parse", "HEAD"]), commit)
    XCTAssertEqual(restored.cleanupPolicySourceID, policy.id)
    XCTAssertNil(restored.eligibleSince)
    XCTAssertEqual(
      try String(contentsOfFile: restored.path + "/tracked", encoding: .utf8), "saved result")
  }

  func testBeforePolicyUnrelatedAndReplacedRepositoriesNeverInherit() throws {
    let fixture = try Fixture()
    let before = try start(fixture)
    let policy = try fixture.registry.enableRepositoryCleanupPolicy(repository: fixture.repository)
      .policy!
    let inherited = try start(fixture)
    XCTAssertEqual(
      try fixture.registry.repositoryCleanupPolicy(repository: inherited.path).policy?.id, policy.id
    )
    let alias = fixture.root + "/alias"
    try FileManager.default.createSymbolicLink(
      atPath: alias, withDestinationPath: fixture.repository)
    XCTAssertEqual(
      try fixture.registry.repositoryCleanupPolicy(repository: alias).policy?.id, policy.id)
    let unrelated = try Fixture()
    let other = try fixture.registry.start(
      branch: UUID().uuidString, repository: unrelated.repository, provider: .git)
    XCTAssertEqual(inherited.cleanupPolicySourceID, policy.id)
    XCTAssertNil(other.cleanupPolicy)
    _ = try fixture.registry.sweep()
    XCTAssertNil(try fixture.registry.inspect(before.id).cleanupPolicy)
    let moved = fixture.root + "/previous-repo"
    try FileManager.default.moveItem(atPath: fixture.repository, toPath: moved)
    _ = try command("/usr/bin/git", ["clone", "--", moved, fixture.repository])
    XCTAssertNil(
      try fixture.registry.repositoryCleanupPolicy(repository: fixture.repository).policy)
    XCTAssertNil(try start(fixture).cleanupPolicy)
  }

  func testAllocationRevokeAndRestoreNeverReenrollUnderStandingPolicy() throws {
    let fixture = try Fixture()
    _ = try fixture.registry.enableRepositoryCleanupPolicy(
      repository: fixture.repository, graceSeconds: 0)
    XCTAssertEqual(
      fixture.wait(
        try fixture.cli([
          "start", "legacy-revoke", "--repo", fixture.repository, "--provider", "git",
          "--allow-cleanup",
        ])), 0)
    let revoked = try fixture.registry.list()[0]
    XCTAssertTrue(revoked.isCleanupAuthorized)
    XCTAssertNotNil(revoked.cleanupPolicy)
    XCTAssertNotNil(revoked.cleanupPolicySourceID)
    let cleared = try fixture.registry.revokeCleanup(revoked.id)
    XCTAssertFalse(cleared.isCleanupAuthorized)
    XCTAssertNil(cleared.cleanupPolicy)
    XCTAssertNil(cleared.cleanupPolicySourceID)
    XCTAssertNil(cleared.eligibleSince)
    _ = try fixture.registry.finish(revoked.id)
    _ = try fixture.registry.sweep()
    XCTAssertNil(try fixture.registry.inspect(revoked.id).cleanupPolicySourceID)
    XCTAssertTrue(try isPresent(revoked.path))
    let removed = try start(fixture)
    _ = try fixture.registry.sweep()
    XCTAssertEqual(try fixture.registry.inspect(removed.id).phase, .removed)
    _ = try fixture.registry.revokeCleanup(removed.id)
    let restored = try fixture.registry.restore(removed.id)
    _ = try fixture.registry.sweep()
    XCTAssertNil(try fixture.registry.inspect(restored.id).cleanupPolicy)
    XCTAssertNil(restored.cleanupPolicySourceID)
    XCTAssertTrue(try isPresent(restored.path))
  }

  func testRepositoryRevokePreservesLegacyCLIGrantAcrossReloadButClearsDerivedAuthority() throws {
    let fixture = try Fixture()
    XCTAssertEqual(
      fixture.wait(
        try fixture.cli(["cleanup-policy", "enable", "--repo", fixture.repository])), 0)
    XCTAssertEqual(
      fixture.wait(
        try fixture.cli([
          "start", "legacy", "--repo", fixture.repository, "--provider", "git", "--allow-cleanup",
        ])), 0)
    let legacy = try fixture.registry.list()[0]
    XCTAssertTrue(legacy.isCleanupAuthorized)
    let derived = try start(fixture)
    let reloaded = try Registry(stateDirectory: fixture.registry.stateDirectory)
    _ = try reloaded.sweep()
    for allocation in [legacy, derived] {
      let eligible = try reloaded.inspect(allocation.id)
      XCTAssertNotNil(eligible.cleanupPolicy)
      XCTAssertNotNil(eligible.cleanupPolicySourceID)
      XCTAssertNotNil(eligible.eligibleSince)
    }
    XCTAssertEqual(
      fixture.wait(
        try fixture.cli(["cleanup-policy", "revoke", "--repo", fixture.repository])), 0)
    let afterRevoke = try Registry(stateDirectory: fixture.registry.stateDirectory)
    for allocation in [legacy, derived] {
      let cleared = try afterRevoke.inspect(allocation.id)
      XCTAssertNil(cleared.cleanupPolicy)
      XCTAssertNil(cleared.cleanupPolicySourceID)
      XCTAssertNil(cleared.eligibleSince)
      XCTAssertEqual(cleared.isCleanupAuthorized, allocation.isCleanupAuthorized)
      XCTAssertEqual(Set(cleared.owners.keys), Set(allocation.owners.keys))
      XCTAssertEqual(cleared.cleanupAttempts?.last?.event, "repository-policy-revoke")
      XCTAssertEqual(cleared.cleanupAttempts?.last?.reasons, ["Repository cleanup policy revoked"])
    }
    XCTAssertFalse(
      try afterRevoke.preview(legacy.id)[0].reasons.contains("Cleanup is not authorized"))
    XCTAssertTrue(
      try afterRevoke.preview(derived.id)[0].reasons.contains("Cleanup is not authorized"))
    _ = try afterRevoke.finish(legacy.id)
    _ = try afterRevoke.finish(derived.id)
    _ = try afterRevoke.sweep()
    XCTAssertEqual(try afterRevoke.inspect(legacy.id).phase, .removed)
    let retained = try afterRevoke.inspect(derived.id)
    XCTAssertFalse(retained.isCleanupAuthorized)
    XCTAssertNil(retained.cleanupPolicy)
    XCTAssertTrue(try isPresent(retained.path))
  }

  func testRepositoryRevokeClearsOnlyDerivedGrantsAndNewGenerationNeverBackfills() throws {
    let fixture = try Fixture()
    let policy = try fixture.registry.enableRepositoryCleanupPolicy(repository: fixture.repository)
      .policy!
    XCTAssertEqual(
      try fixture.registry.enableRepositoryCleanupPolicy(repository: fixture.repository).policy?.id,
      policy.id)
    XCTAssertThrowsError(
      try fixture.registry.enableRepositoryCleanupPolicy(
        repository: fixture.repository, graceSeconds: 0))
    let derived = try start(fixture)
    let explicit = try start(fixture)
    _ = try fixture.registry.authorizeCleanup(explicit.id, graceSeconds: 120)
    XCTAssertNil(try fixture.registry.inspect(explicit.id).cleanupPolicySourceID)
    _ = try fixture.registry.sweep()
    XCTAssertNotNil(try fixture.registry.inspect(derived.id).eligibleSince)
    _ = try fixture.registry.revokeRepositoryCleanupPolicy(repository: fixture.repository)
    let reloaded = try Registry(stateDirectory: fixture.registry.stateDirectory)
    let cleared = try reloaded.inspect(derived.id)
    XCTAssertNil(cleared.cleanupPolicy)
    XCTAssertNil(cleared.cleanupPolicySourceID)
    XCTAssertNil(cleared.eligibleSince)
    XCTAssertFalse(cleared.isCleanupAuthorized)
    XCTAssertEqual(Set(cleared.owners.keys), Set(derived.owners.keys))
    XCTAssertEqual(try reloaded.inspect(explicit.id).cleanupPolicy?.graceSeconds, 120)
    XCTAssertNil(try start(fixture).cleanupPolicy)
    let next = try reloaded.enableRepositoryCleanupPolicy(repository: fixture.repository).policy!
    XCTAssertNotEqual(next.id, policy.id)
    _ = try reloaded.sweep()
    XCTAssertNil(try reloaded.inspect(derived.id).cleanupPolicy)
    XCTAssertEqual(try start(fixture).cleanupPolicySourceID, next.id)
    XCTAssertTrue(try isPresent(derived.path))
  }

  func testRepositoryRevokeRollsBackEveryDerivedGrantAndRejectsPendingRemoval() throws {
    let fixture = try Fixture()
    let policy = try fixture.registry.enableRepositoryCleanupPolicy(repository: fixture.repository)
      .policy!
    let first = try start(fixture)
    let second = try start(fixture)
    _ = try fixture.registry.sweep()
    try sql(
      fixture,
      "CREATE TRIGGER reject_policy_delete BEFORE DELETE ON repository_cleanup_policies BEGIN SELECT RAISE(ABORT, 'injected revoke failure'); END"
    )
    XCTAssertThrowsError(
      try fixture.registry.revokeRepositoryCleanupPolicy(repository: fixture.repository))
    for id in [first.id, second.id] {
      let unchanged = try fixture.registry.inspect(id)
      XCTAssertEqual(unchanged.cleanupPolicySourceID, policy.id)
      XCTAssertNotNil(unchanged.cleanupPolicy)
      XCTAssertNotNil(unchanged.eligibleSince)
    }
    XCTAssertEqual(
      try fixture.registry.repositoryCleanupPolicy(repository: fixture.repository).policy?.id,
      policy.id)
    try sql(fixture, "DROP TRIGGER reject_policy_delete")
    var pending = try fixture.registry.inspect(second.id)
    pending.isRemovalPending = true
    pending.phase = .removing
    try fixture.inject(pending)
    XCTAssertThrowsError(
      try fixture.registry.revokeRepositoryCleanupPolicy(repository: fixture.repository))
    XCTAssertEqual(try fixture.registry.inspect(first.id).cleanupPolicySourceID, policy.id)
    XCTAssertEqual(
      try fixture.registry.repositoryCleanupPolicy(repository: fixture.repository).policy?.id,
      policy.id)
  }

  func testRepositoryRevokePreservesRecoveryAndRestorationDoesNotReenroll() throws {
    let fixture = try Fixture()
    _ = try fixture.registry.enableRepositoryCleanupPolicy(
      repository: fixture.repository, graceSeconds: 0)
    let allocation = try start(fixture)
    _ = try fixture.registry.sweep()
    let removed = try fixture.registry.inspect(allocation.id)
    _ = try fixture.registry.revokeRepositoryCleanupPolicy(repository: fixture.repository)
    _ = try fixture.registry.enableRepositoryCleanupPolicy(
      repository: fixture.repository, graceSeconds: 0)
    let restored = try fixture.registry.restore(allocation.id)
    XCTAssertEqual(restored.recovery?.reference, removed.recovery?.reference)
    XCTAssertNil(restored.cleanupPolicy)
    _ = try fixture.registry.sweep()
    XCTAssertTrue(try isPresent(restored.path))
  }

  func testInheritedPolicyPreservesActiveOwnersConversationsAndUnsavedFiles() throws {
    let fixture = try Fixture()
    _ = try fixture.registry.enableRepositoryCleanupPolicy(
      repository: fixture.repository, graceSeconds: 0)
    let owned = try start(fixture)
    _ = try fixture.registry.retain(owned.id, owner: "workspace", kind: .workspace)
    _ = try fixture.registry.retain(owned.id, owner: "execution", kind: .execution)
    _ = try fixture.registry.keep(owned.id)
    _ = try fixture.registry.entryExit(owned.id, owner: "execution", status: 0)
    _ = try fixture.registry.sweep()
    XCTAssertEqual(try fixture.registry.preview(owned.id)[0].reasons.count, 3)
    _ = try fixture.registry.release(owned.id, owner: "workspace")
    _ = try fixture.registry.closeScope(owned.id, owner: "execution")
    XCTAssertTrue(try isPresent(owned.path))
    XCTAssertEqual(try fixture.registry.unkeep(owned.id).phase, .removed)
    let conversation = try Registry(
      stateDirectory: fixture.registry.stateDirectory,
      conversation: ConversationContext(sessionID: "live", processID: getpid()))
    let live = try conversation.start(
      branch: "live", repository: fixture.repository, provider: .git)
    var uncertain = try start(fixture)
    uncertain.conversationClaims = [
      ConversationClaim(
        sessionID: "uncertain", processID: 0, bootIdentity: "", startSeconds: 0,
        startMicroseconds: 0)
    ]
    try fixture.inject(uncertain)
    let reloaded = try Registry(stateDirectory: fixture.registry.stateDirectory)
    _ = try reloaded.sweep()
    for allocation in [live, uncertain] {
      XCTAssertTrue(try isPresent(allocation.path))
      XCTAssertTrue(
        try reloaded.preview(allocation.id)[0].reasons.contains {
          $0.contains("Retained conversation")
        })
    }
    for relative in ["tracked", "untracked", "ignored/private"] {
      let allocation = try start(fixture)
      try FileManager.default.createDirectory(
        atPath: allocation.path + "/ignored", withIntermediateDirectories: true)
      try Data("preserve".utf8).write(to: URL(fileURLWithPath: allocation.path + "/" + relative))
      _ = try reloaded.sweep()
      XCTAssertTrue(try isPresent(allocation.path + "/" + relative))
      XCTAssertNotEqual(try reloaded.inspect(allocation.id).phase, .removed)
    }
  }

  func testStableIdentityFormatAndConversationSavesNeverDowngrade() throws {
    let fixture = try Fixture()
    let before = try start(fixture)
    XCTAssertEqual(try version(fixture), "5")
    XCTAssertNil(
      try Registry(stateDirectory: fixture.registry.stateDirectory).inspect(before.id).cleanupPolicy
    )
    let conversation = try Registry(
      stateDirectory: fixture.registry.stateDirectory,
      conversation: ConversationContext(sessionID: "live", processID: getpid()))
    _ = try conversation.claim(before.id)
    XCTAssertEqual(try version(fixture), "5")
    _ = try fixture.registry.enableRepositoryCleanupPolicy(repository: fixture.repository)
    XCTAssertEqual(try version(fixture), "5")
    _ = try conversation.claim(before.id)
    _ = try fixture.registry.revokeRepositoryCleanupPolicy(repository: fixture.repository)
    _ = try fixture.registry.sweep()
    XCTAssertEqual(try version(fixture), "5")
    XCTAssertNil(try fixture.registry.inspect(before.id).cleanupPolicy)
  }

  func testFailedFirstPolicySaveRollsBackFormatAndMismatchedIdentityCannotGrant() throws {
    let fixture = try Fixture()
    _ = try fixture.registry.list()
    try sql(
      fixture, "CREATE TABLE repository_cleanup_policies (repository_identity TEXT PRIMARY KEY)")
    XCTAssertThrowsError(
      try fixture.registry.enableRepositoryCleanupPolicy(repository: fixture.repository))
    XCTAssertEqual(try version(fixture), "1")
    XCTAssertNil(
      try fixture.registry.repositoryCleanupPolicy(repository: fixture.repository).policy)
    try sql(fixture, "DROP TABLE repository_cleanup_policies")
    _ = try fixture.registry.enableRepositoryCleanupPolicy(repository: fixture.repository)
    try sql(
      fixture,
      "UPDATE repository_cleanup_policies SET data=json_set(data, '$.repositoryIdentity', 'replaced')"
    )
    XCTAssertThrowsError(try start(fixture))
    XCTAssertThrowsError(
      try fixture.registry.repositoryCleanupPolicy(repository: fixture.repository))
    XCTAssertTrue(try fixture.registry.list().isEmpty)
  }

  func testVersionTwoBinaryRejectsPolicyBeforeCleanupOrMutation() throws {
    guard let legacy = ProcessInfo.processInfo.environment["WORKFREE_V2_EXECUTABLE"] else {
      throw XCTSkip("Set WORKFREE_V2_EXECUTABLE to a verified version-2 wf build")
    }
    let fixture = try Fixture()
    let allocation = try start(fixture)
    _ = try fixture.registry.enableRepositoryCleanupPolicy(repository: fixture.repository)
    for args in [
      ["sweep"], ["finish", allocation.id],
      ["retain", allocation.id, "--owner", "old", "--kind", "workspace"],
    ] {
      let errors = Pipe()
      let process = Process()
      process.executableURL = URL(fileURLWithPath: legacy)
      process.arguments = ["--state-dir", fixture.registry.stateDirectory, "--json"] + args
      process.standardOutput = FileHandle.nullDevice
      process.standardError = errors
      try process.run()
      process.waitUntilExit()
      XCTAssertNotEqual(process.terminationStatus, 0)
      let error = String(
        decoding: try errors.fileHandleForReading.readToEnd() ?? Data(), as: UTF8.self)
      XCTAssertTrue(error.contains("Unsupported registry version"), error)
      XCTAssertNotNil(try fixture.registry.inspect(allocation.id).owners["task:" + allocation.id])
      XCTAssertTrue(try isPresent(allocation.path))
    }
  }

  private func start(_ fixture: Fixture) throws -> Allocation {
    try fixture.registry.start(
      branch: UUID().uuidString, repository: fixture.repository, provider: .git)
  }

  private func sql(_ fixture: Fixture, _ statement: String) throws {
    var database: OpaquePointer?
    try require(
      sqlite3_open(fixture.registry.stateDirectory + "/registry.sqlite", &database) == SQLITE_OK,
      "Cannot open test registry")
    defer { sqlite3_close(database) }
    try require(
      sqlite3_exec(database, statement, nil, nil, nil) == SQLITE_OK, "Cannot execute test SQL")
  }

  private func version(_ fixture: Fixture) throws -> String {
    var database: OpaquePointer?
    try require(
      sqlite3_open(fixture.registry.stateDirectory + "/registry.sqlite", &database) == SQLITE_OK,
      "Cannot open test registry")
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    try require(
      sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
      "Cannot inspect version")
    defer { sqlite3_finalize(statement) }
    try require(sqlite3_step(statement) == SQLITE_ROW, "Missing version")
    return String(sqlite3_column_int(statement, 0))
  }
}
