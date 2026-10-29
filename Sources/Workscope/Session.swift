import Darwin
import Foundation

public struct ConversationClaim: Codable, Sendable, Equatable {
  public let sessionID: String
  public let processID: Int32
  public let bootIdentity: String
  public let startSeconds: UInt64
  public let startMicroseconds: UInt64
}

enum ProcessSnapshot {
  case running(bootIdentity: String, seconds: UInt64, microseconds: UInt64)
  case absent
  case unknown
}

func processSnapshot(_ pid: Int32) -> ProcessSnapshot {
  guard pid > 0 else { return .unknown }
  var boot = timeval()
  var size = MemoryLayout<timeval>.size
  guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0,
    size == MemoryLayout<timeval>.size
  else { return .unknown }
  var info = proc_bsdinfo()
  let count = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
  if count == Int32(MemoryLayout<proc_bsdinfo>.size), info.pbi_start_tvsec > 0 {
    return .running(
      bootIdentity: "\(boot.tv_sec):\(boot.tv_usec)", seconds: info.pbi_start_tvsec,
      microseconds: info.pbi_start_tvusec)
  }
  if kill(pid, 0) == -1 && errno == ESRCH { return .absent }
  return .unknown
}

func isConversationBlocking(
  _ claim: ConversationClaim, snapshot: (Int32) -> ProcessSnapshot = processSnapshot
) -> Bool {
  guard claim.processID > 0, !claim.bootIdentity.isEmpty, claim.startSeconds > 0,
    !claim.sessionID.isEmpty
  else { return true }
  switch snapshot(claim.processID) {
  case .unknown: return true
  case .absent: return false
  case .running(let boot, let seconds, let microseconds):
    guard !boot.isEmpty, seconds > 0 else { return true }
    return boot == claim.bootIdentity && seconds == claim.startSeconds
      && microseconds == claim.startMicroseconds
  }
}

public struct ConversationContext: Sendable {
  let claim: ConversationClaim
  let allocationIDs: [String]
  let cwd: String?

  public init(sessionID: String, processID: Int32, allocationIDs: [String] = [], cwd: String? = nil)
    throws
  {
    try require(!sessionID.isEmpty && !sessionID.utf8.contains(0), "Invalid conversation ID")
    guard case .running(let boot, let seconds, let microseconds) = processSnapshot(processID) else {
      throw WorkscopeError("Cannot verify conversation host process identity")
    }
    claim = ConversationClaim(
      sessionID: sessionID, processID: processID, bootIdentity: boot,
      startSeconds: seconds, startMicroseconds: microseconds)
    self.allocationIDs = allocationIDs
    self.cwd = try cwd.map { try canonical($0) }
  }
}

func acquireConversation(_ allocation: inout Allocation, _ context: ConversationContext) throws {
  try require(
    !allocation.isRemovalPending && (allocation.phase == .retained || allocation.phase == .blocked),
    "Allocation is unavailable for conversation acquisition")
  try verifyIdentity(allocation)
  retainConversation(&allocation, context)
}

private func retainConversation(_ allocation: inout Allocation, _ context: ConversationContext) {
  var claims = (allocation.conversationClaims ?? []).filter { isConversationBlocking($0) }
  if !claims.contains(context.claim) { claims.append(context.claim) }
  allocation.conversationClaims = claims
  allocation.eligibleSince = nil
}

func withConversationRegistry<T>(
  _ directory: String, conversation: ConversationContext?, excluding id: String? = nil,
  _ operation: (RegistryStore) throws -> T
) throws -> T {
  try withRegistry(directory) { store in
    if let conversation {
      let allocations = try store.allocations()
      let ids = Set(conversation.allocationIDs)
      for id in ids { _ = try store.allocation(id) }
      for var allocation in allocations where allocation.id != id {
        let isCwd = conversation.cwd.map { isWithin($0, allocation.path) } ?? false
        if isCwd {
          try acquireConversation(&allocation, conversation)
          try store.save(allocation)
        } else if ids.contains(allocation.id) {
          retainConversation(&allocation, conversation)
          try store.save(allocation)
        }
      }
    }
    return try operation(store)
  }
}

func conversationReasons(_ allocation: Allocation) -> [String] {
  (allocation.conversationClaims ?? []).filter { isConversationBlocking($0) }.map {
    "Retained conversation: \($0.sessionID)"
  }
}
