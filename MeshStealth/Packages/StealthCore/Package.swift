// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "StealthCore",
    platforms: [
        .iOS("26.0"),    // iOS 26+ required for CryptoKit MLKEM768
        .macOS("26.0")   // macOS Tahoe 26+ required for CryptoKit MLKEM768
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

        // Post-quantum cryptography: NO EXTERNAL DEPENDENCY NEEDED
        // CryptoKit MLKEM768 is built into iOS 26+ / macOS 26+
    ],
    targets: [
        .target(
            name: "StealthCore",
            dependencies: [
                .product(name: "Sodium", package: "swift-sodium-full"),
                .product(name: "Base58Swift", package: "Base58Swift"),
            ],
            path: "Sources/StealthCore",
            resources: [
                .process("Privacy/Resources")
            ]
        ),
        .testTarget(
            name: "StealthCoreTests",
            dependencies: ["StealthCore"],
            path: "Tests/StealthCoreTests"
        ),
    ]
)
