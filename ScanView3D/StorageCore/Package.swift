// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StorageCore",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "StorageCore", targets: ["StorageCore"])],
    targets: [
        .target(name: "StorageCore"),
        .testTarget(name: "StorageCoreTests", dependencies: ["StorageCore"])
    ]
)
