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
    XCTAssertEqual(offloaded.phase, .removed, offloaded.reason ?? "")
    XCTAssertEqual(offloaded.recovery?.event, "manual-cleanup")
    XCTAssertEqual(
      try git(fixture.repository, ["rev-parse", offloaded.recovery!.commit + "^^"]), original)
    XCTAssertEqual(
      try git(fixture.repository, ["show", offloaded.recovery!.commit + "^:tracked"]), "staged")
    XCTAssertEqual(
      try git(fixture.repository, ["show", offloaded.recovery!.commit + ":tracked"]), "working")
    XCTAssertEqual(
      try git(fixture.repository, ["show", offloaded.recovery!.commit + ":new-file"]), "new")
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
    XCTAssertEqual(record.phase, .removed, record.reason ?? "")
    XCTAssertEqual(record.recovery?.event, "manual-cleanup")
    XCTAssertEqual(
      try git(
        fixture.repository,
        [
          "ls-remote", "--heads", "origin", "refs/heads/workfree/offload/" + saved.id,
        ]
      ).split(separator: "\t").first.map(String.init), record.recovery?.commit)

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

  func testMalformedUnrelatedTranscriptDoesNotBlockButPossibleMentionDoes() throws {
    let fixture = try Fixture()
    let allocation = try fixture.registry.start(
      branch: UUID().uuidString, repository: fixture.repository, provider: .git)
    let old = Date().addingTimeInterval(-7 * 24 * 3600)
    for path in ["", "tracked", ".gitignore"] {
      try FileManager.default.setAttributes(
        [.modificationDate: old], ofItemAtPath: allocation.path + "/" + path)
    }
    let transcript = fixture.root + "/malformed.jsonl"
    let invalid =
      "{\"type\":\"message\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"\\udc00\"}]}}\n"
    try Data(invalid.utf8).write(to: URL(fileURLWithPath: transcript))
    let preview = try XCTUnwrap(
      fixture.registry.oneOffPreview(
        id: allocation.id, minimumIdle: 24 * 3600, transcriptDirectory: fixture.root
      ).first)
    XCTAssertTrue(preview.isEligible, preview.reasons.description)

    let possibleMention = invalid.replacingOccurrences(
      of: "\\udc00", with: allocation.id + "\\udc00")
    try Data(possibleMention.utf8).write(to: URL(fileURLWithPath: transcript))
    XCTAssertThrowsError(
      try fixture.registry.oneOffPreview(
        id: allocation.id, minimumIdle: 24 * 3600, transcriptDirectory: fixture.root))
    let first = try XCTUnwrap(allocation.id.utf8.first)
    let partlyEscaped = String(format: "\\u%04x", Int(first)) + allocation.id.dropFirst()
    let escapedMention = invalid.replacingOccurrences(
      of: "\\udc00", with: partlyEscaped + "\\udc00")
    try Data(escapedMention.utf8).write(to: URL(fileURLWithPath: transcript))
    XCTAssertThrowsError(
      try fixture.registry.oneOffPreview(
        id: allocation.id, minimumIdle: 24 * 3600, transcriptDirectory: fixture.root))
    XCTAssertTrue(FileManager.default.fileExists(atPath: allocation.path))
  }

  func testUnicodeEscapedIdentifierStillCountsAsAConversationMention() throws {
    let fixture = try Fixture()
    let allocation = try fixture.registry.start(
      branch: UUID().uuidString, repository: fixture.repository, provider: .git)
    let old = Date().addingTimeInterval(-7 * 24 * 3600)
    for path in ["", "tracked", ".gitignore"] {
      try FileManager.default.setAttributes(
        [.modificationDate: old], ofItemAtPath: allocation.path + "/" + path)
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let escaped = allocation.id.utf8.map { String(format: "\\u%04x", Int($0)) }.joined()
    let line =
      "{\"type\":\"message\",\"timestamp\":\"\(formatter.string(from: Date()))\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"\(escaped)\"}]}}\n"
    try Data(line.utf8).write(to: URL(fileURLWithPath: fixture.root + "/encoded.jsonl"))
    let preview = try XCTUnwrap(
      fixture.registry.oneOffPreview(
        id: allocation.id, minimumIdle: 24 * 3600, transcriptDirectory: fixture.root
      ).first)
    XCTAssertFalse(preview.isEligible)
    XCTAssertTrue(preview.reasons.contains { $0.contains("Minimum idle age") })
  }

  func testExplicitPathMentionBlocksOffloadWithRawOrEscapedSlashes() throws {
    let fixture = try Fixture()
    let allocation = try fixture.registry.start(
      branch: UUID().uuidString, repository: fixture.repository,
      path: fixture.root + "/custom-checkout", provider: .git)
    let old = Date().addingTimeInterval(-7 * 24 * 3600)
    for path in ["", "tracked", ".gitignore"] {
      try FileManager.default.setAttributes(
        [.modificationDate: old], ofItemAtPath: allocation.path + "/" + path)
    }
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let transcript = fixture.root + "/path-mention.jsonl"
    for path in [allocation.path, allocation.path.replacingOccurrences(of: "/", with: "\\/")] {
      let line =
        "{\"type\":\"message\",\"timestamp\":\"\(formatter.string(from: Date()))\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"\(path)\"}]}}\n"
      try Data(line.utf8).write(to: URL(fileURLWithPath: transcript))
      let preview = try XCTUnwrap(
        fixture.registry.oneOffPreview(
          id: allocation.id, minimumIdle: 24 * 3600, transcriptDirectory: fixture.root
        ).first)
      XCTAssertNotNil(preview.lastMention)
      XCTAssertFalse(preview.isEligible)
    }
  }

  func testCanonicallyEquivalentEscapedPathMentionBlocksOffload() throws {
    let fixture = try Fixture()
    let allocation = try fixture.registry.start(
      branch: UUID().uuidString, repository: fixture.repository,
      path: fixture.root + "/café-checkout", provider: .git)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let decomposed = allocation.path.decomposedStringWithCanonicalMapping
    let record: [String: Any] = [
      "type": "message", "timestamp": formatter.string(from: Date()),
      "message": ["role": "user", "content": [["type": "text", "text": decomposed]]],
    ]
    let json = try XCTUnwrap(
      String(data: JSONSerialization.data(withJSONObject: record), encoding: .utf8))
    let encoded = Data(json.replacingOccurrences(of: "\u{0301}", with: "\\u0301").utf8)
    XCTAssertNil(encoded.range(of: Data(allocation.path.utf8)))
    try (encoded + Data([10])).write(to: URL(fileURLWithPath: fixture.root + "/unicode.jsonl"))
    XCTAssertNotNil(try transcriptMentions([allocation], directory: fixture.root)[allocation.id])
  }

  func testASCIIPathWithUnicodeEquivalentMentionBlocksOffload() throws {
    let fixture = try Fixture()
    let allocation = try fixture.registry.start(
      branch: UUID().uuidString, repository: fixture.repository,
      path: fixture.root + "/Key-checkout", provider: .git)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let mention = allocation.path.replacingOccurrences(of: "/Key-", with: "/Key-")
    let record: [String: Any] = [
      "type": "message", "timestamp": formatter.string(from: Date()),
      "message": ["role": "assistant", "content": [["type": "text", "text": mention]]],
    ]
    let encoded = try JSONSerialization.data(withJSONObject: record)
    XCTAssertNil(encoded.range(of: Data(allocation.path.utf8)))
    try (encoded + Data([10])).write(to: URL(fileURLWithPath: fixture.root + "/kelvin.jsonl"))
    XCTAssertNotNil(try transcriptMentions([allocation], directory: fixture.root)[allocation.id])
  }

  func testPathMentionAcrossTextPartsBlocksOffload() throws {
    let fixture = try Fixture()
    let allocation = try fixture.registry.start(
      branch: UUID().uuidString, repository: fixture.repository,
      path: fixture.root + "/segment\nsuffix", provider: .git)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let pathParts = allocation.path.components(separatedBy: "\n")
    let record: [String: Any] = [
      "type": "message", "timestamp": formatter.string(from: Date()),
      "message": [
        "role": "user", "content": pathParts.map { ["type": "text", "text": $0] },
      ],
    ]
    let encoded = try JSONSerialization.data(withJSONObject: record)
    XCTAssertNil(encoded.range(of: Data(allocation.path.utf8)))
    try (encoded + Data([10])).write(to: URL(fileURLWithPath: fixture.root + "/parts.jsonl"))
    XCTAssertNotNil(try transcriptMentions([allocation], directory: fixture.root)[allocation.id])
  }

  func testRecordLimitIsCheckedPerLineNotPerReadChunk() throws {
    let fixture = try Fixture()
    let allocation = try fixture.registry.start(
      branch: UUID().uuidString, repository: fixture.repository, provider: .git)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let line =
      "{\"type\":\"message\",\"timestamp\":\"\(formatter.string(from: Date()))\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"\(allocation.id)\"}]}}\n"
    let maximum = line.utf8.count + 32
    let unrelated = line.replacingOccurrences(
      of: allocation.id, with: String(repeating: "x", count: allocation.id.utf8.count + 32))
    try Data((unrelated + line).utf8).write(
      to: URL(fileURLWithPath: fixture.root + "/records.jsonl"))
    XCTAssertEqual(unrelated.utf8.count, maximum)
    XCTAssertNotNil(
      try transcriptMentions(
        [allocation], directory: fixture.root, maximumRecordBytes: maximum)[allocation.id])
  }

  func testEscapedTabAndQuotePathMentionsBlockOffload() throws {
    let fixture = try Fixture()
    let allocation = try fixture.registry.start(
      branch: UUID().uuidString, repository: fixture.repository,
      path: fixture.root + "/tab\t\"quote", provider: .git)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let record: [String: Any] = [
      "type": "message", "timestamp": formatter.string(from: Date()),
      "message": [
        "role": "user", "content": [["type": "text", "text": "See \(allocation.path)"]],
      ],
    ]
    let encoded = try JSONSerialization.data(withJSONObject: record)
    XCTAssertNil(encoded.range(of: Data(allocation.path.utf8)))
    let transcript = URL(fileURLWithPath: fixture.root + "/records.jsonl")
    try (encoded + Data([10])).write(to: transcript)
    XCTAssertNotNil(try transcriptMentions([allocation], directory: fixture.root)[allocation.id])

    try (encoded + Data("{\n".utf8)).write(to: transcript)
    XCTAssertThrowsError(try transcriptMentions([allocation], directory: fixture.root))
  }

  func testMalformedEscapedMentionAcrossBufferBoundaryBlocksOffload() throws {
    let fixture = try Fixture()
    let allocation = try fixture.registry.start(
      branch: UUID().uuidString, repository: fixture.repository, provider: .git)
    let escaped = allocation.id.unicodeScalars.map { String(format: "\\u%04x", $0.value) }.joined()
    let invalid = "{\"content\":\"" + String(repeating: "z", count: 8_174) + escaped + "{\n"
    XCTAssertNil(Data(invalid.utf8).range(of: Data(allocation.id.utf8)))
    try Data(invalid.utf8).write(
      to: URL(fileURLWithPath: fixture.root + "/invalid.jsonl"))
    XCTAssertThrowsError(try transcriptMentions([allocation], directory: fixture.root))
  }

  func testMalformedUnicodeEscapedPathBlocksOffload() throws {
    let fixture = try Fixture()
    let allocation = try fixture.registry.start(
      branch: UUID().uuidString, repository: fixture.repository,
      path: fixture.root + "/café-😀", provider: .git)
    let old = Date().addingTimeInterval(-7 * 24 * 3600)
    for path in ["", "tracked", ".gitignore"] {
      try FileManager.default.setAttributes(
        [.modificationDate: old], ofItemAtPath: allocation.path + "/" + path)
    }
    let escaped = allocation.path.replacingOccurrences(of: "é", with: "\\u00e9")
      .replacingOccurrences(of: "😀", with: "\\ud83d\\ude00")
    let invalid =
      "{\"type\":\"message\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"\(escaped)\\udc00\"}]}}\n"
    try Data(invalid.utf8).write(to: URL(fileURLWithPath: fixture.root + "/unicode.jsonl"))
    XCTAssertThrowsError(
      try fixture.registry.oneOffPreview(
        id: allocation.id, minimumIdle: 24 * 3600, transcriptDirectory: fixture.root))
    XCTAssertTrue(FileManager.default.fileExists(atPath: allocation.path))
  }

  func testModifiedTranscriptRechecksMentionWithoutReadingOldHistory() throws {
    let fixture = try Fixture()
    let allocation = try fixture.registry.start(
      branch: UUID().uuidString, repository: fixture.repository, provider: .git)
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let transcript = fixture.root + "/modified.jsonl"
    let line =
      "{\"type\":\"message\",\"timestamp\":\"\(formatter.string(from: Date()))\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"\(allocation.id)\"}]}}\n"
    try Data(line.utf8).write(to: URL(fileURLWithPath: transcript))
    let started = Date()
    try FileManager.default.setAttributes(
      [.modificationDate: started.addingTimeInterval(-3600)], ofItemAtPath: transcript)
    XCTAssertNil(
      try transcriptMentions([allocation], directory: fixture.root, modifiedSince: started)[
        allocation.id])
    try FileManager.default.setAttributes(
      [.modificationDate: started.addingTimeInterval(1)], ofItemAtPath: transcript)
    XCTAssertNotNil(
      try transcriptMentions([allocation], directory: fixture.root, modifiedSince: started)[
        allocation.id])
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
    XCTAssertEqual(offloaded.phase, .removed, offloaded.reason ?? "")
  }

  func testSweepDoesNotReclaimTouchedCheckpointUntilIdleAgain() throws {
    let fixture = try Fixture()
    let allocation = try fixture.registry.start(
      branch: UUID().uuidString, repository: fixture.repository, provider: .git)
    let offloaded = try XCTUnwrap(
      fixture.registry.offload(
        id: allocation.id, minimumIdle: 0, transcriptDirectory: fixture.root,
        isRemote: false
      ).first)
    XCTAssertEqual(offloaded.phase, .removed)
    _ = try fixture.registry.restore(allocation.id)
    try withRegistry(fixture.registry.stateDirectory) { store in
      var pending = try store.allocation(allocation.id)
      let recovery = try XCTUnwrap(pending.recovery)
      pending.recovery = RecoveryRecord(
        commit: recovery.commit, reference: recovery.reference, branch: recovery.branch,
        preservedAt: recovery.preservedAt, event: "manual-offload-local",
        lastFileActivity: Date().addingTimeInterval(-7_200))
      pending.offloadCleanup = OffloadCleanup(
        minimumIdle: 3_600, transcriptDirectory: fixture.root, nextCheckAt: nil)
      try store.save(pending)
    }
    _ = try fixture.registry.sweep()
    let waiting = try fixture.registry.inspect(allocation.id)
    XCTAssertEqual(waiting.phase, .retained)
    XCTAssertNotNil(waiting.offloadCleanup?.nextCheckAt)
    XCTAssertTrue(FileManager.default.fileExists(atPath: allocation.path))
    let old = Date().addingTimeInterval(-7_200)
    for path in ["", "tracked", ".gitignore"] {
      try FileManager.default.setAttributes(
        [.modificationDate: old], ofItemAtPath: allocation.path + "/" + path)
    }
    try withRegistry(fixture.registry.stateDirectory) { store in
      var pending = try store.allocation(allocation.id)
      pending.offloadCleanup?.nextCheckAt = nil
      try store.save(pending)
    }
    _ = try fixture.registry.sweep()
    XCTAssertEqual(try fixture.registry.inspect(allocation.id).phase, .removed)
    XCTAssertFalse(FileManager.default.fileExists(atPath: allocation.path))
  }

  func testExplicitZeroHourCleanupIgnoresStoredSweepDeadline() throws {
    let fixture = try Fixture()
    let allocation = try fixture.registry.start(
      branch: UUID().uuidString, repository: fixture.repository, provider: .git)
    _ = try fixture.registry.offload(
      id: allocation.id, minimumIdle: 0, transcriptDirectory: fixture.root, isRemote: false)
    _ = try fixture.registry.restore(allocation.id)
    try withRegistry(fixture.registry.stateDirectory) { store in
      var pending = try store.allocation(allocation.id)
      let recovery = try XCTUnwrap(pending.recovery)
      pending.recovery = RecoveryRecord(
        commit: recovery.commit, reference: recovery.reference, branch: recovery.branch,
        preservedAt: recovery.preservedAt, event: "manual-offload-local",
        lastFileActivity: Date().addingTimeInterval(-7_200))
      pending.offloadCleanup = OffloadCleanup(
        minimumIdle: 3_600, transcriptDirectory: fixture.root, nextCheckAt: nil)
      try store.save(pending)
    }
    _ = try fixture.registry.sweep()
    let waiting = try fixture.registry.inspect(allocation.id)
    XCTAssertTrue((waiting.offloadCleanup?.nextCheckAt ?? .distantPast) > Date())
    let result = try XCTUnwrap(
      fixture.registry.oneOffCleanup(
        id: allocation.id, minimumIdle: 0, transcriptDirectory: fixture.root
      ).first)
    XCTAssertEqual(result.phase, .removed, result.reason ?? "")
    XCTAssertFalse(FileManager.default.fileExists(atPath: allocation.path))
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
    XCTAssertNotNil(try transcriptMentions([allocation], directory: fixture.root)[allocation.id])
    XCTAssertEqual(result.phase, .blocked)
    XCTAssertTrue(result.reason?.contains("minimum idle age") == true)
    XCTAssertTrue(FileManager.default.fileExists(atPath: allocation.path))
  }

  func testCleanupNowEnrollsAnExistingCheckpointForAutomaticReclamation() throws {
    let fixture = try Fixture()
    let allocation = try fixture.registry.start(
      branch: UUID().uuidString, repository: fixture.repository, provider: .git)
    _ = try fixture.registry.offload(
      id: allocation.id, minimumIdle: 0, transcriptDirectory: fixture.root, isRemote: false)
    _ = try fixture.registry.restore(allocation.id)
    try withRegistry(fixture.registry.stateDirectory) { store in
      var pending = try store.allocation(allocation.id)
      let recovery = try XCTUnwrap(pending.recovery)
      pending.recovery = RecoveryRecord(
        commit: recovery.commit, reference: recovery.reference, branch: recovery.branch,
        preservedAt: recovery.preservedAt, event: "manual-offload-local",
        lastFileActivity: Date().addingTimeInterval(-7_200))
      pending.offloadCleanup = nil
      try store.save(pending)
    }
    let old = Date().addingTimeInterval(-7_200)
    for path in ["", "tracked", ".gitignore"] {
      try FileManager.default.setAttributes(
        [.modificationDate: old], ofItemAtPath: allocation.path + "/" + path)
    }
    let removed = try XCTUnwrap(
      fixture.registry.oneOffCleanup(
        id: allocation.id, minimumIdle: 3_600, transcriptDirectory: fixture.root
      ).first)
    XCTAssertEqual(removed.phase, .removed, removed.reason ?? "")
    XCTAssertFalse(FileManager.default.fileExists(atPath: allocation.path))
  }

  func testInterruptedManualCleanupResumesAfterIdle() throws {
    let fixture = try Fixture()
    let allocation = try fixture.registry.start(
      branch: UUID().uuidString, repository: fixture.repository, provider: .git)
    _ = try fixture.registry.offload(
      id: allocation.id, minimumIdle: 0, transcriptDirectory: fixture.root, isRemote: false)
    var pending = try fixture.registry.restore(allocation.id)
    let recovery = try XCTUnwrap(pending.recovery)
    pending.recovery = RecoveryRecord(
      commit: recovery.commit, reference: recovery.reference, branch: recovery.branch,
      preservedAt: recovery.preservedAt, event: "manual-cleanup",
      lastFileActivity: Date().addingTimeInterval(-7_200))
    pending.offloadCleanup = OffloadCleanup(
      minimumIdle: 3_600, transcriptDirectory: fixture.root, nextCheckAt: nil)
    pending.phase = .removing
    pending.isRemovalPending = true
    try withRegistry(fixture.registry.stateDirectory) { store in try store.save(pending) }
    _ = try fixture.registry.sweep()
    let retained = try fixture.registry.inspect(allocation.id)
    XCTAssertEqual(retained.phase, .retained)
    XCTAssertFalse(retained.isRemovalPending)
    XCTAssertTrue(FileManager.default.fileExists(atPath: allocation.path))
    let old = Date().addingTimeInterval(-7_200)
    for path in ["", "tracked", ".gitignore"] {
      try FileManager.default.setAttributes(
        [.modificationDate: old], ofItemAtPath: allocation.path + "/" + path)
    }
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
      "manual-cleanup")
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
