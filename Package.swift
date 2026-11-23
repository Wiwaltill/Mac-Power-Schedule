// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "MacPowerSchedule", platforms: [.macOS(.v13)], products: [
    .executable(name: "PowerSchedule", targets: ["PowerSchedule"]),
    .executable(name: "PowerScheduler", targets: ["PowerScheduler"])
], dependencies: [
    .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
], targets: [
    .target(name: "PowerCore"),
    .executableTarget(name: "PowerSchedule", dependencies: ["PowerCore", .product(name: "Sparkle", package: "Sparkle")], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
    .executableTarget(name: "PowerScheduler", dependencies: ["PowerCore"]),
    .testTarget(name: "PowerCoreTests", dependencies: ["PowerCore"])
])
