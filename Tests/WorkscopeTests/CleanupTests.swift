import Foundation
import XCTest

@testable import Workscope

final class CleanupTests: XCTestCase {
  func testPolicyEvictsSavedTaskAndRestoresExactDetachedCommit() throws {
    let fixture = try Fixture()
    for provider in [WorktreeProvider.git, .simgit] {
      let allocation = try fixture.registry.start(
        branch: UUID().uuidString, repository: fixture.repository, provider: provider)
      _ = try git(allocation.path, ["checkout", "--detach"])
      try Data("saved result".utf8).write(to: URL(fileURLWithPath: allocation.path + "/tracked"))
      _ = try git(allocation.path, ["commit", "-am", "Saved result"])
      let commit = try git(allocation.path, ["rev-parse", "HEAD"])
      _ = try fixture.registry.authorizeCleanup(allocation.id, graceSeconds: 0)
      XCTAssertEqual(try fixture.registry.preview(allocation.id).first?.isEligible, true)
      XCTAssertTrue(FileManager.default.fileExists(atPath: allocation.path))
      _ = try fixture.registry.sweep()
      let removed = try fixture.registry.inspect(allocation.id)
      XCTAssertEqual(removed.phase, .removed, removed.reason ?? "")
      _ = try command(
        "/usr/bin/git",
        [
          "-C", fixture.repository, "merge-base", "--is-ancestor", commit,
          removed.recovery!.commit,
        ])
      XCTAssertNotNil(removed.owners["task:" + allocation.id])
      XCTAssertFalse(FileManager.default.fileExists(atPath: allocation.path))
      _ = try fixture.registry.sweep()
      XCTAssertEqual(
        try fixture.registry.inspect(allocation.id).recovery?.reference, removed.recovery?.reference
      )
      let count = try fixture.registry.status(since: nil, isLiveMeasured: false).removedCount
      _ = try fixture.registry.restore(allocation.id)
      XCTAssertEqual(
        try fixture.registry.status(since: nil, isLiveMeasured: false).removedCount, count)
      XCTAssertEqual(try git(allocation.path, ["rev-parse", "HEAD"]), removed.recovery?.commit)
      XCTAssertEqual(
        try String(contentsOfFile: allocation.path + "/tracked", encoding: .utf8), "saved result")
    }
  }

  func testWorkspaceExecutionAndPinsBlockPolicyEviction() throws {
    let fixture = try Fixture()
    let allocation = try fixture.start(isAuthorized: false)
    _ = try fixture.registry.authorizeCleanup(allocation.id, graceSeconds: 0)
    _ = try fixture.registry.retain(allocation.id, owner: "workspace", kind: .workspace)
    _ = try fixture.registry.retain(allocation.id, owner: "execution", kind: .execution)
    _ = try fixture.registry.keep(allocation.id)
    _ = try fixture.registry.entryExit(allocation.id, owner: "execution", status: 0)
    _ = try fixture.registry.sweep()
    XCTAssertEqual(try fixture.registry.preview(allocation.id).first?.reasons.count, 3)
    _ = try fixture.registry.release(allocation.id, owner: "workspace")
    _ = try fixture.registry.closeScope(allocation.id, owner: "execution")
    XCTAssertTrue(FileManager.default.fileExists(atPath: allocation.path))
    XCTAssertEqual(try fixture.registry.unkeep(allocation.id).phase, .removed)
  }

  func testSweepSkipsFileChecksWhilePinBlocksRemoval() throws {
    let fixture = try Fixture()
    let allocation = try fixture.start(isAuthorized: false)
    _ = try fixture.registry.authorizeCleanup(allocation.id, graceSeconds: 0)
    _ = try fixture.registry.keep(allocation.id)
    try Data("unsaved".utf8).write(to: URL(fileURLWithPath: allocation.path + "/tracked"))

    _ = try fixture.registry.sweep()
    let retained = try fixture.registry.inspect(allocation.id)
    XCTAssertEqual(retained.phase, .retained)
    XCTAssertEqual(retained.reason, "Retained pin owner: pin:" + allocation.id)
    XCTAssertTrue(
      try fixture.registry.preview(allocation.id)[0].reasons.contains {
        $0.contains("Retained pin owner")
      })

    let released = try fixture.registry.unkeep(allocation.id)
    XCTAssertEqual(released.phase, .removed, released.reason ?? "")
    _ = try fixture.registry.restore(allocation.id)
    XCTAssertEqual(
      try String(contentsOfFile: allocation.path + "/tracked", encoding: .utf8), "unsaved")
  }

  func testGraceReacquisitionRevocationAndLegacyPermissionAreIndependent() throws {
    let fixture = try Fixture()
    let allocation = try fixture.start(isAuthorized: false)
    _ = try fixture.registry.sweep()
    XCTAssertNil(try fixture.registry.inspect(allocation.id).eligibleSince)
    _ = try fixture.registry.authorizeCleanup(allocation.id, graceSeconds: 60)
    _ = try fixture.registry.sweep()
    XCTAssertNotNil(try fixture.registry.inspect(allocation.id).eligibleSince)
    _ = try fixture.registry.retain(allocation.id, owner: "reopened", kind: .workspace)
    XCTAssertNil(try fixture.registry.inspect(allocation.id).eligibleSince)
    _ = try fixture.registry.revokeCleanup(allocation.id)
    _ = try fixture.registry.release(allocation.id, owner: "reopened")
    _ = try fixture.registry.sweep()
    XCTAssertNil(try fixture.registry.inspect(allocation.id).cleanupPolicy)
    XCTAssertTrue(FileManager.default.fileExists(atPath: allocation.path))
  }

  func testPolicyPreservesUnsavedFilesAndOnlyDiscardsApprovedIgnoredOutput() throws {
    let fixture = try Fixture()
    let allocation = try fixture.start(isAuthorized: false)
    try Data("valuable".utf8).write(to: URL(fileURLWithPath: allocation.path + "/tracked"))
    try Data("valuable".utf8).write(to: URL(fileURLWithPath: allocation.path + "/untracked"))
    _ = try fixture.registry.authorizeCleanup(allocation.id, graceSeconds: 0)
    _ = try fixture.registry.sweep()
    XCTAssertEqual(try fixture.registry.inspect(allocation.id).phase, .removed)
    _ = try fixture.registry.restore(allocation.id)
    XCTAssertEqual(
      try String(contentsOfFile: allocation.path + "/tracked", encoding: .utf8), "valuable")
    XCTAssertEqual(
      try String(contentsOfFile: allocation.path + "/untracked", encoding: .utf8), "valuable")
    let generated = try fixture.start(isAuthorized: false)
    try FileManager.default.createDirectory(
      atPath: generated.path + "/ignored", withIntermediateDirectories: true)
    try Data("rebuildable".utf8).write(to: URL(fileURLWithPath: generated.path + "/ignored/output"))
    _ = try fixture.registry.authorizeCleanup(
      generated.id, graceSeconds: 0, disposablePaths: ["ignored"])
    _ = try fixture.registry.sweep()
    XCTAssertEqual(try fixture.registry.inspect(generated.id).phase, .removed)
    for path in [".", "..", "/tmp", "build/../private", ".git", "build//out"] {
      XCTAssertThrowsError(
        try fixture.registry.authorizeCleanup(generated.id, disposablePaths: [path]))
    }
  }

  func testStagedDeletionInsideApprovedIgnoredRootPreservesIndexAndFile() throws {
    let fixture = try Fixture()
    let allocation = try fixture.registry.start(
      branch: "staged-deletion", repository: fixture.repository, provider: .git)
    let relative = "ignored/valuable"
    let path = allocation.path + "/" + relative
    try FileManager.default.createDirectory(
      atPath: allocation.path + "/ignored", withIntermediateDirectories: true)
    try Data("preserve staged deletion contents".utf8).write(to: URL(fileURLWithPath: path))
    _ = try git(allocation.path, ["add", "--force", "--", relative])
    _ = try git(allocation.path, ["commit", "-m", "Track valuable ignored file"])
    _ = try git(allocation.path, ["rm", "--cached", "--", relative])
    let staged = try git(allocation.path, ["diff", "--cached", "--name-status"])
    XCTAssertEqual(staged, "D\t" + relative)
    _ = try fixture.registry.authorizeCleanup(
      allocation.id, graceSeconds: 0, disposablePaths: ["ignored"])
    _ = try fixture.registry.finish(allocation.id)
    _ = try fixture.registry.sweep()
    let blocked = try fixture.registry.inspect(allocation.id)
    XCTAssertEqual(blocked.phase, .blocked)
    XCTAssertTrue(blocked.reason?.contains("Disposable path contains tracked files") == true)
    XCTAssertFalse(blocked.isRemovalPending)
    XCTAssertNil(blocked.recovery)
    XCTAssertTrue(
      try git(fixture.repository, ["for-each-ref", "refs/workfree/recovery/" + allocation.id])
        .isEmpty)
    XCTAssertEqual(try git(allocation.path, ["diff", "--cached", "--name-status"]), staged)
    XCTAssertEqual(
      try String(contentsOfFile: path, encoding: .utf8), "preserve staged deletion contents")
  }

  func testApprovedIgnoredDirectoryDoesNotOverflowStatusOutput() throws {
    let fixture = try Fixture()
    let allocation = try fixture.start(isAuthorized: false)
    let directory =
      "ignored/"
      + Array(repeating: String(repeating: "g", count: 90), count: 8)
      .joined(separator: "/")
    try FileManager.default.createDirectory(
      atPath: allocation.path + "/" + directory, withIntermediateDirectories: true)
    for index in 0..<6000 {
      try Data().write(to: URL(fileURLWithPath: allocation.path + "/" + directory + "/\(index)"))
    }
    _ = try fixture.registry.authorizeCleanup(
      allocation.id, graceSeconds: 0, disposablePaths: ["ignored"])
    _ = try fixture.registry.sweep()
    let result = try fixture.registry.inspect(allocation.id)
    XCTAssertEqual(result.phase, .removed, result.reason ?? "")
    XCTAssertNotNil(result.recovery)
  }

  func testDisposableParentPreservesUnignoredFilesInCheckpoint() throws {
    let fixture = try Fixture()
    let allocation = try fixture.start(isAuthorized: false)
    try Data("ignored/\nmixed/generated\n".utf8).write(
      to: URL(fileURLWithPath: allocation.path + "/.gitignore"))
    _ = try git(allocation.path, ["commit", "-am", "Ignore generated output"])
    try FileManager.default.createDirectory(
      atPath: allocation.path + "/mixed", withIntermediateDirectories: true)
    for name in ["generated", "notes"] {
      try Data("preserve".utf8).write(to: URL(fileURLWithPath: allocation.path + "/mixed/" + name))
    }
    _ = try fixture.registry.authorizeCleanup(
      allocation.id, graceSeconds: 0, disposablePaths: ["mixed"])
    _ = try fixture.registry.sweep()
    XCTAssertEqual(try fixture.registry.inspect(allocation.id).phase, .removed)
    _ = try fixture.registry.restore(allocation.id)
    XCTAssertEqual(
      try String(contentsOfFile: allocation.path + "/mixed/notes", encoding: .utf8),
      "preserve")
  }

  func testChangedRecoveryReferenceAndOccupiedRestoreDestinationFailClosed() throws {
    let fixture = try Fixture()
    let allocation = try fixture.start(isAuthorized: false)
    _ = try fixture.registry.authorizeCleanup(allocation.id, graceSeconds: 0)
    _ = try fixture.registry.sweep()
    let removed = try fixture.registry.inspect(allocation.id)
    try FileManager.default.createDirectory(atPath: removed.path, withIntermediateDirectories: true)
    XCTAssertThrowsError(try fixture.registry.restore(allocation.id))
    try FileManager.default.removeItem(atPath: removed.path)
    _ = try git(fixture.repository, ["update-ref", "-d", removed.recovery!.reference])
    XCTAssertThrowsError(try fixture.registry.restore(allocation.id))
    XCTAssertEqual(try fixture.registry.inspect(allocation.id).phase, .removed)
  }

  func testFailedProviderRestoreAndPreCreationCrashRemainRetryable() throws {
    let fixture = try Fixture()
    let allocation = try fixture.start(isAuthorized: false)
    _ = try fixture.registry.authorizeCleanup(allocation.id, graceSeconds: 0)
    _ = try fixture.registry.sweep()
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = "/usr/bin:/bin"
    let process = try fixture.cli(["restore", allocation.id], environment: environment)
    XCTAssertNotEqual(fixture.wait(process), 0)
    var pending = try fixture.registry.inspect(allocation.id)
    XCTAssertEqual(pending.phase, .removed)
    XCTAssertNil(pending.pastRemovals)
    pending.phase = .creating
    try fixture.inject(pending)
    XCTAssertEqual(try fixture.registry.recover(allocation.id).phase, .removed)
    let restored = try fixture.registry.restore(allocation.id)
    XCTAssertEqual(restored.phase, .retained)
    XCTAssertEqual(restored.pastRemovals?.count, 1)
    XCTAssertEqual(try git(restored.path, ["rev-parse", "HEAD"]), pending.recovery?.commit)
  }

  func testLegacyPendingRemovalReconcilesPresentAndAbsentCheckouts() throws {
    let fixture = try Fixture()
    for isAbsent in [false, true] {
      let allocation = try fixture.registry.start(
        branch: UUID().uuidString, repository: fixture.repository, provider: .git)
      _ = try fixture.registry.finish(allocation.id)
      var pending = try fixture.registry.inspect(allocation.id)
      pending.isCleanupAuthorized = true
      pending.isRemovalPending = true
      pending.phase = .removing
      XCTAssertNil(pending.recovery)
      try fixture.inject(pending)
      if isAbsent {
        _ = try git(fixture.repository, ["worktree", "remove", "--", allocation.path])
      }
      let recovered = try fixture.registry.recover(allocation.id)
      XCTAssertEqual(recovered.phase, .removed, recovered.reason ?? "")
      XCTAssertEqual(recovered.recovery == nil, isAbsent)
      XCTAssertEqual(try fixture.registry.recover(allocation.id).phase, .removed)
    }
  }

  func testDefaultFinishClosesFreshTaskAfterLegacyRestore() throws {
    let fixture = try Fixture()
    let allocation = try fixture.start()
    XCTAssertEqual(try fixture.registry.finish(allocation.id).phase, .removed)
    let restored = try fixture.registry.restore(allocation.id)
    XCTAssertNotNil(restored.defaultTaskToken)
    XCTAssertNotEqual(restored.defaultTaskToken, "task:" + allocation.id)
    let finished = try fixture.registry.finish(allocation.id)
    XCTAssertTrue(finished.owners.isEmpty)
    XCTAssertEqual(finished.phase, .removed)
  }

  func testInterruptedRemovalKeepsCommitAndReconcilesWithoutLosingTask() throws {
    let fixture = try Fixture()
    let allocation = try fixture.start(isAuthorized: false)
    _ = try fixture.registry.authorizeCleanup(allocation.id, graceSeconds: 0)
    _ = try fixture.registry.sweep()
    var pending = try fixture.registry.inspect(allocation.id)
    pending.phase = .removing
    pending.isRemovalPending = true
    pending.removedAt = nil
    try fixture.inject(pending)
    let recovered = try fixture.registry.recover(pending.id)
    XCTAssertEqual(recovered.phase, .removed)
    XCTAssertEqual(recovered.recovery?.commit, pending.recovery?.commit)
    XCTAssertNotNil(recovered.owners["task:" + allocation.id])
    XCTAssertEqual(
      try fixture.registry.recover(pending.id).recovery?.reference, recovered.recovery?.reference)
  }

  func testInheritedPolicyOffloadsChangesOnlyAfterOneDayAndConfirmedPush() throws {
    let fixture = try Fixture()
    _ = try fixture.registry.enableGlobalCleanupPolicy()
    let allocation = try fixture.start(isAuthorized: false)
    try Data("edited".utf8).write(to: URL(fileURLWithPath: allocation.path + "/tracked"))
    try Data("new".utf8).write(to: URL(fileURLWithPath: allocation.path + "/untracked"))
    _ = try fixture.registry.sweep()
    let waiting = try fixture.registry.inspect(allocation.id)
    XCTAssertEqual(waiting.phase, .retained)
    XCTAssertNotNil(waiting.eligibleSince)
    XCTAssertTrue(FileManager.default.fileExists(atPath: allocation.path))

    var stale = waiting
    stale.eligibleSince = Date(timeIntervalSinceNow: -86_401)
    try fixture.inject(stale)
    _ = try git(fixture.repository, ["remote", "remove", "origin"])
    _ = try fixture.registry.sweep()
    XCTAssertTrue(FileManager.default.fileExists(atPath: allocation.path))
    XCTAssertTrue(try fixture.registry.inspect(allocation.id).reason?.contains("origin") == true)

    _ = try git(fixture.repository, ["remote", "add", "origin", fixture.root + "/remote.git"])
    _ = try fixture.registry.sweep()
    let removed = try fixture.registry.inspect(allocation.id)
    XCTAssertEqual(removed.phase, .removed, removed.reason ?? "")
    let reference = "refs/heads/workfree/offload/" + allocation.id
    XCTAssertEqual(
      try git(fixture.repository, ["ls-remote", "--heads", "origin", reference])
        .split(separator: "\t").first.map(String.init), removed.recovery?.commit)
    _ = try fixture.registry.restore(allocation.id)
    XCTAssertEqual(
      try String(contentsOfFile: allocation.path + "/tracked", encoding: .utf8), "edited")
    XCTAssertEqual(
      try String(contentsOfFile: allocation.path + "/untracked", encoding: .utf8), "new")
  }

  func testGitProviderOffloadPreservesStagedAndUnstagedChanges() throws {
    let fixture = try Fixture()
    let allocation = try fixture.registry.start(
      branch: UUID().uuidString, repository: fixture.repository, provider: .git)
    try Data("staged".utf8).write(to: URL(fileURLWithPath: allocation.path + "/tracked"))
    _ = try git(allocation.path, ["add", "tracked"])
    try Data("unstaged".utf8).write(to: URL(fileURLWithPath: allocation.path + "/tracked"))
    _ = try fixture.registry.authorizeCleanup(allocation.id, graceSeconds: 0)
    _ = try fixture.registry.sweep()
    let removed = try fixture.registry.inspect(allocation.id)
    XCTAssertEqual(removed.phase, .removed, removed.reason ?? "")
    XCTAssertEqual(
      try git(fixture.repository, ["show", removed.recovery!.commit + "^:tracked"]), "staged")
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.repository + "/tracked"))
    _ = try fixture.registry.restore(allocation.id)
    XCTAssertEqual(
      try String(contentsOfFile: allocation.path + "/tracked", encoding: .utf8), "unstaged")
  }

  func testOffloadRetryFromRootCommitKeepsIncrementalHistory() throws {
    let fixture = try Fixture()
    let allocation = try fixture.registry.start(
      branch: UUID().uuidString, repository: fixture.repository, provider: .git)
    let source = try git(allocation.path, ["rev-parse", "HEAD"])
    let tree = try git(allocation.path, ["rev-parse", "HEAD^{tree}"])
    let staged = try git(
      allocation.path,
      [
        "commit-tree", tree, "-p", source, "-m", "workfree offload staged: " + allocation.id,
      ])
    let first = try git(
      allocation.path,
      [
        "commit-tree", tree, "-p", staged, "-m", "workfree offload: " + allocation.id,
      ])
    let reference = "refs/heads/workfree/offload/" + allocation.id
    _ = try git(allocation.path, ["push", "origin", first + ":" + reference])
    try Data("later".utf8).write(to: URL(fileURLWithPath: allocation.path + "/tracked"))

    _ = try fixture.registry.authorizeCleanup(allocation.id, graceSeconds: 0)
    _ = try fixture.registry.sweep()
    let removed = try fixture.registry.inspect(allocation.id)
    XCTAssertEqual(removed.phase, .removed, removed.reason ?? "")
    XCTAssertEqual(
      try git(fixture.repository, ["rev-parse", removed.recovery!.commit + "^^"]), first)
    XCTAssertEqual(
      try git(fixture.repository, ["ls-remote", "--heads", "origin", reference])
        .split(separator: "\t").first.map(String.init), removed.recovery?.commit)
    _ = try fixture.registry.restore(allocation.id)
    XCTAssertEqual(
      try String(contentsOfFile: allocation.path + "/tracked", encoding: .utf8), "later")
  }

  func testPolicyDoesNotOffloadUnapprovedIgnoredFiles() throws {
    let fixture = try Fixture()
    let allocation = try fixture.start(isAuthorized: false)
    try FileManager.default.createDirectory(
      atPath: allocation.path + "/ignored", withIntermediateDirectories: true)
    let ignored = allocation.path + "/ignored/private"
    try Data("private".utf8).write(to: URL(fileURLWithPath: ignored))
    _ = try fixture.registry.authorizeCleanup(allocation.id, graceSeconds: 0)
    _ = try fixture.registry.sweep()
    let retained = try fixture.registry.inspect(allocation.id)
    XCTAssertEqual(retained.phase, .retained)
    XCTAssertTrue(retained.reason?.contains("Unapproved ignored file") == true)
    XCTAssertTrue(FileManager.default.fileExists(atPath: ignored))
    XCTAssertTrue(
      try git(
        fixture.repository,
        ["ls-remote", "--heads", "origin", "refs/heads/workfree/offload/" + allocation.id]
      ).isEmpty)
  }
}
