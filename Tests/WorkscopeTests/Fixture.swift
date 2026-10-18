import CSQLite
import Darwin
import Foundation
import XCTest

@testable import Workscope

final class Fixture {
  let root: String
  let repository: String
  let registry: Registry
  let binary: String

  init() throws {
    root = try canonical("/tmp/workfree-tests-" + UUID().uuidString)
    repository = root + "/repo"
    registry = try Registry(stateDirectory: root + "/state")
    binary =
      URL(fileURLWithPath: #filePath).deletingLastPathComponent()
      .deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent(".build/debug/wf").path
    try FileManager.default.createDirectory(atPath: repository, withIntermediateDirectories: true)
    _ = try git(repository, ["init", "-b", "main"])
    _ = try git(repository, ["config", "user.name", "Workfree tests"])
    _ = try git(repository, ["config", "user.email", "workfree@example.invalid"])
    try Data("tracked\n".utf8).write(to: URL(fileURLWithPath: repository + "/tracked"))
    try Data("ignored/\n".utf8).write(to: URL(fileURLWithPath: repository + "/.gitignore"))
    _ = try git(repository, ["add", "."])
    _ = try git(repository, ["commit", "-m", "Fixture"])
  }

  deinit { try? FileManager.default.removeItem(atPath: root) }

  func start(_ branch: String = UUID().uuidString, isAuthorized: Bool = true) throws -> Allocation {
    try registry.start(
      branch: branch, repository: repository, isCleanupAuthorized: isAuthorized, provider: .simgit)
  }

  func cli(_ arguments: [String], environment: [String: String]? = nil) throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = ["--state-dir", registry.stateDirectory, "--json"] + arguments
    process.environment = environment ?? ProcessInfo.processInfo.environment
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    return process
  }

  @discardableResult
  func wait(_ process: Process) -> Int32 {
    process.waitUntilExit()
    return process.terminationStatus
  }

  func awaitFile(_ path: String) throws {
    let deadline = Date().addingTimeInterval(15)
    while !FileManager.default.fileExists(atPath: path) {
      try require(Date() < deadline, "Timed out awaiting \(path)")
      Thread.sleep(forTimeInterval: 0.01)
    }
  }

  func inject(_ allocation: Allocation, overrides: [String: Any] = [:]) throws {
    var object =
      try JSONSerialization.jsonObject(with: JSONEncoder().encode(allocation)) as! [String: Any]
    for (key, value) in overrides { object[key] = value }
    let data = try JSONSerialization.data(withJSONObject: object)
    var database: OpaquePointer?
    try require(
      sqlite3_open(registry.stateDirectory + "/registry.sqlite", &database) == SQLITE_OK,
      "Cannot open test registry")
    defer { sqlite3_close(database) }
    let text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "'", with: "''")
    try require(
      sqlite3_exec(
        database,
        "UPDATE allocations SET data='\(text)', path='\(object["path"] as! String)' WHERE id='\(allocation.id)'",
        nil, nil, nil) == SQLITE_OK, "Cannot inject interrupted state")
  }

  func wrapper(isAfterRemoval: Bool) throws -> [String: String] {
    let directory = root + "/bin"
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let actual = try command("/usr/bin/which", ["simgit"]).trimmingCharacters(in: .newlines)
    let action = isAfterRemoval ? "\"\(actual)\" \"$@\" || exit $?" : ":"
    let tail = isAfterRemoval ? "exit 0" : "exec \"\(actual)\" \"$@\""
    let script = """
      #!/bin/sh
      if [ "$1" != remove ]; then exec "\(actual)" "$@"; fi
      \(action)
      echo $$ > "\(root)/provider.pid"
      touch "\(root)/provider.ready"
      while [ ! -e "\(root)/provider.continue" ]; do sleep 0.02; done
      \(tail)
      """
    try Data(script.utf8).write(to: URL(fileURLWithPath: directory + "/simgit"))
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: directory + "/simgit")
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = directory + ":" + (environment["PATH"] ?? "")
    return environment
  }
}
