// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PupilleCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "PupilleCore", targets: ["PupilleCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")
    ],
    targets: [
        .target(
            name: "PupilleCore",
            dependencies: [.product(name: "Crypto", package: "swift-crypto")]
        ),
        .testTarget(
            name: "PupilleCoreTests",
            dependencies: ["PupilleCore"],
            resources: [.copy("Fixtures")]
        )
    ]
)
