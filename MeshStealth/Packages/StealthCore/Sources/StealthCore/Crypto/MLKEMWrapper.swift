import Foundation
import CryptoKit

/// Wrapper for CryptoKit's MLKEM768 post-quantum key encapsulation mechanism.
///
/// MLKEM768 (ML-KEM-768) is the NIST FIPS 203 standardized Module-Lattice
/// Key Encapsulation Mechanism providing NIST Level 3 security (~192-bit).
///
/// This wrapper provides a consistent API for the stealth protocol's hybrid
/// classical + post-quantum key exchange.
///
/// Key Sizes:
/// - Public Key: 1,184 bytes
/// - Private Key: ~2,400 bytes (serialized)
/// - Ciphertext: 1,088 bytes
/// - Shared Secret: 32 bytes
public struct MLKEMWrapper {

    // MARK: - Constants

    /// Size of MLKEM768 public key in bytes
    public static let publicKeyBytes = 1184

    /// Size of MLKEM768 ciphertext in bytes
    public static let ciphertextBytes = 1088

    /// Size of shared secret in bytes
    public static let sharedSecretBytes = 32

    // MARK: - Key Generation

    /// Generate a new MLKEM768 keypair
    /// - Returns: Tuple of (privateKey, publicKey)
    /// - Throws: CryptoKit error if generation fails
    public static func generateKeyPair() throws -> (privateKey: MLKEM768.PrivateKey, publicKey: MLKEM768.PublicKey) {
        let privateKey = try MLKEM768.PrivateKey()
        return (privateKey, privateKey.publicKey)
    }

    /// Generate a new MLKEM768 keypair and return raw bytes
    /// - Returns: Tuple of (privateKeyData, publicKeyData)
    /// - Throws: CryptoKit error if generation fails
    public static func generateKeyPairData() throws -> (privateKey: Data, publicKey: Data) {
        let privateKey = try MLKEM768.PrivateKey()
        let publicKey = privateKey.publicKey

        // Use integrityCheckedRepresentation for private key, rawRepresentation for public key
        let privateKeyData = Data(privateKey.integrityCheckedRepresentation)
        let publicKeyData = Data(publicKey.rawRepresentation)

        return (privateKeyData, publicKeyData)
    }

    // MARK: - Encapsulation (Sender-side)

    /// Encapsulate a shared secret using the recipient's public key
    ///
    /// The sender uses this to generate a shared secret and ciphertext.
    /// The ciphertext is sent to the recipient who can decapsulate it
    /// using their private key to recover the same shared secret.
    ///
    /// - Parameter publicKey: Recipient's MLKEM768 public key
    /// - Returns: Tuple of (ciphertext, sharedSecret)
    /// - Throws: CryptoKit error if encapsulation fails
    public static func encapsulate(publicKey: MLKEM768.PublicKey) throws -> (ciphertext: Data, sharedSecret: Data) {
        let result = try publicKey.encapsulate()
        // Convert ciphertext and shared secret to Data
        let ciphertextData = Data(result.encapsulated)
        // SharedSecret needs to be converted via withUnsafeBytes
        let sharedSecretData = result.sharedSecret.withUnsafeBytes { Data($0) }
        return (ciphertextData, sharedSecretData)
    }

    /// Encapsulate using raw public key bytes
    /// - Parameter publicKeyData: 1,184-byte public key
    /// - Returns: Tuple of (ciphertext, sharedSecret)
    /// - Throws: StealthError if public key is invalid or encapsulation fails
    public static func encapsulate(publicKeyData: Data) throws -> (ciphertext: Data, sharedSecret: Data) {
        guard publicKeyData.count == publicKeyBytes else {
            throw StealthError.invalidMLKEMPublicKey
        }

        let publicKey = try MLKEM768.PublicKey(rawRepresentation: publicKeyData)
        return try encapsulate(publicKey: publicKey)
    }

    // MARK: - Decapsulation (Receiver-side)

    /// Decapsulate to recover the shared secret
    ///
    /// The recipient uses this with their private key to recover the
    /// shared secret from the ciphertext sent by the sender.
    ///
    /// - Parameters:
    ///   - encapsulated: The encapsulated ciphertext from encapsulation (1,088 bytes)
    ///   - privateKey: Recipient's MLKEM768 private key
    /// - Returns: The shared secret (32 bytes)
    /// - Throws: Error if decapsulation fails
    public static func decapsulate(
        encapsulated: Data,
        privateKey: MLKEM768.PrivateKey
    ) throws -> Data {
        let sharedSecret = try privateKey.decapsulate(encapsulated)
        return sharedSecret.withUnsafeBytes { Data($0) }
    }

    /// Decapsulate using raw key bytes
    /// - Parameters:
    ///   - ciphertextData: 1,088-byte ciphertext
    ///   - privateKeyData: Private key data (from dataRepresentation)
    /// - Returns: 32-byte shared secret
    /// - Throws: StealthError if decapsulation fails
    public static func decapsulate(
        ciphertextData: Data,
        privateKeyData: Data
    ) throws -> Data {
        guard ciphertextData.count == ciphertextBytes else {
            throw StealthError.invalidMLKEMCiphertext
        }

        // Private keys use integrityCheckedRepresentation for restoration
        let privateKey = try MLKEM768.PrivateKey(integrityCheckedRepresentation: privateKeyData)
        return try decapsulate(encapsulated: ciphertextData, privateKey: privateKey)
    }

    // MARK: - Key Restoration

    /// Restore a private key from serialized data
    /// - Parameter data: Private key data (from dataRepresentation)
    /// - Returns: MLKEM768.PrivateKey or nil if invalid
    public static func restorePrivateKey(from data: Data) -> MLKEM768.PrivateKey? {
        return try? MLKEM768.PrivateKey(integrityCheckedRepresentation: data)
    }

    /// Restore a public key from raw bytes
    /// - Parameter data: 1,184-byte public key data
    /// - Returns: MLKEM768.PublicKey or nil if invalid
    public static func restorePublicKey(from data: Data) -> MLKEM768.PublicKey? {
        guard data.count == publicKeyBytes else {
            return nil
        }
        return try? MLKEM768.PublicKey(rawRepresentation: data)
    }

    // MARK: - Validation

    /// Validate that data could be a valid MLKEM768 public key
    /// - Parameter data: Data to validate
    /// - Returns: true if the data has correct size and can be parsed as a public key
    public static func isValidPublicKey(_ data: Data) -> Bool {
        guard data.count == publicKeyBytes else {
            return false
        }
        return (try? MLKEM768.PublicKey(rawRepresentation: data)) != nil
    }

    /// Validate that data could be a valid MLKEM768 ciphertext
    /// - Parameter data: Data to validate
    /// - Returns: true if the data has correct size
    public static func isValidCiphertext(_ data: Data) -> Bool {
        return data.count == ciphertextBytes
    }
}
