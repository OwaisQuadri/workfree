import CSQLite
import Darwin
import Foundation

final class RegistryStore {
  private var database: OpaquePointer?

  init(directory: String, isNewLock: Bool) throws {
    let path = directory + "/registry.sqlite"
    let isNew = try !isPresent(path)
    try require(!isNew || isNewLock, "Registry is missing; refusing to recreate it")
    let descriptor = try privateFile(path, isCreating: isNew)
    close(descriptor)
    do {
      try require(
        sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
          == SQLITE_OK, "Cannot open registry")
      try execute("PRAGMA synchronous=FULL")
      try execute("PRAGMA fullfsync=ON")
      try execute("PRAGMA journal_mode=DELETE")
      if isNew {
        try transaction {
          try execute("PRAGMA application_id=1465074512")
          try execute("PRAGMA user_version=1")
          try execute(
            "CREATE TABLE allocations (id TEXT PRIMARY KEY, path TEXT NOT NULL UNIQUE, data TEXT NOT NULL)"
          )
          try execute(
            "CREATE TABLE owner_tokens (token TEXT PRIMARY KEY, allocation_id TEXT NOT NULL)")
        }
        try syncDirectory(directory)
      }
      try require(try strings("PRAGMA application_id") == ["1465074512"], "Unknown registry")
      try require(
        try [["1"], ["2"], ["3"], ["4"]].contains(strings("PRAGMA user_version")),
        "Unsupported registry version")
      try require(try strings("PRAGMA integrity_check") == ["ok"], "Corrupt registry")
      _ = try strings("SELECT token FROM owner_tokens LIMIT 1")
      _ = try strings("SELECT data FROM allocations LIMIT 1")
      if try [["3"], ["4"]].contains(strings("PRAGMA user_version")) {
        _ = try strings("SELECT data FROM repository_cleanup_policies LIMIT 1")
      }
      if try strings("PRAGMA user_version") == ["4"] {
        _ = try strings("SELECT data FROM global_cleanup_policy LIMIT 1")
        _ = try strings("SELECT repository FROM cleanup_exclusions LIMIT 1")
      }
    } catch {
      sqlite3_close(database)
      database = nil
      throw error
    }
  }

  deinit { sqlite3_close(database) }

  func allocations() throws -> [Allocation] {
    try strings("SELECT data FROM allocations ORDER BY id").map {
      try JSONDecoder().decode(Allocation.self, from: Data($0.utf8))
    }
  }

  func allocation(_ id: String) throws -> Allocation {
    let rows = try strings("SELECT data FROM allocations WHERE id=?", [id])
    guard let row = rows.first else { throw WorkscopeError("Unknown allocation: \(id)") }
    let allocation = try JSONDecoder().decode(Allocation.self, from: Data(row.utf8))
    try require(allocation.id == id, "Allocation identity mismatch")
    return allocation
  }

  func isTokenReserved(_ token: String) throws -> Bool {
    try !strings("SELECT allocation_id FROM owner_tokens WHERE token=?", [token]).isEmpty
  }

  func save(_ allocation: Allocation, isNew: Bool = false) throws {
    try transaction { try saveAllocation(allocation, isNew: isNew) }
  }

  func repositoryCleanupPolicy(_ identity: String) throws -> RepositoryCleanupPolicy? {
    guard try [["3"], ["4"]].contains(strings("PRAGMA user_version")) else { return nil }
    guard
      let data = try strings(
        "SELECT data FROM repository_cleanup_policies WHERE repository_identity=?", [identity]
      ).first
    else { return nil }
    let policy = try JSONDecoder().decode(RepositoryCleanupPolicy.self, from: Data(data.utf8))
    try require(
      policy.repositoryIdentity == identity && !policy.id.isEmpty,
      "Repository policy identity mismatch")
    return policy
  }

  func saveRepositoryCleanupPolicy(_ policy: RepositoryCleanupPolicy) throws {
    let data = String(decoding: try JSONEncoder().encode(policy), as: UTF8.self)
    try transaction {
      if try strings("PRAGMA user_version") != ["4"] { try execute("PRAGMA user_version=3") }
      try execute(
        "CREATE TABLE IF NOT EXISTS repository_cleanup_policies (repository_identity TEXT PRIMARY KEY, data TEXT NOT NULL)"
      )
      try execute(
        "INSERT INTO repository_cleanup_policies (repository_identity, data) VALUES (?, ?)",
        [policy.repositoryIdentity, data])
    }
  }

  func revokeRepositoryCleanupPolicy(_ identity: String) throws {
    try transaction {
      guard let policy = try repositoryCleanupPolicy(identity) else { return }
      let derived = try allocations().filter { $0.cleanupPolicySourceID == policy.id }
      try require(!derived.contains { $0.isRemovalPending }, "Derived removal is pending")
      for var allocation in derived {
        allocation.cleanupPolicy = nil
        allocation.cleanupPolicySourceID = nil
        allocation.eligibleSince = nil
        allocation.isStandingCleanupDeclined = true
        recordAttempt(
          &allocation, event: "repository-policy-revoke",
          reasons: ["Repository cleanup policy revoked"])
        try saveAllocation(allocation)
      }
      try execute(
        "DELETE FROM repository_cleanup_policies WHERE repository_identity=?", [identity])
    }
  }

  func globalCleanupPolicy() throws -> GlobalCleanupPolicyStatus {
    guard try strings("PRAGMA user_version") == ["4"] else {
      return GlobalCleanupPolicyStatus(policy: nil, excludedRepositories: [])
    }
    let policy = try strings("SELECT data FROM global_cleanup_policy").first.map {
      try JSONDecoder().decode(RepositoryCleanupPolicy.self, from: Data($0.utf8))
    }
    return GlobalCleanupPolicyStatus(
      policy: policy,
      excludedRepositories: try strings("SELECT repository FROM cleanup_exclusions ORDER BY repository"))
  }

  func effectiveCleanupPolicy(_ identity: String, repository: String) throws
    -> RepositoryCleanupPolicy?
  {
    let global = try globalCleanupPolicy()
    if global.excludedRepositories.contains(repository) { return nil }
    return try repositoryCleanupPolicy(identity) ?? global.policy
  }

  func changeGlobalCleanupPolicy(
    _ policy: RepositoryCleanupPolicy?, excludedRepository: String? = nil,
    isExcluded: Bool = false
  ) throws {
    try transaction {
      try execute(
        "CREATE TABLE IF NOT EXISTS repository_cleanup_policies (repository_identity TEXT PRIMARY KEY, data TEXT NOT NULL)")
      try execute(
        "CREATE TABLE IF NOT EXISTS global_cleanup_policy (singleton INTEGER PRIMARY KEY CHECK(singleton=1), data TEXT NOT NULL)")
      try execute("CREATE TABLE IF NOT EXISTS cleanup_exclusions (repository TEXT PRIMARY KEY)")
      try execute("PRAGMA user_version=4")
      let previous = try globalCleanupPolicy()
      let derived = try allocations().filter {
        if let excludedRepository { return $0.repository == excludedRepository && $0.cleanupPolicySourceID != nil }
        return previous.policy != nil && $0.cleanupPolicySourceID == previous.policy?.id
      }
      try require(!derived.contains { $0.isRemovalPending }, "Derived removal is pending")
      if excludedRepository != nil || policy == nil {
        for var allocation in derived {
          allocation.cleanupPolicy = nil
          allocation.cleanupPolicySourceID = nil
          allocation.isStandingCleanupDeclined = true
          allocation.eligibleSince = nil
          recordAttempt(&allocation, event: "global-policy-revoke", reasons: ["Standing cleanup policy revoked"])
          try saveAllocation(allocation)
        }
      }
      if let excludedRepository {
        if isExcluded {
          try execute("INSERT OR IGNORE INTO cleanup_exclusions (repository) VALUES (?)", [excludedRepository])
        } else {
          try execute("DELETE FROM cleanup_exclusions WHERE repository=?", [excludedRepository])
        }
      } else {
        try execute("DELETE FROM global_cleanup_policy")
        if let policy {
          try execute(
            "INSERT INTO global_cleanup_policy (singleton, data) VALUES (1, ?)",
            [String(decoding: try JSONEncoder().encode(policy), as: UTF8.self)])
        }
      }
    }
  }

  func migrateGlobalCleanupPolicy() throws -> [Allocation] {
    try transaction {
      let global = try globalCleanupPolicy()
      try require(global.policy != nil, "Enable global cleanup policy before migration")
      var migrated: [Allocation] = []
      for var allocation in try allocations() {
        guard allocation.phase == .retained || allocation.phase == .blocked,
          !allocation.isRemovalPending, allocation.cleanupPolicy == nil,
          allocation.cleanupPolicySourceID == nil,
          allocation.isStandingCleanupDeclined != true,
          !(allocation.cleanupAttempts ?? []).contains(where: {
            ["policy-revoke", "repository-policy-revoke", "global-policy-revoke"].contains($0.event)
          }),
          let policy = try effectiveCleanupPolicy(
            allocation.repositoryIdentity, repository: allocation.repository)
        else { continue }
        try verifyIdentity(allocation)
        allocation.cleanupPolicy = policy.cleanupPolicy
        allocation.cleanupPolicySourceID = policy.id
        allocation.eligibleSince = nil
        recordAttempt(&allocation, event: "global-policy-migrate", reasons: ["Awaiting cleanup evaluation"])
        try saveAllocation(allocation)
        migrated.append(allocation)
      }
      return migrated
    }
  }

  private func saveAllocation(_ allocation: Allocation, isNew: Bool = false) throws {
    let data = String(decoding: try JSONEncoder().encode(allocation), as: UTF8.self)
    if !(allocation.conversationClaims ?? []).isEmpty,
      try strings("PRAGMA user_version") == ["1"]
    {
      try execute("PRAGMA user_version=2")
    }
    for token in Array(allocation.owners.keys) + Array(allocation.retiredOwners.keys) {
      try execute(
        "INSERT OR IGNORE INTO owner_tokens (token, allocation_id) VALUES (?, ?)",
        [token, allocation.id])
      try require(
        try strings("SELECT allocation_id FROM owner_tokens WHERE token=?", [token])
          == [allocation.id], "Owner token belongs to another allocation")
    }
    if isNew {
      try execute(
        "INSERT INTO allocations (id, path, data) VALUES (?, ?, ?)",
        [allocation.id, allocation.path, data])
    } else {
      try execute(
        "UPDATE allocations SET data=? WHERE id=? AND path=?",
        [data, allocation.id, allocation.path])
      try require(sqlite3_changes(database) == 1, "Allocation identity changed")
    }
  }

  private func transaction<T>(_ operation: () throws -> T) throws -> T {
    try execute("BEGIN IMMEDIATE")
    do {
      let result = try operation()
      try execute("COMMIT")
      return result
    } catch {
      try? execute("ROLLBACK")
      throw error
    }
  }

  private func statement(_ sql: String, _ values: [String]) throws -> OpaquePointer {
    var statement: OpaquePointer?
    try require(sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, failure())
    guard let statement else { throw WorkscopeError("No SQLite statement") }
    for (index, value) in values.enumerated() {
      let result = value.withCString {
        sqlite3_bind_text(
          statement, Int32(index + 1), $0, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
      }
      guard result == SQLITE_OK else {
        sqlite3_finalize(statement)
        throw WorkscopeError(failure())
      }
    }
    return statement
  }

  private func execute(_ sql: String, _ values: [String] = []) throws {
    let statement = try statement(sql, values)
    defer { sqlite3_finalize(statement) }
    var result = sqlite3_step(statement)
    while result == SQLITE_ROW { result = sqlite3_step(statement) }
    try require(result == SQLITE_DONE, failure())
  }

  private func strings(_ sql: String, _ values: [String] = []) throws -> [String] {
    let statement = try statement(sql, values)
    defer { sqlite3_finalize(statement) }
    var rows: [String] = []
    var result = sqlite3_step(statement)
    while result == SQLITE_ROW {
      guard let text = sqlite3_column_text(statement, 0) else {
        throw WorkscopeError("Unexpected NULL in registry")
      }
      rows.append(String(cString: text))
      result = sqlite3_step(statement)
    }
    try require(result == SQLITE_DONE, failure())
    return rows
  }

  private func failure() -> String {
    "Registry error: " + String(cString: sqlite3_errmsg(database))
  }
}

func withRegistry<T>(_ directory: String, _ operation: (RegistryStore) throws -> T) throws -> T {
  var ancestor = directory
  while try !isPresent(ancestor) { ancestor = (ancestor as NSString).deletingLastPathComponent }
  try require(
    (try? git(ancestor, ["rev-parse", "--absolute-git-dir"])) == nil,
    "State directory must be outside repositories")
  try FileManager.default.createDirectory(
    atPath: directory, withIntermediateDirectories: true,
    attributes: [.posixPermissions: 0o700])
  var info = stat()
  try require(
    lstat(directory, &info) == 0 && info.st_uid == getuid()
      && info.st_mode & S_IFMT == S_IFDIR && info.st_mode & 0o777 == 0o700,
    "State directory must be private (0700) and owned by this user")
  let lockPath = directory + "/registry.lock"
  let isNewLock = try !isPresent(lockPath)
  let descriptor = try privateFile(lockPath, isCreating: isNewLock)
  defer { close(descriptor) }
  try require(flock(descriptor, LOCK_EX) == 0, "Cannot lock registry")
  defer { _ = flock(descriptor, LOCK_UN) }
  return try operation(RegistryStore(directory: directory, isNewLock: isNewLock))
}
