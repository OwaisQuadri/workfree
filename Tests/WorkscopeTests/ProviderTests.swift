import Foundation
import XCTest

@testable import Workscope

final class ProviderTests: XCTestCase {
  func testNativeGitWithoutSimgitKeepsPermissionAndExecutionGates() throws {
    let fixture = try Fixture()
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = "/usr/bin:/bin"
    XCTAssertEqual(
      fixture.wait(
        try fixture.cli(
          ["start", "unauthorized", "--repo", fixture.repository], environment: environment)), 0)
    let denied = try XCTUnwrap(fixture.registry.list().first)
    XCTAssertEqual(denied.provider, .git)
    XCTAssertFalse(denied.isCleanupAuthorized)
    XCTAssertEqual(try fixture.registry.finish(denied.id).reason, "Cleanup is not authorized")
    XCTAssertTrue(FileManager.default.fileExists(atPath: denied.path))
    XCTAssertEqual(
      fixture.wait(
        try fixture.cli(
          ["start", "native", "--repo", fixture.repository, "--base", "main", "--allow-cleanup"],
          environment: environment)), 0)
    let allocation = try XCTUnwrap(fixture.registry.list().first { $0.id != denied.id })
    XCTAssertEqual(allocation.provider, .git)
    XCTAssertEqual(
      fixture.wait(
        try fixture.cli(
          ["run", allocation.id, "--owner", "native-scope", "--", "/bin/sh", "-c", "exit 17"],
          environment: environment)), 17)
    _ = try fixture.registry.finish(allocation.id)
    XCTAssertEqual(
      try fixture.registry.inspect(allocation.id).owners["native-scope"]?.entryStatus, 17)
    XCTAssertThrowsError(try fixture.registry.release(allocation.id, owner: "native-scope"))
    XCTAssertEqual(try fixture.registry.recover(allocation.id).phase, .retained)
    XCTAssertEqual(
      fixture.wait(
        try fixture.cli(
          ["close-scope", allocation.id, "--owner", "native-scope"], environment: environment)), 0)
    XCTAssertEqual(try fixture.registry.inspect(allocation.id).phase, .removed)
    XCTAssertFalse(FileManager.default.fileExists(atPath: allocation.path))
    XCTAssertFalse(try isRegistered(fixture.repository, allocation.path))
    XCTAssertFalse(
      try git(fixture.repository, ["show-ref", "--verify", "refs/heads/native"]).isEmpty)
  }

  func testRequireCowRejectsNativeAndUnavailableSimgitWithoutAllocation() throws {
    let fixture = try Fixture()
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = "/usr/bin:/bin"
    for options in [
      ["--require-cow"], ["--provider", "simgit"], ["--provider", "git", "--require-cow"],
    ] {
      let process = try fixture.cli(
        ["start", "must-not-exist", "--repo", fixture.repository] + options,
        environment: environment)
      XCTAssertNotEqual(fixture.wait(process), 0)
    }
    XCTAssertTrue(try fixture.registry.list().isEmpty)
    XCTAssertThrowsError(
      try git(fixture.repository, ["show-ref", "--verify", "refs/heads/must-not-exist"]))
  }

  func testSelectedProviderFailureNeverFallsBack() throws {
    let fixture = try Fixture()
    let environment = try rejectingSimgit(fixture)
    let automatic = try fixture.cli(
      ["start", "must-not-exist", "--repo", fixture.repository], environment: environment)
    XCTAssertNotEqual(fixture.wait(automatic), 0)
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root + "/simgit.invoked"))
    XCTAssertTrue(try fixture.registry.list().isEmpty)
    XCTAssertThrowsError(
      try git(fixture.repository, ["show-ref", "--verify", "refs/heads/must-not-exist"]))
    try FileManager.default.removeItem(atPath: fixture.root + "/simgit.invoked")
    let native = try fixture.cli(
      [
        "start", "failed-native", "--repo", fixture.repository, "--provider", "git", "--base",
        "missing-ref",
      ], environment: environment)
    XCTAssertNotEqual(fixture.wait(native), 0)
    let allocation = try XCTUnwrap(fixture.registry.list().first)
    XCTAssertEqual(allocation.provider, .git)
    XCTAssertEqual(allocation.phase, .failed)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root + "/simgit.invoked"))
  }

  func testRecordedProviderControlsRemovalWhenAvailabilityChanges() throws {
    let fixture = try Fixture()
    let native = try fixture.registry.start(
      branch: "explicit-native", repository: fixture.repository, isCleanupAuthorized: true,
      provider: .git)
    let rejected = try rejectingSimgit(fixture)
    XCTAssertEqual(fixture.wait(try fixture.cli(["finish", native.id], environment: rejected)), 0)
    XCTAssertEqual(try fixture.registry.inspect(native.id).phase, .removed)
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root + "/simgit.invoked"))
    let cow = try fixture.registry.start(
      branch: "cow", repository: fixture.repository, isCleanupAuthorized: true, provider: .simgit,
      isCowRequired: true)
    XCTAssertEqual(cow.provider, .simgit)
    var unavailable = ProcessInfo.processInfo.environment
    unavailable["PATH"] = "/usr/bin:/bin"
    XCTAssertEqual(fixture.wait(try fixture.cli(["finish", cow.id], environment: unavailable)), 0)
    let blocked = try fixture.registry.inspect(cow.id)
    XCTAssertEqual(blocked.provider, .simgit)
    XCTAssertEqual(blocked.phase, .blocked)
    XCTAssertTrue(blocked.isRemovalPending)
    XCTAssertTrue(FileManager.default.fileExists(atPath: cow.path))
    XCTAssertEqual(try fixture.registry.recover(cow.id).phase, .removed)
  }

  func testNativeGitPreservesDirtyIgnoredDetachedAndReplacementWorktrees() throws {
    let fixture = try Fixture()
    for kind in ["tracked", "ignored", "detached", "replacement"] {
      let allocation = try fixture.registry.start(
        branch: kind, repository: fixture.repository, isCleanupAuthorized: true, provider: .git)
      switch kind {
      case "ignored":
        try FileManager.default.createDirectory(
          atPath: allocation.path + "/ignored", withIntermediateDirectories: true)
        try Data("valuable".utf8).write(
          to: URL(fileURLWithPath: allocation.path + "/ignored/result"))
      case "replacement":
        _ = try git(fixture.repository, ["worktree", "remove", "--", allocation.path])
        _ = try git(fixture.repository, ["worktree", "add", "--", allocation.path, kind])
      default:
        try Data("valuable".utf8).write(to: URL(fileURLWithPath: allocation.path + "/tracked"))
        if kind == "detached" {
          _ = try git(allocation.path, ["checkout", "--detach"])
          _ = try git(allocation.path, ["commit", "-am", "Unreferenced result"])
        }
      }
      let blocked = try fixture.registry.finish(allocation.id)
      XCTAssertEqual(blocked.phase, .blocked, kind)
      XCTAssertTrue(FileManager.default.fileExists(atPath: allocation.path), kind)
      if kind == "detached" {
        XCTAssertEqual(blocked.reason, "No ordinary branch or tag preserves HEAD")
      }
      if kind == "tracked" || kind == "detached" {
        XCTAssertEqual(
          try String(contentsOfFile: allocation.path + "/tracked", encoding: .utf8), "valuable")
      }
      if kind == "ignored" {
        XCTAssertEqual(
          try String(contentsOfFile: allocation.path + "/ignored/result", encoding: .utf8),
          "valuable")
      }
    }
  }

  private func rejectingSimgit(_ fixture: Fixture) throws -> [String: String] {
    let directory = fixture.root + "/bin"
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let script = "#!/bin/sh\ntouch '\(fixture.root)/simgit.invoked'\nexit 23\n"
    try Data(script.utf8).write(to: URL(fileURLWithPath: directory + "/simgit"))
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: directory + "/simgit")
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = directory + ":" + (environment["PATH"] ?? "")
    return environment
  }
}
