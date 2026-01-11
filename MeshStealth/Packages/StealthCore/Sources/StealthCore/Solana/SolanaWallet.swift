import Foundation
import Sodium

/// Main Solana wallet with BIP-39 mnemonic support
///
/// Uses proper ed25519 signing via libsodium (not CryptoKit Curve25519).
/// Supports BIP-39 mnemonic generation and SLIP-0010 key derivation.
///
/// Derivation path: m/44'/501'/0'/0' (Solana standard, all hardened)
public actor SolanaWallet {

    // MARK: - Properties

    /// The 64-byte ed25519 secret key (32-byte seed + 32-byte public key)
    private let secretKey: Data

    /// The mnemonic phrase (for backup) - nil if restored from secret key only
    public let mnemonic: [String]?

    /// libsodium instance
    private let sodium = Sodium()

    // MARK: - Computed Properties

    /// 32-byte public key
    public var publicKeyData: Data {
        Data(secretKey.suffix(32))
    }

    /// Public key as Solana address (base58)
    public var address: String {
        publicKeyData.base58EncodedString
    }

    /// 32-byte private key (seed portion)
    public var privateKeyData: Data {
        Data(secretKey.prefix(32))
    }

    /// Full 64-byte secret key for storage
    public var secretKeyData: Data {
        secretKey
    }

    // MARK: - Initialization

    /// Generate new wallet with BIP-39 mnemonic
    /// - Parameter wordCount: 12 or 24 words (default 12)
    public init(wordCount: Int = 12) throws {
        let strength = wordCount == 24 ? 256 : 128
        let phrase = try BIP39.generateMnemonic(strength: strength)
        try self.init(mnemonic: phrase)
    }

    /// Restore wallet from mnemonic phrase
    /// - Parameters:
    ///   - mnemonic: Array of BIP-39 words
    ///   - passphrase: Optional BIP-39 passphrase
    public init(mnemonic: [String], passphrase: String = "") throws {
        // Validate mnemonic
        try BIP39.validate(phrase: mnemonic)

        self.mnemonic = mnemonic

        // BIP-39: Mnemonic → 64-byte seed
        let seed = BIP39.mnemonicToSeed(phrase: mnemonic, passphrase: passphrase)

        // SLIP-0010: Seed → 32-byte private key at m/44'/501'/0'/0'
        let privateKey = try SLIP0010.deriveSolanaKey(seed: seed)

        // libsodium: Generate ed25519 keypair from 32-byte seed
        guard let keypair = Sodium().sign.keyPair(seed: Array(privateKey)) else {
            throw WalletError.keyDerivationFailed
        }

        // secretKey = 64 bytes (32-byte seed + 32-byte public key)
        self.secretKey = Data(keypair.secretKey)
    }

    /// Restore wallet from mnemonic string
    /// - Parameters:
    ///   - mnemonicString: Space-separated mnemonic words
    ///   - passphrase: Optional BIP-39 passphrase
    public init(mnemonicString: String, passphrase: String = "") throws {
        let words = BIP39.parse(mnemonicString)
        try self.init(mnemonic: words, passphrase: passphrase)
    }

    /// Restore from stored 64-byte secret key (no mnemonic available)
    /// - Parameter secretKey: 64-byte ed25519 secret key
    public init(secretKey: Data) throws {
        guard secretKey.count == 64 else {
            throw WalletError.invalidKeyLength
        }
        self.secretKey = secretKey
        self.mnemonic = nil
    }

    /// Legacy: Restore from 32-byte private key (will derive public key)
    /// - Parameter privateKeyData: 32-byte ed25519 seed
    public init(privateKeyData: Data) throws {
        guard privateKeyData.count == 32 else {
            throw WalletError.invalidKeyLength
        }

        // Generate keypair from seed
        guard let keypair = Sodium().sign.keyPair(seed: Array(privateKeyData)) else {
            throw WalletError.keyDerivationFailed
        }

        self.secretKey = Data(keypair.secretKey)
        self.mnemonic = nil
    }

    /// Create wallet from a raw scalar (for stealth address spending keys).
    ///
    /// Unlike `init(privateKeyData:)` which treats the input as an ed25519 seed
    /// and performs key expansion, this initializer uses the scalar directly
    /// for `public key = scalar * G`. Required for stealth address arithmetic
    /// where spending keys are derived as `p = m + hash(S) mod L`.
    ///
    /// - Parameter scalar: 32-byte raw scalar (NOT a seed)
    /// - Returns: Wallet that can sign using the raw scalar
    /// - Throws: WalletError if scalar is invalid
    public init(stealthScalar scalar: Data) throws {
        guard scalar.count == 32 else {
            throw WalletError.invalidKeyLength
        }

        // Derive public key directly: P = scalar * G (no clamping/expansion)
        guard let publicKey = SodiumWrapper.derivePublicKeyFromScalar(scalar) else {
            throw WalletError.keyDerivationFailed
        }

        // Store as pseudo-secretKey: [scalar (32 bytes) || publicKey (32 bytes)]
        // Note: This is NOT a valid ed25519 secretKey format, but we use it
        // to store the scalar and pubkey together. signWithScalar() uses these.
        self.secretKey = scalar + publicKey
        self.mnemonic = nil
    }

    /// Whether this wallet uses raw scalar signing (for stealth addresses)
    public var isStealthScalarWallet: Bool {
        // Standard ed25519 secretKey has the seed in first 32 bytes, and
        // the public key derived FROM that seed in last 32 bytes.
        // For stealth scalar wallets, the first 32 bytes ARE the scalar,
        // and scalar * G == publicKey (no expansion).
        // We can detect this by checking if scalar * G == stored pubkey
        let scalar = privateKeyData
        let storedPubKey = publicKeyData
        guard let derivedPubKey = SodiumWrapper.derivePublicKeyFromScalar(scalar) else {
            return false
        }
        return derivedPubKey == storedPubKey
    }

    // MARK: - Signing

    /// Sign a message with ed25519
    /// - Parameter message: Message bytes to sign
    /// - Returns: 64-byte ed25519 signature
    public func sign(_ message: Data) throws -> Data {
        // Check if this is a stealth scalar wallet (raw scalar, not seed-expanded)
        if isStealthScalarWallet {
            // Use raw scalar signing for stealth address spending keys
            guard let signature = SodiumWrapper.signWithScalar(
                message: message,
                scalar: privateKeyData,
                publicKey: publicKeyData
            ) else {
                throw WalletError.signingFailed
            }
            return signature
        }

        // Standard ed25519 signing for seed-based wallets
        guard let signature = sodium.sign.signature(
            message: Array(message),
            secretKey: Array(secretKey)
        ) else {
            throw WalletError.signingFailed
        }
        return Data(signature)
    }

    /// Sign a message and return combined signed message (signature + message)
    /// - Parameter message: Message bytes to sign
    /// - Returns: Signed message (64-byte signature prepended to message)
    public func signCombined(_ message: Data) throws -> Data {
        guard let signedMessage = sodium.sign.sign(
            message: Array(message),
            secretKey: Array(secretKey)
        ) else {
            throw WalletError.signingFailed
        }
        return Data(signedMessage)
    }

    // MARK: - Verification

    /// Verify a signature
    /// - Parameters:
    ///   - signature: 64-byte ed25519 signature
    ///   - message: Original message
    /// - Returns: true if signature is valid
    public func verify(signature: Data, message: Data) -> Bool {
        sodium.sign.verify(
            message: Array(message),
            publicKey: Array(publicKeyData),
            signature: Array(signature)
        )
    }
}

// MARK: - Sendable Conformance

extension SolanaWallet: Sendable {}
