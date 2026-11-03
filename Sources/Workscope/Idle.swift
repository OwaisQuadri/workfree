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

func unescapedJSONReferences(_ data: Data) -> Data {
  let bytes = Array(data)
  var result = Data()
  result.reserveCapacity(bytes.count)
  func codeUnit(at index: Int) -> UInt32? {
    guard index + 5 < bytes.count, bytes[index] == 92, bytes[index + 1] == 117 else {
      return nil
    }
    return UInt32(String(decoding: bytes[(index + 2)...(index + 5)], as: UTF8.self), radix: 16)
  }
  var index = 0
  while index < bytes.count {
    if bytes[index] == 92, index + 1 < bytes.count {
      if bytes[index + 1] == 47 {
        result.append(47)
        index += 2
        continue
      }
      if let first = codeUnit(at: index) {
        if (0xD800...0xDBFF).contains(first), let second = codeUnit(at: index + 6),
          (0xDC00...0xDFFF).contains(second),
          let scalar = UnicodeScalar(0x10000 + (first - 0xD800) * 0x400 + second - 0xDC00)
        {
          result.append(contentsOf: String(scalar).utf8)
          index += 12
          continue
        }
        if let scalar = UnicodeScalar(first) {
          result.append(contentsOf: String(scalar).utf8)
          index += 6
          continue
        }
      }
    }
    result.append(bytes[index])
    index += 1
  }
  return result
}

func transcriptMentions(
  _ allocations: [Allocation], directory: String, modifiedSince: Date? = nil,
  maximumRecordBytes: Int = 64 * 1_024 * 1_024
) throws -> [String: Date] {
  guard !allocations.isEmpty else { return [:] }
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
  let mentionStrings = allocations.flatMap { [$0.id, $0.path] }
  let mentionBytes = mentionStrings.map { Data($0.utf8) }
  let rawPattern = try NSRegularExpression(
    pattern: mentionStrings.map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|"))
  let unicodeEscape = Data("\\u".utf8)
  let slashEscape = Data("\\/".utf8)
  let formatter = ISO8601DateFormatter()
  formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
  func readLine(_ data: Data) throws {
    let line = String(decoding: data, as: UTF8.self)
    let hasRawMention =
      rawPattern.firstMatch(
        in: line, range: NSRange(line.startIndex..<line.endIndex, in: line)) != nil
    let hasEscape = data.range(of: unicodeEscape) != nil || data.range(of: slashEscape) != nil
    guard hasRawMention || hasEscape else { return }
    let parsed: Any
    do {
      parsed = try JSONSerialization.jsonObject(with: data)
    } catch {
      if hasRawMention { throw error }
      let unescaped = unescapedJSONReferences(data)
      if mentionBytes.contains(where: { unescaped.range(of: $0) != nil }) { throw error }
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
    let attributes = try file.resourceValues(forKeys: [
      .isRegularFileKey, .contentModificationDateKey,
    ])
    guard attributes.isRegularFile == true else { continue }
    if let modifiedSince, let modified = attributes.contentModificationDate,
      modified < modifiedSince
    {
      continue
    }
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    var pending = Data()
    while let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty {
      var start = chunk.startIndex
      while let newline = chunk[start...].firstIndex(of: 10) {
        pending.append(chunk[start..<newline])
        guard pending.count <= maximumRecordBytes else {
          throw WorkscopeError("Conversation record exceeds 64 MiB")
        }
        try readLine(pending)
        pending.removeAll(keepingCapacity: true)
        start = chunk.index(after: newline)
      }
      pending.append(chunk[start...])
      guard pending.count <= maximumRecordBytes else {
        throw WorkscopeError("Conversation record exceeds 64 MiB")
      }
    }
    if !pending.isEmpty { try readLine(pending) }
  }
  if let enumerationError { throw enumerationError }
  return latest
}

func oneOffPreviews(
  _ allocations: [Allocation], minimumIdle: TimeInterval, transcriptDirectory: String,
  isCheckpointRequired: Bool = false, modifiedSince: Date? = nil, now: Date = Date()
) throws -> [OneOffPreview] {
  try require(minimumIdle >= 0 && minimumIdle.isFinite, "Invalid minimum idle age")
  let mentions =
    try minimumIdle > 0
    ? transcriptMentions(allocations, directory: transcriptDirectory, modifiedSince: modifiedSince)
    : [:]
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
