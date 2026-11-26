// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "TerminalFlamingo",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TerminalFlamingo", targets: ["TerminalFlamingo"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0")
    ],
    targets: [
        .target(
            name: "TerminalFlamingoCore",
            path: "Sources/TerminalFlamingoCore"
        ),
        .executableTarget(
            name: "TerminalFlamingo",
            dependencies: [
                "TerminalFlamingoCore",
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/TerminalFlamingo"
        ),
        .testTarget(
            name: "TerminalFlamingoCoreTests",
            dependencies: ["TerminalFlamingoCore"],
            path: "Tests/TerminalFlamingoCoreTests"
        )
    ]
)
