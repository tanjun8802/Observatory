// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Observatory",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Observatory", targets: ["Observatory"])],
    targets: [
        .executableTarget(name: "Observatory", resources: [.copy("Skills")]),
        .testTarget(name: "ObservatoryTests", dependencies: ["Observatory"])
    ]
)
