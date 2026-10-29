import Darwin
import Foundation

public struct Registry: Sendable {
  public let stateDirectory: String

  public let conversation: ConversationContext?

  public init(stateDirectory: String? = nil, conversation: ConversationContext? = nil) throws {
    self.conversation = conversation
    self.stateDirectory = try canonical(
      stateDirectory
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
          "Library/Application Support/workfree"
        ).path)
  }

  private func withRegistry<T>(
    _ directory: String, excluding id: String? = nil,
    _ operation: (RegistryStore) throws -> T
  ) throws -> T {
    try withConversationRegistry(directory, conversation: conversation, excluding: id, operation)
  }

  public func claim(_ id: String? = nil) throws -> [Allocation] {
    try require(conversation != nil, "Conversation identity is required")
    return try withRegistry(stateDirectory) { store in
      if let id {
        var allocation = try store.allocation(id)
        try acquireConversation(&allocation, conversation!)
        try store.save(allocation)
      }
      return try store.allocations().filter {
        $0.conversationClaims?.contains(conversation!.claim) == true
      }
    }
  }

  public func globalCleanupPolicy() throws -> GlobalCleanupPolicyStatus {
    try withRegistry(stateDirectory) { try $0.globalCleanupPolicy() }
  }

  public func enableGlobalCleanupPolicy(graceSeconds: TimeInterval = 60) throws
    -> GlobalCleanupPolicyStatus
  {
    try require(
      graceSeconds.isFinite && (0...86_400).contains(graceSeconds), "Invalid grace period")
    return try withRegistry(stateDirectory) { store in
      let status = try store.globalCleanupPolicy()
      if let policy = status.policy {
        try require(
          policy.cleanupPolicy.graceSeconds == graceSeconds,
          "Revoke the global policy before changing its grace period")
        return status
      }
      try store.changeGlobalCleanupPolicy(
        RepositoryCleanupPolicy(
          id: UUID().uuidString.lowercased(), repository: "", repositoryIdentity: "",
          grantedAt: Date(),
          cleanupPolicy: CleanupPolicy(graceSeconds: graceSeconds, disposablePaths: [])))
      return try store.globalCleanupPolicy()
    }
  }

  public func revokeGlobalCleanupPolicy() throws -> GlobalCleanupPolicyStatus {
    try withRegistry(stateDirectory) { store in
      try store.changeGlobalCleanupPolicy(nil)
      return try store.globalCleanupPolicy()
    }
  }

  public func excludeRepositoryFromCleanup(repository: String, isExcluded: Bool = true) throws
    -> GlobalCleanupPolicyStatus
  {
    try withRegistry(stateDirectory) { store in
      let status = try cleanupPolicyStatus(repository, store: store)
      if !isExcluded {
        let global = try store.globalCleanupPolicy()
        if !global.excludedRepositories.contains(status.repository) { return global }
      }
      try store.changeGlobalCleanupPolicy(
        nil, excludedRepository: status.repository, isExcluded: isExcluded)
      return try store.globalCleanupPolicy()
    }
  }

  public func migrateGlobalCleanupPolicy() throws -> [Allocation] {
    try withRegistry(stateDirectory) { try $0.migrateGlobalCleanupPolicy() }
  }

  public func repositoryCleanupPolicy(repository: String) throws -> RepositoryCleanupPolicyStatus {
    try withRegistry(stateDirectory) { try cleanupPolicyStatus(repository, store: $0) }
  }

  public func enableRepositoryCleanupPolicy(
    repository: String, graceSeconds: TimeInterval = 60
  ) throws -> RepositoryCleanupPolicyStatus {
    try require(
      graceSeconds.isFinite && (0...86_400).contains(graceSeconds), "Invalid grace period")
    return try withRegistry(stateDirectory) { store in
      let status = try cleanupPolicyStatus(repository, store: store)
      if let policy = status.policy {
        try require(
          policy.cleanupPolicy.graceSeconds == graceSeconds,
          "Revoke the existing repository policy before changing its grace period")
        return status
      }
      let policy = RepositoryCleanupPolicy(
        id: UUID().uuidString.lowercased(), repository: status.repository,
        repositoryIdentity: status.repositoryIdentity, grantedAt: Date(),
        cleanupPolicy: CleanupPolicy(graceSeconds: graceSeconds, disposablePaths: []))
      try store.saveRepositoryCleanupPolicy(policy)
      return RepositoryCleanupPolicyStatus(
        repository: status.repository, repositoryIdentity: status.repositoryIdentity, policy: policy
      )
    }
  }

  public func revokeRepositoryCleanupPolicy(repository: String) throws
    -> RepositoryCleanupPolicyStatus
  {
    try withRegistry(stateDirectory) { store in
      let status = try cleanupPolicyStatus(repository, store: store)
      try store.revokeRepositoryCleanupPolicy(status.repositoryIdentity)
      return RepositoryCleanupPolicyStatus(
        repository: status.repository, repositoryIdentity: status.repositoryIdentity, policy: nil)
    }
  }

  public func authorizeCleanup(
    _ id: String, graceSeconds: TimeInterval = 60, disposablePaths: [String] = []
  ) throws -> Allocation {
    try require(
      graceSeconds.isFinite && (0...86_400).contains(graceSeconds), "Invalid grace period")
    for path in disposablePaths { try validateDisposablePath(path) }
    return try withRegistry(stateDirectory) { store in
      var allocation = try store.allocation(id)
      try require(
        !allocation.isRemovalPending && allocation.phase != .removed, "Allocation is unavailable")
      try verifyIdentity(allocation)
      allocation.cleanupPolicy = CleanupPolicy(
        graceSeconds: graceSeconds, disposablePaths: disposablePaths)
      allocation.cleanupPolicySourceID = nil
      allocation.eligibleSince = nil
      allocation.isStandingCleanupDeclined = false
      recordAttempt(&allocation, event: "policy-grant", reasons: ["Awaiting cleanup evaluation"])
      try store.save(allocation)
      return allocation
    }
  }

  public func revokeCleanup(_ id: String) throws -> Allocation {
    try withRegistry(stateDirectory) { store in
      var allocation = try store.allocation(id)
      try require(!allocation.isRemovalPending, "Removal is pending")
      allocation.cleanupPolicy = nil
      allocation.cleanupPolicySourceID = nil
      allocation.isCleanupAuthorized = false
      allocation.isStandingCleanupDeclined = true
      allocation.eligibleSince = nil
      recordAttempt(&allocation, event: "policy-revoke", reasons: ["Cleanup is not authorized"])
      try store.save(allocation)
      return allocation
    }
  }

  public func preview(_ id: String? = nil) throws -> [CleanupPreview] {
    try withRegistry(stateDirectory) { store in
      let allocations = try id.map { [try store.allocation($0)] } ?? store.allocations()
      return allocations.filter { $0.phase != .removed }.map { cleanupPreview($0) }
    }
  }

  public func sweep() throws -> [Allocation] {
    try withRegistry(stateDirectory) { store in
      var results: [Allocation] = []
      for var allocation in try store.allocations() {
        if let claims = allocation.conversationClaims {
          allocation.conversationClaims = claims.filter { isConversationBlocking($0) }
          try store.save(allocation)
        }
        guard allocation.phase != .removed,
          allocation.cleanupPolicy != nil || allocation.isCleanupAuthorized
        else { continue }
        if allocation.isRemovalPending {
          try reconcileRemoval(&allocation, store: store)
        } else {
          try cleanup(&allocation, store: store, event: "sweep")
        }
        results.append(allocation)
      }
      return results
    }
  }

  public func restore(_ id: String) throws -> Allocation {
    try withRegistry(stateDirectory, excluding: id) { store in
      var allocation = try store.allocation(id)
      try require(allocation.phase == .removed, "Only a removed allocation can be restored")
      guard let recovery = allocation.recovery else { throw WorkscopeError("No recovery record") }
      try verifyRecovery(allocation)
      try require(try !isPresent(allocation.path), "Restore destination is occupied")
      try require(
        try !isRegistered(allocation.repository, allocation.path),
        "Restore destination is registered")
      let branch = "workfree/restore/" + id + "/" + UUID().uuidString.lowercased()
      allocation.phase = .creating
      allocation.eligibleSince = nil
      allocation.reason = nil
      try store.save(allocation)
      do {
        switch allocation.provider {
        case .simgit:
          let creation = try JSONDecoder().decode(
            Creation.self,
            from: Data(
              try command(
                "/usr/bin/env",
                [
                  "simgit", "add", branch, "--path", allocation.path, "--base", recovery.commit,
                  "--require-cow", "--json",
                ], at: allocation.repository
              ).utf8))
          try require(
            try canonical(creation.path) == allocation.path && creation.mode == "cow-clone"
              && !creation.cleanupToken.isEmpty, "Unexpected restored checkout")
        case .git:
          _ = try git(
            allocation.repository,
            ["worktree", "add", "-b", branch, "--", allocation.path, recovery.commit])
        }
        allocation.admin = try canonical(git(allocation.path, ["rev-parse", "--absolute-git-dir"]))
        try verifyRepository(allocation)
        try require(
          try git(allocation.path, ["rev-parse", "HEAD"]) == recovery.commit,
          "Restored commit mismatch")
        let descriptor = try privateFile(
          allocation.admin! + "/workfree-allocation", isCreating: true)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: marker(allocation))
        try require(fsync(descriptor) == 0, "Cannot sync allocation marker")
        try handle.close()
        try syncDirectory(allocation.admin!)
        try verifyIdentity(allocation)
        completeRestore(&allocation)
        allocation.phase = .retained
        if let conversation { try acquireConversation(&allocation, conversation) }
        recordAttempt(&allocation, event: "restore", reasons: [])
        try store.save(allocation)
        return allocation
      } catch {
        allocation.phase =
          (try? isPresent(allocation.path)) == false
            && (try? isRegistered(allocation.repository, allocation.path)) == false
          ? .removed : .failed
        allocation.reason = "Restore interrupted; preserved commit remains available: \(error)"
        try store.save(allocation)
        throw error
      }
    }
  }

  public func list() throws -> [Allocation] {
    try withRegistry(stateDirectory) { try $0.allocations() }
  }

  public func status(since: TimeInterval?, isLiveMeasured: Bool = true) throws -> StorageStatus {
    storageStatus(try list(), since: since, isLiveMeasured: isLiveMeasured)
  }

  public func inspect(_ id: String) throws -> Allocation {
    try withRegistry(stateDirectory) { try $0.allocation(id) }
  }

  public func start(
    branch: String, repository: String, isCleanupAuthorized: Bool = false,
    base: String? = nil, path: String? = nil, provider: WorktreeProvider? = nil,
    isCowRequired: Bool = false, isCleanupPolicyRequired: Bool = false
  ) throws -> Allocation {
    try require(
      !branch.isEmpty && !branch.hasPrefix("-") && !branch.utf8.contains(0), "Invalid branch")
    if let base { try require(!base.isEmpty && !base.utf8.contains(0), "Invalid base reference") }
    let source = try canonical(repository)
    return try withRegistry(stateDirectory) { store in
      let selectedProvider = provider ?? (isExecutableAvailable("simgit") ? .simgit : .git)
      try require(!isCowRequired || selectedProvider == .simgit, "CoW requires the simgit provider")
      try require(
        try git(source, ["rev-parse", "--is-bare-repository"]) == "false",
        "A non-bare repository is required")
      let common = try canonical(
        git(source, ["rev-parse", "--path-format=absolute", "--git-common-dir"]))
      guard let primary = try registeredPaths(source).first else {
        throw WorkscopeError("Cannot identify primary checkout")
      }
      try require(
        try canonical(git(primary, ["rev-parse", "--absolute-git-dir"])) == common,
        "Primary repository identity mismatch")
      if selectedProvider == .simgit {
        let doctor = try JSONDecoder().decode(
          Doctor.self,
          from: Data(try command("/usr/bin/env", ["simgit", "doctor", "--json"], at: source).utf8))
        try require(
          doctor.identity == "simgit" && doctor.product == "simgit", "Unexpected simgit identity")
        try require(
          doctor.isCowSupported && doctor.isGitWorktreeSupported,
          "Real simgit CoW support is required")
        try require(
          try canonical(doctor.repository)
            == canonical(git(source, ["rev-parse", "--show-toplevel"]))
            && canonical(doctor.repositoryDetails.commonGitDirectory) == common
            && canonical(doctor.repositoryDetails.commonGitOwner) == primary,
          "Doctor repository identity mismatch")
      }
      let id = UUID().uuidString.lowercased()
      let target = try canonical(path ?? stateDirectory + "/worktrees/" + id)
      try require(
        !isWithin(target, primary) && !isWithin(target, source),
        "Checkout must be outside the source repository")
      try require(!isWithin(stateDirectory, target), "Checkout cannot contain the registry")
      try require(try !isPresent(target), "Explicit path already exists; adoption is not supported")
      try require(
        try !isRegistered(primary, target), "Path is already registered with Git")
      let allocations = try store.allocations()
      try require(
        !allocations.contains { isWithin(target, $0.path) || isWithin($0.path, target) },
        "Path is already reserved, including its tombstone")
      var allocation = Allocation(
        id: id, path: target, repository: primary,
        repositoryIdentity: try repositoryIdentity(primary), provider: selectedProvider,
        isCleanupAuthorized: isCleanupAuthorized,
        phase: .creating, owners: ["task:\(id)": Owner(kind: .task, label: nil)], retiredOwners: [:]
      )
      if let policy = try store.effectiveCleanupPolicy(
        allocation.repositoryIdentity, repository: allocation.repository)
      {
        allocation.cleanupPolicy = policy.cleanupPolicy
        allocation.cleanupPolicySourceID = policy.id
      }
      try require(
        !isCleanupPolicyRequired || allocation.cleanupPolicy != nil,
        "No standing cleanup authority. Operator setup: wf cleanup-policy enable --repo PATH. Existing allocations require an explicit operator wf authorize-cleanup ID grant."
      )
      try store.save(allocation, isNew: true)
      do {
        switch selectedProvider {
        case .simgit:
          var arguments = ["simgit", "add", branch, "--path", target, "--require-cow", "--json"]
          if let base { arguments += ["--base", base] }
          let creation = try JSONDecoder().decode(
            Creation.self, from: Data(try command("/usr/bin/env", arguments, at: primary).utf8))
          try require(
            try canonical(creation.path) == target,
            "simgit returned an unexpected path: \(creation.path), expected \(target)")
          try require(
            !creation.cleanupToken.isEmpty && creation.mode == "cow-clone",
            "simgit did not create a CoW worktree")
        case .git:
          var arguments = ["worktree", "add", "-b", branch, "--", target]
          if let base { arguments.append(base) }
          _ = try git(primary, arguments)
        }
        let admin = try canonical(git(target, ["rev-parse", "--absolute-git-dir"]))
        allocation.admin = admin
        try verifyRepository(allocation)
        try require(
          try isRegistered(primary, target), "Created checkout is not registered")
        try store.save(allocation)
        let markerPath = admin + "/workfree-allocation"
        let descriptor = try privateFile(markerPath, isCreating: true)
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: marker(allocation))
        try require(fsync(descriptor) == 0, "Cannot sync allocation marker")
        try handle.close()
        try syncDirectory(admin)
        try verifyIdentity(allocation)
        allocation.phase = .retained
        if let conversation { try acquireConversation(&allocation, conversation) }
        try store.save(allocation)
        return allocation
      } catch {
        allocation.phase = .failed
        allocation.reason = String(describing: error)
        try store.save(allocation)
        throw WorkscopeError("Allocation \(id) remains recoverable: \(error)")
      }
    }
  }

  public func retain(_ id: String, owner token: String, kind: OwnerKind, label: String? = nil)
    throws -> Allocation
  {
    try validToken(token)
    return try withRegistry(stateDirectory) { store in
      var allocation = try store.allocation(id)
      try retainOwner(&allocation, token: token, kind: kind, label: label, store: store)
      return allocation
    }
  }

  public func release(_ id: String, owner token: String) throws -> Allocation {
    try retire(id, token: token, requiredKind: nil, isCooperativeClosure: false)
  }

  public func finish(_ id: String, owner token: String? = nil) throws -> Allocation {
    try withRegistry(stateDirectory) { store in
      var allocation = try store.allocation(id)
      try retireOwner(
        &allocation, token: token ?? allocation.defaultTaskToken ?? "task:\(id)",
        requiredKind: .task, isCooperativeClosure: false, store: store)
      return allocation
    }
  }

  public func keep(_ id: String) throws -> Allocation {
    try withRegistry(stateDirectory) { store in
      var allocation = try store.allocation(id)
      let token: String
      if let current = allocation.defaultPinToken, allocation.owners[current] != nil {
        token = current
      } else {
        let initial = "pin:\(id)"
        token =
          try store.isTokenReserved(initial)
          ? initial + ":" + UUID().uuidString.lowercased() : initial
        allocation.defaultPinToken = token
      }
      try retainOwner(&allocation, token: token, kind: .pin, label: nil, store: store)
      return allocation
    }
  }

  public func unkeep(_ id: String) throws -> Allocation {
    try withRegistry(stateDirectory) { store in
      var allocation = try store.allocation(id)
      if let token = allocation.defaultPinToken {
        try retireOwner(
          &allocation, token: token, requiredKind: .pin, isCooperativeClosure: false, store: store)
      }
      return allocation
    }
  }

  public func closeScope(_ id: String, owner token: String) throws -> Allocation {
    try retire(id, token: token, requiredKind: .execution, isCooperativeClosure: true)
  }

  public func entryExit(_ id: String, owner token: String, status: Int32) throws -> Allocation {
    try withRegistry(stateDirectory) { store in
      var allocation = try store.allocation(id)
      guard var owner = allocation.owners[token], owner.kind == .execution else {
        throw WorkscopeError("Entry exit requires an active execution owner")
      }
      try require(
        owner.entryStatus == nil || owner.entryStatus == status, "Entry status already recorded")
      owner.entryStatus = status
      allocation.owners[token] = owner
      try store.save(allocation)
      return allocation
    }
  }

  public func recover(_ id: String) throws -> Allocation {
    try withRegistry(stateDirectory) { store in
      var allocation = try store.allocation(id)
      if allocation.phase == .removed { return allocation }
      try require(conversationReasons(allocation).isEmpty, "Conversation prevents recovery")
      if allocation.phase == .creating || allocation.phase == .failed {
        do {
          if allocation.recovery != nil {
            try verifyRecovery(allocation)
            if try !isPresent(allocation.path)
              && !isRegistered(allocation.repository, allocation.path)
            {
              allocation.phase = .removed
              allocation.reason = nil
              try store.save(allocation)
              return allocation
            }
          }
          try verifyIdentity(allocation)
          if allocation.recovery != nil { completeRestore(&allocation) }
          allocation.phase = .retained
          allocation.reason = nil
          try store.save(allocation)
        } catch {
          allocation.phase = .failed
          allocation.reason = "Creation identity is unproven; no adoption or deletion: \(error)"
          try store.save(allocation)
          return allocation
        }
      }
      if allocation.isRemovalPending {
        try reconcileRemoval(&allocation, store: store)
      } else if allocation.owners.isEmpty, try !isPresent(allocation.path) {
        do {
          try require(allocation.isCleanupAuthorized, "Cleanup is not authorized")
          try require(
            try repositoryIdentity(allocation.repository) == allocation.repositoryIdentity,
            "Repository identity changed")
          try require(
            try !isRegistered(allocation.repository, allocation.path),
            "Removal left a registration")
          allocation.phase = .removed
          allocation.isRemovalPending = false
          allocation.reason = nil
          allocation.removedAt = Date()
        } catch {
          allocation.phase = .blocked
          allocation.reason = String(describing: error)
        }
        try store.save(allocation)
      } else {
        try cleanup(&allocation, store: store)
      }
      return allocation
    }
  }

  public func run(_ id: String, owner token: String? = nil, command arguments: [String]) throws
    -> Int32
  {
    try require(!arguments.isEmpty && !arguments[0].isEmpty, "Missing command")
    try require(arguments.allSatisfy { !$0.utf8.contains(0) }, "Invalid command argument")
    let token = token ?? "execution:\(UUID().uuidString.lowercased())"
    let allocation = try retain(id, owner: token, kind: .execution)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["--"] + arguments
    process.currentDirectoryURL = URL(fileURLWithPath: allocation.path)
    var environment = ProcessInfo.processInfo.environment
    environment["WORKFREE_ALLOCATION_ID"] = id
    environment["WORKFREE_OWNER_TOKEN"] = token
    environment["WORKFREE_PATH"] = allocation.path
    process.environment = environment
    try process.run()
    process.waitUntilExit()
    let status =
      process.terminationReason == .exit
      ? process.terminationStatus : 128 + process.terminationStatus
    _ = try entryExit(id, owner: token, status: status)
    return status
  }

  private func retire(
    _ id: String, token: String, requiredKind: OwnerKind?, isCooperativeClosure: Bool
  ) throws -> Allocation {
    try validToken(token)
    return try withRegistry(stateDirectory) { store in
      var allocation = try store.allocation(id)
      try retireOwner(
        &allocation, token: token, requiredKind: requiredKind,
        isCooperativeClosure: isCooperativeClosure, store: store)
      return allocation
    }
  }
}

private func cleanupPolicyStatus(
  _ repository: String, store: RegistryStore
) throws -> RepositoryCleanupPolicyStatus {
  let source = try canonical(repository)
  try require(
    try git(source, ["rev-parse", "--is-bare-repository"]) == "false",
    "A non-bare repository is required")
  guard let primary = try registeredPaths(source).first else {
    throw WorkscopeError("Cannot identify primary checkout")
  }
  let identity = try repositoryIdentity(primary)
  try require(try repositoryIdentity(source) == identity, "Primary repository identity mismatch")
  return RepositoryCleanupPolicyStatus(
    repository: primary, repositoryIdentity: identity,
    policy: try store.repositoryCleanupPolicy(identity))
}

private func completeRestore(_ allocation: inout Allocation) {
  if let removedAt = allocation.removedAt {
    var history = allocation.pastRemovals ?? []
    history.append(Reclamation(date: removedAt, estimatedBytes: allocation.reclaimedBytes ?? 0))
    allocation.pastRemovals = history
  }
  allocation.removedAt = nil
  allocation.reclaimedBytes = nil
  if !allocation.owners.values.contains(where: { $0.kind == .task }) {
    let token = "task:restore:" + UUID().uuidString.lowercased()
    allocation.owners[token] = Owner(kind: .task, label: "Restored task")
    allocation.defaultTaskToken = token
  }
}

private func retainOwner(
  _ allocation: inout Allocation, token: String, kind: OwnerKind, label: String?,
  store: RegistryStore
) throws {
  try require(
    allocation.phase == .retained || allocation.phase == .blocked, "Allocation is unavailable")
  try require(
    !allocation.isRemovalPending, "Removal is pending; allocation cannot be reacquired")
  try verifyIdentity(allocation)
  try require(allocation.retiredOwners[token] == nil, "Retired owner token cannot be reused")
  if let owner = allocation.owners[token] {
    try require(owner.kind == kind && owner.label == label, "Owner token metadata changed")
  } else {
    allocation.owners[token] = Owner(kind: kind, label: label)
  }
  allocation.phase = .retained
  allocation.reason = nil
  allocation.eligibleSince = nil
  try store.save(allocation)
}

private func retireOwner(
  _ allocation: inout Allocation, token: String, requiredKind: OwnerKind?,
  isCooperativeClosure: Bool, store: RegistryStore
) throws {
  guard var owner = allocation.owners[token] ?? allocation.retiredOwners[token] else {
    throw WorkscopeError("Unknown owner token")
  }
  try require(requiredKind == nil || owner.kind == requiredKind, "Wrong owner kind")
  try require(
    owner.kind != .execution || isCooperativeClosure,
    "Execution ownership requires explicit close-scope")
  if allocation.owners[token] != nil {
    owner.isCooperativelyClosed = isCooperativeClosure
    allocation.owners.removeValue(forKey: token)
    allocation.retiredOwners[token] = owner
    try store.save(allocation)
  }
  if allocation.phase != .removed { try cleanup(&allocation, store: store) }
}

private func validToken(_ token: String) throws {
  try require(!token.isEmpty && !token.utf8.contains(0), "Invalid owner token")
}

func repositoryIdentity(_ repository: String) throws -> String {
  let common = try canonical(
    git(repository, ["rev-parse", "--path-format=absolute", "--git-common-dir"]))
  var info = stat()
  try require(stat(common, &info) == 0, "Cannot inspect repository identity")
  return "\(common):\(info.st_dev):\(info.st_ino)"
}

private func marker(_ allocation: Allocation) throws -> Data {
  try JSONEncoder().encode([allocation.id, allocation.repositoryIdentity, allocation.path])
}

private func verifyRepository(_ allocation: Allocation) throws {
  try require(
    try repositoryIdentity(allocation.repository) == allocation.repositoryIdentity,
    "Repository identity changed")
  try require(
    try repositoryIdentity(allocation.path) == allocation.repositoryIdentity,
    "Checkout repository changed")
  let admin = try canonical(git(allocation.path, ["rev-parse", "--absolute-git-dir"]))
  let common = try canonical(
    git(allocation.path, ["rev-parse", "--path-format=absolute", "--git-common-dir"]))
  try require(admin == allocation.admin, "Administrative identity changed")
  try require(
    try canonical(git(allocation.path, ["rev-parse", "--show-toplevel"])) == allocation.path,
    "Git checkout root changed")
  try require(try canonical(allocation.path) == allocation.path, "Checkout path identity changed")
  try require(
    allocation.path != allocation.repository && admin != common,
    "Primary checkout cannot be removed")
  try require(
    admin.hasPrefix(common + "/worktrees/"), "Not a linked-worktree administrative directory")
}

func verifyIdentity(_ allocation: Allocation) throws {
  try verifyRepository(allocation)
  guard let admin = allocation.admin else {
    throw WorkscopeError("Missing administrative identity")
  }
  let descriptor = try privateFile(admin + "/workfree-allocation", isCreating: false)
  let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
  defer { try? handle.close() }
  try require(try handle.readToEnd() == marker(allocation), "Allocation marker changed")
  try require(
    try isRegistered(allocation.repository, allocation.path),
    "Checkout registration changed")
}
