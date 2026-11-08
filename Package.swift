// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CCS",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ccs", targets: ["CCSCLI"]),
        .executable(name: "CCSApp", targets: ["CCSApp"]),
    ],
    targets: [
        .target(name: "CCSCore"),
        .target(name: "CTerminal", cSettings: [.define("NCURSES_WIDECHAR", to: "1")], linkerSettings: [.linkedLibrary("ncurses")]),
        .executableTarget(name: "CCSCLI", dependencies: ["CCSCore", "CTerminal"]),
        .executableTarget(name: "CCSApp", dependencies: ["CCSCore"],
                          linkerSettings: [.linkedFramework("Carbon")]),
        .testTarget(name: "CCSCoreTests", dependencies: ["CCSCore"]),
        .testTarget(name: "CCSAppTests", dependencies: ["CCSApp"]),
    ]
)
