import Darwin
import Foundation

public struct Usage: Codable, Sendable, Equatable {
  public var fullBytes: Int64 = 0
  public var privateBytes: Int64 = 0

  public var savedBytes: Int64 { fullBytes - privateBytes }

  static func + (left: Usage, right: Usage) -> Usage {
    Usage(
      fullBytes: left.fullBytes + right.fullBytes,
      privateBytes: left.privateBytes + right.privateBytes)
  }
}

func privateSize(_ path: String) -> Int64? {
  var attributes = attrlist()
  attributes.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
  attributes.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
  attributes.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
  var buffer = [UInt8](repeating: 0, count: 64)
  let options = UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW)
  guard getattrlist(path, &attributes, &buffer, buffer.count, options) == 0 else { return nil }
  return buffer.withUnsafeBytes { raw in
    let returned = raw.load(fromByteOffset: 4, as: attribute_set_t.self)
    guard returned.forkattr & attrgroup_t(ATTR_CMNEXT_PRIVATESIZE) != 0 else { return nil }
    return raw.loadUnaligned(
      fromByteOffset: 4 + MemoryLayout<attribute_set_t>.size, as: off_t.self)
  }
}

func fileUsage(_ path: String) -> Usage? {
  var info = stat()
  guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
  let full = Int64(info.st_blocks) * 512
  return Usage(fullBytes: full, privateBytes: min(privateSize(path) ?? full, full))
}

public struct UsageMeasurement: Codable, Sendable {
  public let usage: Usage
  public let measuredAt: Date
}

public struct PathUsage: Codable, Sendable {
  public let path: String
  public let usage: Usage
  public let full: String
  public let copied: String
}

public func measurePaths(_ paths: [String]) -> [PathUsage] {
  let present = paths.compactMap { path -> (String, String)? in
    guard let resolved = try? canonical(path), (try? isPresent(resolved)) == true else {
      return nil
    }
    return (path, resolved)
  }
  let roots = present.map(\.1)
  return present.map { path, resolved in
    let usage = measure(
      resolved, excluding: roots.filter { $0 != resolved && isWithin($0, resolved) })
    return PathUsage(
      path: path, usage: usage, full: formatBytes(usage.fullBytes),
      copied: formatBytes(usage.privateBytes))
  }
}

func measure(_ root: String, excluding excluded: [String] = []) -> Usage {
  var total = Usage()
  guard let enumerator = FileManager.default.enumerator(atPath: root) else { return total }
  while let relative = enumerator.nextObject() as? String {
    let path = root + "/" + relative
    if excluded.contains(where: { isWithin(path, $0) }) {
      enumerator.skipDescendants()
      continue
    }
    if let usage = fileUsage(path) { total = total + usage }
  }
  return total
}

func cowEstimate(_ path: String, usage: Usage) -> Int64 {
  guard let tracked = try? git(path, ["ls-files", "-z"]),
    let changed = try? git(path, ["diff", "--name-only", "-z", "HEAD"])
  else { return usage.privateBytes }
  let changedSet = Set(changed.split(separator: "\0"))
  let shareable = tracked.split(separator: "\0").filter { !changedSet.contains($0) }
    .compactMap { fileUsage(path + "/" + $0)?.fullBytes }.reduce(0, +)
  return max(usage.privateBytes - shareable, 0)
}

public func parseInterval(_ text: String) throws -> TimeInterval? {
  if text == "all" { return nil }
  let units: [Character: TimeInterval] = ["h": 3_600, "d": 86_400, "w": 604_800]
  guard let unit = text.last, let seconds = units[unit], let count = Int(text.dropLast()),
    (1...100_000).contains(count)
  else { throw WorkscopeError("Invalid interval: use a number with h, d, or w, or 'all'") }
  return TimeInterval(count) * seconds
}

public func formatBytes(_ bytes: Int64) -> String {
  let value = Double(bytes)
  if value >= 1e9 { return String(format: "%.1f GB", value / 1e9) }
  if value >= 1e6 { return String(format: "%.1f MB", value / 1e6) }
  return String(format: "%.0f KB", value / 1e3)
}

public struct StorageOverview: Codable, Sendable {
  public let worktreeCount: Int
  public let measuredCount: Int
  public let savedBytes: Int64?
  public let measuredAt: Date?
  public let reclaimedBytes: Int64
  public let removedCount: Int
  public let sinceSeconds: TimeInterval?
  public let pendingCount: Int
  public let pendingBytes: Int64?
  public let nextEligibleAt: Date?
  public let nextEligibleCount: Int
  public let nextEligibleBytes: Int64?
  public let availableBytes: Int64?

  public var text: String {
    let age = measuredAt.map { " · oldest measurement \(describeAge($0))" } ?? ""
    let coverage =
      measuredCount < worktreeCount
      ? " · \(measuredCount) of \(worktreeCount) measured" : ""
    let saving = savedBytes.map(formatBytes) ?? "not measured"
    let window = sinceSeconds.map { "last \(describe($0))" } ?? "all time"
    let pending =
      pendingCount == 0 ? "0 KB" : pendingBytes.map { "~\(formatBytes($0))" } ?? "size not measured"
    let next =
      nextEligibleAt.map { date -> String in
        let formatter = DateFormatter()
        formatter.dateStyle = Calendar.current.isDateInToday(date) ? .none : .medium
        formatter.timeStyle = .short
        let size = nextEligibleBytes.map { "~\(formatBytes($0))" } ?? "size not measured"
        return
          "  Next eligible: \(size) · \(plural(nextEligibleCount, "worktree")) · \(formatter.string(from: date))"
      } ?? "  Next eligible: none scheduled"
    let available = availableBytes.map { " · \(formatBytes($0)) available on this disk" } ?? ""
    return [
      "Workfree",
      "",
      "  \(saving)   saved with CoW\(age)\(coverage)",
      "  \(formatBytes(reclaimedBytes))   reclaimed by cleanup · \(window)",
      "  \(pending)   pending cleanup · \(plural(pendingCount, "worktree"))",
      "",
      next,
      "",
      "  \(plural(worktreeCount, "worktree"))\(available)",
    ].joined(separator: "\n")
  }
}

func describeAge(_ date: Date, now: Date = Date()) -> String {
  let seconds = max(0, Int(now.timeIntervalSince(date)))
  if seconds < 60 { return "just now" }
  if seconds < 3_600 { return "\(seconds / 60)m ago" }
  if seconds < 86_400 { return "\(seconds / 3_600)h ago" }
  return "\(seconds / 86_400)d ago"
}

func storageOverview(
  _ allocations: [Allocation], measurements: [String: UsageMeasurement], since: TimeInterval?,
  stateDirectory: String, now: Date = Date()
) -> StorageOverview {
  let active = allocations.filter {
    $0.phase != .removed && (try? isPresent($0.path)) == true
  }
  let measured = active.compactMap { measurements[$0.id] }
  let pending = active.compactMap { allocation -> (Date, UsageMeasurement?)? in
    guard allocation.phase == .retained, !allocation.isRemovalPending,
      let policy = allocation.cleanupPolicy, let eligibleSince = allocation.eligibleSince,
      ownershipReasons(allocation).isEmpty
    else { return nil }
    return (eligibleSince.addingTimeInterval(policy.graceSeconds), measurements[allocation.id])
  }
  let nextDate = pending.map(\.0).min()
  let next = pending.filter { candidate in
    nextDate.map { candidate.0 <= $0.addingTimeInterval(60) } ?? false
  }
  var volume = statfs()
  let available =
    statfs(stateDirectory, &volume) == 0
    ? Int64(volume.f_bavail) * Int64(volume.f_bsize) : nil
  let removed = reclamations(allocations, since: since, now: now)
  return StorageOverview(
    worktreeCount: active.count, measuredCount: measured.count,
    savedBytes: measured.isEmpty && !active.isEmpty
      ? nil : measured.map(\.usage.savedBytes).reduce(0, +),
    measuredAt: measured.map(\.measuredAt).min(),
    reclaimedBytes: removed.map(\.estimatedBytes).reduce(0, +),
    removedCount: removed.count, sinceSeconds: since,
    pendingCount: pending.count,
    pendingBytes: pending.allSatisfy { $0.1 != nil }
      ? pending.compactMap { $0.1?.usage.privateBytes }.reduce(0, +) : nil,
    nextEligibleAt: nextDate, nextEligibleCount: next.count,
    nextEligibleBytes: next.allSatisfy { $0.1 != nil }
      ? next.compactMap { $0.1?.usage.privateBytes }.reduce(0, +) : nil,
    availableBytes: available)
}

func reclamations(
  _ allocations: [Allocation], since: TimeInterval?, now: Date
) -> [Reclamation] {
  allocations.flatMap { allocation -> [Reclamation] in
    var history = allocation.pastRemovals ?? []
    if allocation.phase == .removed {
      history.append(
        Reclamation(
          date: allocation.removedAt ?? .distantPast, estimatedBytes: allocation.reclaimedBytes ?? 0
        ))
    }
    return history
  }.filter { since == nil || $0.date >= now.addingTimeInterval(-since!) }
}

public struct StorageStatus: Codable, Sendable {
  public struct Worktree: Codable, Sendable {
    public let id: String
    public let path: String
    public let branch: String?
    public let provider: WorktreeProvider
    public let phase: Phase
    public let reason: String?
    public let usage: Usage
    public let cowEstimateBytes: Int64?
  }

  public struct Repository: Codable, Sendable {
    public let path: String
    public let baseBytes: Int64
    public let worktreeBytes: Int64
    public let worktrees: [Worktree]
  }

  public struct Missing: Codable, Sendable {
    public let id: String
    public let path: String
    public let phase: Phase
    public let reason: String?
  }

  public let repositories: [Repository]
  public let missing: [Missing]
  public let live: Usage
  public let sinceSeconds: TimeInterval?
  public let removedCount: Int
  public let reclaimedBytes: Int64

  public var summary: [String] {
    let worktrees = repositories.flatMap(\.worktrees)
    var lines = [
      "Live worktrees: \(worktrees.count) · full checkouts would use \(formatBytes(live.fullBytes))"
        + " · actually using \(formatBytes(live.privateBytes)) · saved \(formatBytes(live.savedBytes))"
    ]
    let native = worktrees.filter { $0.provider == .git }
    if !native.isEmpty {
      let used = native.map(\.usage.privateBytes).reduce(0, +)
      let estimate = native.compactMap(\.cowEstimateBytes).reduce(0, +)
      lines.append(
        "Native checkouts: \(native.count) use \(formatBytes(used)). With simgit, they would use"
          + " about \(formatBytes(estimate)) (estimate).")
    }
    lines.append(cleanupLine)
    return lines
  }

  public var cleanupLine: String {
    let window = sinceSeconds.map { "last \(describe($0))" } ?? "all time"
    return "Auto-cleanup, \(window): \(plural(removedCount, "worktree")) removed · "
      + "\(formatBytes(reclaimedBytes)) reclaimed (estimated private bytes)"
  }

  public var text: String {
    var lines = summary
    for repository in repositories {
      lines.append("")
      lines.append(
        "\(repository.path)  \(formatBytes(repository.baseBytes)) + \(formatBytes(repository.worktreeBytes))"
      )
      for worktree in repository.worktrees {
        let size = formatBytes(worktree.usage.privateBytes)
        let blocker = describe(worktree.phase, worktree.reason)
        lines.append("  \(worktree.branch ?? "-")  \(worktree.id)  \(size)\(blocker)")
      }
    }
    if !missing.isEmpty {
      lines.append("")
      lines.append("Missing checkouts:")
      for allocation in missing {
        lines.append(
          "  \(allocation.id)  \(allocation.path)\(describe(allocation.phase, allocation.reason))")
      }
    }
    return lines.joined(separator: "\n")
  }
}

func describe(_ phase: Phase, _ reason: String?) -> String {
  guard phase != .retained || reason != nil else { return "" }
  let detail =
    reason.map { ": " + $0.split(whereSeparator: \.isNewline).joined(separator: " · ") } ?? ""
  return "  \(phase.rawValue)\(detail)"
}

func plural(_ count: Int, _ noun: String) -> String {
  "\(count) \(noun)\(count == 1 ? "" : "s")"
}

func describe(_ seconds: TimeInterval) -> String {
  if seconds >= 172_800, seconds.truncatingRemainder(dividingBy: 86_400) == 0 {
    return plural(Int(seconds / 86_400), "day")
  }
  return plural(Int(seconds / 3_600), "hour")
}

func storageStatus(
  _ allocations: [Allocation], since: TimeInterval?, isLiveMeasured: Bool = true,
  now: Date = Date()
) -> StorageStatus {
  var live = Usage()
  var repositories: [StorageStatus.Repository] = []
  let active = allocations.filter { isLiveMeasured && $0.phase != .removed }
  let presence = Dictionary(
    active.map { ($0.id, (try? isPresent($0.path)) == true) },
    uniquingKeysWith: { first, _ in first })
  let present = active.filter { presence[$0.id] == true }
  let missing = active.filter { presence[$0.id] != true && $0.admin != nil }.map {
    StorageStatus.Missing(id: $0.id, path: $0.path, phase: $0.phase, reason: $0.reason)
  }
  for (repository, members) in Dictionary(grouping: present, by: \.repository).sorted(by: {
    $0.key < $1.key
  }) {
    let worktrees = members.map { allocation in
      let usage = measure(allocation.path)
      live = live + usage
      return StorageStatus.Worktree(
        id: allocation.id, path: allocation.path,
        branch: try? git(allocation.path, ["symbolic-ref", "--short", "-q", "HEAD"]),
        provider: allocation.provider, phase: allocation.phase,
        reason: Array(Set(ownershipReasons(allocation) + (allocation.reason.map { [$0] } ?? [])))
          .sorted().joined(separator: "; "),
        usage: usage,
        cowEstimateBytes: allocation.provider == .git
          ? cowEstimate(allocation.path, usage: usage) : nil)
    }
    let base = measure(repository)
    repositories.append(
      StorageStatus.Repository(
        path: repository, baseBytes: base.fullBytes,
        worktreeBytes: worktrees.map(\.usage.privateBytes).reduce(0, +), worktrees: worktrees))
  }
  let removed = reclamations(allocations, since: since, now: now)
  return StorageStatus(
    repositories: repositories, missing: missing, live: live, sinceSeconds: since,
    removedCount: removed.count,
    reclaimedBytes: removed.map(\.estimatedBytes).reduce(0, +))
}
