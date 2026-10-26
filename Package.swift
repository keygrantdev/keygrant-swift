// swift-tools-version: 6.0
import PackageDescription

/// The KeyGrant licensing SDK for Swift: macOS apps (SwiftUI or AppKit), iPhone and iPad apps
/// (SwiftUI or UIKit), Mac Catalyst apps (a Mac to the SDK), and Linux.
///
/// Swift 6 language mode, so strict concurrency checking is on for every file.
let package = Package(
    name: "KeyGrant",
    platforms: [.macOS(.v12), .iOS(.v15), .macCatalyst(.v15)],
    products: [
        .library(name: "KeyGrant", targets: ["KeyGrant"]),
    ],
    dependencies: [
        // Ed25519 and SHA-256: CryptoKit itself on Apple platforms, its BoringSSL build on Linux.
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0" ..< "5.0.0"),
    ],
    targets: [
        .target(
            name: "KeyGrant",
            dependencies: [.product(name: "Crypto", package: "swift-crypto")],
            // What the App Store asks of an SDK: no tracking; the device id, an address and product
            // interaction sent for the app's licensing; and why it reads file dates (its own state
            // files' age) and the time since boot (its time bounds).
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .testTarget(
            name: "KeyGrantTests",
            dependencies: ["KeyGrant", .product(name: "Crypto", package: "swift-crypto")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
