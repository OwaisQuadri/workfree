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

func measure(_ root: String) -> Usage {
  var total = Usage()
  guard let enumerator = FileManager.default.enumerator(atPath: root) else { return total }
  while let relative = enumerator.nextObject() as? String {
    if let usage = fileUsage(root + "/" + relative) { total = total + usage }
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
      + "\(formatBytes(reclaimedBytes)) reclaimed"
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
        provider: allocation.provider, phase: allocation.phase, reason: allocation.reason,
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
  let removed = allocations.filter { allocation in
    guard allocation.phase == .removed else { return false }
    guard let since else { return true }
    return (allocation.removedAt ?? .distantPast) >= now.addingTimeInterval(-since)
  }
  return StorageStatus(
    repositories: repositories, missing: missing, live: live, sinceSeconds: since,
    removedCount: removed.count,
    reclaimedBytes: removed.compactMap(\.reclaimedBytes).reduce(0, +))
}
