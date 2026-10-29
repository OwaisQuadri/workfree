import CSQLite
import Darwin
import Foundation
import XCTest

@testable import Workscope

final class SessionCompatibilityTests: XCTestCase {
  func testFirstClaimAtomicallyBlocksLegacyCleanupAndOwnerMutationWithoutDowngrade() throws {
    guard let legacy = ProcessInfo.processInfo.environment["WORKFREE_LEGACY_EXECUTABLE"] else {
      throw XCTSkip("Set WORKFREE_LEGACY_EXECUTABLE to a pre-conversation-claims wf build")
    }
    let fixture = try Fixture()
    let output = try command(
      legacy,
      [
        "--state-dir", fixture.registry.stateDirectory, "--json", "start", "compatibility",
        "--repo", fixture.repository, "--provider", "git",
      ])
    let allocation = try JSONDecoder().decode(Allocation.self, from: Data(output.utf8))
    _ = try fixture.registry.authorizeCleanup(allocation.id, graceSeconds: 0)
    XCTAssertEqual(try version(fixture), 1)
    _ = try command(
      legacy, ["--state-dir", fixture.registry.stateDirectory, "inspect", allocation.id])
    let host = Process()
    host.executableURL = URL(fileURLWithPath: "/bin/cat")
    let input = Pipe()
    host.standardInput = input
    host.standardOutput = FileHandle.nullDevice
    try host.run()
    defer {
      if host.isRunning {
        host.terminate()
        host.waitUntilExit()
      }
    }
    let conversation = try Registry(
      stateDirectory: fixture.registry.stateDirectory,
      conversation: ConversationContext(sessionID: "live", processID: host.processIdentifier))
    _ = try conversation.claim(allocation.id)
    XCTAssertEqual(try version(fixture), 2)
    let claims = try fixture.registry.inspect(allocation.id).conversationClaims
    for arguments in [
      ["sweep"], ["finish", allocation.id],
      ["retain", allocation.id, "--owner", "old-writer", "--kind", "workspace"],
    ] {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: legacy)
      process.arguments = ["--state-dir", fixture.registry.stateDirectory, "--json"] + arguments
      process.standardOutput = FileHandle.nullDevice
      let errors = Pipe()
      process.standardError = errors
      try process.run()
      process.waitUntilExit()
      XCTAssertNotEqual(process.terminationStatus, 0)
      let error = String(
        decoding: try errors.fileHandleForReading.readToEnd() ?? Data(), as: UTF8.self)
      XCTAssertTrue(error.contains("Unsupported registry version"), error)
      XCTAssertEqual(try fixture.registry.inspect(allocation.id).conversationClaims, claims)
      XCTAssertTrue(try isPresent(allocation.path))
    }
    try input.fileHandleForWriting.close()
    host.waitUntilExit()
    _ = try fixture.registry.sweep()
    XCTAssertEqual(try fixture.registry.inspect(allocation.id).phase, .removed)
    XCTAssertEqual(try version(fixture), 2)
  }

  private func version(_ fixture: Fixture) throws -> Int32 {
    var database: OpaquePointer?
    try require(
      sqlite3_open_v2(
        fixture.registry.stateDirectory + "/registry.sqlite", &database, SQLITE_OPEN_READONLY, nil)
        == SQLITE_OK, "Cannot inspect test registry")
    defer { sqlite3_close(database) }
    var statement: OpaquePointer?
    try require(
      sqlite3_prepare_v2(database, "PRAGMA user_version", -1, &statement, nil) == SQLITE_OK,
      "Cannot inspect test version")
    defer { sqlite3_finalize(statement) }
    try require(sqlite3_step(statement) == SQLITE_ROW, "Missing test version")
    return sqlite3_column_int(statement, 0)
  }
}
