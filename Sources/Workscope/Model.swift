import Foundation

public struct WorkscopeError: Error, CustomStringConvertible {
  public let description: String

  public init(_ description: String) {
    self.description = description
  }
}

func require(_ isValid: Bool, _ message: String) throws {
  guard isValid else { throw WorkscopeError(message) }
}

public enum WorktreeProvider: String, Codable, Sendable {
  case git, simgit
}

public enum OwnerKind: String, Codable, Sendable {
  case task, workspace, execution, pin
}

public struct Owner: Codable, Sendable {
  public let kind: OwnerKind
  public let label: String?
  public internal(set) var entryStatus: Int32?
  public internal(set) var isCooperativelyClosed: Bool = false
}

public enum Phase: String, Codable, Sendable {
  case creating, failed, retained, checking, blocked, removing, removed
}

public struct Allocation: Codable, Sendable {
  public let id: String
  public let path: String
  public let repository: String
  public let repositoryIdentity: String
  public let provider: WorktreeProvider
  public internal(set) var isCleanupAuthorized: Bool
  public internal(set) var defaultPinToken: String?
  public internal(set) var defaultTaskToken: String?
  public internal(set) var isRemovalPending: Bool = false
  public internal(set) var admin: String?
  public internal(set) var phase: Phase
  public internal(set) var reason: String?
  public internal(set) var owners: [String: Owner]
  public internal(set) var retiredOwners: [String: Owner]
  public internal(set) var removedAt: Date?
  public internal(set) var reclaimedBytes: Int64?
  public internal(set) var cleanupPolicy: CleanupPolicy?
  public internal(set) var eligibleSince: Date?
  public internal(set) var recovery: RecoveryRecord?
  public internal(set) var cleanupAttempts: [CleanupAttempt]?
  public internal(set) var pastRemovals: [Reclamation]?
  public internal(set) var conversationClaims: [ConversationClaim]?
}

public struct Reclamation: Codable, Sendable {
  public let date: Date
  public let estimatedBytes: Int64
}

public struct CleanupPolicy: Codable, Sendable {
  public let graceSeconds: TimeInterval
  public let disposablePaths: [String]
}

public struct RecoveryRecord: Codable, Sendable {
  public let commit: String
  public let reference: String
  public let branch: String?
  public let preservedAt: Date
  public let event: String
}

public struct CleanupAttempt: Codable, Sendable {
  public let date: Date
  public let event: String
  public let reasons: [String]
  public let phase: Phase
}

public struct CleanupPreview: Codable, Sendable {
  public let id: String
  public let reasons: [String]
  public let eligibleAt: Date?
  public let estimatedBytes: Int64

  public var isEligible: Bool { reasons.isEmpty }
}
