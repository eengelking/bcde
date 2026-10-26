// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "bcard",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "bcard",
            path: "Sources/bcard",
            swiftSettings: [.unsafeFlags(["-Ounchecked"], .when(configuration: .release))],
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
