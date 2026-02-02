import Foundation
import CryptoKit

/// Result of generating a stealth address
public struct StealthAddressResult {
    /// The one-time stealth address (Solana base58 format)
    public let stealthAddress: String

    /// The stealth public key (32 bytes)
    public let stealthPublicKey: Data

    /// Ephemeral public key to include in transaction memo (32 bytes)
    public let ephemeralPublicKey: Data

    /// View tag (first byte of hashed secret) for fast filtering
    public let viewTag: UInt8

    /// MLKEM768 ciphertext for hybrid mode (1088 bytes)
    /// nil if classical-only mode was used
    public let mlkemCiphertext: Data?

    /// Ephemeral public key as base58 string (for memo)
    public var ephemeralPublicKeyString: String {
        ephemeralPublicKey.base58EncodedString
    }

    /// Whether this result was generated with post-quantum (hybrid) mode
    public var isHybrid: Bool {
        mlkemCiphertext != nil
    }

    /// Combined memo data for hybrid mode: R (32) || ciphertext (1088)
    /// Returns just ephemeralPublicKey for classical mode
    public var memoData: Data {
        if let ciphertext = mlkemCiphertext {
            return ephemeralPublicKey + ciphertext
        }
        return ephemeralPublicKey
    }
}

/// Generates stealth addresses from meta-addresses (sender-side operations).
///
/// The sender uses this to derive a one-time stealth address from
/// the receiver's stealth meta-address. The derivation follows EIP-5564
/// adapted for ed25519/Solana.
///
/// Supports both classical (X25519 only) and hybrid (X25519 + MLKEM768) modes.
public struct StealthAddressGenerator {

    /// Generate a stealth address from a receiver's meta-address string (classical mode)
    /// - Parameter metaAddressString: Base58-encoded stealth meta-address (64 bytes decoded)
    /// - Returns: StealthAddressResult containing address and ephemeral key
    /// - Throws: StealthError if generation fails
    public static func generateStealthAddress(
        metaAddressString: String
    ) throws -> StealthAddressResult {
        // 1. Parse meta-address to get public keys
        let (spendPubKey, viewPubKey) = try StealthKeyPair.parseMetaAddress(metaAddressString)

        return try generateStealthAddress(
            spendingPublicKey: spendPubKey,
            viewingPublicKey: viewPubKey
        )
    }

    /// Generate a stealth address with automatic mode detection
    /// Uses hybrid mode if MLKEM public key is present in meta-address
    /// - Parameter metaAddressString: Base58-encoded meta-address (64 or 1248 bytes decoded)
    /// - Returns: StealthAddressResult with appropriate mode
    /// - Throws: StealthError if generation fails
    public static func generateStealthAddressAuto(
        metaAddressString: String
    ) throws -> StealthAddressResult {
        let (spendPubKey, viewPubKey, mlkemPubKey) = try StealthKeyPair.parseHybridMetaAddress(metaAddressString)

        if let mlkemPub = mlkemPubKey {
            return try generateHybridStealthAddress(
                spendingPublicKey: spendPubKey,
                viewingPublicKey: viewPubKey,
                mlkemPublicKey: mlkemPub
            )
        } else {
            return try generateStealthAddress(
                spendingPublicKey: spendPubKey,
                viewingPublicKey: viewPubKey
            )
        }
    }

    /// Generate a stealth address from parsed public keys
    /// - Parameters:
    ///   - spendingPublicKey: Receiver's ed25519 spending public key M (32 bytes)
    ///   - viewingPublicKey: Receiver's X25519 viewing public key V (32 bytes)
    /// - Returns: StealthAddressResult
    /// - Throws: StealthError if generation fails
    public static func generateStealthAddress(
        spendingPublicKey: Data,
        viewingPublicKey: Data
    ) throws -> StealthAddressResult {
        // Validate input lengths
        guard spendingPublicKey.count == 32, viewingPublicKey.count == 32 else {
            throw StealthError.invalidMetaAddress
        }

        // 2. Generate ephemeral X25519 keypair (r, R)
        let ephemeralPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let ephemeralPublicKey = Data(ephemeralPrivateKey.publicKey.rawRepresentation)

        // 3. Compute shared secret: S = X25519(r, V)
        let viewKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: viewingPublicKey)
        let sharedSecret = try ephemeralPrivateKey.sharedSecretFromKeyAgreement(with: viewKey)
        let sharedSecretData = sharedSecret.withUnsafeBytes { Data($0) }

        // 4. Hash shared secret: s_h = SHA256(S)
        let sharedSecretHash = Data(SHA256.hash(data: sharedSecretData))

        // 5. View tag = first byte of hash (for fast filtering)
        let viewTag = sharedSecretHash[0]

        // 6. Reduce hash to valid scalar (SHA-256 output can be > L)
        guard let reducedHash = SodiumWrapper.scalarReduce32(sharedSecretHash) else {
            throw StealthError.keyDerivationFailed
        }

        // 7. Compute hash * G (scalar multiplication of reduced hash with base point)
        guard let hashPoint = SodiumWrapper.scalarMultBaseNoclamp(reducedHash) else {
            throw StealthError.keyDerivationFailed
        }

        // 7. Compute stealth pubkey: P_stealth = M + hash(S)*G (point addition)
        guard let stealthPubKey = SodiumWrapper.pointAdd(spendingPublicKey, hashPoint) else {
            throw StealthError.pointAdditionFailed
        }

        // 8. Validate result is on curve
        guard SodiumWrapper.isValidPoint(stealthPubKey) else {
            throw StealthError.pointAdditionFailed
        }

        // 9. Encode as Solana address (base58 of raw ed25519 pubkey)
        let stealthAddress = stealthPubKey.base58EncodedString

        return StealthAddressResult(
            stealthAddress: stealthAddress,
            stealthPublicKey: stealthPubKey,
            ephemeralPublicKey: ephemeralPublicKey,
            viewTag: viewTag,
            mlkemCiphertext: nil
        )
    }

    /// Generate a hybrid stealth address using X25519 + MLKEM768
    /// Combined secret: S = SHA256(S_classical || S_kyber)
    /// - Parameters:
    ///   - spendingPublicKey: Receiver's ed25519 spending public key M (32 bytes)
    ///   - viewingPublicKey: Receiver's X25519 viewing public key V (32 bytes)
    ///   - mlkemPublicKey: Receiver's MLKEM768 public key K (1184 bytes)
    /// - Returns: StealthAddressResult with MLKEM ciphertext
    /// - Throws: StealthError if generation fails
    public static func generateHybridStealthAddress(
        spendingPublicKey: Data,
        viewingPublicKey: Data,
        mlkemPublicKey: Data
    ) throws -> StealthAddressResult {
        // Validate input lengths
        guard spendingPublicKey.count == 32,
              viewingPublicKey.count == 32,
              mlkemPublicKey.count == MLKEMWrapper.publicKeyBytes else {
            throw StealthError.invalidMetaAddress
        }

        // 1. Generate ephemeral X25519 keypair (r, R)
        let ephemeralPrivateKey = Curve25519.KeyAgreement.PrivateKey()
        let ephemeralPublicKey = Data(ephemeralPrivateKey.publicKey.rawRepresentation)

        // 2. Compute classical shared secret: S_classical = X25519(r, V)
        let viewKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: viewingPublicKey)
        let classicalSecret = try ephemeralPrivateKey.sharedSecretFromKeyAgreement(with: viewKey)
        let classicalSecretData = classicalSecret.withUnsafeBytes { Data($0) }

        // 3. MLKEM768 encapsulation: (ciphertext, S_kyber) = Encaps(K)
        let (mlkemCiphertext, kyberSecret) = try MLKEMWrapper.encapsulate(publicKeyData: mlkemPublicKey)

        // 4. Combined shared secret: S = SHA256(S_classical || S_kyber)
        let combinedSecretInput = classicalSecretData + kyberSecret
        let combinedSecret = try SodiumWrapper.sha256(combinedSecretInput)

        // 5. Hash combined secret: s_h = SHA256(S)
        let sharedSecretHash = Data(SHA256.hash(data: combinedSecret))

        // 6. View tag = first byte of hash (for fast filtering)
        let viewTag = sharedSecretHash[0]

        // 7. Reduce hash to valid scalar (SHA-256 output can be > L)
        guard let reducedHash = SodiumWrapper.scalarReduce32(sharedSecretHash) else {
            throw StealthError.keyDerivationFailed
        }

        // 8. Compute hash * G (scalar multiplication of reduced hash with base point)
        guard let hashPoint = SodiumWrapper.scalarMultBaseNoclamp(reducedHash) else {
            throw StealthError.keyDerivationFailed
        }

        // 9. Compute stealth pubkey: P_stealth = M + hash(S)*G (point addition)
        guard let stealthPubKey = SodiumWrapper.pointAdd(spendingPublicKey, hashPoint) else {
            throw StealthError.pointAdditionFailed
        }

        // 10. Validate result is on curve
        guard SodiumWrapper.isValidPoint(stealthPubKey) else {
            throw StealthError.pointAdditionFailed
        }

        // 11. Encode as Solana address (base58 of raw ed25519 pubkey)
        let stealthAddress = stealthPubKey.base58EncodedString

        return StealthAddressResult(
            stealthAddress: stealthAddress,
            stealthPublicKey: stealthPubKey,
            ephemeralPublicKey: ephemeralPublicKey,
            viewTag: viewTag,
            mlkemCiphertext: mlkemCiphertext
        )
    }

    /// Verify a stealth address matches expected derivation (for testing/verification)
    /// - Parameters:
    ///   - stealthAddress: The stealth address to verify
    ///   - spendingPublicKey: Receiver's spending public key M
    ///   - viewingPublicKey: Receiver's viewing public key V
    ///   - ephemeralPublicKey: The ephemeral public key R used
    ///   - viewingPrivateKey: Receiver's viewing private key v (for computing shared secret)
    /// - Returns: true if the stealth address matches
    public static func verifyStealthAddress(
        stealthAddress: String,
        spendingPublicKey: Data,
        viewingPublicKey: Data,
        ephemeralPublicKey: Data,
        viewingPrivateKey: Data
    ) throws -> Bool {
        // Recompute using receiver's viewing key
        let viewKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: viewingPrivateKey)
        let ephemeralKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephemeralPublicKey)

        // Compute shared secret: S = v * R
        let sharedSecret = try viewKey.sharedSecretFromKeyAgreement(with: ephemeralKey)
        let sharedSecretData = sharedSecret.withUnsafeBytes { Data($0) }

        // Hash: s_h = SHA256(S)
        let hashData = Data(SHA256.hash(data: sharedSecretData))

        // Reduce hash to valid scalar (SHA-256 output can be > L)
        guard let reducedHash = SodiumWrapper.scalarReduce32(hashData) else {
            return false
        }

        // Compute hash * G
        guard let hashPoint = SodiumWrapper.scalarMultBaseNoclamp(reducedHash) else {
            return false
        }

        // Compute expected pubkey: P' = M + hash(S)*G
        guard let expectedPubKey = SodiumWrapper.pointAdd(spendingPublicKey, hashPoint) else {
            return false
        }

        // Encode and compare
        let expectedAddress = expectedPubKey.base58EncodedString
        return stealthAddress == expectedAddress
    }

    /// Compute the view tag for a given ephemeral key and viewing key
    /// Used for quick filtering during scanning
    /// - Parameters:
    ///   - ephemeralPublicKey: Sender's ephemeral public key R
    ///   - viewingPrivateKey: Receiver's viewing private key v
    /// - Returns: View tag (first byte of hashed shared secret)
    public static func computeViewTag(
        ephemeralPublicKey: Data,
        viewingPrivateKey: Data
    ) throws -> UInt8 {
        let viewKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: viewingPrivateKey)
        let ephemeralKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephemeralPublicKey)

        let sharedSecret = try viewKey.sharedSecretFromKeyAgreement(with: ephemeralKey)
        let sharedSecretData = sharedSecret.withUnsafeBytes { Data($0) }

        let hashData = Data(SHA256.hash(data: sharedSecretData))
        return hashData[0]
    }
}
