// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Murmur",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Murmur", targets: ["MurmurApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/gonzalezreal/textual.git", exact: "0.5.0")
    ],
    targets: [
        .executableTarget(
            name: "MurmurApp",
            dependencies: [.product(name: "Textual", package: "textual")],
            path: "Sources/MurmurApp"
        ),
        .testTarget(
            name: "MurmurTests",
            dependencies: ["MurmurApp"],
            path: "Tests/MurmurTests"
        )
    ]
)
