import Darwin
import Foundation
import XCTest

@testable import Workscope

final class PolicyArgumentsTests: XCTestCase {
  func testRepositoryPolicyCLIRequiresExplicitScopeAndNeverTreatsSubcommandAsAllocation() throws {
    let fixture = try Fixture()
    for args in [
      ["cleanup-policy", "enable"],
      ["cleanup-policy", "enable", "--repo", fixture.repository, "--disposable-path", "ignored"],
      ["cleanup-policy", "show", "--repo", fixture.repository, "--grace-seconds", "0"],
      ["cleanup-policy", "enable", "--repo", fixture.repository, "--allow-cleanup"],
      ["cleanup-policy", "enable", "--repo", fixture.repository, "--grace-seconds", "-1"],
    ] {
      XCTAssertNotEqual(fixture.wait(try fixture.cli(args)), 0)
    }
    XCTAssertNil(
      try fixture.registry.repositoryCleanupPolicy(repository: fixture.repository).policy)
    for action in ["show", "enable", "show"] {
      XCTAssertEqual(
        fixture.wait(
          try fixture.cli([
            "--session-id", "operator", "--session-pid", String(getpid()),
            "cleanup-policy", action, "--repo", fixture.repository,
          ])), 0)
    }
    let policy = try fixture.registry.repositoryCleanupPolicy(repository: fixture.repository)
      .policy!
    XCTAssertEqual(policy.cleanupPolicy.graceSeconds, 60)
    XCTAssertEqual(
      fixture.wait(
        try fixture.cli([
          "start", "inherited", "--repo", fixture.repository, "--provider", "git",
          "--require-cleanup-policy",
        ])), 0)
    let allocation = try fixture.registry.list()[0]
    XCTAssertEqual(allocation.cleanupPolicySourceID, policy.id)
    XCTAssertFalse(allocation.isCleanupAuthorized)
    XCTAssertEqual(
      fixture.wait(
        try fixture.cli([
          "cleanup-policy", "revoke", "--repo", fixture.repository,
        ])), 0)
    XCTAssertNil(try fixture.registry.inspect(allocation.id).cleanupPolicy)
    XCTAssertNotEqual(
      fixture.wait(
        try fixture.cli([
          "start", "unauthorized", "--repo", fixture.repository, "--provider", "git",
          "--require-cleanup-policy",
        ])), 0)
    XCTAssertEqual(try fixture.registry.list().count, 1)
  }

  func testRepeatedDisposablePathsAuthorizeBothRootsWithoutAllowingOtherDuplicateOptions() throws {
    let fixture = try Fixture()
    try Data("ignored/\nother-generated/\n".utf8).write(
      to: URL(fileURLWithPath: fixture.repository + "/.gitignore"))
    _ = try git(fixture.repository, ["commit", "-am", "Two generated roots"])
    let allocation = try fixture.registry.start(
      branch: "two-roots", repository: fixture.repository, provider: .git)
    for root in ["ignored", "other-generated"] {
      try FileManager.default.createDirectory(
        atPath: allocation.path + "/" + root, withIntermediateDirectories: true)
      try Data("generated".utf8).write(
        to: URL(fileURLWithPath: allocation.path + "/" + root + "/output"))
    }
    XCTAssertNotEqual(
      fixture.wait(
        try fixture.cli([
          "authorize-cleanup", allocation.id, "--grace-seconds", "0", "--grace-seconds", "1",
        ])), 0)
    XCTAssertNotEqual(
      fixture.wait(
        try fixture.cli([
          "authorize-cleanup", allocation.id, "--disposable-path", "ignored", "--disposable-path",
          "../private",
        ])), 0)
    XCTAssertNil(try fixture.registry.inspect(allocation.id).cleanupPolicy)
    XCTAssertEqual(
      fixture.wait(
        try fixture.cli([
          "authorize-cleanup", allocation.id, "--grace-seconds", "0",
          "--disposable-path", "ignored", "--disposable-path", "other-generated",
        ])), 0)
    XCTAssertEqual(
      try fixture.registry.inspect(allocation.id).cleanupPolicy?.disposablePaths,
      ["ignored", "other-generated"])
    _ = try fixture.registry.sweep()
    XCTAssertEqual(try fixture.registry.inspect(allocation.id).phase, .removed)
  }
}
