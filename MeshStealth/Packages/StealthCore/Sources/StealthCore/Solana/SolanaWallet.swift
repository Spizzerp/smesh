import Foundation
import CryptoKit

/// Main Solana wallet for holding and spending funds
/// This is the user's visible wallet that receives airdrops and external deposits
public actor SolanaWallet {
    /// The ed25519 keypair for this wallet
    private let privateKey: Curve25519.Signing.PrivateKey

    /// Public key raw bytes
    public var publicKeyData: Data {
        Data(privateKey.publicKey.rawRepresentation)
    }

    /// Public key as Solana address (base58)
    public var address: String {
        publicKeyData.base58EncodedString
    }

    /// Generate a new random wallet
    public init() {
        self.privateKey = Curve25519.Signing.PrivateKey()
    }

    /// Restore from stored private key
    public init(privateKeyData: Data) throws {
        self.privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: privateKeyData)
    }

    /// Sign a message (for transaction signing)
    public func sign(_ message: Data) throws -> Data {
        try privateKey.signature(for: message)
    }

    /// Export private key for secure storage
    public var privateKeyData: Data {
        Data(privateKey.rawRepresentation)
    }
}

// MARK: - Sendable Conformance

extension SolanaWallet: Sendable {}
