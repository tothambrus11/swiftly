// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "Hello",
  targets: [
    .target(name: "HelloLib", path: "Sources/HelloLib"),
    .executableTarget(name: "Hello", dependencies: ["HelloLib"], path: "Sources/Hello"),
    .executableTarget(name: "FoundationDemo", path: "Sources/FoundationDemo"),
    .target(name: "CHello", path: "Sources/CHello"),
    .executableTarget(name: "CDemo", dependencies: ["CHello"], path: "Sources/CDemo"),
    .testTarget(name: "HelloTests", dependencies: ["HelloLib"], path: "Tests/HelloTests"),
  ]
)
