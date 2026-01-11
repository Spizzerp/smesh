import Foundation
import CryptoKit

/// SLIP-0010 ed25519 HD key derivation
/// Reference: https://github.com/satoshilabs/slips/blob/master/slip-0010.md
///
/// Unlike BIP-32 (secp256k1), ed25519 only supports hardened derivation.
/// Solana uses the derivation path: m/44'/501'/0'/0' (all hardened)
public struct SLIP0010: Sendable {

    /// The curve identifier used for HMAC key
    private static let ed25519Curve = "ed25519 seed"

    /// Hardened key offset (0x80000000)
    public static let hardenedOffset: UInt32 = 0x80000000

    // MARK: - Errors

    public enum Error: Swift.Error, LocalizedError {
        case invalidPath
        case invalidSeed
        case derivationFailed

        public var errorDescription: String? {
            switch self {
            case .invalidPath:
                return "Invalid derivation path"
            case .invalidSeed:
                return "Invalid seed data"
            case .derivationFailed:
                return "Key derivation failed"
            }
        }
    }

    // MARK: - Key Structure

    /// HD key with private key and chain code
    public struct HDKey: Sendable {
        /// 32-byte private key (ed25519 seed)
        public let key: Data
        /// 32-byte chain code
        public let chainCode: Data

        public init(key: Data, chainCode: Data) {
            self.key = key
            self.chainCode = chainCode
        }
    }

    // MARK: - Master Key Derivation

    /// Derive master key from BIP-39 seed
    /// - Parameter seed: 64-byte seed from BIP-39 mnemonic
    /// - Returns: Master HDKey
    public static func masterKey(seed: Data) throws -> HDKey {
        guard seed.count >= 16 else {
            throw Error.invalidSeed
        }

        let key = SymmetricKey(data: ed25519Curve.data(using: .utf8)!)
        let hmac = HMAC<SHA512>.authenticationCode(for: seed, using: key)
        let data = Data(hmac)

        return HDKey(
            key: data.prefixData(32),
            chainCode: data.suffixData(32)
        )
    }

    // MARK: - Child Key Derivation

    /// Derive child key at index (hardened only for ed25519)
    /// - Parameters:
    ///   - parent: Parent HDKey
    ///   - index: Child index (will be hardened automatically)
    /// - Returns: Child HDKey
    public static func deriveChild(parent: HDKey, index: UInt32) -> HDKey {
        // ed25519 only supports hardened derivation
        let hardenedIndex = index | hardenedOffset

        // Data = 0x00 || parent_key || index
        var data = Data([0x00])
        data.append(parent.key)
        data.append(hardenedIndex.bigEndianData)

        let key = SymmetricKey(data: parent.chainCode)
        let hmac = HMAC<SHA512>.authenticationCode(for: data, using: key)
        let result = Data(hmac)

        return HDKey(
            key: result.prefixData(32),
            chainCode: result.suffixData(32)
        )
    }

    // MARK: - Path Derivation

    /// Derive key at path (e.g., "m/44'/501'/0'/0'")
    /// - Parameters:
    ///   - path: BIP-44 style derivation path
    ///   - seed: 64-byte BIP-39 seed
    /// - Returns: Derived private key (32 bytes)
    public static func derivePath(_ path: String, seed: Data) throws -> Data {
        let hdKey = try deriveHDKey(path: path, seed: seed)
        return hdKey.key
    }

    /// Derive HDKey at path (includes chain code)
    /// - Parameters:
    ///   - path: BIP-44 style derivation path
    ///   - seed: 64-byte BIP-39 seed
    /// - Returns: Derived HDKey
    public static func deriveHDKey(path: String, seed: Data) throws -> HDKey {
        let indices = try parsePath(path)

        var current = try masterKey(seed: seed)

        for index in indices {
            current = deriveChild(parent: current, index: index)
        }

        return current
    }

    // MARK: - Path Parsing

    /// Parse a derivation path string into indices
    /// - Parameter path: Path like "m/44'/501'/0'/0'"
    /// - Returns: Array of indices (without hardened offset)
    public static func parsePath(_ path: String) throws -> [UInt32] {
        let normalized = path.trimmingCharacters(in: .whitespaces)

        // Must start with "m" or "m/"
        guard normalized.hasPrefix("m") else {
            throw Error.invalidPath
        }

        // Handle "m" alone (master key)
        if normalized == "m" {
            return []
        }

        // Remove "m/" prefix
        let pathWithoutM = normalized.hasPrefix("m/")
            ? String(normalized.dropFirst(2))
            : String(normalized.dropFirst())

        // Split by "/"
        let components = pathWithoutM.split(separator: "/")

        var indices: [UInt32] = []

        for component in components {
            let str = String(component)

            // Check for hardened marker
            let isHardened = str.hasSuffix("'") || str.hasSuffix("h") || str.hasSuffix("H")
            let indexStr = isHardened ? String(str.dropLast()) : str

            guard let index = UInt32(indexStr) else {
                throw Error.invalidPath
            }

            // For ed25519, all derivation is hardened, but we store the base index
            // The deriveChild function will add the hardened offset
            indices.append(index)
        }

        return indices
    }

    // MARK: - Solana-Specific

    /// Standard Solana derivation path
    public static let solanaPaths = SolanaPaths()

    public struct SolanaPaths: Sendable {
        /// Standard Solana wallet path: m/44'/501'/0'/0'
        public let standard = "m/44'/501'/0'/0'"

        /// Derive path for account at index: m/44'/501'/account'/0'
        public func account(_ index: UInt32) -> String {
            "m/44'/501'/\(index)'/0'"
        }

        /// Derive path for address at account and address index: m/44'/501'/account'/address'
        public func address(account: UInt32, address: UInt32) -> String {
            "m/44'/501'/\(account)'/\(address)'"
        }
    }

    /// Derive Solana wallet key from seed using standard path
    /// - Parameter seed: 64-byte BIP-39 seed
    /// - Returns: 32-byte ed25519 private key
    public static func deriveSolanaKey(seed: Data) throws -> Data {
        try derivePath(solanaPaths.standard, seed: seed)
    }

    /// Derive Solana wallet key for specific account
    /// - Parameters:
    ///   - seed: 64-byte BIP-39 seed
    ///   - account: Account index
    /// - Returns: 32-byte ed25519 private key
    public static func deriveSolanaKey(seed: Data, account: UInt32) throws -> Data {
        try derivePath(solanaPaths.account(account), seed: seed)
    }
}

// MARK: - Extensions

extension UInt32 {
    /// Convert to big-endian Data (4 bytes)
    var bigEndianData: Data {
        var value = self.bigEndian
        return Data(bytes: &value, count: 4)
    }
}

extension Data {
    /// First n bytes as Data
    func prefixData(_ maxLength: Int) -> Data {
        Data(self.prefix(maxLength))
    }

    /// Last n bytes as Data
    func suffixData(_ maxLength: Int) -> Data {
        Data(self.suffix(maxLength))
    }
}
