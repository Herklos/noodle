// swift-tools-version: 6.0
import PackageDescription

// Noodle Push rings a phone through PushKit when a bot calls and the app is closed or away from its Hub.
// The server runs on Linux in a Cloudflare container behind the Worker in `worker/`; see `Dockerfile`.
//
// PushWire, in `Wire/`, holds what the phone, the Hub and the server must agree on byte for byte. It is a
// package of its own, depending only on swift-crypto, so HubLink and Mobile share it without resolving the
// server's dependencies. PushCore is the server's logic without HTTP, so it is tested on macOS; NoodlePush
// only puts it behind Hummingbird.
let package = Package(
    name: "Push",
    platforms: [.macOS("26.0"), .iOS("26.0")],
    products: [
        .executable(name: "NoodlePush", targets: ["NoodlePush"]),
    ],
    dependencies: [
        .package(path: "Wire"),
        // APNSwift still caps swift-crypto below 5; the wide range keeps PushWire usable next to HubLink.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0" ..< "6.0.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.4.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.16.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.80.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.28.0"),
        .package(url: "https://github.com/swift-server-community/APNSwift.git", from: "7.1.0"),
    ],
    targets: [
        .target(name: "PushCore", dependencies: [
            .product(name: "PushWire", package: "Wire"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "Logging", package: "swift-log"),
            .product(name: "APNS", package: "APNSwift"),
            .product(name: "APNSCore", package: "APNSwift"),
            .product(name: "NIOPosix", package: "swift-nio"),
        ]),
        .executableTarget(name: "NoodlePush", dependencies: [
            "PushCore",
            .product(name: "Hummingbird", package: "hummingbird"),
            .product(name: "HTTPTypes", package: "swift-http-types"),
            .product(name: "Logging", package: "swift-log"),
        ]),
        .testTarget(name: "PushWireTests", dependencies: [
            .product(name: "PushWire", package: "Wire"), .product(name: "Crypto", package: "swift-crypto"),
        ]),
        .testTarget(name: "PushCoreTests", dependencies: [
            "PushCore", .product(name: "PushWire", package: "Wire"),
            .product(name: "APNSCore", package: "APNSwift"),
            .product(name: "Crypto", package: "swift-crypto"),
            .product(name: "Logging", package: "swift-log"),
        ]),
    ]
)
