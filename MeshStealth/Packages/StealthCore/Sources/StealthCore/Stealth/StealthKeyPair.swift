import Foundation
import CryptoKit

/// Represents a complete stealth identity with spending and viewing keypairs.
///
/// The stealth keypair consists of:
/// - **Spending keypair (m, M)**: Scalar keypair where M = m * G (for stealth arithmetic)
/// - **Viewing keypair (v, V)**: X25519 keypair for ECDH (computing shared secrets)
///
/// Note: The spending key is a raw scalar, NOT an ed25519 seed. This allows
/// correct stealth address derivation: P = M + hash(S)*G, p = m + hash(S).
///
/// The meta-address is the concatenation of both public keys, shared with senders.
public struct StealthKeyPair: Codable, Equatable {

    /// Spending public key (32 bytes) - M = m * G
    public let spendingPublicKey: Data

    /// Curve25519 viewing public key (32 bytes) - for ECDH
    public let viewingPublicKey: Data

    /// Spending private key scalar (32 bytes) - stored encrypted in Keychain
    /// This is NOT an ed25519 seed - it's a raw scalar for direct arithmetic.
    internal let spendingScalar: Data

    /// Viewing private key (32 bytes) - stored encrypted in Keychain
    internal let viewingPrivateKey: Data

    /// Combined stealth meta-address (64 bytes: spending pubkey || viewing pubkey)
    public var metaAddress: Data {
        spendingPublicKey + viewingPublicKey
    }

    /// Base58-encoded stealth meta-address for sharing
    /// Format: Full 64-byte meta-address encoded as base58
    public var metaAddressString: String {
        metaAddress.base58EncodedString
    }

    /// Generate a new random stealth keypair
    /// - Returns: New StealthKeyPair
    /// - Throws: StealthError if key generation fails
    public static func generate() throws -> StealthKeyPair {
        // Generate spending keypair using raw scalar (for correct stealth arithmetic)
        // This is NOT an ed25519 seed - it's a scalar where M = m * G directly
        guard let scalarKeyPair = SodiumWrapper.generateScalarKeyPair() else {
            throw StealthError.keyGenerationFailed
        }

        // Generate viewing keypair (X25519 for ECDH)
        // Use CryptoKit for X25519
        let viewingKey = Curve25519.KeyAgreement.PrivateKey()
        let viewingPublicKey = Data(viewingKey.publicKey.rawRepresentation)
        let viewingPrivateKey = Data(viewingKey.rawRepresentation)

        return StealthKeyPair(
            spendingPublicKey: scalarKeyPair.publicKey,
            viewingPublicKey: viewingPublicKey,
            spendingScalar: scalarKeyPair.scalar,
            viewingPrivateKey: viewingPrivateKey
        )
    }

    /// Restore keypair from stored scalar/keys
    /// - Parameters:
    ///   - spendingScalar: 32-byte spending scalar (NOT an ed25519 seed)
    ///   - viewingPrivateKey: 32-byte X25519 private key
    /// - Returns: Restored StealthKeyPair
    /// - Throws: StealthError if key derivation fails
    public static func restore(spendingScalar: Data, viewingPrivateKey: Data) throws -> StealthKeyPair {
        // Derive spending public key from scalar: M = m * G
        guard let spendingPublicKey = SodiumWrapper.derivePublicKeyFromScalar(spendingScalar) else {
            throw StealthError.keyDerivationFailed
        }

        // Derive viewing public key from private key
        let viewingKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: viewingPrivateKey)
        let viewingPublicKey = Data(viewingKey.publicKey.rawRepresentation)

        return StealthKeyPair(
            spendingPublicKey: spendingPublicKey,
            viewingPublicKey: viewingPublicKey,
            spendingScalar: spendingScalar,
            viewingPrivateKey: viewingPrivateKey
        )
    }

    /// Parse meta-address from base58 string
    /// - Parameter metaAddressString: Base58-encoded meta-address (64 bytes when decoded)
    /// - Returns: Tuple of (spendingPubKey, viewingPubKey)
    /// - Throws: StealthError if format is invalid
    public static func parseMetaAddress(_ metaAddressString: String) throws -> (spendingPubKey: Data, viewingPubKey: Data) {
        guard let decoded = metaAddressString.base58DecodedData,
              decoded.count == 64 else {
            throw StealthError.invalidMetaAddress
        }

        let (spendPubKey, viewPubKey) = decoded.splitAt(32)
        return (spendPubKey, viewPubKey)
    }

    /// Compute shared secret with an ephemeral public key (for scanning)
    /// Uses X25519 ECDH: S = v * R where v is our viewing private key
    /// - Parameter ephemeralPubKey: Sender's ephemeral public key R (32 bytes)
    /// - Returns: 32-byte shared secret
    /// - Throws: StealthError if computation fails
    public func computeSharedSecret(ephemeralPubKey: Data) throws -> Data {
        guard ephemeralPubKey.count == 32 else {
            throw StealthError.invalidEphemeralKey
        }

        // Use CryptoKit for X25519 ECDH
        let viewKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: viewingPrivateKey)
        let ephemeralKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephemeralPubKey)

        let sharedSecret = try viewKey.sharedSecretFromKeyAgreement(with: ephemeralKey)

        // Convert SharedSecret to Data
        return sharedSecret.withUnsafeBytes { Data($0) }
    }

    /// Derive stealth spending key from shared secret hash
    /// Computes: p_stealth = m + hash(S) mod L
    /// - Parameter sharedSecretHash: SHA-256 hash of the shared secret (32 bytes)
    /// - Returns: Derived spending private key scalar (32 bytes)
    /// - Throws: StealthError if computation fails
    public func deriveStealthSpendingKey(sharedSecretHash: Data) throws -> Data {
        guard sharedSecretHash.count == 32 else {
            throw StealthError.keyDerivationFailed
        }

        // p_stealth = m + hash(S) mod L
        guard let result = SodiumWrapper.scalarAdd(spendingScalar, sharedSecretHash) else {
            throw StealthError.scalarAdditionFailed
        }

        return result
    }

    /// Get the raw spending scalar for secure storage
    public var rawSpendingScalar: Data { spendingScalar }

    /// Get the raw viewing private key for secure storage
    public var rawViewingPrivateKey: Data { viewingPrivateKey }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case spendingPublicKey
        case viewingPublicKey
        case spendingScalar
        case viewingPrivateKey
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let spendingPubHex = try container.decode(String.self, forKey: .spendingPublicKey)
        let viewingPubHex = try container.decode(String.self, forKey: .viewingPublicKey)
        let spendingScalarHex = try container.decode(String.self, forKey: .spendingScalar)
        let viewingPrivHex = try container.decode(String.self, forKey: .viewingPrivateKey)

        guard let spendingPub = Data(hexString: spendingPubHex),
              let viewingPub = Data(hexString: viewingPubHex),
              let spendScalar = Data(hexString: spendingScalarHex),
              let viewPriv = Data(hexString: viewingPrivHex) else {
            throw StealthError.invalidMetaAddress
        }

        self.spendingPublicKey = spendingPub
        self.viewingPublicKey = viewingPub
        self.spendingScalar = spendScalar
        self.viewingPrivateKey = viewPriv
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(spendingPublicKey.hexString, forKey: .spendingPublicKey)
        try container.encode(viewingPublicKey.hexString, forKey: .viewingPublicKey)
        try container.encode(spendingScalar.hexString, forKey: .spendingScalar)
        try container.encode(viewingPrivateKey.hexString, forKey: .viewingPrivateKey)
    }

    // MARK: - Equatable

    public static func == (lhs: StealthKeyPair, rhs: StealthKeyPair) -> Bool {
        lhs.spendingPublicKey == rhs.spendingPublicKey &&
        lhs.viewingPublicKey == rhs.viewingPublicKey
    }

    // MARK: - Internal Init

    internal init(
        spendingPublicKey: Data,
        viewingPublicKey: Data,
        spendingScalar: Data,
        viewingPrivateKey: Data
    ) {
        self.spendingPublicKey = spendingPublicKey
        self.viewingPublicKey = viewingPublicKey
        self.spendingScalar = spendingScalar
        self.viewingPrivateKey = viewingPrivateKey
    }
}

// MARK: - Stealth Errors

/// Errors that can occur in stealth address operations
public enum StealthError: Error, LocalizedError, Equatable {
    case keyGenerationFailed
    case keyDerivationFailed
    case invalidMetaAddress
    case invalidEphemeralKey
    case invalidStealthAddress
    case scalarAdditionFailed
    case pointAdditionFailed
    case encryptionFailed
    case decryptionFailed
    case keychainError(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .keyGenerationFailed:
            return "Failed to generate cryptographic keys"
        case .keyDerivationFailed:
            return "Failed to derive key from seed"
        case .invalidMetaAddress:
            return "Invalid stealth meta-address format (expected 64 bytes base58)"
        case .invalidEphemeralKey:
            return "Invalid ephemeral public key (expected 32 bytes)"
        case .invalidStealthAddress:
            return "Invalid stealth address format"
        case .scalarAdditionFailed:
            return "Ed25519 scalar addition failed"
        case .pointAdditionFailed:
            return "Ed25519 point addition failed"
        case .encryptionFailed:
            return "Payload encryption failed"
        case .decryptionFailed:
            return "Payload decryption failed"
        case .keychainError(let status):
            return "Keychain operation failed with status: \(status)"
        }
    }

    public static func == (lhs: StealthError, rhs: StealthError) -> Bool {
        switch (lhs, rhs) {
        case (.keyGenerationFailed, .keyGenerationFailed),
             (.keyDerivationFailed, .keyDerivationFailed),
             (.invalidMetaAddress, .invalidMetaAddress),
             (.invalidEphemeralKey, .invalidEphemeralKey),
             (.invalidStealthAddress, .invalidStealthAddress),
             (.scalarAdditionFailed, .scalarAdditionFailed),
             (.pointAdditionFailed, .pointAdditionFailed),
             (.encryptionFailed, .encryptionFailed),
             (.decryptionFailed, .decryptionFailed):
            return true
        case (.keychainError(let a), .keychainError(let b)):
            return a == b
        default:
            return false
        }
    }
}
