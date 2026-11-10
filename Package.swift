// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "SinDisk",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SinDisk", targets: ["SinDisk"]),
        .library(name: "SinDiskCore", targets: ["SinDiskCore"]),
    ],
    targets: [
        .target(name: "SinDiskCore"),
        .executableTarget(name: "SinDisk", dependencies: ["SinDiskCore"]),
        .testTarget(name: "SinDiskCoreTests", dependencies: ["SinDiskCore"]),
    ]
)
