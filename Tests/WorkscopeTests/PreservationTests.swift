import Foundation
import XCTest

@testable import Workscope

final class PreservationTests: XCTestCase {
  func testTrackedStagedUntrackedIgnoredAndHiddenIndexChangesBlockRemoval() throws {
    let fixture = try Fixture()
    for kind in ["tracked", "staged", "untracked", "ignored", "assumed", "skipped"] {
      let allocation = try fixture.start()
      let file: String
      switch kind {
      case "ignored":
        try FileManager.default.createDirectory(
          atPath: allocation.path + "/ignored", withIntermediateDirectories: true)
        file = allocation.path + "/ignored/result"
      case "untracked": file = allocation.path + "/result"
      default: file = allocation.path + "/tracked"
      }
      if kind == "assumed" {
        _ = try git(allocation.path, ["update-index", "--assume-unchanged", "tracked"])
      }
      if kind == "skipped" {
        _ = try git(allocation.path, ["update-index", "--skip-worktree", "tracked"])
      }
      try Data("valuable".utf8).write(to: URL(fileURLWithPath: file))
      if kind == "staged" { _ = try git(allocation.path, ["add", "tracked"]) }
      let blocked = try fixture.registry.finish(allocation.id)
      XCTAssertEqual(blocked.phase, .blocked, kind)
      XCTAssertEqual(try String(contentsOfFile: file, encoding: .utf8), "valuable", kind)
      XCTAssertFalse(blocked.isRemovalPending, kind)
    }
  }

  func testUnreferencedDetachedCommitIsNotRemoved() throws {
    let fixture = try Fixture()
    let allocation = try fixture.start()
    _ = try git(allocation.path, ["checkout", "--detach"])
    try Data("detached result".utf8).write(to: URL(fileURLWithPath: allocation.path + "/tracked"))
    _ = try git(allocation.path, ["commit", "-am", "Detached result"])
    let head = try git(allocation.path, ["rev-parse", "HEAD"])
    let blocked = try fixture.registry.finish(allocation.id)
    XCTAssertEqual(blocked.reason, "No ordinary branch or tag preserves HEAD")
    XCTAssertEqual(try git(allocation.path, ["rev-parse", "HEAD"]), head)
    _ = try git(fixture.repository, ["tag", "preserved", head])
    XCTAssertEqual(try fixture.registry.recover(allocation.id).phase, .removed)
  }

  func testReplacedCheckoutAndChangedMarkerNeverSatisfyOldRemoval() throws {
    let fixture = try Fixture()
    let allocation = try fixture.start("original")
    _ = try command("/usr/bin/env", ["simgit", "remove", allocation.path], at: fixture.repository)
    _ = try command(
      "/usr/bin/env",
      ["simgit", "add", "--attach", "original", "--path", allocation.path, "--require-cow"],
      at: fixture.repository)
    XCTAssertEqual(try fixture.registry.finish(allocation.id).phase, .blocked)
    XCTAssertTrue(FileManager.default.fileExists(atPath: allocation.path))
    XCTAssertThrowsError(
      try fixture.registry.retain(allocation.id, owner: "replacement", kind: .workspace))
    let other = try fixture.start()
    try Data("different identity".utf8).write(
      to: URL(fileURLWithPath: other.admin! + "/workfree-allocation"))
    XCTAssertEqual(try fixture.registry.finish(other.id).reason, "Allocation marker changed")
    XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
  }

  func testPrimaryCheckoutCannotPassLinkedIdentityCheck() throws {
    let fixture = try Fixture()
    let allocation = try fixture.start()
    try fixture.inject(
      allocation, overrides: ["path": fixture.repository, "admin": fixture.repository + "/.git"])
    let blocked = try fixture.registry.finish(allocation.id)
    XCTAssertEqual(blocked.reason, "Primary checkout cannot be removed")
    XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.repository + "/tracked"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: allocation.path))
  }

  func testAbsentAliasedPathWithOrphanRegistrationRemainsBlocked() throws {
    let fixture = try Fixture()
    var allocation = try fixture.start()
    XCTAssertTrue(allocation.path.hasPrefix("/private/tmp/"))
    let temporaryAlias = String(allocation.path.dropFirst("/private".count))
    let alias =
      (temporaryAlias as NSString).deletingLastPathComponent + "/"
      + (temporaryAlias as NSString).lastPathComponent.uppercased()
    try FileManager.default.moveItem(atPath: allocation.path, toPath: allocation.path + ".moved")
    allocation.retiredOwners = allocation.owners
    allocation.owners = [:]
    allocation.phase = .removing
    allocation.isRemovalPending = true
    try fixture.inject(allocation, overrides: ["path": alias])
    let blocked = try fixture.registry.recover(allocation.id)
    XCTAssertEqual(blocked.phase, .blocked)
    XCTAssertEqual(blocked.reason, "Removal left a registration")
    XCTAssertTrue(try registeredPaths(fixture.repository).contains(allocation.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: allocation.path + ".moved/.git"))
    XCTAssertThrowsError(try fixture.registry.retain(allocation.id, owner: "late", kind: .task))
    XCTAssertEqual(try fixture.registry.recover(allocation.id).phase, .blocked)
  }

  func testCorruptMissingAndPermissionlessRegistryFailClosed() throws {
    let fixture = try Fixture()
    let allocation = try fixture.start()
    try fixture.inject(allocation, overrides: ["isCleanupAuthorized": NSNull()])
    XCTAssertThrowsError(try fixture.registry.finish(allocation.id))
    XCTAssertTrue(FileManager.default.fileExists(atPath: allocation.path))
    try Data("not sqlite".utf8).write(
      to: URL(fileURLWithPath: fixture.registry.stateDirectory + "/registry.sqlite"))
    XCTAssertThrowsError(try fixture.registry.recover(allocation.id))
    try FileManager.default.removeItem(atPath: fixture.registry.stateDirectory + "/registry.sqlite")
    XCTAssertThrowsError(try fixture.registry.list())
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: fixture.registry.stateDirectory + "/registry.sqlite"))
    let inside = try Registry(stateDirectory: fixture.repository + "/state")
    XCTAssertThrowsError(try inside.list())
    XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.repository + "/state"))
    let attributes = try FileManager.default.attributesOfItem(
      atPath: fixture.registry.stateDirectory)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
  }
}
