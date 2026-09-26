// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PupilleCore",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "PupilleCore", targets: ["PupilleCore"]),
        .executable(name: "pupille-sign-cli", targets: ["pupille-sign-cli"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0")
    ],
    targets: [
        .target(
            name: "PupilleCore",
            dependencies: [.product(name: "Crypto", package: "swift-crypto")]
        ),
        .executableTarget(
            name: "pupille-sign-cli",
            dependencies: ["PupilleCore"]
        ),
        .testTarget(
            name: "PupilleCoreTests",
            dependencies: ["PupilleCore"],
            resources: [.copy("Fixtures")]
        )
    ]
)
