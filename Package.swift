// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "MacPowerSchedule", platforms: [.macOS(.v13)], products: [
    .executable(name: "PowerSchedule", targets: ["PowerSchedule"]),
    .executable(name: "PowerScheduler", targets: ["PowerScheduler"])
], targets: [
    .target(name: "PowerCore"),
    .executableTarget(name: "PowerSchedule", dependencies: ["PowerCore"]),
    .executableTarget(name: "PowerScheduler", dependencies: ["PowerCore"]),
    .testTarget(name: "PowerCoreTests", dependencies: ["PowerCore"])
])
