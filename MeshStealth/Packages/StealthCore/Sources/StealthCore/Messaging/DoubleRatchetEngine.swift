import Foundation
import CryptoKit

/// Engine for the Hybrid Post-Quantum Double Ratchet protocol.
///
/// Provides encryption and decryption using a combination of:
/// - X25519 for classical Diffie-Hellman key agreement
/// - ML-KEM 768 for post-quantum key encapsulation
/// - AES-256-GCM for authenticated encryption
/// - HKDF-SHA256 for key derivation
///
/// Security Properties:
/// - Forward Secrecy: Compromising current keys doesn't reveal past messages
/// - Post-Compromise Security: Session recovers security after compromise
/// - Quantum Resistance: Secure against quantum computer attacks
public enum DoubleRatchetEngine {

    // MARK: - Constants

    /// Size of symmetric keys in bytes
    public static let keySize = 32

    /// Size of AES-GCM nonce in bytes
    public static let nonceSize = 12

    /// Size of AES-GCM authentication tag in bytes
    public static let tagSize = 16

    /// Info string for root key derivation
    private static let rootKeyInfo = "MeshChat_RootKey".data(using: .utf8)!

    /// Info string for chain key derivation
    private static let chainKeyInfo = "MeshChat_ChainKey".data(using: .utf8)!

    /// Info string for message key derivation
    private static let messageKeyInfo = "MeshChat_MessageKey".data(using: .utf8)!

    // MARK: - Errors

    public enum RatchetError: Error, LocalizedError {
        case invalidPublicKey
        case keyDerivationFailed
        case encryptionFailed
        case decryptionFailed
        case invalidCiphertext
        case invalidNonce
        case missingKeys
        case sessionExpired

        public var errorDescription: String? {
            switch self {
            case .invalidPublicKey: return "Invalid public key format"
            case .keyDerivationFailed: return "Key derivation failed"
            case .encryptionFailed: return "Message encryption failed"
            case .decryptionFailed: return "Message decryption failed"
            case .invalidCiphertext: return "Invalid ciphertext format"
            case .invalidNonce: return "Invalid nonce"
            case .missingKeys: return "Required keys not available"
            case .sessionExpired: return "Chat session has expired"
            }
        }
    }

    // MARK: - Hybrid Key Derivation

    /// Derive a hybrid shared secret by combining X25519 and ML-KEM secrets.
    ///
    /// This provides security against both classical and quantum attackers -
    /// an attacker must break BOTH cryptosystems to recover the shared secret.
    ///
    /// - Parameters:
    ///   - x25519Secret: Shared secret from X25519 key exchange (32 bytes)
    ///   - mlkemSecret: Shared secret from ML-KEM encapsulation (32 bytes)
    /// - Returns: Combined 32-byte shared secret
    public static func deriveHybridSecret(x25519Secret: Data, mlkemSecret: Data) -> Data {
        var hasher = SHA256()
        hasher.update(data: x25519Secret)
        hasher.update(data: mlkemSecret)
        return Data(hasher.finalize())
    }

    /// Perform initial key exchange as the session initiator.
    ///
    /// - Parameters:
    ///   - state: Our ratchet state (will be modified)
    ///   - remoteX25519PublicKey: Remote peer's X25519 public key
    ///   - remoteMlkemPublicKey: Remote peer's ML-KEM public key
    /// - Returns: Tuple of (ML-KEM ciphertext to send, updated state)
    /// - Throws: RatchetError if key exchange fails
    public static func initiatorKeyExchange(
        state: inout DoubleRatchetState,
        remoteX25519PublicKey: Data,
        remoteMlkemPublicKey: Data
    ) throws -> Data {
        // Compute X25519 shared secret
        let remoteKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remoteX25519PublicKey)
        let x25519Secret = try state.dhPrivateKey.sharedSecretFromKeyAgreement(with: remoteKey)
        let x25519SecretData = x25519Secret.withUnsafeBytes { Data($0) }

        // Encapsulate with ML-KEM to get shared secret and ciphertext
        let (mlkemCiphertext, mlkemSecret) = try MLKEMWrapper.encapsulate(publicKeyData: remoteMlkemPublicKey)

        // Derive hybrid secret
        let hybridSecret = deriveHybridSecret(x25519Secret: x25519SecretData, mlkemSecret: mlkemSecret)

        // Derive root key and initial chain keys using HKDF
        let (rootKey, sendingChain, receivingChain) = deriveInitialKeys(from: hybridSecret)

        // Update state
        state.remotePublicKey = remoteX25519PublicKey
        state.remoteMlkemPublicKey = remoteMlkemPublicKey
        state.setRootKey(rootKey)
        state.setupSendingChain(sendingChain)
        state.setupReceivingChain(receivingChain)

        return mlkemCiphertext
    }

    /// Complete key exchange as the session responder.
    ///
    /// - Parameters:
    ///   - state: Our ratchet state (will be modified)
    ///   - remoteX25519PublicKey: Remote peer's X25519 public key
    ///   - mlkemCiphertext: ML-KEM ciphertext from initiator
    /// - Throws: RatchetError if key exchange fails
    public static func responderKeyExchange(
        state: inout DoubleRatchetState,
        remoteX25519PublicKey: Data,
        mlkemCiphertext: Data
    ) throws {
        // Compute X25519 shared secret
        let remoteKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remoteX25519PublicKey)
        let x25519Secret = try state.dhPrivateKey.sharedSecretFromKeyAgreement(with: remoteKey)
        let x25519SecretData = x25519Secret.withUnsafeBytes { Data($0) }

        // Decapsulate ML-KEM to get shared secret
        let mlkemPrivateKeyData = Data(state.mlkemPrivateKey.integrityCheckedRepresentation)
        let mlkemSecret = try MLKEMWrapper.decapsulate(
            ciphertextData: mlkemCiphertext,
            privateKeyData: mlkemPrivateKeyData
        )

        // Derive hybrid secret
        let hybridSecret = deriveHybridSecret(x25519Secret: x25519SecretData, mlkemSecret: mlkemSecret)

        // Derive root key and initial chain keys using HKDF
        // Note: Responder's chains are swapped (their sending = our receiving)
        let (rootKey, receivingChain, sendingChain) = deriveInitialKeys(from: hybridSecret)

        // Update state
        state.remotePublicKey = remoteX25519PublicKey
        state.setRootKey(rootKey)
        state.setupSendingChain(sendingChain)
        state.setupReceivingChain(receivingChain)
    }

    /// Derive initial keys from the hybrid shared secret using HKDF.
    private static func deriveInitialKeys(from secret: Data) -> (rootKey: Data, chain1: Data, chain2: Data) {
        let inputKey = SymmetricKey(data: secret)

        // Derive 96 bytes (3 x 32-byte keys)
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: Data("MeshChat_Salt".utf8),
            info: rootKeyInfo,
            outputByteCount: 96
        )

        let derivedData = derived.withUnsafeBytes { Data($0) }

        let rootKey = derivedData[0..<32]
        let chain1 = derivedData[32..<64]
        let chain2 = derivedData[64..<96]

        return (Data(rootKey), Data(chain1), Data(chain2))
    }

    // MARK: - Message Encryption

    /// Encrypt a message using the current ratchet state.
    ///
    /// - Parameters:
    ///   - plaintext: Message to encrypt
    ///   - state: Current ratchet state (will be modified to advance chain)
    /// - Returns: Encrypted message data (nonce + ciphertext + tag)
    /// - Throws: RatchetError if encryption fails
    public static func encrypt(
        plaintext: Data,
        state: inout DoubleRatchetState
    ) throws -> EncryptedMessage {
        // Get message key by advancing the sending chain
        guard let messageKey = state.advanceSendingChain() else {
            throw RatchetError.missingKeys
        }

        // Generate random nonce
        var nonceBytes = [UInt8](repeating: 0, count: nonceSize)
        guard SecRandomCopyBytes(kSecRandomDefault, nonceSize, &nonceBytes) == errSecSuccess else {
            throw RatchetError.encryptionFailed
        }
        let nonce = Data(nonceBytes)

        // Encrypt with AES-256-GCM
        let symmetricKey = SymmetricKey(data: messageKey)
        let aesNonce = try AES.GCM.Nonce(data: nonce)

        let sealedBox = try AES.GCM.seal(plaintext, using: symmetricKey, nonce: aesNonce)

        return EncryptedMessage(
            dhPublicKey: state.dhPublicKey,
            messageNumber: state.sendingMessageNumber - 1, // Already incremented
            nonce: nonce,
            ciphertext: Data(sealedBox.ciphertext),
            tag: Data(sealedBox.tag)
        )
    }

    /// Decrypt a message using the current ratchet state.
    ///
    /// - Parameters:
    ///   - message: Encrypted message to decrypt
    ///   - state: Current ratchet state (will be modified if needed)
    ///   - skippedKeys: Storage for skipped message keys
    /// - Returns: Decrypted plaintext
    /// - Throws: RatchetError if decryption fails
    public static func decrypt(
        message: EncryptedMessage,
        state: inout DoubleRatchetState,
        skippedKeys: inout SkippedMessageKeys
    ) throws -> Data {
        // Check if this is from a skipped message
        if let messageKey = skippedKeys.retrieve(
            publicKey: message.dhPublicKey,
            messageNumber: message.messageNumber
        ) {
            return try decryptWithKey(message: message, key: messageKey)
        }

        // Check if we need to do a DH ratchet step
        if message.dhPublicKey != state.remotePublicKey {
            // Skip any remaining messages in current chain
            try skipMessages(until: state.previousChainLength, state: &state, skippedKeys: &skippedKeys)

            // Perform DH ratchet
            try state.performDHRatchet(newRemotePublicKey: message.dhPublicKey)

            // Derive new receiving chain from the new DH shared secret
            try deriveReceivingChain(state: &state)
        }

        // Skip any messages before this one in the current chain
        try skipMessages(until: message.messageNumber, state: &state, skippedKeys: &skippedKeys)

        // Get message key by advancing the receiving chain
        guard let messageKey = state.advanceReceivingChain() else {
            throw RatchetError.missingKeys
        }

        return try decryptWithKey(message: message, key: messageKey)
    }

    /// Decrypt a message with a specific key.
    private static func decryptWithKey(message: EncryptedMessage, key: Data) throws -> Data {
        let symmetricKey = SymmetricKey(data: key)

        guard let aesNonce = try? AES.GCM.Nonce(data: message.nonce) else {
            throw RatchetError.invalidNonce
        }

        let sealedBox = try AES.GCM.SealedBox(
            nonce: aesNonce,
            ciphertext: message.ciphertext,
            tag: message.tag
        )

        do {
            return try AES.GCM.open(sealedBox, using: symmetricKey)
        } catch {
            throw RatchetError.decryptionFailed
        }
    }

    /// Skip messages by storing their keys for later retrieval.
    private static func skipMessages(
        until targetNumber: UInt32,
        state: inout DoubleRatchetState,
        skippedKeys: inout SkippedMessageKeys
    ) throws {
        guard let remotePublicKey = state.remotePublicKey else { return }

        while state.receivingMessageNumber < targetNumber {
            if let messageKey = state.advanceReceivingChain() {
                skippedKeys.store(
                    publicKey: remotePublicKey,
                    messageNumber: state.receivingMessageNumber - 1,
                    key: messageKey
                )
            }
        }
    }

    /// Derive a new receiving chain after DH ratchet step.
    private static func deriveReceivingChain(state: inout DoubleRatchetState) throws {
        guard let remotePublicKey = state.remotePublicKey else {
            throw RatchetError.missingKeys
        }

        // Compute new DH shared secret
        let remoteKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remotePublicKey)
        let dhSecret = try state.dhPrivateKey.sharedSecretFromKeyAgreement(with: remoteKey)
        let dhSecretData = dhSecret.withUnsafeBytes { Data($0) }

        // Derive new root key and receiving chain
        let inputKey = SymmetricKey(data: dhSecretData)
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: state.rootKey,
            info: chainKeyInfo,
            outputByteCount: 64
        )

        let derivedData = derived.withUnsafeBytes { Data($0) }
        state.setRootKey(Data(derivedData[0..<32]))
        state.setupReceivingChain(Data(derivedData[32..<64]))
    }
}

// MARK: - Encrypted Message

/// Encrypted message container with all data needed for decryption.
public struct EncryptedMessage: Codable, Sendable {
    /// Sender's current DH public key (for ratchet step detection)
    public let dhPublicKey: Data

    /// Message number in the current sending chain
    public let messageNumber: UInt32

    /// AES-GCM nonce (12 bytes)
    public let nonce: Data

    /// Encrypted message content
    public let ciphertext: Data

    /// AES-GCM authentication tag (16 bytes)
    public let tag: Data

    public init(
        dhPublicKey: Data,
        messageNumber: UInt32,
        nonce: Data,
        ciphertext: Data,
        tag: Data
    ) {
        self.dhPublicKey = dhPublicKey
        self.messageNumber = messageNumber
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.tag = tag
    }

    /// Total size in bytes
    public var totalSize: Int {
        dhPublicKey.count + 4 + nonce.count + ciphertext.count + tag.count
    }
}
