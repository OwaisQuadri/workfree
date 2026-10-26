import Foundation
import XCTest

@testable import Workscope

final class PolicyArgumentsTests: XCTestCase {
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
