// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "StealthCore",
    platforms: [
        .iOS(.v15),
        .macOS(.v12)
    ],
    products: [
        .library(
            name: "StealthCore",
            targets: ["StealthCore"]
        ),
    ],
    dependencies: [
        // Ed25519 point arithmetic - Algorand fork with full libsodium build
        // Exposes crypto_core_ed25519_add, crypto_scalarmult_ed25519_base_noclamp, etc.
        .package(url: "https://github.com/algorandfoundation/swift-sodium-full.git", from: "1.0.0"),

        // Base58 encoding for Solana addresses
        .package(url: "https://github.com/keefertaylor/Base58Swift.git", from: "2.1.0"),

        // Post-quantum cryptography (Kyber/ML-KEM) - optional for now
        // .package(url: "https://github.com/open-quantum-safe/liboqs-swift.git", branch: "main"),
    ],
    targets: [
        .target(
            name: "StealthCore",
            dependencies: [
                .product(name: "Sodium", package: "swift-sodium-full"),
                .product(name: "Base58Swift", package: "Base58Swift"),
            ],
            path: "Sources/StealthCore"
        ),
        .testTarget(
            name: "StealthCoreTests",
            dependencies: ["StealthCore"],
            path: "Tests/StealthCoreTests"
        ),
    ]
)
