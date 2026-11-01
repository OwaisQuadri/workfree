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

  func testOverviewUsesSavedMeasurementsAndExcludesOwnedCleanup() throws {
    let fixture = try Fixture()
    _ = try fixture.registry.enableRepositoryCleanupPolicy(
      repository: fixture.repository, graceSeconds: 3_600)
    let allocation = try fixture.registry.start(
      branch: "overview", repository: fixture.repository, provider: .git)
    let unmeasured = try fixture.registry.overview(since: 86_400)
    XCTAssertNil(unmeasured.savedBytes)
    XCTAssertEqual(unmeasured.measuredCount, 0)

    let refreshed = try fixture.registry.refreshOverview(since: 86_400)
    XCTAssertEqual(refreshed.worktreeCount, 1)
    XCTAssertEqual(refreshed.measuredCount, 1)
    XCTAssertNotNil(refreshed.measuredAt)
    let original = try withRegistry(fixture.registry.stateDirectory) { store in
      try XCTUnwrap(store.usageMeasurement(allocation.id))
    }
    try withRegistry(fixture.registry.stateDirectory) { store in
      try store.save(store.allocation(allocation.id))
    }
    try Data(repeating: 3, count: 100_000).write(
      to: URL(fileURLWithPath: allocation.path + "/new-data"))
    let saved = try withRegistry(fixture.registry.stateDirectory) {
      try $0.usageMeasurement(allocation.id)
    }
    XCTAssertEqual(try fixture.registry.overview(since: 86_400).measuredAt, original.measuredAt)
    XCTAssertEqual(saved?.usage, original.usage)
    _ = try fixture.registry.refreshOverview(since: 86_400)
    let updated = try withRegistry(fixture.registry.stateDirectory) {
      try $0.usageMeasurement(allocation.id)
    }
    XCTAssertGreaterThan(try XCTUnwrap(updated).usage.privateBytes, original.usage.privateBytes)

    try FileManager.default.removeItem(atPath: allocation.path + "/new-data")
    _ = try fixture.registry.finish(allocation.id)
    let pending = try fixture.registry.overview(since: 86_400)
    XCTAssertEqual(pending.pendingCount, 1)
    XCTAssertNotNil(pending.pendingBytes)
    XCTAssertNotNil(pending.nextEligibleAt)
    XCTAssertEqual(pending.nextEligibleCount, 1)
    _ = try fixture.registry.retain(allocation.id, owner: "workspace", kind: .workspace)
    let owned = try fixture.registry.overview(since: 86_400)
    XCTAssertEqual(owned.pendingCount, 0)
    XCTAssertNil(owned.nextEligibleAt)
    XCTAssertTrue(owned.text.contains("0 KB   pending cleanup · 0 worktrees"))
  }

  func testRestoreDiscardsMeasurementsFromTheRemovedCheckout() throws {
    let fixture = try Fixture()
    let allocation = try fixture.start("restored-storage")
    XCTAssertEqual(try fixture.registry.refreshOverview(since: nil).measuredCount, 1)
    XCTAssertEqual(try fixture.registry.finish(allocation.id).phase, .removed)
    XCTAssertEqual(try fixture.registry.overview(since: nil).measuredCount, 0)

    XCTAssertEqual(try fixture.registry.restore(allocation.id).phase, .retained)
    let restored = try fixture.registry.overview(since: nil)
    XCTAssertEqual(restored.worktreeCount, 1)
    XCTAssertEqual(restored.measuredCount, 0)
    XCTAssertNil(restored.savedBytes)
    XCTAssertEqual(try fixture.registry.refreshOverview(since: nil).measuredCount, 1)
  }

  func testOlderRefreshCannotReplaceNewerSavedMeasurement() throws {
    let fixture = try Fixture()
    let allocation = try fixture.start("ordered-storage")
    _ = try fixture.registry.refreshOverview(since: nil)
    let latest = try withRegistry(fixture.registry.stateDirectory) { store in
      try XCTUnwrap(store.usageMeasurement(allocation.id))
    }
    try withRegistry(fixture.registry.stateDirectory) { store in
      try store.saveUsageMeasurement(
        UsageMeasurement(
          usage: latest.usage, measuredAt: latest.measuredAt.addingTimeInterval(-60)),
        for: allocation.id)
    }
    XCTAssertEqual(try fixture.registry.overview(since: nil).measuredAt, latest.measuredAt)
  }

  func testDetailedStatusFlagRunsTheLegacyReport() throws {
    let fixture = try Fixture()
    XCTAssertEqual(fixture.wait(try fixture.cli(["status", "--detailed"])), 0)
    XCTAssertEqual(fixture.wait(try fixture.cli(["status", "--details"])), 0)
  }

  func testMeasurePathsSkipsMissingAndExcludesNestedRoots() throws {
    let fixture = try Fixture()
    let nested = fixture.repository + "/.worktrees/nested"
    _ = try git(fixture.repository, ["worktree", "add", "-q", "--detach", nested])
    try Data(repeating: 5, count: 3_000_000).write(to: URL(fileURLWithPath: nested + "/payload"))
    let inputs = [fixture.repository, nested, fixture.repository + "/missing"]
    let usages = measurePaths(inputs)
    XCTAssertEqual(usages.map(\.path), Array(inputs.prefix(2)))
    XCTAssertLessThan(usages[0].usage.fullBytes, 3_000_000)
    XCTAssertGreaterThanOrEqual(usages[1].usage.fullBytes, 3_000_000)
  }
}
