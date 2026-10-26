// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "bcde",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "bcde",
            path: "Sources/bcde",
            swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))],
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
