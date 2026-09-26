// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Fusen",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "Fusen", targets: ["Fusen"]),
    ],
    targets: [
        // Everything except the entry point lives here so the tests can import it.
        .target(name: "FusenCore"),
        .executableTarget(name: "Fusen", dependencies: ["FusenCore"]),
        .testTarget(name: "FusenCoreTests", dependencies: ["FusenCore"]),
    ]
)
