import Darwin
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
  FileHandle.standardError.write(Data("Expected staging and installation directories.\n".utf8))
  exit(2)
}
let staging = arguments[1]
let prefix = arguments[2]
let commands = ["wf", "wf-herdr-open", "wf-herdr-close"]
var published: [String] = []
do {
  for name in commands {
    guard link(staging + "/bin/" + name, prefix + "/bin/" + name) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    published.append(name)
  }
  guard
    renamex_np(staging + "/share/workfree", prefix + "/share/workfree", UInt32(RENAME_EXCL)) == 0
  else {
    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
  }
} catch {
  for name in published.reversed() {
    let target = prefix + "/bin/" + name
    var sourceInfo = stat()
    var targetInfo = stat()
    if lstat(staging + "/bin/" + name, &sourceInfo) == 0,
      lstat(target, &targetInfo) == 0,
      sourceInfo.st_dev == targetInfo.st_dev,
      sourceInfo.st_ino == targetInfo.st_ino
    {
      _ = unlink(target)
    }
  }
  FileHandle.standardError.write(
    Data("Installation publication failed: \(error.localizedDescription)\n".utf8))
  exit(1)
}
