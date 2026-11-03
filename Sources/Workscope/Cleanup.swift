import Darwin
import Foundation

private func cleanupGrace(_ allocation: Allocation) -> TimeInterval {
  let configured = allocation.cleanupPolicy?.graceSeconds ?? 0
  return allocation.cleanupPolicySourceID == nil ? configured : max(configured, 86_400)
}

func checkpointTree(_ path: String) throws -> String {
  var template = Array((NSTemporaryDirectory() + "/workfree-index.XXXXXX").utf8CString)
  guard let directory = mkdtemp(&template) else {
    throw WorkscopeError("Cannot create checkpoint index directory")
  }
  let index = String(cString: directory) + "/index"
  defer { try? FileManager.default.removeItem(atPath: String(cString: directory)) }
  func indexedGit(_ arguments: [String]) throws -> String {
    try command(
      "/usr/bin/env",
      ["GIT_INDEX_FILE=" + index, "/usr/bin/git", "-C", path] + arguments
    ).trimmingCharacters(in: .newlines)
  }
  _ = try indexedGit(["read-tree", "HEAD"])
  _ = try indexedGit(["add", "-A", "--", "."])
  return try indexedGit(["write-tree"])
}

func pushOffload(_ allocation: Allocation) throws -> (
  commit: String, source: String, stagedTree: String
) {
  let path = allocation.path
  let source = try git(path, ["rev-parse", "--verify", "HEAD^{commit}"])
  let stagedTree = try git(path, ["write-tree"])
  let tree = try checkpointTree(path)
  let remote = try git(path, ["remote", "get-url", "--push", "origin"])
  try require(!remote.isEmpty, "Offload requires an origin push remote")
  let reference = "refs/heads/workfree/offload/" + allocation.id
  let existing = try git(path, ["ls-remote", "--heads", "origin", reference])
    .split(separator: "\t").first.map(String.init)
  if let existing {
    try require(
      try git(path, ["cat-file", "-t", existing]) == "commit",
      "Offload branch changed outside this checkout")
    _ = try command(
      "/usr/bin/git", ["-C", path, "merge-base", "--is-ancestor", source, existing])
    let previousTree = try git(path, ["rev-parse", existing + "^{tree}"])
    let previousStagedTree = try git(path, ["rev-parse", existing + "^^{tree}"])
    if previousTree == tree && previousStagedTree == stagedTree {
      return (existing, source, stagedTree)
    }
  }
  let parent = try git(
    path,
    [
      "commit-tree", stagedTree, "-p", existing ?? source, "-m",
      "workfree offload staged: " + allocation.id,
    ])
  let commit = try git(
    path, ["commit-tree", tree, "-p", parent, "-m", "workfree offload: " + allocation.id])
  _ = try git(path, ["push", "origin", commit + ":" + reference])
  let published = try git(path, ["ls-remote", "--heads", "origin", reference])
    .split(separator: "\t").first.map(String.init)
  try require(published == commit, "Offload push was not confirmed")
  return (commit, source, stagedTree)
}

func localOffload(_ allocation: Allocation) throws -> (
  commit: String, source: String, stagedTree: String
) {
  let path = allocation.path
  let source = try git(path, ["rev-parse", "--verify", "HEAD^{commit}"])
  let stagedTree = try git(path, ["write-tree"])
  let staged = try git(
    path,
    ["commit-tree", stagedTree, "-p", source, "-m", "workfree offload staged: " + allocation.id])
  let commit = try git(
    path,
    ["commit-tree", checkpointTree(path), "-p", staged, "-m", "workfree offload: " + allocation.id])
  return (commit, source, stagedTree)
}

func advanceCheckout(
  _ allocation: Allocation,
  offload: (
    commit: String, source: String, stagedTree: String
  )
) throws {
  let path = allocation.path
  let index = try git(path, ["rev-parse", "--path-format=absolute", "--git-path", "index"])
  let baseline = try Data(contentsOf: URL(fileURLWithPath: index))
  try require(
    try git(path, ["write-tree"]) == offload.stagedTree,
    "Checkout changed before index replacement")
  let lock = index + ".lock"
  let descriptor = open(lock, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
  try require(descriptor >= 0, "Cannot lock checkout index")
  _ = close(descriptor)
  defer { _ = unlink(lock) }
  let shadow = lock + ".checkpoint"
  defer { _ = unlink(shadow) }
  try require(
    try git(path, ["rev-parse", "HEAD"]) == offload.source
      && Data(contentsOf: URL(fileURLWithPath: index)) == baseline,
    "Checkout changed before index replacement")
  _ = try command(
    "/usr/bin/env",
    ["GIT_INDEX_FILE=" + shadow, "/usr/bin/git", "-C", path, "read-tree", offload.commit])
  try require(rename(shadow, lock) == 0, "Cannot prepare checkpoint index")
  _ = try git(path, ["update-ref", "HEAD", offload.commit, offload.source])
  try require(rename(lock, index) == 0, "Cannot install checkpoint index")
}

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

func ownershipReasons(_ allocation: Allocation, isManual: Bool = false) -> [String] {
  var reasons = conversationReasons(allocation)
  if !isManual && !allocation.isCleanupAuthorized && allocation.cleanupPolicy == nil {
    reasons.append("Cleanup is not authorized")
  }
  if !isManual && allocation.recovery?.event.hasPrefix("manual-offload-") == true {
    reasons.append("Awaiting manual cleanup")
  }
  for (token, owner) in allocation.owners.sorted(by: { $0.key < $1.key }) {
    if owner.kind == .task && (allocation.cleanupPolicy != nil || isManual) { continue }
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
    let committed = try git(
      allocation.path, ["--literal-pathspecs", "ls-tree", "-r", "HEAD", "--", relative])
    try require(
      tracked.isEmpty && committed.isEmpty,
      "Disposable path contains tracked files: \(relative)")
    return try isPresent(path) ? path : nil
  }
}

func verifyFiles(_ allocation: Allocation, isCheckpointAllowed: Bool = false) throws -> [String] {
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
  let trackedStatus = try git(
    allocation.path,
    [
      "status", "--porcelain=v1", "-z", "--untracked-files=no", "--ignored=no",
      "--ignore-submodules=none",
    ])
  if !isCheckpointAllowed {
    try require(trackedStatus.isEmpty, "Changed, staged, untracked, or ignored files remain")
  }
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
      if isCheckpointAllowed { continue }
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
    try isRepositoryIdentityMatching(allocation.repository, allocation: allocation),
    "Repository identity changed")
  guard let recovery = allocation.recovery else { throw WorkscopeError("No recovery record") }
  try require(
    recovery.reference.hasPrefix("refs/workfree/recovery/" + allocation.id + "/"),
    "Invalid recovery reference")
  try require(
    try git(allocation.repository, ["rev-parse", "--verify", recovery.reference + "^{commit}"])
      == recovery.commit, "Recovery reference changed")
}

func cleanupPreview(
  _ allocation: Allocation, isFileVerificationRequired: Bool = true, isManual: Bool = false
) -> CleanupPreview {
  var reasons = ownershipReasons(allocation, isManual: isManual)
  if allocation.phase == .creating || allocation.phase == .failed {
    reasons.append("Allocation identity requires recovery")
  }
  if allocation.isRemovalPending { reasons.append("Removal is pending; use recover") }
  let eligibleAt = allocation.eligibleSince.map {
    $0.addingTimeInterval(cleanupGrace(allocation))
  }
  let isGracePending =
    !isManual && allocation.cleanupPolicy != nil
    && (eligibleAt.map { $0 > Date() } ?? (cleanupGrace(allocation) > 0))
  if isFileVerificationRequired || (reasons.isEmpty && !isGracePending) {
    do {
      _ = try verifyFiles(
        allocation, isCheckpointAllowed: allocation.cleanupPolicy != nil || isManual)
      if allocation.cleanupPolicy == nil && !isManual {
        let head = try git(allocation.path, ["rev-parse", "HEAD"])
        let refs = try git(
          allocation.repository,
          ["for-each-ref", "--contains", head, "--format=%(refname)", "refs/heads", "refs/tags"])
        try require(!refs.isEmpty, "No ordinary branch or tag preserves HEAD")
      }
    } catch { reasons.append(String(describing: error)) }
  }
  let estimatedBytes =
    reasons.isEmpty && (!isGracePending || isFileVerificationRequired)
    ? measure(allocation.path).privateBytes : 0
  if reasons.isEmpty, allocation.cleanupPolicy != nil && !isManual {
    if eligibleAt != nil {
      if isGracePending { reasons.append("Eligible after grace period") }
    } else if cleanupGrace(allocation) > 0 {
      reasons.append("Awaiting grace period")
    }
  }
  return CleanupPreview(
    id: allocation.id, reasons: reasons, eligibleAt: eligibleAt,
    estimatedBytes: estimatedBytes)
}

func cleanup(
  _ allocation: inout Allocation, store: RegistryStore, event: String = "owner-release",
  minimumIdle: TimeInterval? = nil, transcriptDirectory: String? = nil
) throws {
  if allocation.phase == .removed { return }
  if allocation.isRemovalPending {
    try reconcileRemoval(&allocation, store: store)
    return
  }
  let isManual = event == "manual-cleanup"
  let preview = cleanupPreview(
    allocation, isFileVerificationRequired: event != "sweep", isManual: isManual)
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
  if !isManual && allocation.cleanupPolicy != nil,
    allocation.eligibleSince!.addingTimeInterval(cleanupGrace(allocation)) > Date()
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
    let isOffload = allocation.cleanupPolicy != nil || isManual
    _ = try verifyFiles(allocation, isCheckpointAllowed: isOffload)
    if isManual {
      guard let recovery = allocation.recovery,
        recovery.event == "manual-offload-local" || recovery.event == "manual-offload-remote"
          || recovery.event == "manual-cleanup"
      else { throw WorkscopeError("Offload this checkout before manual cleanup") }
      try verifyRecovery(allocation)
      let head = try git(allocation.path, ["rev-parse", "HEAD"])
      let tree = try git(allocation.path, ["rev-parse", recovery.commit + "^{tree}"])
      try require(
        head == recovery.commit && git(allocation.path, ["write-tree"]) == tree
          && checkpointTree(allocation.path) == tree,
        "Checkout changed after offload; offload again before cleanup")
    }
    let offload = try isOffload && !isManual ? pushOffload(allocation) : nil
    let head =
      try offload?.commit
      ?? git(allocation.path, ["rev-parse", "--verify", "HEAD^{commit}"])
    if isManual, let checkpoint = allocation.recovery {
      allocation.recovery = RecoveryRecord(
        commit: checkpoint.commit, reference: checkpoint.reference, branch: checkpoint.branch,
        preservedAt: checkpoint.preservedAt, event: event,
        lastFileActivity: checkpoint.lastFileActivity)
    } else {
      let reference =
        "refs/workfree/recovery/" + allocation.id + "/" + UUID().uuidString.lowercased()
      _ = try git(
        allocation.repository, ["-c", "core.fsync=reference", "update-ref", reference, head, ""])
      allocation.recovery = RecoveryRecord(
        commit: head, reference: reference,
        branch: try? git(allocation.path, ["symbolic-ref", "--short", "HEAD"]),
        preservedAt: Date(), event: event, lastFileActivity: nil)
    }
    try verifyRecovery(allocation)
    let bytes = measure(allocation.path).privateBytes
    let targets = try verifyFiles(allocation, isCheckpointAllowed: isOffload)
    if let offload {
      try require(
        try git(allocation.path, ["rev-parse", "HEAD"]) == offload.source
          && git(allocation.path, ["write-tree"]) == offload.stagedTree
          && checkpointTree(allocation.path)
            == git(allocation.repository, ["rev-parse", head + "^{tree}"]),
        "Checkout changed during offload")
    } else {
      try require(
        try git(allocation.path, ["rev-parse", "HEAD"]) == head, "HEAD changed during cleanup")
    }
    if isManual {
      guard let minimumIdle, let transcriptDirectory else {
        throw WorkscopeError("Manual cleanup requires an idle age and transcript directory")
      }
      let current = try oneOffPreviews(
        [allocation], minimumIdle: minimumIdle, transcriptDirectory: transcriptDirectory,
        isCheckpointRequired: true)[0]
      try require(current.isEligible, current.reasons.joined(separator: "; "))
    }
    allocation.phase = .removing
    allocation.isRemovalPending = true
    allocation.reason = nil
    allocation.reclaimedBytes = bytes
    recordAttempt(&allocation, event: event, reasons: [])
    try store.save(allocation)
    if let offload { try advanceCheckout(allocation, offload: offload) }
    for target in targets {
      if isOffload {
        let relative = String(target.dropFirst(allocation.path.count + 1))
        _ = try git(allocation.path, ["--literal-pathspecs", "clean", "-fdX", "--", relative])
      } else {
        try FileManager.default.removeItem(atPath: target)
      }
    }
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
    let isManual = allocation.recovery?.event == "manual-cleanup"
    try require(
      allocation.isCleanupAuthorized || allocation.cleanupPolicy != nil || isManual,
      "Cleanup is not authorized")
    try require(
      ownershipReasons(allocation, isManual: isManual).isEmpty,
      "Active owners prevent recovery")
    if try !isPresent(allocation.path) {
      try require(
        try !isRegistered(allocation.repository, allocation.path), "Removal left a registration")
    }
    if allocation.recovery == nil {
      try require(
        try isRepositoryIdentityMatching(allocation.repository, allocation: allocation),
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
      try cleanup(&allocation, store: store, event: isManual ? "manual-cleanup" : "recovery")
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
