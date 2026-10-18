import Darwin
import Foundation

func canonical(_ path: String) throws -> String {
  try require(!path.isEmpty && !path.utf8.contains(0), "Invalid path")
  var candidate = path.hasPrefix("/") ? path : FileManager.default.currentDirectoryPath + "/" + path
  var suffix: [String] = []
  while true {
    if let resolved = realpath(candidate, nil) {
      defer { free(resolved) }
      return suffix.reversed().reduce(String(cString: resolved)) { parent, component in
        if component == "." { return parent }
        if component == ".." { return (parent as NSString).deletingLastPathComponent }
        return (parent as NSString).appendingPathComponent(component)
      }
    }
    try require(errno == ENOENT, "Cannot resolve path: \(candidate)")
    try require(candidate != "/", "Cannot resolve root")
    suffix.append((candidate as NSString).lastPathComponent)
    candidate = (candidate as NSString).deletingLastPathComponent
  }
}

func isSamePath(_ first: String, _ second: String) -> Bool {
  first.compare(second, options: .caseInsensitive) == .orderedSame
}

func isWithin(_ path: String, _ parent: String) -> Bool {
  isSamePath(path, parent)
    || path.range(of: parent == "/" ? "/" : parent + "/", options: [.anchored, .caseInsensitive])
      != nil
}

func isPresent(_ path: String) throws -> Bool {
  var info = stat()
  if lstat(path, &info) == 0 { return true }
  try require(errno == ENOENT, "Cannot inspect path: \(path)")
  return false
}

func privateFile(_ path: String, isCreating: Bool) throws -> Int32 {
  let descriptor = open(
    path, O_RDWR | O_CLOEXEC | O_NOFOLLOW | (isCreating ? O_CREAT | O_EXCL : 0),
    S_IRUSR | S_IWUSR)
  try require(descriptor >= 0, "Cannot open private file: \(path)")
  var info = stat()
  guard fstat(descriptor, &info) == 0, info.st_uid == getuid(),
    info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o777 == 0o600, info.st_nlink == 1
  else {
    close(descriptor)
    throw WorkscopeError("Unsafe private file: \(path)")
  }
  return descriptor
}

func syncDirectory(_ path: String) throws {
  let descriptor = open(path, O_RDONLY | O_CLOEXEC)
  try require(descriptor >= 0, "Cannot open directory for sync")
  defer { close(descriptor) }
  try require(fsync(descriptor) == 0, "Cannot sync directory")
}

func isExecutableAvailable(_ name: String) -> Bool {
  let search = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"
  return search.split(separator: ":", omittingEmptySubsequences: false).contains { directory in
    let path =
      (directory.isEmpty ? FileManager.default.currentDirectoryPath : String(directory)) + "/"
      + name
    var info = stat()
    return stat(path, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
      && access(path, X_OK) == 0
  }
}

func git(_ path: String, _ args: [String]) throws -> String {
  try command("/usr/bin/git", ["-C", path] + args).trimmingCharacters(in: .newlines)
}

func command(_ executable: String, _ args: [String], at directory: String? = nil) throws
  -> String
{
  let process = Process()
  process.executableURL = URL(fileURLWithPath: executable)
  process.arguments = args
  if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
  var environment = ProcessInfo.processInfo.environment
  for key in environment.keys where key.hasPrefix("GIT_") { environment.removeValue(forKey: key) }
  environment["GIT_TERMINAL_PROMPT"] = "0"
  process.environment = environment
  let output = try temporaryHandle()
  let errors = try temporaryHandle()
  defer {
    try? output.close()
    try? errors.close()
  }
  process.standardOutput = output
  process.standardError = errors
  process.standardInput = FileHandle.nullDevice
  try process.run()
  process.waitUntilExit()
  try output.seek(toOffset: 0)
  try errors.seek(toOffset: 0)
  let data = try output.read(upToCount: 4_194_305) ?? Data()
  let errorData = try errors.read(upToCount: 16_384) ?? Data()
  try require(
    process.terminationReason == .exit && process.terminationStatus == 0,
    "Command failed: \(executable) \(args.joined(separator: " "))\n"
      + String(decoding: errorData, as: UTF8.self))
  try require(data.count <= 4_194_304, "Command output exceeds safety limit")
  guard let text = String(data: data, encoding: .utf8) else {
    throw WorkscopeError("Command output is not UTF-8")
  }
  return text
}

private func temporaryHandle() throws -> FileHandle {
  var template = Array((NSTemporaryDirectory() + "/workfree-output.XXXXXX").utf8CString)
  let descriptor = mkstemp(&template)
  try require(descriptor >= 0, "Cannot create command output file")
  _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
  template.withUnsafeBufferPointer { pointer in _ = unlink(pointer.baseAddress!) }
  return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
}

func registeredPaths(_ repository: String) throws -> [String] {
  try git(repository, ["worktree", "list", "--porcelain", "-z"])
    .split(separator: "\0").filter { $0.hasPrefix("worktree ") }
    .map { try canonical(String($0.dropFirst(9))) }
}

func isRegistered(_ repository: String, _ path: String) throws -> Bool {
  let target = try canonical(path)
  return try registeredPaths(repository).contains { isSamePath($0, target) }
}

struct Doctor: Decodable {
  let identity: String
  let product: String
  let repository: String
  let isCowSupported: Bool
  let isGitWorktreeSupported: Bool
  let repositoryDetails: Details

  enum CodingKeys: String, CodingKey {
    case identity, product, repository
    case repositoryDetails = "repository_details"
    case isCowSupported = "cow_supported"
    case isGitWorktreeSupported = "git_worktree_supported"
  }

  struct Details: Decodable {
    let commonGitDirectory: String
    let commonGitOwner: String

    enum CodingKeys: String, CodingKey {
      case commonGitDirectory = "common_git_dir"
      case commonGitOwner = "common_git_owner"
    }
  }
}

struct Creation: Decodable {
  let path: String
  let cleanupToken: String
  let mode: String

  enum CodingKeys: String, CodingKey {
    case path, mode
    case cleanupToken = "cleanup_token"
  }
}
