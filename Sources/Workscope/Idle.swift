import Foundation

public struct OneOffPreview: Codable, Sendable {
  public let id: String
  public let lastFileActivity: Date
  public let lastMention: Date?
  public let eligibleAt: Date
  public let reasons: [String]
  public let estimatedBytes: Int64

  public var isEligible: Bool { reasons.isEmpty }
}

func lastFileActivity(_ path: String) throws -> Date {
  let manager = FileManager.default
  let root = URL(fileURLWithPath: path)
  var enumerationError: Error?
  guard
    let files = manager.enumerator(
      at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
      errorHandler: { _, error in
        enumerationError = error
        return false
      }
    )
  else { throw WorkscopeError("Cannot inspect checkout activity") }
  var latest =
    try root.resourceValues(forKeys: [.contentModificationDateKey])
    .contentModificationDate ?? .distantPast
  for case let file as URL in files {
    if file.lastPathComponent == ".git" {
      files.skipDescendants()
      continue
    }
    let values = try file.resourceValues(forKeys: [.contentModificationDateKey])
    latest = max(latest, values.contentModificationDate ?? .distantPast)
  }
  if let enumerationError { throw enumerationError }
  return latest
}

func transcriptMentions(
  _ allocations: [Allocation], directory: String
) throws -> [String: Date] {
  let root = URL(fileURLWithPath: directory)
  var enumerationError: Error?
  guard
    let files = FileManager.default.enumerator(
      at: root, includingPropertiesForKeys: [.isRegularFileKey],
      errorHandler: { _, error in
        enumerationError = error
        return false
      }
    )
  else { throw WorkscopeError("Cannot inspect conversation transcripts") }
  var latest: [String: Date] = [:]
  let identifiers = allocations.map { Data($0.id.utf8) }
  let unicodeEscape = Data("\\u".utf8)
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  func readLine(_ data: Data) throws {
    let hasIdentifier = identifiers.contains { data.range(of: $0) != nil }
    guard hasIdentifier || data.range(of: unicodeEscape) != nil else { return }
    let parsed: Any
    do {
      parsed = try JSONSerialization.jsonObject(with: data)
    } catch {
      if hasIdentifier { throw error }
      return
    }
    guard let entry = parsed as? [String: Any],
      entry["type"] as? String == "message",
      let message = entry["message"] as? [String: Any],
      let role = message["role"] as? String, role == "user" || role == "assistant",
      let stamp = entry["timestamp"] as? String,
      let contents = message["content"] as? [[String: Any]]
    else { return }
    guard let date = formatter.date(from: stamp) else {
      throw WorkscopeError("Invalid conversation timestamp")
    }
    let text = contents.compactMap { part -> String? in
      guard part["type"] as? String == "text" else { return nil }
      return part["text"] as? String
    }.joined(separator: "\n")
    for allocation in allocations
    where text.contains(allocation.id) || text.contains(allocation.path) {
      latest[allocation.id] = max(latest[allocation.id] ?? .distantPast, date)
    }
  }
  for case let file as URL in files where file.pathExtension == "jsonl" {
    guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
      continue
    }
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var pending = Data()
    while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
      pending.append(chunk)
      while let newline = pending.firstIndex(of: 10) {
        try readLine(pending.prefix(upTo: newline))
        pending.removeSubrange(...newline)
      }
    }
    if !pending.isEmpty { try readLine(pending) }
  }
  if let enumerationError { throw enumerationError }
  return latest
}

func oneOffPreviews(
  _ allocations: [Allocation], minimumIdle: TimeInterval, transcriptDirectory: String,
  isCheckpointRequired: Bool = false, now: Date = Date()
) throws -> [OneOffPreview] {
  try require(minimumIdle >= 0 && minimumIdle.isFinite, "Invalid minimum idle age")
  let mentions =
    try minimumIdle > 0
    ? transcriptMentions(allocations, directory: transcriptDirectory) : [:]
  return try allocations.map { allocation in
    var reasons = ownershipReasons(allocation, isManual: true)
    if allocation.phase == .creating || allocation.phase == .failed || allocation.phase == .removed
    {
      reasons.append("Allocation is not an active checkout")
    }
    if allocation.isRemovalPending { reasons.append("Removal is pending") }
    if isCheckpointRequired
      && allocation.recovery?.event.hasPrefix("manual-offload-") != true
      && allocation.recovery?.event != "manual-cleanup"
    {
      reasons.append("No manual offload checkpoint")
    }
    guard FileManager.default.fileExists(atPath: allocation.path) else {
      reasons.append("Checkout is missing")
      return OneOffPreview(
        id: allocation.id, lastFileActivity: .distantPast,
        lastMention: mentions[allocation.id], eligibleAt: .distantPast,
        reasons: reasons, estimatedBytes: 0)
    }
    let modified = try lastFileActivity(allocation.path)
    let fileActivity: Date
    if isCheckpointRequired, let recovery = allocation.recovery,
      let beforeOffload = recovery.lastFileActivity, modified <= recovery.preservedAt
    {
      fileActivity = beforeOffload
    } else {
      fileActivity = modified
    }
    let eligibleAt = max(fileActivity, mentions[allocation.id] ?? .distantPast)
      .addingTimeInterval(minimumIdle)
    if eligibleAt > now { reasons.append("Minimum idle age has not elapsed") }
    if reasons.isEmpty {
      do { _ = try verifyFiles(allocation, isCheckpointAllowed: true) } catch {
        reasons.append(String(describing: error))
      }
    }
    return OneOffPreview(
      id: allocation.id, lastFileActivity: fileActivity, lastMention: mentions[allocation.id],
      eligibleAt: eligibleAt, reasons: reasons,
      estimatedBytes: reasons.isEmpty ? measure(allocation.path).privateBytes : 0)
  }
}
