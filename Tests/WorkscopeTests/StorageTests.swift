import Foundation
import XCTest

@testable import Workscope

final class StorageTests: XCTestCase {
  func testStatusSeparatesSharedAndPrivateBytesAndRecordsRemovals() throws {
    let fixture = try Fixture()
    let payload = Data(repeating: 7, count: 2_000_000)
    try payload.write(to: URL(fileURLWithPath: fixture.repository + "/large"))
    _ = try git(fixture.repository, ["add", "large"])
    _ = try git(fixture.repository, ["commit", "-m", "Large"])
    let allocation = try fixture.start("storage")
    let fresh = try fixture.registry.status(since: 86_400)
    let worktree = try XCTUnwrap(fresh.repositories.first?.worktrees.first)
    XCTAssertGreaterThanOrEqual(worktree.usage.fullBytes, 2_000_000)
    XCTAssertLessThan(worktree.usage.privateBytes, 200_000)
    XCTAssertGreaterThanOrEqual(fresh.live.savedBytes, 1_800_000)

    try Data(repeating: 9, count: 1_000_000).write(
      to: URL(fileURLWithPath: allocation.path + "/large"))
    _ = try git(allocation.path, ["commit", "-am", "Change"])
    let changed = try fixture.registry.status(since: 86_400)
    XCTAssertGreaterThanOrEqual(changed.live.privateBytes, 1_000_000)

    let removed = try fixture.registry.finish(allocation.id)
    XCTAssertEqual(removed.phase, .removed)
    XCTAssertGreaterThanOrEqual(removed.reclaimedBytes ?? 0, 1_000_000)
    let history = try fixture.registry.status(since: 86_400, isLiveMeasured: false)
    XCTAssertEqual(history.removedCount, 1)
    XCTAssertEqual(history.reclaimedBytes, removed.reclaimedBytes)
    try fixture.inject(
      removed, overrides: ["removedAt": Date().timeIntervalSinceReferenceDate - 172_800])
    XCTAssertEqual(try fixture.registry.status(since: 86_400).removedCount, 0)
    XCTAssertEqual(try fixture.registry.status(since: nil).removedCount, 1)
  }
}
