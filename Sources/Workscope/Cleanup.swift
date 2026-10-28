import Foundation

func validateDisposablePath(_ path: String) throws {
  let components = path.split(separator: "/", omittingEmptySubsequences: false)
  try require(
    !path.isEmpty && !path.hasPrefix("/") && !path.utf8.contains(0)
      && components.allSatisfy {
        !$0.isEmpty && $0 != "." && $0 != ".." && $0.lowercased() != ".git"
      },
    "Disposable paths must be explicit checkout-relative paths")
}

func recordAttempt(_ allocation: inout Allocation, event: String, reasons: [String]) {
  var attempts = allocation.cleanupAttempts ?? []
  attempts.append(
    CleanupAttempt(date: Date(), event: event, reasons: reasons, phase: allocation.phase))
  allocation.cleanupAttempts = Array(attempts.suffix(32))
}

func ownershipReasons(_ allocation: Allocation) -> [String] {
  var reasons = conversationReasons(allocation)
  if !allocation.isCleanupAuthorized && allocation.cleanupPolicy == nil {
    reasons.append("Cleanup is not authorized")
  }
  for (token, owner) in allocation.owners.sorted(by: { $0.key < $1.key }) {
    if owner.kind == .task && allocation.cleanupPolicy != nil { continue }
    reasons.append("Retained \(owner.kind.rawValue) owner: \(token)")
  }
  if allocation.retiredOwners.values.contains(where: {
    $0.kind == .execution && !$0.isCooperativelyClosed
  }) {
    reasons.append("Execution scope closure is unproven")
  }
  return reasons
}

func disposableTargets(_ allocation: Allocation) throws -> [String] {
  try (allocation.cleanupPolicy?.disposablePaths ?? []).compactMap { relative in
    try validateDisposablePath(relative)
    let path = allocation.path + "/" + relative
    let resolved = try canonical(path)
    try require(
      resolved == path && isWithin(resolved, allocation.path),
      "Disposable path contains an alias: \(relative)")
    let tracked = try git(
      allocation.path, ["--literal-pathspecs", "ls-files", "-z", "--", relative])
    try require(tracked.isEmpty, "Disposable path contains tracked files: \(relative)")
    return try isPresent(path) ? path : nil
  }
}

func verifyFiles(_ allocation: Allocation) throws -> [String] {
  try verifyIdentity(allocation)
  guard let admin = allocation.admin else {
    throw WorkscopeError("Missing administrative identity")
  }
  for operation in [
    "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply", "sequencer",
    "BISECT_LOG", "index.lock",
  ] {
    try require(try !isPresent(admin + "/" + operation), "Git operation in progress: \(operation)")
  }
  let index = try git(allocation.path, ["ls-files", "-v", "-z"])
  try require(
    index.split(separator: "\0").allSatisfy { field in
      guard let flag = field.first else { return false }
      return flag != "S" && !flag.isLowercase
    }, "Index flags can hide tracked changes")
  let entries = try git(allocation.path, ["ls-files", "--stage", "-z"])
  try require(
    !entries.split(separator: "\0").contains { $0.hasPrefix("160000 ") },
    "Submodule preservation is unproven")
  let targets = try disposableTargets(allocation)
  var statusPaths = ["."]
  for target in targets {
    let relative = String(target.dropFirst(allocation.path.count + 1))
    let ignored = try command(
      "/usr/bin/git", ["-C", allocation.path, "check-ignore", "--no-index", "--", relative],
      accepting: [0, 1])
    if !ignored.isEmpty { statusPaths.append(":(exclude,literal)" + relative) }
  }
  let status = try git(
    allocation.path,
    [
      "status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored",
      "--ignore-submodules=none", "--",
    ] + statusPaths)
  for entry in status.split(separator: "\0") {
    let text = String(entry)
    guard text.hasPrefix("!! ") else {
      throw WorkscopeError("Changed, staged, untracked, or ignored files remain")
    }
    let relative = String(text.dropFirst(3)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let path = allocation.path + "/" + relative
    try require(targets.contains { isWithin(path, $0) }, "Unapproved ignored file: \(relative)")
  }
  return targets
}

func verifyRecovery(_ allocation: Allocation) throws {
  try require(
    try repositoryIdentity(allocation.repository) == allocation.repositoryIdentity,
    "Repository identity changed")
  guard let recovery = allocation.recovery else { throw WorkscopeError("No recovery record") }
  try require(
    recovery.reference.hasPrefix("refs/workfree/recovery/" + allocation.id + "/"),
    "Invalid recovery reference")
  try require(
    try git(allocation.repository, ["rev-parse", "--verify", recovery.reference + "^{commit}"])
      == recovery.commit, "Recovery reference changed")
}

func cleanupPreview(_ allocation: Allocation) -> CleanupPreview {
  var reasons = ownershipReasons(allocation)
  if allocation.phase == .creating || allocation.phase == .failed {
    reasons.append("Allocation identity requires recovery")
  }
  if allocation.isRemovalPending { reasons.append("Removal is pending; use recover") }
  do {
    _ = try verifyFiles(allocation)
    if allocation.cleanupPolicy == nil {
      let head = try git(allocation.path, ["rev-parse", "HEAD"])
      let refs = try git(
        allocation.repository,
        ["for-each-ref", "--contains", head, "--format=%(refname)", "refs/heads", "refs/tags"])
      try require(!refs.isEmpty, "No ordinary branch or tag preserves HEAD")
    }
  } catch { reasons.append(String(describing: error)) }
  let estimatedBytes = reasons.isEmpty ? measure(allocation.path).privateBytes : 0
  let eligibleAt = allocation.eligibleSince.map {
    $0.addingTimeInterval(allocation.cleanupPolicy?.graceSeconds ?? 0)
  }
  if reasons.isEmpty, let policy = allocation.cleanupPolicy {
    if let eligibleAt {
      if eligibleAt > Date() { reasons.append("Eligible after grace period") }
    } else if policy.graceSeconds > 0 {
      reasons.append("Awaiting grace period")
    }
  }
  return CleanupPreview(
    id: allocation.id, reasons: reasons, eligibleAt: eligibleAt,
    estimatedBytes: estimatedBytes)
}

func cleanup(_ allocation: inout Allocation, store: RegistryStore, event: String = "owner-release")
  throws
{
  if allocation.phase == .removed { return }
  if allocation.isRemovalPending {
    try reconcileRemoval(&allocation, store: store)
    return
  }
  let preview = cleanupPreview(allocation)
  let blockers = preview.reasons.filter {
    $0 != "Awaiting grace period" && $0 != "Eligible after grace period"
  }
  if !blockers.isEmpty {
    allocation.eligibleSince = nil
    if allocation.phase != .creating && allocation.phase != .failed {
      allocation.phase = allocation.owners.isEmpty ? .blocked : .retained
    }
    allocation.reason = blockers.joined(separator: "; ")
    recordAttempt(&allocation, event: event, reasons: blockers)
    try store.save(allocation)
    return
  }
  if allocation.eligibleSince == nil { allocation.eligibleSince = Date() }
  if let policy = allocation.cleanupPolicy,
    allocation.eligibleSince!.addingTimeInterval(policy.graceSeconds) > Date()
  {
    allocation.phase = .retained
    allocation.reason = "Eligible after grace period"
    recordAttempt(&allocation, event: event, reasons: [allocation.reason!])
    try store.save(allocation)
    return
  }
  allocation.phase = .checking
  try store.save(allocation)
  do {
    _ = try verifyFiles(allocation)
    let head = try git(allocation.path, ["rev-parse", "--verify", "HEAD^{commit}"])
    let reference = "refs/workfree/recovery/" + allocation.id + "/" + UUID().uuidString.lowercased()
    _ = try git(
      allocation.repository, ["-c", "core.fsync=reference", "update-ref", reference, head, ""])
    allocation.recovery = RecoveryRecord(
      commit: head, reference: reference,
      branch: try? git(allocation.path, ["symbolic-ref", "--short", "HEAD"]), preservedAt: Date(),
      event: event)
    try verifyRecovery(allocation)
    let bytes = measure(allocation.path).privateBytes
    let targets = try verifyFiles(allocation)
    try require(
      try git(allocation.path, ["rev-parse", "HEAD"]) == head, "HEAD changed during cleanup")
    allocation.phase = .removing
    allocation.isRemovalPending = true
    allocation.reason = nil
    allocation.reclaimedBytes = bytes
    recordAttempt(&allocation, event: event, reasons: [])
    try store.save(allocation)
    for target in targets { try FileManager.default.removeItem(atPath: target) }
    switch allocation.provider {
    case .simgit:
      _ = try command(
        "/usr/bin/env", ["simgit", "remove", allocation.path], at: allocation.repository)
    case .git:
      _ = try git(allocation.repository, ["worktree", "remove", "--", allocation.path])
    }
    try completeRemoval(&allocation)
    recordAttempt(&allocation, event: event, reasons: [])
  } catch {
    allocation.phase = .blocked
    allocation.reason = String(describing: error)
    recordAttempt(&allocation, event: event, reasons: [allocation.reason!])
  }
  try store.save(allocation)
}

func completeRemoval(_ allocation: inout Allocation) throws {
  try verifyRecovery(allocation)
  try require(try !isPresent(allocation.path), "Checkout remains")
  try require(
    try !isRegistered(allocation.repository, allocation.path), "Removal left a registration")
  allocation.phase = .removed
  allocation.isRemovalPending = false
  allocation.reason = nil
  allocation.eligibleSince = nil
  allocation.removedAt = Date()
}

func reconcileRemoval(_ allocation: inout Allocation, store: RegistryStore) throws {
  do {
    try require(
      allocation.isCleanupAuthorized || allocation.cleanupPolicy != nil, "Cleanup is not authorized"
    )
    try require(ownershipReasons(allocation).isEmpty, "Active owners prevent recovery")
    if try !isPresent(allocation.path) {
      try require(
        try !isRegistered(allocation.repository, allocation.path), "Removal left a registration")
    }
    if allocation.recovery == nil {
      try require(
        try repositoryIdentity(allocation.repository) == allocation.repositoryIdentity,
        "Repository identity changed")
      if try !isPresent(allocation.path) {
        allocation.phase = .removed
        allocation.isRemovalPending = false
        allocation.reason = nil
        allocation.removedAt = Date()
        recordAttempt(
          &allocation, event: "legacy-recovery",
          reasons: ["Legacy removal has no exact recovery record"])
        try store.save(allocation)
        return
      }
    } else {
      try verifyRecovery(allocation)
    }
    if try isPresent(allocation.path) {
      try verifyIdentity(allocation)
      allocation.isRemovalPending = false
      allocation.phase = .retained
      try store.save(allocation)
      try cleanup(&allocation, store: store, event: "recovery")
      return
    }
    try completeRemoval(&allocation)
    recordAttempt(&allocation, event: "recovery", reasons: [])
  } catch {
    allocation.phase = .blocked
    allocation.reason = String(describing: error)
    recordAttempt(&allocation, event: "recovery", reasons: [allocation.reason!])
  }
  try store.save(allocation)
}
