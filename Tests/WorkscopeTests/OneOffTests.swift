import Foundation
import XCTest

@testable import Workscope

final class OneOffTests: XCTestCase {
  func testLocalOffloadPreservesStagedAndWorkingChangesBeforeManualCleanup() throws {
    let fixture = try Fixture()
    let allocation = try fixture.registry.start(
      branch: UUID().uuidString, repository: fixture.repository, provider: .git)
    _ = try git(fixture.repository, ["remote", "remove", "origin"])
    let original = try git(allocation.path, ["rev-parse", "HEAD"])
    try Data("staged".utf8).write(to: URL(fileURLWithPath: allocation.path + "/tracked"))
    _ = try git(allocation.path, ["add", "tracked"])
    try Data("working".utf8).write(to: URL(fileURLWithPath: allocation.path + "/tracked"))
    try Data("new".utf8).write(to: URL(fileURLWithPath: allocation.path + "/new-file"))

    let offloaded = try XCTUnwrap(
      fixture.registry.offload(
        id: allocation.id, minimumIdle: 0, transcriptDirectory: fixture.root, isRemote: false
      ).first)
    XCTAssertEqual(offloaded.phase, .retained, offloaded.reason ?? "")
    XCTAssertEqual(offloaded.recovery?.event, "manual-offload-local")
    XCTAssertEqual(try git(allocation.path, ["rev-parse", "HEAD"]), offloaded.recovery?.commit)
    XCTAssertEqual(try git(allocation.path, ["status", "--porcelain"]), "")
    XCTAssertEqual(try git(allocation.path, ["rev-parse", "HEAD^^"]), original)
    XCTAssertEqual(try git(allocation.path, ["show", "HEAD^:tracked"]), "staged")
    XCTAssertEqual(try git(allocation.path, ["show", "HEAD:tracked"]), "working")
    XCTAssertEqual(try git(allocation.path, ["show", "HEAD:new-file"]), "new")
    _ = try fixture.registry.sweep()
    XCTAssertTrue(FileManager.default.fileExists(atPath: allocation.path))

    let result = try XCTUnwrap(
      fixture.registry.oneOffCleanup(
        id: allocation.id, minimumIdle: 0, transcriptDirectory: fixture.root
      ).first)
    XCTAssertEqual(result.phase, .removed, result.reason ?? "")
    XCTAssertFalse(FileManager.default.fileExists(atPath: allocation.path))
    XCTAssertFalse(
      try fixture.registry.oneOffPreview(
        id: allocation.id, minimumIdle: 0, transcriptDirectory: fixture.root
      )[0].isEligible)
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.repository + "/tracked"))
    _ = try fixture.registry.restore(allocation.id)
    XCTAssertEqual(try git(allocation.path, ["status", "--porcelain"]), "")
    XCTAssertEqual(
      try String(contentsOfFile: allocation.path + "/tracked", encoding: .utf8), "working")
  }

  func testRemoteOffloadChecksOriginAndSkipsActiveWorkspaceOnRepoCleanup() throws {
    let fixture = try Fixture()
    let saved = try fixture.registry.start(
      branch: UUID().uuidString, repository: fixture.repository, provider: .git)
    let active = try fixture.registry.start(
      branch: UUID().uuidString, repository: fixture.repository, provider: .git)
    _ = try fixture.registry.retain(active.id, owner: "active", kind: .workspace)
    try Data("draft".utf8).write(to: URL(fileURLWithPath: saved.path + "/tracked"))

    let offloaded = try fixture.registry.offload(
      repository: fixture.repository, minimumIdle: 0,
      transcriptDirectory: fixture.root, isRemote: true)
    XCTAssertEqual(offloaded.map(\.id), [saved.id])
    let record = try fixture.registry.inspect(saved.id)
    XCTAssertEqual(record.phase, .retained, record.reason ?? "")
    XCTAssertEqual(record.recovery?.event, "manual-offload-remote")
    XCTAssertEqual(
      try git(
        fixture.repository,
        [
          "ls-remote", "--heads", "origin", "refs/heads/workfree/offload/" + saved.id,
        ]
      ).split(separator: "\t").first.map(String.init), record.recovery?.commit)

    let removed = try fixture.registry.oneOffCleanup(
      repository: fixture.repository, minimumIdle: 0, transcriptDirectory: fixture.root)
    XCTAssertEqual(removed.map(\.id), [saved.id])
    XCTAssertEqual(removed.first?.phase, .removed)
    XCTAssertTrue(FileManager.default.fileExists(atPath: active.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.repository + "/tracked"))
    _ = try fixture.registry.restore(saved.id)
    XCTAssertEqual(
      try String(contentsOfFile: saved.path + "/tracked", encoding: .utf8), "draft")
  }

  func testPreviewChecksTranscriptMentionsAndSkipsMissingWorktrees() throws {
    let fixture = try Fixture()
    let allocation = try fixture.registry.start(
      branch: UUID().uuidString, repository: fixture.repository, provider: .git)
    let old = Date().addingTimeInterval(-7 * 24 * 3600)
    for path in [allocation.path + "/tracked", allocation.path + "/.gitignore", allocation.path] {
      try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: path)
    }
    let sessions = fixture.root + "/sessions"
    try FileManager.default.createDirectory(atPath: sessions, withIntermediateDirectories: true)
    let file = URL(fileURLWithPath: sessions + "/conversation.jsonl")
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let entry: [String: Any] = [
      "type": "message", "timestamp": formatter.string(from: Date()),
      "message": [
        "role": "user", "content": [["type": "text", "text": "Please check " + allocation.id]],
      ],
    ]
    try JSONSerialization.data(withJSONObject: entry).write(to: file)
    var preview = try XCTUnwrap(
      fixture.registry.oneOffPreview(
        id: allocation.id, minimumIdle: 24 * 3600, transcriptDirectory: sessions
      ).first)
    XCTAssertFalse(preview.isEligible)
    XCTAssertNotNil(preview.lastMention)

    let spaced = String(decoding: try JSONSerialization.data(withJSONObject: entry), as: UTF8.self)
      .replacingOccurrences(of: "\"role\":\"user\"", with: "\"role\": \"user\"")
    try Data(spaced.utf8).write(to: file)
    preview = try XCTUnwrap(
      fixture.registry.oneOffPreview(
        id: allocation.id, minimumIdle: 24 * 3600, transcriptDirectory: sessions
      ).first)
    XCTAssertFalse(preview.isEligible)
    XCTAssertNotNil(preview.lastMention)

    let escaped = spaced.replacingOccurrences(of: "\"role\"", with: "\"\\u0072ole\"")
    try Data(escaped.utf8).write(to: file)
    preview = try XCTUnwrap(
      fixture.registry.oneOffPreview(
        id: allocation.id, minimumIdle: 24 * 3600, transcriptDirectory: sessions
      ).first)
    XCTAssertFalse(preview.isEligible)
    XCTAssertNotNil(preview.lastMention)

    var tool = entry
    tool["message"] = [
      "role": "toolResult", "content": [["type": "text", "text": "Log mentions " + allocation.id]],
    ]
    try JSONSerialization.data(withJSONObject: tool).write(to: file)
    preview = try XCTUnwrap(
      fixture.registry.oneOffPreview(
        id: allocation.id, minimumIdle: 24 * 3600, transcriptDirectory: sessions
      ).first)
    XCTAssertTrue(preview.isEligible, preview.reasons.description)
    XCTAssertNil(preview.lastMention)
    XCTAssertTrue(
      try fixture.registry.oneOffCleanup(
        id: allocation.id, minimumIdle: 0, transcriptDirectory: sessions
      ).isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(atPath: allocation.path))
  }

  func testUnreadableTranscriptSubtreeBlocksAgeBasedOffload() throws {
    let fixture = try Fixture()
    let allocation = try fixture.registry.start(
      branch: UUID().uuidString, repository: fixture.repository, provider: .git)
    let sessions = fixture.root + "/sessions"
    let privateDirectory = sessions + "/private"
    try FileManager.default.createDirectory(
      atPath: privateDirectory, withIntermediateDirectories: true)
    try Data("recent conversation".utf8).write(
      to: URL(fileURLWithPath: privateDirectory + "/conversation.jsonl"))
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o000], ofItemAtPath: privateDirectory)
    defer {
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: privateDirectory)
    }
    XCTAssertThrowsError(
      try fixture.registry.oneOffPreview(
        id: allocation.id, minimumIdle: 24 * 3600, transcriptDirectory: sessions))
    XCTAssertTrue(FileManager.default.fileExists(atPath: allocation.path))
  }

  func testRecentTrackedFileInsidePackageBlocksIdleAge() throws {
    let fixture = try Fixture()
    let allocation = try fixture.registry.start(
      branch: UUID().uuidString, repository: fixture.repository, provider: .git)
    let contents = allocation.path + "/Example.app/Contents"
    try FileManager.default.createDirectory(atPath: contents, withIntermediateDirectories: true)
    let file = contents + "/state.txt"
    try Data("old".utf8).write(to: URL(fileURLWithPath: file))
    _ = try git(allocation.path, ["add", "Example.app/Contents/state.txt"])
    let old = Date().addingTimeInterval(-7 * 24 * 3600)
    for path in [
      "", "tracked", ".gitignore", "Example.app", "Example.app/Contents",
      "Example.app/Contents/state.txt",
    ] {
      try FileManager.default.setAttributes(
        [.modificationDate: old], ofItemAtPath: allocation.path + "/" + path)
    }
    try Data("recent".utf8).write(to: URL(fileURLWithPath: file))
    let preview = try XCTUnwrap(
      fixture.registry.oneOffPreview(
        id: allocation.id, minimumIdle: 24 * 3600, transcriptDirectory: fixture.root
      ).first)
    XCTAssertFalse(preview.isEligible)
    XCTAssertTrue(preview.reasons.contains("Minimum idle age has not elapsed"))
  }

  func testDeletingAFileCountsAsRecentActivity() throws {
    let fixture = try Fixture()
    let allocation = try fixture.registry.start(
      branch: UUID().uuidString, repository: fixture.repository, provider: .git)
    let deleted = allocation.path + "/deleted.txt"
    try Data("old".utf8).write(to: URL(fileURLWithPath: deleted))
    _ = try git(allocation.path, ["add", "deleted.txt"])
    let old = Date().addingTimeInterval(-7 * 24 * 3600)
    for path in [
      allocation.path + "/tracked", allocation.path + "/.gitignore", deleted,
      allocation.path,
    ] {
      try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: path)
    }
    try FileManager.default.removeItem(atPath: deleted)
    let preview = try XCTUnwrap(
      fixture.registry.oneOffPreview(
        id: allocation.id, minimumIdle: 24 * 3600, transcriptDirectory: fixture.root
      ).first)
    XCTAssertFalse(preview.isEligible)
    XCTAssertTrue(preview.reasons.contains("Minimum idle age has not elapsed"))
  }

  func testOffloadDoesNotRestartTheChosenIdleAge() throws {
    let fixture = try Fixture()
    let allocation = try fixture.registry.start(
      branch: UUID().uuidString, repository: fixture.repository, provider: .git)
    try Data("old staged change".utf8).write(to: URL(fileURLWithPath: allocation.path + "/tracked"))
    _ = try git(allocation.path, ["add", "tracked"])
    let old = Date().addingTimeInterval(-7_200)
    for path in ["", "tracked", ".gitignore"] {
      try FileManager.default.setAttributes(
        [.modificationDate: old], ofItemAtPath: allocation.path + "/" + path)
    }
    let preview = try XCTUnwrap(
      fixture.registry.oneOffPreview(
        id: allocation.id, minimumIdle: 3_600, transcriptDirectory: fixture.root
      ).first)
    XCTAssertTrue(preview.isEligible, preview.reasons.joined(separator: "; "))
    let offloaded = try XCTUnwrap(
      fixture.registry.offload(
        id: allocation.id, minimumIdle: 3_600, transcriptDirectory: fixture.root,
        isRemote: false
      ).first)
    XCTAssertEqual(offloaded.phase, .retained, offloaded.reason ?? "")
    let cleaned = try XCTUnwrap(
      fixture.registry.oneOffCleanup(
        id: allocation.id, minimumIdle: 3_600, transcriptDirectory: fixture.root
      ).first)
    XCTAssertEqual(cleaned.phase, .removed, cleaned.reason ?? "")
  }

  func testCleanupRechecksAContentPreservingTouchBeforeRemoval() throws {
    let fixture = try Fixture()
    let allocation = try fixture.registry.start(
      branch: UUID().uuidString, repository: fixture.repository, provider: .git)
    let old = Date().addingTimeInterval(-7_200)
    for path in ["", "tracked", ".gitignore"] {
      try FileManager.default.setAttributes(
        [.modificationDate: old], ofItemAtPath: allocation.path + "/" + path)
    }
    let offloaded = try XCTUnwrap(
      fixture.registry.offload(
        id: allocation.id, minimumIdle: 3_600, transcriptDirectory: fixture.root,
        isRemote: false
      ).first)
    XCTAssertEqual(offloaded.phase, .retained, offloaded.reason ?? "")
    let selected = try oneOffPreviews(
      [offloaded], minimumIdle: 3_600, transcriptDirectory: fixture.root,
      isCheckpointRequired: true)[0]
    XCTAssertTrue(selected.isEligible, selected.reasons.joined(separator: "; "))
    try FileManager.default.setAttributes(
      [.modificationDate: Date()], ofItemAtPath: allocation.path + "/tracked")
    try withRegistry(fixture.registry.stateDirectory) { store in
      var current = try store.allocation(allocation.id)
      try cleanup(
        &current, store: store, event: "manual-cleanup", minimumIdle: 3_600,
        transcriptDirectory: fixture.root)
      XCTAssertEqual(current.phase, .blocked)
      XCTAssertTrue(current.reason?.contains("Minimum idle age has not elapsed") == true)
    }
    XCTAssertTrue(FileManager.default.fileExists(atPath: allocation.path))
    XCTAssertEqual(try git(allocation.path, ["status", "--porcelain"]), "")
  }

  func testRemoteOffloadRechecksMentionsWrittenDuringPush() throws {
    let fixture = try Fixture()
    let allocation = try fixture.registry.start(
      branch: UUID().uuidString, repository: fixture.repository, provider: .git)
    let old = Date().addingTimeInterval(-7_200)
    for path in ["", "tracked", ".gitignore"] {
      try FileManager.default.setAttributes(
        [.modificationDate: old], ofItemAtPath: allocation.path + "/" + path)
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let entry: [String: Any] = [
      "type": "message", "timestamp": formatter.string(from: Date()),
      "message": [
        "role": "assistant", "content": [["type": "text", "text": allocation.id]],
      ],
    ]
    let json = String(decoding: try JSONSerialization.data(withJSONObject: entry), as: UTF8.self)
    let transcript = fixture.root + "/during-push.jsonl"
    let hook = URL(
      fileURLWithPath: try git(fixture.repository, ["rev-parse", "--git-path", "hooks/pre-push"]),
      relativeTo: URL(fileURLWithPath: fixture.repository + "/")
    ).standardizedFileURL.path
    try Data(("#!/bin/zsh\nprintf '%s\\n' '" + json + "' > '" + transcript + "'\n").utf8)
      .write(to: URL(fileURLWithPath: hook))
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook)
    let selected = try XCTUnwrap(
      fixture.registry.oneOffPreview(
        id: allocation.id, minimumIdle: 3_600, transcriptDirectory: fixture.root
      ).first)
    XCTAssertTrue(selected.isEligible, selected.reasons.joined(separator: "; "))
    let result = try XCTUnwrap(
      fixture.registry.offload(
        id: allocation.id, minimumIdle: 3_600, transcriptDirectory: fixture.root,
        isRemote: true
      ).first)
    XCTAssertTrue(FileManager.default.fileExists(atPath: transcript))
    XCTAssertEqual(result.phase, .blocked)
    XCTAssertTrue(result.reason?.contains("minimum idle age") == true)
    XCTAssertTrue(FileManager.default.fileExists(atPath: allocation.path))
  }

  func testChangedCheckoutRequiresAnotherOffloadBeforeCleanup() throws {
    let fixture = try Fixture()
    let allocation = try fixture.registry.start(
      branch: UUID().uuidString, repository: fixture.repository, provider: .git)
    _ = try fixture.registry.offload(
      id: allocation.id, minimumIdle: 0, transcriptDirectory: fixture.root, isRemote: false)
    try Data("late edit".utf8).write(to: URL(fileURLWithPath: allocation.path + "/tracked"))
    let result = try XCTUnwrap(
      fixture.registry.oneOffCleanup(
        id: allocation.id, minimumIdle: 0, transcriptDirectory: fixture.root
      ).first)
    XCTAssertEqual(result.phase, .blocked)
    XCTAssertTrue(FileManager.default.fileExists(atPath: allocation.path))
    XCTAssertEqual(
      try String(contentsOfFile: allocation.path + "/tracked", encoding: .utf8), "late edit")
    let retried = try XCTUnwrap(
      fixture.registry.offload(
        id: allocation.id, minimumIdle: 0, transcriptDirectory: fixture.root, isRemote: false
      ).first)
    XCTAssertEqual(retried.phase, .retained, retried.reason ?? "")
    XCTAssertEqual(try git(allocation.path, ["status", "--porcelain"]), "")
  }

  func testInterruptedManualCleanupCanReconcileWithoutStandingPolicy() throws {
    let fixture = try Fixture()
    let allocation = try fixture.registry.start(
      branch: UUID().uuidString, repository: fixture.repository, provider: .git)
    var pending = try XCTUnwrap(
      fixture.registry.offload(
        id: allocation.id, minimumIdle: 0, transcriptDirectory: fixture.root, isRemote: false
      ).first)
    let recovery = try XCTUnwrap(pending.recovery)
    pending.recovery = RecoveryRecord(
      commit: recovery.commit, reference: recovery.reference, branch: recovery.branch,
      preservedAt: recovery.preservedAt, event: "manual-cleanup",
      lastFileActivity: recovery.lastFileActivity)
    pending.phase = .removing
    pending.isRemovalPending = true
    try withRegistry(fixture.registry.stateDirectory) { store in try store.save(pending) }
    _ = try fixture.registry.sweep()
    XCTAssertEqual(try fixture.registry.inspect(allocation.id).phase, .removed)
    XCTAssertFalse(FileManager.default.fileExists(atPath: allocation.path))
  }

  func testOneOffCommandLineRequiresScopeAndRunsAsTwoSteps() throws {
    let fixture = try Fixture()
    let allocation = try fixture.registry.start(
      branch: UUID().uuidString, repository: fixture.repository, provider: .git)
    XCTAssertNotEqual(
      fixture.wait(
        try fixture.cli([
          "offload", allocation.id, "--checkpoint", "local",
        ])), 0)
    XCTAssertNotEqual(
      fixture.wait(
        try fixture.cli([
          "offload", "--min-idle", "0h", "--checkpoint", "local",
        ])), 0)
    XCTAssertEqual(
      fixture.wait(
        try fixture.cli([
          "offload-preview", allocation.id, "--min-idle", "0h",
          "--sessions-dir", fixture.root,
        ])), 0)
    XCTAssertEqual(
      fixture.wait(
        try fixture.cli([
          "offload", allocation.id, "--min-idle", "0h", "--checkpoint", "local",
          "--sessions-dir", fixture.root,
        ])), 0)
    XCTAssertEqual(
      try fixture.registry.inspect(allocation.id).recovery?.event,
      "manual-offload-local")
    XCTAssertTrue(FileManager.default.fileExists(atPath: allocation.path))
    XCTAssertEqual(
      fixture.wait(
        try fixture.cli([
          "cleanup-now", "--repo", fixture.repository, "--min-idle", "0h",
          "--sessions-dir", fixture.root,
        ])), 0)
    XCTAssertEqual(try fixture.registry.inspect(allocation.id).phase, .removed)
    XCTAssertFalse(FileManager.default.fileExists(atPath: allocation.path))
  }

  func testRemoteFailureAndIgnoredFilesKeepCheckouts() throws {
    let fixture = try Fixture()
    let first = try fixture.registry.start(
      branch: UUID().uuidString, repository: fixture.repository, provider: .git)
    _ = try git(fixture.repository, ["remote", "remove", "origin"])
    let result = try XCTUnwrap(
      fixture.registry.offload(
        id: first.id, minimumIdle: 0, transcriptDirectory: fixture.root, isRemote: true
      ).first)
    XCTAssertEqual(result.phase, .blocked)
    XCTAssertNil(result.recovery)
    XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))

    try FileManager.default.createDirectory(
      atPath: first.path + "/ignored", withIntermediateDirectories: true)
    try Data("private".utf8).write(to: URL(fileURLWithPath: first.path + "/ignored/private"))
    XCTAssertTrue(
      try fixture.registry.offload(
        id: first.id, minimumIdle: 0, transcriptDirectory: fixture.root, isRemote: false
      ).isEmpty)
    XCTAssertTrue(FileManager.default.fileExists(atPath: first.path + "/ignored/private"))
  }
}
