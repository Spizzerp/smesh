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

    // MARK: - Signing

    /// Sign a message with ed25519
    /// - Parameter message: Message bytes to sign
    /// - Returns: 64-byte ed25519 signature
    public func sign(_ message: Data) throws -> Data {
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
