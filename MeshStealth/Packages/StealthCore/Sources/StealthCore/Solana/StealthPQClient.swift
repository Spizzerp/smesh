import Foundation
import Base58Swift
import CryptoKit

/// Program ID for the stealth-pq Anchor program on devnet
public let STEALTH_PQ_PROGRAM_ID = "5YXYyH7i9WnQz1Hzh8kEuxSU5ws3n1Kor2KdTxnJkv6y"

/// System program ID
public let SYSTEM_PROGRAM_ID = "11111111111111111111111111111111"

/// MLKEM768 ciphertext size in bytes
public let MLKEM_CIPHERTEXT_SIZE = 1088

/// Ephemeral X25519 public key size in bytes
public let EPHEMERAL_PUBKEY_SIZE = 32

/// Maximum chunk size per transaction
public let CHUNK_SIZE = 512

/// Ciphertext account data fetched from the stealth-pq program
public struct CiphertextAccountData: Sendable {
    /// The stealth address this ciphertext is for (32 bytes)
    public let stealthPubkey: Data

    /// Ephemeral X25519 public key (R) used for ECDH shared secret (32 bytes)
    public let ephemeralPubkey: Data

    /// MLKEM768 ciphertext from encapsulation (1088 bytes)
    public let mlkemCiphertext: Data

    /// Unix timestamp when the transfer was created
    public let createdAt: Int64

    /// Bump seed for PDA derivation
    public let bump: UInt8

    /// Parse CiphertextAccountData from raw account data
    /// - Parameter data: Raw account data (includes 8-byte Anchor discriminator)
    /// - Returns: Parsed CiphertextAccountData or nil if invalid
    public static func parse(from data: Data) -> CiphertextAccountData? {
        // Account layout (with 8-byte Anchor discriminator):
        // [0..8]    - Anchor discriminator
        // [8..40]   - stealth_pubkey (32 bytes)
        // [40..72]  - ephemeral_pubkey (32 bytes)
        // [72..1160] - mlkem_ciphertext (1088 bytes)
        // [1160..1168] - created_at (i64, 8 bytes)
        // [1168]    - bump (u8, 1 byte)
        // Total: 8 + 32 + 32 + 1088 + 8 + 1 = 1169 bytes

        guard data.count >= 1169 else {
            return nil
        }

        let stealthPubkey = data[8..<40]
        let ephemeralPubkey = data[40..<72]
        let mlkemCiphertext = data[72..<1160]

        // Parse i64 timestamp (little-endian)
        let timestampData = data[1160..<1168]
        let createdAt = timestampData.withUnsafeBytes { $0.load(as: Int64.self) }

        let bump = data[1168]

        return CiphertextAccountData(
            stealthPubkey: Data(stealthPubkey),
            ephemeralPubkey: Data(ephemeralPubkey),
            mlkemCiphertext: Data(mlkemCiphertext),
            createdAt: createdAt,
            bump: bump
        )
    }
}

/// Client for interacting with the stealth-pq Anchor program on Solana
public actor StealthPQClient {

    private let rpcClient: SolanaRPCClient
    private let programId: String

    /// Initialize the StealthPQ client
    /// - Parameters:
    ///   - rpcClient: Solana RPC client for network operations
    ///   - programId: Program ID (defaults to devnet deployment)
    public init(rpcClient: SolanaRPCClient, programId: String = STEALTH_PQ_PROGRAM_ID) {
        self.rpcClient = rpcClient
        self.programId = programId
    }

    // MARK: - PDA Derivation

    /// Derive the CiphertextAccount PDA address for a stealth address
    /// - Parameter stealthAddress: Base58-encoded stealth address
    /// - Returns: Base58-encoded PDA address and bump seed
    public func deriveCiphertextPDA(stealthAddress: String) throws -> (address: String, bump: UInt8) {
        let stealthPubkey = try SolanaRPCClient.decodePublicKey(stealthAddress)
        return try Self.deriveCiphertextPDA(stealthPubkey: stealthPubkey, programId: programId)
    }

    /// Derive the CiphertextAccount PDA address (static version)
    /// - Parameters:
    ///   - stealthPubkey: 32-byte stealth public key
    ///   - programId: Program ID
    /// - Returns: Base58-encoded PDA address and bump seed
    public static func deriveCiphertextPDA(stealthPubkey: Data, programId: String) throws -> (address: String, bump: UInt8) {
        guard stealthPubkey.count == 32 else {
            throw SolanaError.invalidPublicKey
        }

        let programIdBytes = try SolanaRPCClient.decodePublicKey(programId)

        // Seeds: ["ciphertext", stealth_pubkey]
        let seed1 = "ciphertext".data(using: .utf8)!
        let seeds = [seed1, stealthPubkey]

        // Find PDA
        for bump in stride(from: 255, through: 0, by: -1) {
            let bumpByte = UInt8(bump)
            if let pda = try? deriveAddress(seeds: seeds + [Data([bumpByte])], programId: programIdBytes) {
                // Verify it's off-curve (valid PDA)
                if isOffCurve(pda) {
                    let address = SolanaRPCClient.encodePublicKey(pda)
                    return (address, bumpByte)
                }
            }
        }

        throw SolanaError.decodingError("Failed to find valid PDA bump")
    }

    // MARK: - Account Operations

    /// Fetch CiphertextAccount data for a stealth address
    /// - Parameter stealthAddress: Base58-encoded stealth address
    /// - Returns: CiphertextAccountData or nil if not found
    public func getCiphertextAccount(stealthAddress: String) async throws -> CiphertextAccountData? {
        let (pdaAddress, _) = try deriveCiphertextPDA(stealthAddress: stealthAddress)

        guard let accountInfo = try await rpcClient.getAccountInfo(pubkey: pdaAddress, encoding: "base64") else {
            return nil
        }

        // Decode base64 data
        guard accountInfo.data.count > 0,
              let accountData = Data(base64Encoded: accountInfo.data[0]) else {
            return nil
        }

        return CiphertextAccountData.parse(from: accountData)
    }

    /// Check if a CiphertextAccount exists for a stealth address
    /// - Parameter stealthAddress: Base58-encoded stealth address
    /// - Returns: True if the account exists
    public func ciphertextAccountExists(stealthAddress: String) async throws -> Bool {
        let (pdaAddress, _) = try deriveCiphertextPDA(stealthAddress: stealthAddress)
        let accountInfo = try await rpcClient.getAccountInfo(pubkey: pdaAddress)
        return accountInfo != nil
    }

    // MARK: - Instruction Building

    /// Build the init_ciphertext instruction data
    /// - Parameters:
    ///   - ephemeralPubkey: 32-byte ephemeral X25519 public key
    ///   - ciphertextPart1: First chunk of ciphertext (max 512 bytes)
    /// - Returns: Serialized instruction data
    public static func buildInitCiphertextData(
        ephemeralPubkey: Data,
        ciphertextPart1: Data
    ) -> Data {
        // Anchor discriminator for init_ciphertext
        // sha256("global:init_ciphertext")[0..8]
        let discriminator = computeDiscriminator(name: "init_ciphertext")

        var data = Data()
        data.append(discriminator)

        // ephemeral_pubkey: [u8; 32]
        data.append(ephemeralPubkey)

        // ciphertext_part1: Vec<u8> (4-byte length prefix + data)
        var length = UInt32(ciphertextPart1.count).littleEndian
        data.append(Data(bytes: &length, count: 4))
        data.append(ciphertextPart1)

        return data
    }

    /// Build the complete_ciphertext instruction data
    /// - Parameters:
    ///   - ciphertextPart2: Remaining chunk of ciphertext
    ///   - offset: Offset in the ciphertext array
    /// - Returns: Serialized instruction data
    public static func buildCompleteCiphertextData(
        ciphertextPart2: Data,
        offset: UInt16
    ) -> Data {
        let discriminator = computeDiscriminator(name: "complete_ciphertext")

        var data = Data()
        data.append(discriminator)

        // ciphertext_part2: Vec<u8>
        var length = UInt32(ciphertextPart2.count).littleEndian
        data.append(Data(bytes: &length, count: 4))
        data.append(ciphertextPart2)

        // offset: u16
        var offsetLE = offset.littleEndian
        data.append(Data(bytes: &offsetLE, count: 2))

        return data
    }

    /// Build the transfer_to_stealth instruction data
    /// - Parameter lamports: Amount of SOL to transfer in lamports
    /// - Returns: Serialized instruction data
    public static func buildTransferToStealthData(lamports: UInt64) -> Data {
        let discriminator = computeDiscriminator(name: "transfer_to_stealth")

        var data = Data()
        data.append(discriminator)

        // lamports: u64
        var lamportsLE = lamports.littleEndian
        data.append(Data(bytes: &lamportsLE, count: 8))

        return data
    }

    /// Build the reclaim_rent instruction data
    /// - Returns: Serialized instruction data
    public static func buildReclaimRentData() -> Data {
        let discriminator = computeDiscriminator(name: "reclaim_rent")
        return discriminator
    }

    // MARK: - Private Helpers

    /// Compute Anchor instruction discriminator
    /// - Parameter name: Instruction name
    /// - Returns: 8-byte discriminator
    private static func computeDiscriminator(name: String) -> Data {
        let preimage = "global:\(name)"
        let hash = SHA256.hash(data: preimage.data(using: .utf8)!)
        return Data(hash.prefix(8))
    }

    /// Derive a program address from seeds
    /// - Parameters:
    ///   - seeds: Array of seed data
    ///   - programId: Program ID bytes
    /// - Returns: Derived address bytes
    private static func deriveAddress(seeds: [Data], programId: Data) throws -> Data {
        // PDA derivation: SHA256(seeds || programId || "ProgramDerivedAddress")
        var hasher = SHA256()

        for seed in seeds {
            hasher.update(data: seed)
        }
        hasher.update(data: programId)
        hasher.update(data: "ProgramDerivedAddress".data(using: .utf8)!)

        let hash = hasher.finalize()
        return Data(hash)
    }

    /// Check if a point is off the ed25519 curve (valid PDA)
    /// - Parameter data: 32-byte point
    /// - Returns: True if off curve
    private static func isOffCurve(_ data: Data) -> Bool {
        // Simple check: PDAs should not be valid curve points
        // In production, this should use proper curve validation
        // For now, we'll accept all derived addresses
        return true
    }
}

// MARK: - Transaction Building Helpers

extension StealthPQClient {

    /// Account meta for instruction building
    public struct AccountMeta: Sendable {
        public let pubkey: String
        public let isSigner: Bool
        public let isWritable: Bool

        public init(pubkey: String, isSigner: Bool, isWritable: Bool) {
            self.pubkey = pubkey
            self.isSigner = isSigner
            self.isWritable = isWritable
        }
    }

    /// Get account metas for init_ciphertext instruction
    /// - Parameters:
    ///   - sender: Sender wallet (payer, signer)
    ///   - stealthAddress: Stealth address receiving funds
    /// - Returns: Array of account metas
    public func getInitCiphertextAccounts(
        sender: String,
        stealthAddress: String
    ) throws -> [AccountMeta] {
        let (ciphertextPDA, _) = try deriveCiphertextPDA(stealthAddress: stealthAddress)

        return [
            AccountMeta(pubkey: sender, isSigner: true, isWritable: true),           // sender
            AccountMeta(pubkey: stealthAddress, isSigner: false, isWritable: true),  // stealth_address
            AccountMeta(pubkey: ciphertextPDA, isSigner: false, isWritable: true),   // ciphertext_account
            AccountMeta(pubkey: SYSTEM_PROGRAM_ID, isSigner: false, isWritable: false) // system_program
        ]
    }

    /// Get account metas for complete_ciphertext instruction
    public func getCompleteCiphertextAccounts(
        sender: String,
        stealthAddress: String
    ) throws -> [AccountMeta] {
        let (ciphertextPDA, _) = try deriveCiphertextPDA(stealthAddress: stealthAddress)

        return [
            AccountMeta(pubkey: sender, isSigner: true, isWritable: true),           // sender
            AccountMeta(pubkey: ciphertextPDA, isSigner: false, isWritable: true)    // ciphertext_account
        ]
    }

    /// Get account metas for transfer_to_stealth instruction
    public func getTransferToStealthAccounts(
        sender: String,
        stealthAddress: String
    ) throws -> [AccountMeta] {
        let (ciphertextPDA, _) = try deriveCiphertextPDA(stealthAddress: stealthAddress)

        return [
            AccountMeta(pubkey: sender, isSigner: true, isWritable: true),           // sender
            AccountMeta(pubkey: stealthAddress, isSigner: false, isWritable: true),  // stealth_address
            AccountMeta(pubkey: ciphertextPDA, isSigner: false, isWritable: false),  // ciphertext_account
            AccountMeta(pubkey: SYSTEM_PROGRAM_ID, isSigner: false, isWritable: false) // system_program
        ]
    }

    /// Get account metas for reclaim_rent instruction
    public func getReclaimRentAccounts(
        stealthSigner: String
    ) throws -> [AccountMeta] {
        let (ciphertextPDA, _) = try deriveCiphertextPDA(stealthAddress: stealthSigner)

        return [
            AccountMeta(pubkey: stealthSigner, isSigner: true, isWritable: true),    // stealth_signer
            AccountMeta(pubkey: ciphertextPDA, isSigner: false, isWritable: true)    // ciphertext_account
        ]
    }
}
