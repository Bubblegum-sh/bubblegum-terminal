// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Bubblegum",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Bubblegum", targets: ["Bubblegum"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0")
    ],
    targets: [
        .target(
            name: "BubblegumCore",
            path: "Sources/BubblegumCore"
        ),
        .executableTarget(
            name: "Bubblegum",
            dependencies: [
                "BubblegumCore",
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/Bubblegum"
        ),
        .testTarget(
            name: "BubblegumCoreTests",
            dependencies: ["BubblegumCore"],
            path: "Tests/BubblegumCoreTests"
        )
    ]
)
