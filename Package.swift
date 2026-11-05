// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LiftLogCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "LiftLogCore", targets: ["LiftLogCore"])],
    dependencies: [.package(url: "https://github.com/swiftlang/swift-markdown.git", .upToNextMinor(from: "0.8.0"))],
    targets: [
        .target(name: "LiftLogCore", dependencies: [.product(name: "Markdown", package: "swift-markdown")], path: "LiftLog",
                exclude: ["App", "Views", "Assets.xcassets", "Info.plist", "LiftLog.entitlements", "Shared/WorkoutActivityAttributes.swift"],
                resources: [.process("Core/Resources")],
                linkerSettings: [.linkedLibrary("sqlite3")]),
        .testTarget(name: "LiftLogCoreTests", dependencies: ["LiftLogCore"], path: "Tests/LiftLogCoreTests", resources: [.copy("Fixtures")])
    ]
)
