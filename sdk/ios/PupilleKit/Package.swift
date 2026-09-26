// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PupilleKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PupilleKit", targets: ["PupilleKit"])
    ],
    dependencies: [
        .package(url: "https://github.com/worldcoin/idkit-swift", exact: "4.0.11")
    ],
    targets: [
        .target(
            name: "PupilleKit",
            dependencies: [.product(name: "IDKit", package: "idkit-swift")]
        )
    ]
)
