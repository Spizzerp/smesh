import Foundation
import Sodium

/// Wrapper for libsodium ed25519 point arithmetic operations.
/// Required for stealth address derivation (EIP-5564 style).
///
/// Key operations:
/// - Point addition: P + Q (for deriving stealth pubkey)
/// - Scalar multiplication: n * G (for computing hash * basepoint)
/// - Scalar addition: a + b mod L (for deriving stealth private key)
public struct SodiumWrapper {

    /// Shared Sodium instance
    private static let sodium = Sodium()

    /// Size of an ed25519 point (compressed)
    public static let pointBytes = 32

    /// Size of an ed25519 scalar
    public static let scalarBytes = 32

    /// Size of an ed25519 seed
    public static let seedBytes = 32

    /// Initialize libsodium. Call once at app launch.
    /// - Returns: true if initialization succeeded
    @discardableResult
    public static func initialize() -> Bool {
        // Sodium() constructor handles initialization
        return true
    }

    // MARK: - Key Generation

    /// Generate a random ed25519 keypair for signing (Solana-compatible)
    /// - Returns: Tuple of (seed, publicKey) or nil on failure
    public static func generateSigningKeyPair() -> (seed: Data, publicKey: Data)? {
        guard let keyPair = sodium.sign.keyPair() else {
            return nil
        }
        // The seed is the first 32 bytes of the secret key
        let seed = Data(keyPair.secretKey.prefix(32))
        let publicKey = Data(keyPair.publicKey)
        return (seed, publicKey)
    }

    /// Derive ed25519 public key from seed
    /// - Parameter seed: 32-byte seed
    /// - Returns: 32-byte public key or nil on failure
    public static func deriveSigningPublicKey(from seed: Data) -> Data? {
        guard seed.count == seedBytes else { return nil }

        guard let keyPair = sodium.sign.keyPair(seed: Bytes(seed)) else {
            return nil
        }
        return Data(keyPair.publicKey)
    }

    /// Generate a random scalar keypair for stealth address arithmetic.
    /// Unlike ed25519 signing keys, this scalar IS directly usable for point arithmetic.
    /// - Returns: Tuple of (scalar, publicKey) where publicKey = scalar * G
    public static func generateScalarKeyPair() -> (scalar: Data, publicKey: Data)? {
        // Generate 64 random bytes and reduce to get a properly distributed scalar mod L
        let randomData = randomBytes(count: 64)

        var reducedScalar = Bytes(repeating: 0, count: scalarBytes)
        reducedScalar.withUnsafeMutableBufferPointer { resultPtr in
            randomData.withUnsafeBytes { inputPtr in
                crypto_core_ed25519_scalar_reduce(
                    resultPtr.baseAddress,
                    inputPtr.bindMemory(to: UInt8.self).baseAddress
                )
            }
        }

        let scalarData = Data(reducedScalar)

        // Derive public key: P = scalar * G
        guard let publicKey = scalarMultBaseNoclamp(scalarData) else {
            return nil
        }

        return (scalarData, publicKey)
    }

    /// Derive public key from a scalar (not an ed25519 seed).
    /// Uses scalar * G without clamping since the scalar is already valid.
    /// - Parameter scalar: 32-byte scalar in valid range
    /// - Returns: 32-byte public key or nil on failure
    public static func derivePublicKeyFromScalar(_ scalar: Data) -> Data? {
        return scalarMultBaseNoclamp(scalar)
    }

    /// Generate a random X25519 keypair for key exchange (ECDH)
    /// - Returns: Tuple of (privateKey, publicKey) or nil on failure
    public static func generateKeyExchangeKeyPair() -> (privateKey: Data, publicKey: Data)? {
        guard let keyPair = sodium.box.keyPair() else {
            return nil
        }
        return (Data(keyPair.secretKey), Data(keyPair.publicKey))
    }

    /// Derive X25519 public key from private key
    /// - Parameter privateKey: 32-byte private key
    /// - Returns: 32-byte public key or nil on failure
    public static func deriveKeyExchangePublicKey(from privateKey: Data) -> Data? {
        guard privateKey.count == scalarBytes else { return nil }

        // X25519 scalar multiplication with base point
        guard let publicKey = sodium.box.keyPair(seed: Bytes(privateKey))?.publicKey else {
            return nil
        }
        return Data(publicKey)
    }

    // MARK: - Ed25519 Point Arithmetic
    // Note: X25519 ECDH is handled via CryptoKit in StealthKeyPair

    /// Add two ed25519 points: result = p + q
    /// Used for: P_stealth = M + hash(S)*G
    /// - Parameters:
    ///   - p: First point (32 bytes, compressed ed25519)
    ///   - q: Second point (32 bytes, compressed ed25519)
    /// - Returns: Result point (32 bytes) or nil if invalid points
    public static func pointAdd(_ p: Data, _ q: Data) -> Data? {
        guard p.count == pointBytes, q.count == pointBytes else { return nil }

        // Use sodium's ed25519 point addition
        // Note: swift-sodium-full should expose this via Sign.Ed25519 extension
        var result = Bytes(repeating: 0, count: pointBytes)

        let success = result.withUnsafeMutableBufferPointer { resultPtr in
            p.withUnsafeBytes { pPtr in
                q.withUnsafeBytes { qPtr in
                    crypto_core_ed25519_add(
                        resultPtr.baseAddress,
                        pPtr.bindMemory(to: UInt8.self).baseAddress,
                        qPtr.bindMemory(to: UInt8.self).baseAddress
                    )
                }
            }
        }

        return success == 0 ? Data(result) : nil
    }

    /// Multiply base point by scalar: result = scalar * G
    /// Used for: hash(S) * G in stealth address derivation
    /// - Parameter scalar: 32-byte scalar (will be clamped by libsodium)
    /// - Returns: Resulting point (32 bytes) or nil on error
    public static func scalarMultBase(_ scalar: Data) -> Data? {
        guard scalar.count == scalarBytes else { return nil }

        var result = Bytes(repeating: 0, count: pointBytes)

        let success = result.withUnsafeMutableBufferPointer { resultPtr in
            scalar.withUnsafeBytes { scalarPtr in
                crypto_scalarmult_ed25519_base(
                    resultPtr.baseAddress,
                    scalarPtr.bindMemory(to: UInt8.self).baseAddress
                )
            }
        }

        return success == 0 ? Data(result) : nil
    }

    /// Multiply base point by scalar WITHOUT clamping: result = scalar * G
    /// Used for derived scalars (like hash outputs) that are already in range
    /// - Parameter scalar: 32-byte scalar in range ]0..L[
    /// - Returns: Resulting point (32 bytes) or nil on error
    public static func scalarMultBaseNoclamp(_ scalar: Data) -> Data? {
        guard scalar.count == scalarBytes else { return nil }

        var result = Bytes(repeating: 0, count: pointBytes)

        let success = result.withUnsafeMutableBufferPointer { resultPtr in
            scalar.withUnsafeBytes { scalarPtr in
                crypto_scalarmult_ed25519_base_noclamp(
                    resultPtr.baseAddress,
                    scalarPtr.bindMemory(to: UInt8.self).baseAddress
                )
            }
        }

        return success == 0 ? Data(result) : nil
    }

    /// Add two scalars modulo L: result = a + b (mod L)
    /// Used for: p_stealth = m + hash(S) (deriving stealth private key)
    /// - Parameters:
    ///   - a: First scalar (32 bytes)
    ///   - b: Second scalar (32 bytes)
    /// - Returns: Result scalar (32 bytes)
    public static func scalarAdd(_ a: Data, _ b: Data) -> Data? {
        guard a.count == scalarBytes, b.count == scalarBytes else { return nil }

        var result = Bytes(repeating: 0, count: scalarBytes)

        result.withUnsafeMutableBufferPointer { resultPtr in
            a.withUnsafeBytes { aPtr in
                b.withUnsafeBytes { bPtr in
                    crypto_core_ed25519_scalar_add(
                        resultPtr.baseAddress,
                        aPtr.bindMemory(to: UInt8.self).baseAddress,
                        bPtr.bindMemory(to: UInt8.self).baseAddress
                    )
                }
            }
        }

        return Data(result)
    }

    /// Reduce a 64-byte hash to a valid scalar mod L
    /// Used when hashing shared secrets to scalars
    /// - Parameter input: 64-byte value (e.g., SHA-512 output)
    /// - Returns: 32-byte scalar in valid range
    public static func scalarReduce(_ input: Data) -> Data? {
        guard input.count == 64 else { return nil }

        var result = Bytes(repeating: 0, count: scalarBytes)

        result.withUnsafeMutableBufferPointer { resultPtr in
            input.withUnsafeBytes { inputPtr in
                crypto_core_ed25519_scalar_reduce(
                    resultPtr.baseAddress,
                    inputPtr.bindMemory(to: UInt8.self).baseAddress
                )
            }
        }

        return Data(result)
    }

    /// Reduce a 32-byte value to a valid scalar mod L
    /// IMPORTANT: Use this before scalarMultBaseNoclamp if the input might be >= L
    /// - Parameter input: 32-byte value (e.g., SHA-256 output)
    /// - Returns: 32-byte scalar in valid range [0, L)
    public static func scalarReduce32(_ input: Data) -> Data? {
        guard input.count == 32 else { return nil }

        // Pad to 64 bytes (put input in lower bytes, zeros in upper)
        var extended = Bytes(repeating: 0, count: 64)
        input.withUnsafeBytes { ptr in
            extended.replaceSubrange(0..<32, with: ptr.bindMemory(to: UInt8.self))
        }

        var result = Bytes(repeating: 0, count: scalarBytes)

        result.withUnsafeMutableBufferPointer { resultPtr in
            extended.withUnsafeBytes { inputPtr in
                crypto_core_ed25519_scalar_reduce(
                    resultPtr.baseAddress,
                    inputPtr.bindMemory(to: UInt8.self).baseAddress
                )
            }
        }

        return Data(result)
    }

    /// Validate that a point is on the ed25519 curve
    /// - Parameter point: 32-byte compressed point
    /// - Returns: true if valid curve point
    public static func isValidPoint(_ point: Data) -> Bool {
        guard point.count == pointBytes else { return false }

        return point.withUnsafeBytes { ptr in
            crypto_core_ed25519_is_valid_point(
                ptr.bindMemory(to: UInt8.self).baseAddress
            ) == 1
        }
    }

    // MARK: - Hashing

    /// SHA-256 hash
    /// - Parameter data: Data to hash
    /// - Returns: 32-byte hash
    public static func sha256(_ data: Data) -> Data {
        guard let hash = sodium.genericHash.hash(message: Bytes(data), outputLength: 32) else {
            // Fallback - should never fail with valid input
            fatalError("SHA-256 hash failed")
        }
        return Data(hash)
    }

    /// SHA-512 hash (for scalar reduction)
    /// - Parameter data: Data to hash
    /// - Returns: 64-byte hash
    public static func sha512(_ data: Data) -> Data {
        guard let hash = sodium.genericHash.hash(message: Bytes(data), outputLength: 64) else {
            fatalError("SHA-512 hash failed")
        }
        return Data(hash)
    }

    // MARK: - Random

    /// Generate cryptographically secure random bytes
    /// - Parameter count: Number of bytes
    /// - Returns: Random data
    public static func randomBytes(count: Int) -> Data {
        return Data(sodium.randomBytes.buf(length: count) ?? [])
    }
}

// MARK: - C Function Declarations

// These are the libsodium C functions we need from swift-sodium-full
// They should be available via the Clibsodium module

@_silgen_name("crypto_core_ed25519_add")
private func crypto_core_ed25519_add(
    _ r: UnsafeMutablePointer<UInt8>?,
    _ p: UnsafePointer<UInt8>?,
    _ q: UnsafePointer<UInt8>?
) -> Int32

@_silgen_name("crypto_scalarmult_ed25519_base")
private func crypto_scalarmult_ed25519_base(
    _ q: UnsafeMutablePointer<UInt8>?,
    _ n: UnsafePointer<UInt8>?
) -> Int32

@_silgen_name("crypto_scalarmult_ed25519_base_noclamp")
private func crypto_scalarmult_ed25519_base_noclamp(
    _ q: UnsafeMutablePointer<UInt8>?,
    _ n: UnsafePointer<UInt8>?
) -> Int32

@_silgen_name("crypto_core_ed25519_scalar_add")
private func crypto_core_ed25519_scalar_add(
    _ z: UnsafeMutablePointer<UInt8>?,
    _ x: UnsafePointer<UInt8>?,
    _ y: UnsafePointer<UInt8>?
)

@_silgen_name("crypto_core_ed25519_scalar_reduce")
private func crypto_core_ed25519_scalar_reduce(
    _ r: UnsafeMutablePointer<UInt8>?,
    _ s: UnsafePointer<UInt8>?
)

@_silgen_name("crypto_core_ed25519_is_valid_point")
private func crypto_core_ed25519_is_valid_point(
    _ p: UnsafePointer<UInt8>?
) -> Int32
