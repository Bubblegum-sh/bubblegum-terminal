// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Flamingo",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Flamingo", targets: ["Flamingo"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0")
    ],
    targets: [
        .target(
            name: "FlamingoCore",
            path: "Sources/FlamingoCore"
        ),
        .executableTarget(
            name: "Flamingo",
            dependencies: [
                "FlamingoCore",
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/Flamingo"
        ),
        .testTarget(
            name: "FlamingoCoreTests",
            dependencies: ["FlamingoCore"],
            path: "Tests/FlamingoCoreTests"
        )
    ]
)
