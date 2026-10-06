// swift-tools-version: 6.0
import PackageDescription

/// The KeyGrant licensing SDK for Swift: macOS apps (SwiftUI or AppKit), and Linux.
///
/// Swift 6 language mode, so strict concurrency checking is on for every file.
let package = Package(
    name: "KeyGrant",
    platforms: [.macOS(.v12)],
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
            dependencies: [.product(name: "Crypto", package: "swift-crypto")]
        ),
        .testTarget(
            name: "KeyGrantTests",
            dependencies: ["KeyGrant", .product(name: "Crypto", package: "swift-crypto")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
