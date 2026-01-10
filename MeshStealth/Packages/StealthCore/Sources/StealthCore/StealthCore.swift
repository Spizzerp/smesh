/// StealthCore - Core cryptographic library for Mesh Stealth Transfers
///
/// This library provides stealth address functionality for Solana, enabling
/// unlinkable one-time addresses that preserve sender and receiver privacy.
///
/// ## Overview
///
/// Stealth addresses allow a receiver to share a single "meta-address" that
/// senders can use to derive unique one-time addresses. Only the receiver
/// can detect and spend from these addresses.
///
/// ## Key Types
///
/// - ``StealthKeyPair``: The receiver's identity (spending + viewing keys)
/// - ``StealthAddressGenerator``: Sender-side stealth address derivation
/// - ``StealthScanner``: Receiver-side transaction scanning
/// - ``KeychainService``: Secure storage for private keys
///
/// ## Usage
///
/// ### Receiver: Generate Identity
/// ```swift
/// let keyPair = try StealthKeyPair.generate()
/// let metaAddress = keyPair.metaAddressString
/// // Share metaAddress via QR code
/// try KeychainService.shared.storeKeyPair(keyPair)
/// ```
///
/// ### Sender: Generate Stealth Address
/// ```swift
/// let result = try StealthAddressGenerator.generateStealthAddress(
///     metaAddressString: recipientMetaAddress
/// )
/// // result.stealthAddress -> transaction destination
/// // result.ephemeralPublicKey -> include in memo
/// ```
///
/// ### Receiver: Scan for Payments
/// ```swift
/// let scanner = StealthScanner(keyPair: keyPair)
/// if let payment = try scanner.scanTransaction(
///     stealthAddress: txDestination,
///     ephemeralPublicKey: memoData
/// ) {
///     // payment.spendingPrivateKey can sign from stealth address
/// }
/// ```

// Re-export all public types
@_exported import Foundation

// Note: In a proper module, types are automatically exported.
// This file serves as documentation and can include module-level
// initialization if needed.

/// Initialize the cryptographic subsystem.
/// Call this once at app launch.
/// - Returns: true if initialization succeeded
public func initializeStealth() -> Bool {
    return SodiumWrapper.initialize()
}
