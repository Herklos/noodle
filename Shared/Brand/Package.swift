// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Brand",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [
        .library(name: "NoodleBrand", targets: ["NoodleBrand"])
    ],
    targets: [
        .target(name: "NoodleBrand", resources: [.copy("Faces")]),
        .testTarget(name: "NoodleBrandTests", dependencies: ["NoodleBrand"])
    ]
)
