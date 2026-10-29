import Darwin
import Foundation
import Workscope

let productName = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
let version = "0.1.0"
let help = """
  Workfree \(version)
  Usage: \(productName) [--state-dir PATH] [--json] COMMAND
    start BRANCH --repo PATH [--allow-cleanup] [--base REF] [--path PATH]
      [--require-cow] [--provider git|simgit] [--require-cleanup-policy]
    claim [ID]
    inspect ID
    list
    status [--since 30d|24h|2w|all]
    measure PATH...
    retain ID --owner TOKEN --kind task|workspace|execution|pin [--label TEXT]
    release ID --owner TOKEN
    finish ID [--owner TOKEN]
    keep ID
    unkeep ID
    close-scope ID --owner TOKEN
    entry-exit ID --owner TOKEN --status INTEGER
    recover ID
    cleanup-policy show|enable|revoke --repo PATH [--grace-seconds 60]
    cleanup-policy show|enable|revoke --global [--grace-seconds 60]
    cleanup-policy exclude|include --repo PATH
    cleanup-policy migrate --global
    authorize-cleanup ID [--grace-seconds 60] [--disposable-path PATH]...
    revoke-cleanup ID
    preview
    sweep
    restore ID
    run ID [--owner TOKEN] -- COMMAND...
    --help
    --version

  Conversation options: --session-id ID --session-pid PID
    [--session-cwd PATH] [--session-allocations JSON_ARRAY]
  Use the Pi host PID, never the short-lived wf subprocess PID.
  claim binds explicit allocations and managed cwd before use; shutdown does not release claims.

  Uses simgit CoW if available, otherwise native Git. --require-cow refuses native Git.
  Selected-provider failures never switch providers.
  Cleanup uses recorded global or repository authority; otherwise it is disabled.
  Execution ownership persists after entry exit.
  close-scope is an explicit cooperative assertion that every scope user has left.
  run inherits standard streams and returns the child exit status, including with --json.
  """

struct Arguments {
  var positional: [String] = []
  var options: [String: String] = [:]
  var disposablePaths: [String] = []
  var isGlobal = false
  var isCowRequired = false
  var isCleanupAuthorized = false
  var isCleanupPolicyRequired = false
  var isJSON = false
  var isHelp = false
  var isVersion = false
  var command: [String] = []

  init(_ arguments: [String]) throws {
    var index = 0
    var flags: Set<String> = []
    while index < arguments.count {
      let argument = arguments[index]
      if argument == "--" {
        command = Array(arguments.dropFirst(index + 1))
        flags.insert("--")
        break
      }
      if argument.hasPrefix("--") {
        guard flags.insert(argument).inserted || argument == "--disposable-path" else {
          throw WorkscopeError("Duplicate option: \(argument)")
        }
        switch argument {
        case "--global": isGlobal = true
        case "--allow-cleanup": isCleanupAuthorized = true
        case "--require-cleanup-policy": isCleanupPolicyRequired = true
        case "--require-cow": isCowRequired = true
        case "--json": isJSON = true
        case "--help": isHelp = true
        case "--version": isVersion = true
        case "--state-dir", "--repo", "--base", "--path", "--owner", "--kind", "--label",
          "--status", "--provider", "--since", "--grace-seconds", "--disposable-path",
          "--session-id", "--session-pid", "--session-cwd", "--session-allocations":
          index += 1
          guard index < arguments.count,
            argument == "--label"
              || (!arguments[index].isEmpty && !arguments[index].hasPrefix("--")),
            !arguments[index].utf8.contains(0)
          else { throw WorkscopeError("Missing value: \(argument)") }
          options[argument] = arguments[index]
          if argument == "--disposable-path" { disposablePaths.append(arguments[index]) }
        default: throw WorkscopeError("Unknown option: \(argument)")
        }
      } else {
        positional.append(argument)
      }
      index += 1
    }
    if isHelp || isVersion { return }
    guard let action = positional.first else { throw WorkscopeError("Missing command; use --help") }
    var allowed: Set<String>
    switch action {
    case "start":
      allowed = [
        "--repo", "--allow-cleanup", "--base", "--path", "--require-cow", "--provider",
        "--require-cleanup-policy",
      ]
    case "cleanup-policy":
      guard positional.count == 2,
        ["show", "enable", "revoke", "exclude", "include", "migrate"].contains(positional[1])
      else { throw WorkscopeError("Invalid cleanup-policy action") }
      let policyAction = positional[1]
      if policyAction == "migrate" {
        guard isGlobal else { throw WorkscopeError("Migration requires --global") }
        allowed = ["--global"]
      } else if ["exclude", "include"].contains(policyAction) {
        allowed = ["--repo"]
      } else {
        guard isGlobal != (options["--repo"] != nil) else {
          throw WorkscopeError("Choose exactly one of --global or --repo PATH")
        }
        allowed = isGlobal ? ["--global"] : ["--repo"]
        if policyAction == "enable" { allowed.insert("--grace-seconds") }
      }
    case "retain": allowed = ["--owner", "--kind", "--label"]
    case "release", "finish", "close-scope": allowed = ["--owner"]
    case "entry-exit": allowed = ["--owner", "--status"]
    case "run": allowed = ["--owner", "--"]
    case "inspect", "list", "keep", "unkeep", "recover", "revoke-cleanup", "restore", "preview",
      "sweep":
      allowed = []
    case "authorize-cleanup": allowed = ["--grace-seconds", "--disposable-path"]
    case "status": allowed = ["--since"]
    case "measure", "claim": allowed = []
    default: throw WorkscopeError("Unknown command: \(action)")
    }
    guard
      flags.subtracting(
        allowed.union([
          "--json", "--state-dir", "--session-id", "--session-pid", "--session-cwd",
          "--session-allocations",
        ])
      ).isEmpty
    else {
      throw WorkscopeError("Option not valid for \(action)")
    }
    let isCountValid =
      action == "claim"
      ? (1...2).contains(positional.count)
      : action == "measure"
        ? positional.count >= 2
        : positional.count == (["list", "status", "preview", "sweep"].contains(action) ? 1 : 2)
    guard isCountValid else {
      throw WorkscopeError("Wrong number of arguments for \(action)")
    }
    if action == "run", !flags.contains("--") || command.isEmpty {
      throw WorkscopeError("run requires -- COMMAND...")
    }
  }

  func value(_ name: String) throws -> String {
    guard let value = options[name] else { throw WorkscopeError("Missing option: \(name)") }
    return value
  }
}

func output<T: Encodable>(_ value: T, isJSON: Bool) throws {
  let encoder = JSONEncoder()
  encoder.outputFormatting = isJSON ? [.sortedKeys] : [.sortedKeys, .prettyPrinted]
  print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

struct CleanupPlan: Encodable {
  let allocations: [CleanupPreview]
  let candidateCount: Int
  let estimatedBytes: Int64

  init(_ allocations: [CleanupPreview]) {
    self.allocations = allocations
    candidateCount = allocations.filter(\.isEligible).count
    estimatedBytes = allocations.filter(\.isEligible).map(\.estimatedBytes).reduce(0, +)
  }
}

let rawArguments = Array(CommandLine.arguments.dropFirst())
do {
  let arguments = try Arguments(rawArguments)
  if arguments.isHelp {
    print(help)
  } else if arguments.isVersion {
    print("\(productName) \(version)")
  } else {
    let action = arguments.positional[0]
    let conversation: ConversationContext?
    if let sessionID = arguments.options["--session-id"] {
      guard let pid = Int32(try arguments.value("--session-pid")), pid > 0 else {
        throw WorkscopeError("Invalid conversation host PID")
      }
      var ids =
        try arguments.options["--session-allocations"].map {
          try JSONDecoder().decode([String].self, from: Data($0.utf8))
        } ?? []
      if arguments.positional.count == 2
        && !["start", "restore", "measure", "cleanup-policy"].contains(action)
      {
        ids.append(arguments.positional[1])
      }
      conversation = try ConversationContext(
        sessionID: sessionID, processID: pid, allocationIDs: ids,
        cwd: arguments.options["--session-cwd"])
    } else {
      guard !arguments.options.keys.contains(where: { $0.hasPrefix("--session-") }) else {
        throw WorkscopeError("Conversation options require --session-id")
      }
      conversation = nil
    }
    let registry = try Registry(
      stateDirectory: arguments.options["--state-dir"], conversation: conversation)
    if action == "cleanup-policy", arguments.isGlobal {
      switch arguments.positional[1] {
      case "enable":
        guard let grace = TimeInterval(arguments.options["--grace-seconds"] ?? "60") else {
          throw WorkscopeError("Invalid grace period")
        }
        try output(registry.enableGlobalCleanupPolicy(graceSeconds: grace), isJSON: arguments.isJSON)
      case "revoke":
        try output(registry.revokeGlobalCleanupPolicy(), isJSON: arguments.isJSON)
      case "migrate":
        try output(registry.migrateGlobalCleanupPolicy(), isJSON: arguments.isJSON)
      default: try output(registry.globalCleanupPolicy(), isJSON: arguments.isJSON)
      }
    } else if action == "cleanup-policy",
      ["exclude", "include"].contains(arguments.positional[1])
    {
      try output(
        registry.excludeRepositoryFromCleanup(
          repository: arguments.value("--repo"),
          isExcluded: arguments.positional[1] == "exclude"),
        isJSON: arguments.isJSON)
    } else if action == "cleanup-policy" {
      let policyRepository = try arguments.value("--repo")
      let policyStatus: RepositoryCleanupPolicyStatus
      switch arguments.positional[1] {
      case "enable":
        guard let grace = TimeInterval(arguments.options["--grace-seconds"] ?? "60") else {
          throw WorkscopeError("Invalid grace period")
        }
        policyStatus = try registry.enableRepositoryCleanupPolicy(
          repository: policyRepository, graceSeconds: grace)
      case "revoke":
        policyStatus = try registry.revokeRepositoryCleanupPolicy(repository: policyRepository)
      default: policyStatus = try registry.repositoryCleanupPolicy(repository: policyRepository)
      }
      try output(policyStatus, isJSON: arguments.isJSON)
    } else if action == "claim" {
      try output(registry.claim(arguments.positional.dropFirst().first), isJSON: arguments.isJSON)
    } else if action == "preview" {
      try output(CleanupPlan(registry.preview()), isJSON: arguments.isJSON)
    } else if action == "sweep" {
      try output(registry.sweep(), isJSON: arguments.isJSON)
    } else if action == "list" {
      try output(registry.list(), isJSON: arguments.isJSON)
    } else if action == "measure" {
      try output(measurePaths(Array(arguments.positional.dropFirst())), isJSON: arguments.isJSON)
    } else if action == "status" {
      let status = try registry.status(since: parseInterval(arguments.options["--since"] ?? "30d"))
      if arguments.isJSON {
        try output(status, isJSON: true)
      } else {
        print(status.text)
      }
    } else {
      let id = arguments.positional[1]
      let isRemovedBefore =
        (try? Registry(stateDirectory: registry.stateDirectory).inspect(id))?.phase == .removed
      let allocation: Allocation
      switch action {
      case "start":
        let provider: WorktreeProvider?
        if let value = arguments.options["--provider"] {
          guard let selected = WorktreeProvider(rawValue: value) else {
            throw WorkscopeError("Invalid provider")
          }
          provider = selected
        } else {
          provider = nil
        }
        allocation = try registry.start(
          branch: id, repository: arguments.value("--repo"),
          isCleanupAuthorized: arguments.isCleanupAuthorized,
          base: arguments.options["--base"], path: arguments.options["--path"], provider: provider,
          isCowRequired: arguments.isCowRequired,
          isCleanupPolicyRequired: arguments.isCleanupPolicyRequired)
      case "inspect": allocation = try registry.inspect(id)
      case "retain":
        guard let kind = OwnerKind(rawValue: try arguments.value("--kind")) else {
          throw WorkscopeError("Invalid owner kind")
        }
        allocation = try registry.retain(
          id, owner: arguments.value("--owner"), kind: kind, label: arguments.options["--label"])
      case "release": allocation = try registry.release(id, owner: arguments.value("--owner"))
      case "finish": allocation = try registry.finish(id, owner: arguments.options["--owner"])
      case "keep": allocation = try registry.keep(id)
      case "unkeep": allocation = try registry.unkeep(id)
      case "close-scope":
        allocation = try registry.closeScope(id, owner: arguments.value("--owner"))
      case "entry-exit":
        guard let status = Int32(try arguments.value("--status")) else {
          throw WorkscopeError("Invalid 32-bit integer status")
        }
        allocation = try registry.entryExit(id, owner: arguments.value("--owner"), status: status)
      case "recover": allocation = try registry.recover(id)
      case "authorize-cleanup":
        guard let grace = TimeInterval(arguments.options["--grace-seconds"] ?? "60") else {
          throw WorkscopeError("Invalid grace period")
        }
        allocation = try registry.authorizeCleanup(
          id, graceSeconds: grace,
          disposablePaths: arguments.disposablePaths)
      case "revoke-cleanup": allocation = try registry.revokeCleanup(id)
      case "restore": allocation = try registry.restore(id)
      case "run":
        exit(try registry.run(id, owner: arguments.options["--owner"], command: arguments.command))
      default: throw WorkscopeError("Unknown command")
      }
      try output(allocation, isJSON: arguments.isJSON)
      if !arguments.isJSON, !isRemovedBefore, allocation.phase == .removed,
        let history = try? registry.status(since: 30 * 86_400, isLiveMeasured: false)
      {
        FileHandle.standardError.write(
          Data(
            "Reclaimed \(formatBytes(allocation.reclaimedBytes ?? 0)). \(history.cleanupLine)\n"
              .utf8))
      }
    }
  }
} catch {
  let isJSON = rawArguments.prefix(while: { $0 != "--" }).contains("--json")
  if isJSON, let data = try? JSONEncoder().encode(["error": String(describing: error)]) {
    FileHandle.standardError.write(data + Data("\n".utf8))
  } else {
    FileHandle.standardError.write(Data("\(productName): \(error)\n".utf8))
  }
  exit(1)
}
