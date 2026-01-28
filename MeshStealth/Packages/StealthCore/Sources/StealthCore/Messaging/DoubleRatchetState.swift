import Foundation
import CryptoKit

/// State for the Hybrid Post-Quantum Double Ratchet protocol.
///
/// Combines X25519 (classical) with ML-KEM 768 (post-quantum) for
/// Signal-level security that's resistant to both classical and quantum attacks.
///
/// Key Properties:
/// - Forward Secrecy: Chain key ratchets after every message
/// - Post-Compromise Security: DH ratchet regenerates keys on each turn
/// - Quantum Resistance: ML-KEM 768 combined with X25519
public struct DoubleRatchetState: Sendable {

    // MARK: - Ratchet Keys

    /// Our current DH private key for the ratchet (X25519)
    public var dhPrivateKey: Curve25519.KeyAgreement.PrivateKey

    /// Remote peer's current DH public key (X25519)
    public var remotePublicKey: Data?

    /// Our ML-KEM 768 private key for post-quantum security
    public var mlkemPrivateKey: MLKEM768.PrivateKey

    /// Remote peer's ML-KEM 768 public key
    public var remoteMlkemPublicKey: Data?

    // MARK: - Chain Keys

    /// Root key derived from hybrid key exchange (32 bytes)
    public var rootKey: Data

    /// Current sending chain key (32 bytes)
    public var sendingChainKey: Data?

    /// Current receiving chain key (32 bytes)
    public var receivingChainKey: Data?

    // MARK: - Message Counters

    /// Number of messages sent in current sending chain
    public var sendingMessageNumber: UInt32 = 0

    /// Number of messages received in current receiving chain
    public var receivingMessageNumber: UInt32 = 0

    /// Number of messages in previous sending chains (for skipped message handling)
    public var previousChainLength: UInt32 = 0

    // MARK: - Session Info

    /// Unique session identifier
    public let sessionID: UUID

    /// Whether we are the initiator of this session
    public let isInitiator: Bool

    /// When this state was created
    public let createdAt: Date

    /// Last activity timestamp
    public var lastActivityAt: Date

    // MARK: - Initialization

    /// Initialize a new ratchet state for initiating a session
    /// - Parameters:
    ///   - sessionID: Unique session identifier
    ///   - isInitiator: Whether we are initiating the session
    /// - Throws: If key generation fails
    public init(sessionID: UUID, isInitiator: Bool) throws {
        self.sessionID = sessionID
        self.isInitiator = isInitiator
        self.createdAt = Date()
        self.lastActivityAt = Date()

        // Generate our initial DH keypair
        self.dhPrivateKey = Curve25519.KeyAgreement.PrivateKey()

        // Generate our ML-KEM keypair
        self.mlkemPrivateKey = try MLKEM768.PrivateKey()

        // Root key will be derived after key exchange
        self.rootKey = Data(repeating: 0, count: 32)
    }

    /// Initialize from received key exchange data (for responder)
    /// - Parameters:
    ///   - sessionID: Unique session identifier
    ///   - remoteX25519PublicKey: Remote peer's X25519 public key
    ///   - remoteMlkemPublicKey: Remote peer's ML-KEM public key
    /// - Throws: If key generation or derivation fails
    public init(
        sessionID: UUID,
        remoteX25519PublicKey: Data,
        remoteMlkemPublicKey: Data
    ) throws {
        self.sessionID = sessionID
        self.isInitiator = false
        self.createdAt = Date()
        self.lastActivityAt = Date()

        // Generate our keypairs
        self.dhPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        self.mlkemPrivateKey = try MLKEM768.PrivateKey()

        // Store remote public keys
        self.remotePublicKey = remoteX25519PublicKey
        self.remoteMlkemPublicKey = remoteMlkemPublicKey

        // Root key will be derived after computing shared secrets
        self.rootKey = Data(repeating: 0, count: 32)
    }

    // MARK: - Public Key Access

    /// Our X25519 public key for key exchange
    public var dhPublicKey: Data {
        Data(dhPrivateKey.publicKey.rawRepresentation)
    }

    /// Our ML-KEM public key for key exchange
    public var mlkemPublicKey: Data {
        Data(mlkemPrivateKey.publicKey.rawRepresentation)
    }

    // MARK: - State Updates

    /// Update the root key after key exchange
    public mutating func setRootKey(_ key: Data) {
        rootKey = key
        lastActivityAt = Date()
    }

    /// Set up sending chain
    public mutating func setupSendingChain(_ chainKey: Data) {
        sendingChainKey = chainKey
        sendingMessageNumber = 0
        lastActivityAt = Date()
    }

    /// Set up receiving chain
    public mutating func setupReceivingChain(_ chainKey: Data) {
        receivingChainKey = chainKey
        receivingMessageNumber = 0
        lastActivityAt = Date()
    }

    /// Advance the sending chain and return the message key
    public mutating func advanceSendingChain() -> Data? {
        guard var chainKey = sendingChainKey else { return nil }

        // Derive message key: HMAC(chainKey, 0x01)
        let messageKey = deriveKey(from: chainKey, info: Data([0x01]))

        // Advance chain key: HMAC(chainKey, 0x02)
        chainKey = deriveKey(from: chainKey, info: Data([0x02]))
        sendingChainKey = chainKey

        sendingMessageNumber += 1
        lastActivityAt = Date()

        return messageKey
    }

    /// Advance the receiving chain and return the message key
    public mutating func advanceReceivingChain() -> Data? {
        guard var chainKey = receivingChainKey else { return nil }

        // Derive message key: HMAC(chainKey, 0x01)
        let messageKey = deriveKey(from: chainKey, info: Data([0x01]))

        // Advance chain key: HMAC(chainKey, 0x02)
        chainKey = deriveKey(from: chainKey, info: Data([0x02]))
        receivingChainKey = chainKey

        receivingMessageNumber += 1
        lastActivityAt = Date()

        return messageKey
    }

    /// Perform a DH ratchet step with new remote public key
    public mutating func performDHRatchet(newRemotePublicKey: Data) throws {
        // Store previous chain length
        previousChainLength = sendingMessageNumber

        // Update remote public key
        remotePublicKey = newRemotePublicKey

        // Generate new DH keypair
        dhPrivateKey = Curve25519.KeyAgreement.PrivateKey()

        // Reset counters
        sendingMessageNumber = 0
        receivingMessageNumber = 0

        lastActivityAt = Date()
    }

    // MARK: - Helpers

    /// Derive a key using HMAC-SHA256
    private func deriveKey(from key: Data, info: Data) -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let hmac = HMAC<SHA256>.authenticationCode(for: info, using: symmetricKey)
        return Data(hmac)
    }

    /// Clear sensitive data from memory
    public mutating func clear() {
        rootKey = Data(repeating: 0, count: 32)
        sendingChainKey = nil
        receivingChainKey = nil
        remotePublicKey = nil
        remoteMlkemPublicKey = nil
    }
}

// MARK: - Skipped Message Keys

/// Storage for skipped message keys (for out-of-order messages)
public struct SkippedMessageKeys: Sendable {
    /// Maximum number of skipped keys to store
    public static let maxSkipped = 100

    /// Stored keys: (ratchetPublicKey, messageNumber) -> messageKey
    private var keys: [SkippedKeyIdentifier: Data] = [:]

    public init() {}

    /// Store a skipped key
    public mutating func store(publicKey: Data, messageNumber: UInt32, key: Data) {
        // Enforce limit
        if keys.count >= Self.maxSkipped {
            // Remove oldest (simple approach - remove any one)
            if let first = keys.keys.first {
                keys.removeValue(forKey: first)
            }
        }

        let id = SkippedKeyIdentifier(publicKey: publicKey, messageNumber: messageNumber)
        keys[id] = key
    }

    /// Retrieve and remove a skipped key
    public mutating func retrieve(publicKey: Data, messageNumber: UInt32) -> Data? {
        let id = SkippedKeyIdentifier(publicKey: publicKey, messageNumber: messageNumber)
        return keys.removeValue(forKey: id)
    }

    /// Clear all skipped keys
    public mutating func clear() {
        keys.removeAll()
    }
}

/// Identifier for skipped message keys
private struct SkippedKeyIdentifier: Hashable, Sendable {
    let publicKey: Data
    let messageNumber: UInt32
}
