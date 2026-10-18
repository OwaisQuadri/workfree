import Darwin
import Foundation
import Workscope

let productName = URL(fileURLWithPath: CommandLine.arguments[0]).lastPathComponent
let version = "0.1.0"
let help = """
  Workfree \(version)
  Usage: \(productName) [--state-dir PATH] [--json] COMMAND
    start BRANCH --repo PATH [--allow-cleanup] [--base REF] [--path PATH]
      [--require-cow] [--provider git|simgit]
    inspect ID
    list
    retain ID --owner TOKEN --kind task|workspace|execution|pin [--label TEXT]
    release ID --owner TOKEN
    finish ID [--owner TOKEN]
    keep ID
    unkeep ID
    close-scope ID --owner TOKEN
    entry-exit ID --owner TOKEN --status INTEGER
    recover ID
    run ID [--owner TOKEN] -- COMMAND...
    --help
    --version

  Uses simgit CoW if available, otherwise native Git. --require-cow refuses native Git.
  Selected-provider failures never switch providers.
  Cleanup permission defaults to false. Execution ownership persists after entry exit.
  close-scope is an explicit cooperative assertion that every scope user has left.
  run inherits standard streams and returns the child exit status, including with --json.
  """

struct Arguments {
  var positional: [String] = []
  var options: [String: String] = [:]
  var isCowRequired = false
  var isCleanupAuthorized = false
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
        guard flags.insert(argument).inserted else {
          throw WorkscopeError("Duplicate option: \(argument)")
        }
        switch argument {
        case "--allow-cleanup": isCleanupAuthorized = true
        case "--require-cow": isCowRequired = true
        case "--json": isJSON = true
        case "--help": isHelp = true
        case "--version": isVersion = true
        case "--state-dir", "--repo", "--base", "--path", "--owner", "--kind", "--label",
          "--status", "--provider":
          index += 1
          guard index < arguments.count, !arguments[index].isEmpty,
            !arguments[index].hasPrefix("--"), !arguments[index].utf8.contains(0)
          else { throw WorkscopeError("Missing value: \(argument)") }
          options[argument] = arguments[index]
        default: throw WorkscopeError("Unknown option: \(argument)")
        }
      } else {
        positional.append(argument)
      }
      index += 1
    }
    if isHelp || isVersion { return }
    guard let action = positional.first else { throw WorkscopeError("Missing command; use --help") }
    let allowed: Set<String>
    switch action {
    case "start":
      allowed = ["--repo", "--allow-cleanup", "--base", "--path", "--require-cow", "--provider"]
    case "retain": allowed = ["--owner", "--kind", "--label"]
    case "release", "finish", "close-scope": allowed = ["--owner"]
    case "entry-exit": allowed = ["--owner", "--status"]
    case "run": allowed = ["--owner", "--"]
    case "inspect", "list", "keep", "unkeep", "recover": allowed = []
    default: throw WorkscopeError("Unknown command: \(action)")
    }
    guard flags.subtracting(allowed.union(["--json", "--state-dir"])).isEmpty else {
      throw WorkscopeError("Option not valid for \(action)")
    }
    guard positional.count == (action == "list" ? 1 : 2) else {
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

let rawArguments = Array(CommandLine.arguments.dropFirst())
do {
  let arguments = try Arguments(rawArguments)
  if arguments.isHelp {
    print(help)
  } else if arguments.isVersion {
    print("\(productName) \(version)")
  } else {
    let registry = try Registry(stateDirectory: arguments.options["--state-dir"])
    let action = arguments.positional[0]
    if action == "list" {
      try output(registry.list(), isJSON: arguments.isJSON)
    } else {
      let id = arguments.positional[1]
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
          isCowRequired: arguments.isCowRequired)
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
      case "run":
        exit(try registry.run(id, owner: arguments.options["--owner"], command: arguments.command))
      default: throw WorkscopeError("Unknown command")
      }
      try output(allocation, isJSON: arguments.isJSON)
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
