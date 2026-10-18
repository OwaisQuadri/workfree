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
  public let isCleanupAuthorized: Bool
  public internal(set) var defaultPinToken: String?
  public internal(set) var isRemovalPending: Bool = false
  public internal(set) var admin: String?
  public internal(set) var phase: Phase
  public internal(set) var reason: String?
  public internal(set) var owners: [String: Owner]
  public internal(set) var retiredOwners: [String: Owner]
}
