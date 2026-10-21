// swift-tools-version: 6.0
import PackageDescription

// What the phone, the Hub and Noodle Push must agree on byte for byte, in a package of its own so HubLink and
// Mobile share it with nothing but swift-crypto (CryptoKit on Apple platforms). A dependency on the Push package
// itself would pull the server's Hummingbird and APNSwift into every app's package resolution.
let package = Package(
    name: "PushWire",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [.library(name: "PushWire", targets: ["PushWire"])],
    dependencies: [
        // APNSwift still caps swift-crypto below 5; the wide range keeps PushWire usable next to HubLink.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0" ..< "6.0.0"),
    ],
    targets: [
        .target(name: "PushWire", dependencies: [.product(name: "Crypto", package: "swift-crypto")]),
    ]
)
