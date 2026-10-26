// swift-tools-version: 6.0
import PackageDescription

// MurmurCore, MurmurLiveServer and murmur-live are platform neutral and build on macOS and Linux.
// The SwiftUI app (and its tests) only exist when the manifest is evaluated on macOS.
var products: [Product] = [
    .library(name: "MurmurCore", targets: ["MurmurCore"]),
    .executable(name: "murmur-live", targets: ["MurmurLive"])
]
var dependencies: [Package.Dependency] = []
var targets: [Target] = [
    .target(
        name: "MurmurCore",
        path: "Sources/MurmurCore"
    ),
    .testTarget(
        name: "MurmurCoreTests",
        dependencies: ["MurmurCore"],
        path: "Tests/MurmurCoreTests"
    ),
    // Live-call web UI over loopback (no SwiftUI): builds on macOS and Linux.
    .target(
        name: "MurmurLiveServer",
        dependencies: ["MurmurCore"],
        path: "Sources/MurmurLiveServer",
        resources: [.copy("Resources/page.html")]
    ),
    .executableTarget(
        name: "MurmurLive",
        dependencies: ["MurmurCore", "MurmurLiveServer"],
        path: "Sources/MurmurLive"
    ),
    .testTarget(
        name: "MurmurLiveServerTests",
        dependencies: ["MurmurLiveServer", "MurmurCore"],
        path: "Tests/MurmurLiveServerTests"
    )
]

#if os(macOS)
products.append(.executable(name: "Murmur", targets: ["MurmurApp"]))
dependencies.append(.package(url: "https://github.com/gonzalezreal/textual.git", exact: "0.5.0"))
targets.append(contentsOf: [
    .executableTarget(
        name: "MurmurApp",
        dependencies: [
            "MurmurCore",
            .product(name: "Textual", package: "textual")
        ],
        path: "Sources/MurmurApp"
    ),
    .testTarget(
        name: "MurmurTests",
        dependencies: ["MurmurApp", "MurmurCore"],
        path: "Tests/MurmurTests"
    )
])
#endif

let package = Package(
    name: "Murmur",
    platforms: [.macOS(.v15)],
    products: products,
    dependencies: dependencies,
    targets: targets
)
