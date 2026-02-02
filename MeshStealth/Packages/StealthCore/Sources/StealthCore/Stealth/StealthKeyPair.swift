import Foundation
import CryptoKit

/// Represents a complete stealth identity with spending and viewing keypairs.
///
/// The stealth keypair consists of:
/// - **Spending keypair (m, M)**: Scalar keypair where M = m * G (for stealth arithmetic)
/// - **Viewing keypair (v, V)**: X25519 keypair for ECDH (computing shared secrets)
/// - **MLKEM keypair (optional)**: Post-quantum key encapsulation for hybrid mode
///
/// Note: The spending key is a raw scalar, NOT an ed25519 seed. This allows
/// correct stealth address derivation: P = M + hash(S)*G, p = m + hash(S).
///
/// The meta-address is the concatenation of both public keys, shared with senders.
/// Hybrid meta-address includes the MLKEM768 public key (1184 bytes additional).
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

    /// MLKEM768 public key (1184 bytes) - for post-quantum key encapsulation
    /// Only present when keypair was generated with post-quantum support
    public let mlkemPublicKey: Data?

    /// MLKEM768 private key data - stored encrypted in Keychain
    /// Uses integrityCheckedRepresentation format (~2400 bytes)
    internal let mlkemPrivateKey: Data?

    /// Whether this keypair has post-quantum (MLKEM768) support
    public var hasPostQuantum: Bool {
        mlkemPublicKey != nil && mlkemPrivateKey != nil
    }

    /// Combined stealth meta-address (64 bytes: spending pubkey || viewing pubkey)
    /// Use this for classical-only mode
    public var metaAddress: Data {
        spendingPublicKey + viewingPublicKey
    }

    /// Hybrid meta-address including MLKEM768 public key (1248 bytes total)
    /// Format: M (32) || V (32) || K_pub (1184)
    /// Returns classical metaAddress if no post-quantum keys present
    public var hybridMetaAddress: Data {
        guard let mlkemPub = mlkemPublicKey else {
            return metaAddress
        }
        return spendingPublicKey + viewingPublicKey + mlkemPub
    }

    /// Base58-encoded stealth meta-address for sharing
    /// Format: Full 64-byte meta-address encoded as base58
    public var metaAddressString: String {
        metaAddress.base58EncodedString
    }

    /// Base58-encoded hybrid meta-address for sharing (with post-quantum support)
    /// Returns classical metaAddressString if no post-quantum keys present
    public var hybridMetaAddressString: String {
        hybridMetaAddress.base58EncodedString
    }

    /// Generate a new random stealth keypair
    /// - Parameter withPostQuantum: If true, also generates MLKEM768 keypair for hybrid mode
    /// - Returns: New StealthKeyPair
    /// - Throws: StealthError if key generation fails
    public static func generate(withPostQuantum: Bool = false) throws -> StealthKeyPair {
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

        // Generate MLKEM768 keypair if post-quantum mode requested
        var mlkemPublicKey: Data? = nil
        var mlkemPrivateKey: Data? = nil

        if withPostQuantum {
            let mlkemKeyPair = try MLKEMWrapper.generateKeyPairData()
            mlkemPublicKey = mlkemKeyPair.publicKey
            mlkemPrivateKey = mlkemKeyPair.privateKey
        }

        return StealthKeyPair(
            spendingPublicKey: scalarKeyPair.publicKey,
            viewingPublicKey: viewingPublicKey,
            spendingScalar: scalarKeyPair.scalar,
            viewingPrivateKey: viewingPrivateKey,
            mlkemPublicKey: mlkemPublicKey,
            mlkemPrivateKey: mlkemPrivateKey
        )
    }

    /// Restore keypair from stored scalar/keys
    /// - Parameters:
    ///   - spendingScalar: 32-byte spending scalar (NOT an ed25519 seed)
    ///   - viewingPrivateKey: 32-byte X25519 private key
    ///   - mlkemPrivateKey: Optional MLKEM768 private key data (for hybrid mode)
    /// - Returns: Restored StealthKeyPair
    /// - Throws: StealthError if key derivation fails
    public static func restore(
        spendingScalar: Data,
        viewingPrivateKey: Data,
        mlkemPrivateKey: Data? = nil
    ) throws -> StealthKeyPair {
        // Derive spending public key from scalar: M = m * G
        guard let spendingPublicKey = SodiumWrapper.derivePublicKeyFromScalar(spendingScalar) else {
            throw StealthError.keyDerivationFailed
        }

        // Derive viewing public key from private key
        let viewingKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: viewingPrivateKey)
        let viewingPublicKey = Data(viewingKey.publicKey.rawRepresentation)

        // Restore MLKEM keypair if provided
        var mlkemPublicKey: Data? = nil
        if let mlkemPriv = mlkemPrivateKey {
            guard let restoredKey = MLKEMWrapper.restorePrivateKey(from: mlkemPriv) else {
                throw StealthError.invalidMLKEMPrivateKey
            }
            mlkemPublicKey = Data(restoredKey.publicKey.rawRepresentation)
        }

        return StealthKeyPair(
            spendingPublicKey: spendingPublicKey,
            viewingPublicKey: viewingPublicKey,
            spendingScalar: spendingScalar,
            viewingPrivateKey: viewingPrivateKey,
            mlkemPublicKey: mlkemPublicKey,
            mlkemPrivateKey: mlkemPrivateKey
        )
    }

    /// Parse meta-address from base58 string (classical 64-byte format)
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

    /// Parse hybrid meta-address from base58 string
    /// Supports both classical (64-byte) and hybrid (1248-byte) formats
    /// - Parameter metaAddressString: Base58-encoded meta-address
    /// - Returns: Tuple of (spendingPubKey, viewingPubKey, mlkemPubKey?)
    /// - Throws: StealthError if format is invalid
    public static func parseHybridMetaAddress(_ metaAddressString: String) throws -> (
        spendingPubKey: Data,
        viewingPubKey: Data,
        mlkemPubKey: Data?
    ) {
        guard let decoded = metaAddressString.base58DecodedData else {
            throw StealthError.invalidMetaAddress
        }

        // Classical format: 64 bytes (M || V)
        // Hybrid format: 1248 bytes (M || V || K_pub)
        let classicalSize = 64
        let hybridSize = 64 + MLKEMWrapper.publicKeyBytes  // 64 + 1184 = 1248

        switch decoded.count {
        case classicalSize:
            let (spendPubKey, viewPubKey) = decoded.splitAt(32)
            return (spendPubKey, viewPubKey, nil)

        case hybridSize:
            let spendPubKey = decoded.prefix(32)
            let viewPubKey = decoded.dropFirst(32).prefix(32)
            let mlkemPubKey = decoded.suffix(MLKEMWrapper.publicKeyBytes)
            return (Data(spendPubKey), Data(viewPubKey), Data(mlkemPubKey))

        default:
            throw StealthError.invalidMetaAddress
        }
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

    /// Decapsulate MLKEM768 ciphertext to recover shared secret (for hybrid scanning)
    /// - Parameter ciphertext: MLKEM768 ciphertext (1088 bytes)
    /// - Returns: 32-byte shared secret
    /// - Throws: StealthError if decapsulation fails or no MLKEM key present
    public func decapsulateMLKEM(ciphertext: Data) throws -> Data {
        guard let mlkemPriv = mlkemPrivateKey else {
            throw StealthError.invalidMLKEMPrivateKey
        }

        return try MLKEMWrapper.decapsulate(ciphertextData: ciphertext, privateKeyData: mlkemPriv)
    }

    /// Compute hybrid shared secret combining X25519 ECDH and MLKEM768 KEM
    /// Combined secret: S = SHA256(S_classical || S_kyber)
    /// - Parameters:
    ///   - ephemeralPubKey: Sender's ephemeral X25519 public key R (32 bytes)
    ///   - mlkemCiphertext: MLKEM768 ciphertext (1088 bytes)
    /// - Returns: 32-byte combined shared secret
    /// - Throws: StealthError if computation fails
    public func computeHybridSharedSecret(
        ephemeralPubKey: Data,
        mlkemCiphertext: Data
    ) throws -> Data {
        // Compute classical X25519 shared secret
        let classicalSecret = try computeSharedSecret(ephemeralPubKey: ephemeralPubKey)

        // Decapsulate MLKEM to get post-quantum shared secret
        let kyberSecret = try decapsulateMLKEM(ciphertext: mlkemCiphertext)

        // Combine: S = SHA256(S_classical || S_kyber)
        let combined = classicalSecret + kyberSecret
        return try SodiumWrapper.sha256(combined)
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

    /// Get the raw MLKEM private key for secure storage
    /// Returns nil if keypair was generated without post-quantum support
    public var rawMLKEMPrivateKey: Data? { mlkemPrivateKey }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case spendingPublicKey
        case viewingPublicKey
        case spendingScalar
        case viewingPrivateKey
        case mlkemPublicKey
        case mlkemPrivateKey
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let spendingPubHex = try container.decode(String.self, forKey: .spendingPublicKey)
        let viewingPubHex = try container.decode(String.self, forKey: .viewingPublicKey)
        let spendingScalarHex = try container.decode(String.self, forKey: .spendingScalar)
        let viewingPrivHex = try container.decode(String.self, forKey: .viewingPrivateKey)

        // MLKEM keys are optional (for backwards compatibility)
        let mlkemPubHex = try container.decodeIfPresent(String.self, forKey: .mlkemPublicKey)
        let mlkemPrivHex = try container.decodeIfPresent(String.self, forKey: .mlkemPrivateKey)

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

        // Decode MLKEM keys if present
        if let pubHex = mlkemPubHex, let privHex = mlkemPrivHex {
            guard let mlkemPub = Data(hexString: pubHex),
                  let mlkemPriv = Data(hexString: privHex) else {
                throw StealthError.invalidMLKEMPrivateKey
            }
            self.mlkemPublicKey = mlkemPub
            self.mlkemPrivateKey = mlkemPriv
        } else {
            self.mlkemPublicKey = nil
            self.mlkemPrivateKey = nil
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        try container.encode(spendingPublicKey.hexString, forKey: .spendingPublicKey)
        try container.encode(viewingPublicKey.hexString, forKey: .viewingPublicKey)
        try container.encode(spendingScalar.hexString, forKey: .spendingScalar)
        try container.encode(viewingPrivateKey.hexString, forKey: .viewingPrivateKey)

        // Encode MLKEM keys if present
        if let mlkemPub = mlkemPublicKey {
            try container.encode(mlkemPub.hexString, forKey: .mlkemPublicKey)
        }
        if let mlkemPriv = mlkemPrivateKey {
            try container.encode(mlkemPriv.hexString, forKey: .mlkemPrivateKey)
        }
    }

    // MARK: - Equatable

    public static func == (lhs: StealthKeyPair, rhs: StealthKeyPair) -> Bool {
        lhs.spendingPublicKey == rhs.spendingPublicKey &&
        lhs.viewingPublicKey == rhs.viewingPublicKey &&
        lhs.mlkemPublicKey == rhs.mlkemPublicKey
    }

    // MARK: - Internal Init

    internal init(
        spendingPublicKey: Data,
        viewingPublicKey: Data,
        spendingScalar: Data,
        viewingPrivateKey: Data,
        mlkemPublicKey: Data? = nil,
        mlkemPrivateKey: Data? = nil
    ) {
        self.spendingPublicKey = spendingPublicKey
        self.viewingPublicKey = viewingPublicKey
        self.spendingScalar = spendingScalar
        self.viewingPrivateKey = viewingPrivateKey
        self.mlkemPublicKey = mlkemPublicKey
        self.mlkemPrivateKey = mlkemPrivateKey
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
    // MLKEM/Post-quantum errors
    case invalidMLKEMPublicKey
    case invalidMLKEMPrivateKey
    case invalidMLKEMCiphertext
    case mlkemEncapsulationFailed
    case mlkemDecapsulationFailed

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
        case .invalidMLKEMPublicKey:
            return "Invalid MLKEM768 public key (expected 1184 bytes)"
        case .invalidMLKEMPrivateKey:
            return "Invalid MLKEM768 private key seed (expected 64 bytes)"
        case .invalidMLKEMCiphertext:
            return "Invalid MLKEM768 ciphertext (expected 1088 bytes)"
        case .mlkemEncapsulationFailed:
            return "MLKEM768 encapsulation failed"
        case .mlkemDecapsulationFailed:
            return "MLKEM768 decapsulation failed"
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
             (.decryptionFailed, .decryptionFailed),
             (.invalidMLKEMPublicKey, .invalidMLKEMPublicKey),
             (.invalidMLKEMPrivateKey, .invalidMLKEMPrivateKey),
             (.invalidMLKEMCiphertext, .invalidMLKEMCiphertext),
             (.mlkemEncapsulationFailed, .mlkemEncapsulationFailed),
             (.mlkemDecapsulationFailed, .mlkemDecapsulationFailed):
            return true
        case (.keychainError(let a), .keychainError(let b)):
            return a == b
        default:
            return false
        }
    }
}
