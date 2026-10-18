import Foundation
import XCTest

@testable import Workscope

final class IdentityTests: XCTestCase {
  func testRealpathPreservesIdentityAcrossExistingAndMissingAliasesAndSymlinkParents() throws {
    let fixture = try Fixture()
    let real = fixture.root + "/real"
    try FileManager.default.createDirectory(
      atPath: real + "/nested", withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      atPath: fixture.root + "/link", withDestinationPath: real + "/nested")
    XCTAssertEqual(try canonical(fixture.root + "/link/../missing"), real + "/missing")
    let alias = String(fixture.root.dropFirst("/private".count))
    XCTAssertEqual(try canonical(alias), fixture.root)
    XCTAssertEqual(try canonical(alias + "/absent/child"), fixture.root + "/absent/child")
  }

  func testDoctorImpersonationCannotReserveOrCreateAnAllocation() throws {
    let fixture = try Fixture()
    let directory = fixture.root + "/bin"
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let actual = try command("/usr/bin/which", ["simgit"]).trimmingCharacters(in: .newlines)
    let script = """
      #!/bin/sh
      "\(actual)" "$@" | /usr/bin/sed 's/"identity": "simgit"/"identity": "git"/'
      """
    try Data(script.utf8).write(to: URL(fileURLWithPath: directory + "/simgit"))
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o700], ofItemAtPath: directory + "/simgit")
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = directory + ":" + (environment["PATH"] ?? "")
    let process = try fixture.cli(
      ["start", "must-not-exist", "--repo", fixture.repository], environment: environment)
    XCTAssertNotEqual(fixture.wait(process), 0)
    XCTAssertTrue(try fixture.registry.list().isEmpty)
    XCTAssertThrowsError(
      try git(fixture.repository, ["show-ref", "--verify", "refs/heads/must-not-exist"]))
  }

  func testRegistryAndLockRequirePrivateRegularFiles() throws {
    let fixture = try Fixture()
    _ = try fixture.start()
    for name in ["registry.sqlite", "registry.lock"] {
      let path = fixture.registry.stateDirectory + "/" + name
      let attributes = try FileManager.default.attributesOfItem(atPath: path)
      XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
      try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
      XCTAssertThrowsError(try fixture.registry.list())
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    }
  }
}
