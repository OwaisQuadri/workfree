// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "workfree",
  platforms: [.macOS(.v13)],
  products: [
    .library(name: "Workscope", targets: ["Workscope"]),
    .executable(name: "wf", targets: ["WorkscopeCLI"]),
  ],
  targets: [
    .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
    .target(name: "Workscope", dependencies: ["CSQLite"]),
    .executableTarget(name: "WorkscopeCLI", dependencies: ["Workscope"]),
    .testTarget(name: "WorkscopeTests", dependencies: ["Workscope", "CSQLite"]),
  ]
)
