import Darwin
import Foundation
import XCTest

@testable import Workscope

final class ProcessTests: XCTestCase {
  func testConcurrentProcessesDoNotLoseOwnersOrShareAReservedPath() throws {
    let fixture = try Fixture()
    let allocation = try fixture.start()
    let acquisitions = try (1...6).map {
      try fixture.cli(["retain", allocation.id, "--owner", "reader:\($0)", "--kind", "workspace"])
    }
    for process in acquisitions { XCTAssertEqual(fixture.wait(process), 0) }
    XCTAssertEqual(try fixture.registry.inspect(allocation.id).owners.count, 7)
    let releases = try (1...6).map {
      try fixture.cli(["release", allocation.id, "--owner", "reader:\($0)"])
    }
    for process in releases { XCTAssertEqual(fixture.wait(process), 0) }
    XCTAssertEqual(try fixture.registry.inspect(allocation.id).owners.count, 1)
    let path = fixture.root + "/contended"
    let starts = try ["first", "second"].map {
      try fixture.cli(["start", $0, "--repo", fixture.repository, "--path", path])
    }
    XCTAssertEqual(starts.map { fixture.wait($0) }.filter { $0 == 0 }.count, 1)
    XCTAssertEqual(try fixture.registry.list().filter { $0.path == path }.count, 1)
  }

  func testAcquisitionWaitsForRemovalAndNeverReturnsADeletedPath() throws {
    let fixture = try Fixture()
    let allocation = try fixture.start()
    let remover = try fixture.cli(
      ["finish", allocation.id], environment: fixture.wrapper(isAfterRemoval: false))
    try fixture.awaitFile(fixture.root + "/provider.ready")
    let acquirer = try fixture.cli([
      "retain", allocation.id, "--owner", "late", "--kind", "workspace",
    ])
    Thread.sleep(forTimeInterval: 0.15)
    XCTAssertTrue(acquirer.isRunning)
    try Data().write(to: URL(fileURLWithPath: fixture.root + "/provider.continue"))
    XCTAssertEqual(fixture.wait(remover), 0)
    XCTAssertNotEqual(fixture.wait(acquirer), 0)
    XCTAssertEqual(try fixture.registry.inspect(allocation.id).phase, .removed)
    XCTAssertFalse(FileManager.default.fileExists(atPath: allocation.path))
  }

  func testManagerKillBeforeAndAfterPhysicalRemovalKeepsDurableIntent() throws {
    for isAfterRemoval in [false, true] {
      let fixture = try Fixture()
      let allocation = try fixture.start()
      let manager = try fixture.cli(
        ["finish", allocation.id], environment: fixture.wrapper(isAfterRemoval: isAfterRemoval))
      try fixture.awaitFile(fixture.root + "/provider.ready")
      XCTAssertEqual(kill(manager.processIdentifier, SIGKILL), 0)
      manager.waitUntilExit()
      let interrupted = try fixture.registry.inspect(allocation.id)
      XCTAssertEqual(interrupted.phase, .removing)
      XCTAssertTrue(interrupted.isRemovalPending)
      XCTAssertTrue(interrupted.owners.isEmpty)
      XCTAssertThrowsError(
        try fixture.registry.retain(allocation.id, owner: "late", kind: .workspace))
      let provider = try Int32(
        String(contentsOfFile: fixture.root + "/provider.pid", encoding: .utf8).trimmingCharacters(
          in: .whitespacesAndNewlines)
      ).unwrap()
      XCTAssertEqual(kill(provider, SIGKILL), 0)
      let recovered = try fixture.registry.recover(allocation.id)
      XCTAssertEqual(recovered.phase, .removed)
      XCTAssertEqual(try fixture.registry.recover(allocation.id).phase, .removed)
      XCTAssertFalse(FileManager.default.fileExists(atPath: allocation.path))
      XCTAssertFalse(try registeredPaths(fixture.repository).contains(allocation.path))
    }
  }

  func testKilledEntryManagerDoesNotExpireExecutionOwnership() throws {
    let fixture = try Fixture()
    let allocation = try fixture.start()
    let script =
      "echo $$ > '\(fixture.root)/entry.pid'; touch '\(fixture.root)/entry.ready'; exec /bin/sleep 30"
    let manager = try fixture.cli([
      "run", allocation.id, "--owner", "uncertain", "--", "/bin/sh", "-c", script,
    ])
    try fixture.awaitFile(fixture.root + "/entry.ready")
    XCTAssertEqual(kill(manager.processIdentifier, SIGKILL), 0)
    manager.waitUntilExit()
    _ = try fixture.registry.finish(allocation.id)
    let recovered = try fixture.registry.recover(allocation.id)
    XCTAssertEqual(recovered.phase, .retained)
    XCTAssertNotNil(recovered.owners["uncertain"])
    XCTAssertNil(recovered.owners["uncertain"]?.entryStatus)
    let entry = try Int32(
      String(contentsOfFile: fixture.root + "/entry.pid", encoding: .utf8).trimmingCharacters(
        in: .whitespacesAndNewlines)
    ).unwrap()
    XCTAssertEqual(kill(entry, SIGKILL), 0)
    XCTAssertEqual(try fixture.registry.recover(allocation.id).phase, .retained)
    XCTAssertTrue(FileManager.default.fileExists(atPath: allocation.path))
  }

  func testRealBackgroundChildRetainsUntilExplicitCooperativeClosure() throws {
    let fixture = try Fixture()
    let allocation = try fixture.start()
    let script = """
      set -e
      "$WORKFREE_BINARY" --state-dir "$WORKFREE_STATE" retain "$WORKFREE_ALLOCATION_ID" --owner child --kind execution >/dev/null
      /bin/sh -c '
        cd "$WORKFREE_PATH" || exit 1
        echo $$ > "$WORKFREE_ROOT/child.pid"
        touch "$WORKFREE_ROOT/child.ready"
        while [ ! -e "$WORKFREE_ROOT/child.finish" ]; do sleep 0.02; done
        cd / || exit 1
        "$WORKFREE_BINARY" --state-dir "$WORKFREE_STATE" close-scope "$WORKFREE_ALLOCATION_ID" --owner child >"$WORKFREE_ROOT/child.result"
        touch "$WORKFREE_ROOT/child.closed"
      ' </dev/null >"$WORKFREE_ROOT/child.log" 2>&1 &
      exit 23
      """
    var environment = ProcessInfo.processInfo.environment
    environment["WORKFREE_BINARY"] = fixture.binary
    environment["WORKFREE_STATE"] = fixture.registry.stateDirectory
    environment["WORKFREE_ROOT"] = fixture.root
    let manager = try fixture.cli(
      ["run", allocation.id, "--owner", "parent", "--", "/bin/sh", "-c", script],
      environment: environment)
    XCTAssertEqual(fixture.wait(manager), 23)
    try fixture.awaitFile(fixture.root + "/child.ready")
    let child = try Int32(
      String(contentsOfFile: fixture.root + "/child.pid", encoding: .utf8).trimmingCharacters(
        in: .whitespacesAndNewlines)
    ).unwrap()
    XCTAssertEqual(kill(child, 0), 0)
    _ = try fixture.registry.finish(allocation.id)
    let exited = try fixture.registry.inspect(allocation.id)
    XCTAssertEqual(exited.owners["parent"]?.entryStatus, 23)
    XCTAssertEqual(Set(exited.owners.keys), ["parent", "child"])
    let childOnly = try fixture.registry.closeScope(allocation.id, owner: "parent")
    XCTAssertEqual(Set(childOnly.owners.keys), ["child"])
    XCTAssertTrue(FileManager.default.fileExists(atPath: allocation.path))
    XCTAssertEqual(kill(child, 0), 0)
    try Data().write(to: URL(fileURLWithPath: fixture.root + "/child.finish"))
    try fixture.awaitFile(fixture.root + "/child.closed")
    XCTAssertEqual(try fixture.registry.inspect(allocation.id).phase, .removed)
    XCTAssertFalse(FileManager.default.fileExists(atPath: allocation.path))
  }
}

extension Optional {
  fileprivate func unwrap() throws -> Wrapped {
    guard let self else { throw WorkscopeError("Missing test value") }
    return self
  }
}
