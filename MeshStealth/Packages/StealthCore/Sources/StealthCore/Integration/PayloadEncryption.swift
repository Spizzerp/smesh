import Foundation
import CryptoKit

/// Encrypted mesh payload for secure transmission over BLE
/// Uses X25519 ECDH + AES-256-GCM for authenticated encryption
public struct EncryptedMeshPayload: Codable, Sendable, Equatable {
    /// Ephemeral X25519 public key for ECDH (32 bytes)
    public let ephemeralPublicKey: Data

    /// AES-GCM nonce (12 bytes)
    public let nonce: Data

    /// Encrypted payload ciphertext
    public let ciphertext: Data

    /// AES-GCM authentication tag (16 bytes)
    public let tag: Data

    public init(
        ephemeralPublicKey: Data,
        nonce: Data,
        ciphertext: Data,
        tag: Data
    ) {
        self.ephemeralPublicKey = ephemeralPublicKey
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.tag = tag
    }

    /// Total size of encrypted payload
    public var totalSize: Int {
        ephemeralPublicKey.count + nonce.count + ciphertext.count + tag.count
    }

    /// Serialize for transmission
    public func serialize() throws -> Data {
        let encoder = JSONEncoder()
        return try encoder.encode(self)
    }

    /// Deserialize from received data
    public static func deserialize(from data: Data) throws -> EncryptedMeshPayload {
        let decoder = JSONDecoder()
        return try decoder.decode(EncryptedMeshPayload.self, from: data)
    }
}

/// Service for encrypting and decrypting mesh payloads
public struct PayloadEncryptionService: Sendable {

    public init() {}

    // MARK: - Encryption

    /// Encrypt a mesh stealth payload for a recipient
    /// - Parameters:
    ///   - payload: The stealth payload to encrypt
    ///   - recipientViewingKey: Recipient's X25519 public viewing key
    /// - Returns: Encrypted payload ready for mesh transmission
    public func encrypt(
        payload: MeshStealthPayload,
        recipientViewingKey: Data
    ) throws -> EncryptedMeshPayload {
        // Encode payload to JSON
        let encoder = JSONEncoder()
        let plaintext = try encoder.encode(payload)

        return try encryptData(plaintext, recipientViewingKey: recipientViewingKey)
    }

    /// Encrypt arbitrary data for a recipient
    /// - Parameters:
    ///   - data: Data to encrypt
    ///   - recipientViewingKey: Recipient's X25519 public viewing key (32 bytes)
    /// - Returns: Encrypted payload
    public func encryptData(
        _ data: Data,
        recipientViewingKey: Data
    ) throws -> EncryptedMeshPayload {
        guard recipientViewingKey.count == 32 else {
            throw PayloadEncryptionError.invalidKeySize(expected: 32, got: recipientViewingKey.count)
        }

        // Generate ephemeral X25519 keypair
        let ephemeralPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let ephemeralPublicKey = ephemeralPrivateKey.publicKey

        // Perform ECDH to derive shared secret
        let recipientKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientViewingKey)
        let sharedSecret = try ephemeralPrivateKey.sharedSecretFromKeyAgreement(with: recipientKey)

        // Derive AES key using HKDF
        let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("MeshStealth-v1".utf8),
            sharedInfo: Data("payload-encryption".utf8),
            outputByteCount: 32
        )

        // Generate random nonce
        var nonceBytes = [UInt8](repeating: 0, count: 12)
        let status = SecRandomCopyBytes(kSecRandomDefault, nonceBytes.count, &nonceBytes)
        guard status == errSecSuccess else {
            throw PayloadEncryptionError.randomGenerationFailed
        }
        let nonce = try AES.GCM.Nonce(data: Data(nonceBytes))

        // Encrypt with AES-256-GCM
        let sealedBox = try AES.GCM.seal(data, using: symmetricKey, nonce: nonce)

        return EncryptedMeshPayload(
            ephemeralPublicKey: ephemeralPublicKey.rawRepresentation,
            nonce: Data(nonceBytes),
            ciphertext: sealedBox.ciphertext,
            tag: sealedBox.tag
        )
    }

    // MARK: - Decryption

    /// Decrypt an encrypted mesh payload
    /// - Parameters:
    ///   - encrypted: The encrypted payload
    ///   - viewingPrivateKey: Recipient's X25519 private viewing key
    /// - Returns: Decrypted stealth payload
    public func decrypt(
        encrypted: EncryptedMeshPayload,
        viewingPrivateKey: Data
    ) throws -> MeshStealthPayload {
        let plaintext = try decryptData(encrypted, viewingPrivateKey: viewingPrivateKey)

        let decoder = JSONDecoder()
        return try decoder.decode(MeshStealthPayload.self, from: plaintext)
    }

    /// Decrypt arbitrary encrypted data
    /// - Parameters:
    ///   - encrypted: The encrypted payload
    ///   - viewingPrivateKey: Recipient's X25519 private viewing key (32 bytes)
    /// - Returns: Decrypted data
    public func decryptData(
        _ encrypted: EncryptedMeshPayload,
        viewingPrivateKey: Data
    ) throws -> Data {
        guard viewingPrivateKey.count == 32 else {
            throw PayloadEncryptionError.invalidKeySize(expected: 32, got: viewingPrivateKey.count)
        }

        guard encrypted.ephemeralPublicKey.count == 32 else {
            throw PayloadEncryptionError.invalidKeySize(expected: 32, got: encrypted.ephemeralPublicKey.count)
        }

        guard encrypted.nonce.count == 12 else {
            throw PayloadEncryptionError.invalidNonceSize(expected: 12, got: encrypted.nonce.count)
        }

        guard encrypted.tag.count == 16 else {
            throw PayloadEncryptionError.invalidTagSize(expected: 16, got: encrypted.tag.count)
        }

        // Reconstruct private key
        let privateKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: viewingPrivateKey)

        // Reconstruct ephemeral public key
        let ephemeralPublicKey = try Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: encrypted.ephemeralPublicKey
        )

        // Perform ECDH
        let sharedSecret = try privateKey.sharedSecretFromKeyAgreement(with: ephemeralPublicKey)

        // Derive same AES key using HKDF
        let symmetricKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("MeshStealth-v1".utf8),
            sharedInfo: Data("payload-encryption".utf8),
            outputByteCount: 32
        )

        // Reconstruct nonce
        let nonce = try AES.GCM.Nonce(data: encrypted.nonce)

        // Reconstruct sealed box
        let sealedBox = try AES.GCM.SealedBox(
            nonce: nonce,
            ciphertext: encrypted.ciphertext,
            tag: encrypted.tag
        )

        // Decrypt
        return try AES.GCM.open(sealedBox, using: symmetricKey)
    }

    // MARK: - Convenience

    /// Encrypt a mesh message (wraps payload encryption)
    public func encryptMessage(
        _ message: MeshMessage,
        recipientViewingKey: Data
    ) throws -> EncryptedMeshPayload {
        let messageData = try message.serialize()
        return try encryptData(messageData, recipientViewingKey: recipientViewingKey)
    }

    /// Decrypt a mesh message
    public func decryptMessage(
        _ encrypted: EncryptedMeshPayload,
        viewingPrivateKey: Data
    ) throws -> MeshMessage {
        let messageData = try decryptData(encrypted, viewingPrivateKey: viewingPrivateKey)
        return try MeshMessage.deserialize(from: messageData)
    }
}

// MARK: - Errors

/// Errors that can occur during payload encryption/decryption
public enum PayloadEncryptionError: Error, LocalizedError {
    case invalidKeySize(expected: Int, got: Int)
    case invalidNonceSize(expected: Int, got: Int)
    case invalidTagSize(expected: Int, got: Int)
    case randomGenerationFailed
    case encryptionFailed(Error)
    case decryptionFailed(Error)
    case invalidPayloadFormat

    public var errorDescription: String? {
        switch self {
        case .invalidKeySize(let expected, let got):
            return "Invalid key size: expected \(expected) bytes, got \(got)"
        case .invalidNonceSize(let expected, let got):
            return "Invalid nonce size: expected \(expected) bytes, got \(got)"
        case .invalidTagSize(let expected, let got):
            return "Invalid tag size: expected \(expected) bytes, got \(got)"
        case .randomGenerationFailed:
            return "Failed to generate random bytes"
        case .encryptionFailed(let error):
            return "Encryption failed: \(error.localizedDescription)"
        case .decryptionFailed(let error):
            return "Decryption failed: \(error.localizedDescription)"
        case .invalidPayloadFormat:
            return "Invalid encrypted payload format"
        }
    }
}
