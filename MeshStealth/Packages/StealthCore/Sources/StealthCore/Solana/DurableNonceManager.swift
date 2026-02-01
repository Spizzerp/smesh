import Foundation

/// State of a nonce account in the pool
public enum NonceState: String, Codable, Sendable {
    case available   // Ready to be reserved for a transaction
    case reserved    // Currently reserved for an in-flight payment
    case consumed    // Used and needs replenishment
}

/// Entry representing a durable nonce account
public struct NonceEntry: Codable, Sendable, Identifiable {
    public var id: String { address }

    /// Base58-encoded nonce account address
    public let address: String

    /// Current nonce value (used as blockhash for durable transactions)
    public var nonceValue: String

    /// Authority pubkey (typically the main wallet)
    public let authority: String

    /// Current state
    public var state: NonceState

    /// When this nonce was last updated
    public var updatedAt: Date

    /// When this nonce was reserved (for timeout tracking)
    public var reservedAt: Date?

    public init(
        address: String,
        nonceValue: String,
        authority: String,
        state: NonceState = .available,
        updatedAt: Date = Date(),
        reservedAt: Date? = nil
    ) {
        self.address = address
        self.nonceValue = nonceValue
        self.authority = authority
        self.state = state
        self.updatedAt = updatedAt
        self.reservedAt = reservedAt
    }
}

/// Manages a pool of durable nonce accounts for pre-signed transactions
///
/// Durable nonces allow Solana transactions to remain valid indefinitely,
/// enabling "receiver settles" flow where the receiver can broadcast
/// a pre-signed transaction when they come online.
public actor DurableNonceManager {

    // MARK: - Configuration

    /// Target pool size (aim to maintain this many available nonces)
    public let targetPoolSize: Int

    /// Minimum balance required in nonce account (rent-exempt minimum)
    /// Approximately 0.00144768 SOL for a nonce account
    public static let nonceRentExemptMinimum: UInt64 = 1_447_680

    /// Reservation timeout (nonces reserved longer than this are released)
    public let reservationTimeout: TimeInterval

    // MARK: - State

    /// Pool of nonce accounts
    private var noncePool: [NonceEntry] = []

    /// RPC client for blockchain operations
    private let rpcClient: DevnetFaucet

    /// Storage key for persistence
    private let storageKey = "meshstealth.nonce_pool"
    private let userDefaults: UserDefaults

    // MARK: - Initialization

    public init(
        rpcClient: DevnetFaucet = DevnetFaucet(),
        userDefaults: UserDefaults = .standard,
        targetPoolSize: Int = 5,
        reservationTimeout: TimeInterval = 3600  // 1 hour
    ) {
        self.rpcClient = rpcClient
        self.userDefaults = userDefaults
        self.targetPoolSize = targetPoolSize
        self.reservationTimeout = reservationTimeout

        // Load pool synchronously from UserDefaults in init
        // This is safe because UserDefaults access is synchronous
        if let data = userDefaults.data(forKey: storageKey) {
            let decoder = JSONDecoder()
            if let loaded = try? decoder.decode([NonceEntry].self, from: data) {
                self.noncePool = loaded
            }
        }
    }

    /// Perform post-init setup (call after initialization)
    /// This releases stale reservations that may have been left over
    public func performPostInitSetup() {
        releaseStaleReservations()
    }

    // MARK: - Pool Management

    /// Reserve an available nonce for a payment
    /// - Returns: The reserved nonce entry
    /// - Throws: NonceError.poolEmpty if no nonces available
    public func reserveNonce() async throws -> NonceEntry {
        // First, release any stale reservations
        releaseStaleReservations()

        // Find an available nonce
        guard let index = noncePool.firstIndex(where: { $0.state == .available }) else {
            throw NonceError.poolEmpty
        }

        // Refresh the nonce value from chain to ensure it's current
        let entry = noncePool[index]
        do {
            let refreshedValue = try await fetchNonceValue(address: entry.address)
            noncePool[index].nonceValue = refreshedValue
        } catch {
            // Nonce account may have been consumed externally, mark it
            noncePool[index].state = .consumed
            savePool()
            throw NonceError.nonceRefreshFailed(entry.address)
        }

        // Mark as reserved
        noncePool[index].state = .reserved
        noncePool[index].reservedAt = Date()
        noncePool[index].updatedAt = Date()
        savePool()

        DebugLogger.log("[NONCE] Reserved nonce: \(entry.address)", category: "NONCE")
        return noncePool[index]
    }

    /// Mark a nonce as consumed after its transaction was broadcast
    /// - Parameter address: The nonce account address
    public func markConsumed(address: String) {
        guard let index = noncePool.firstIndex(where: { $0.address == address }) else {
            return
        }

        noncePool[index].state = .consumed
        noncePool[index].updatedAt = Date()
        noncePool[index].reservedAt = nil
        savePool()

        DebugLogger.log("[NONCE] Marked consumed: \(address)", category: "NONCE")
    }

    /// Release a reserved nonce back to available (e.g., if payment was cancelled)
    /// - Parameter address: The nonce account address
    public func releaseNonce(address: String) {
        guard let index = noncePool.firstIndex(where: { $0.address == address }) else {
            return
        }

        if noncePool[index].state == .reserved {
            noncePool[index].state = .available
            noncePool[index].reservedAt = nil
            noncePool[index].updatedAt = Date()
            savePool()

            DebugLogger.log("[NONCE] Released nonce: \(address)", category: "NONCE")
        }
    }

    /// Replenish the nonce pool to target size
    /// Should be called when coming online
    /// - Parameter authorityWallet: The wallet that will be the nonce authority
    public func replenishPool(authorityWallet: SolanaWallet) async throws {
        DebugLogger.log("[NONCE] Replenishing pool (current: \(noncePool.count), target: \(targetPoolSize))", category: "NONCE")

        // First, refresh existing available nonces to verify they're still valid
        await refreshAvailableNonces()

        // Remove consumed nonces
        noncePool.removeAll { $0.state == .consumed }

        // Calculate how many new nonces we need
        let availableCount = noncePool.filter { $0.state == .available }.count
        let needed = max(0, targetPoolSize - availableCount)

        guard needed > 0 else {
            DebugLogger.log("[NONCE] Pool is full, no replenishment needed", category: "NONCE")
            savePool()
            return
        }

        DebugLogger.log("[NONCE] Creating \(needed) new nonce accounts", category: "NONCE")

        // Create new nonce accounts
        for i in 0..<needed {
            do {
                let entry = try await createNonceAccount(authorityWallet: authorityWallet)
                noncePool.append(entry)
                DebugLogger.log("[NONCE] Created nonce \(i + 1)/\(needed): \(entry.address)", category: "NONCE")
            } catch {
                DebugLogger.error("[NONCE] Failed to create nonce \(i + 1)", error: error, category: "NONCE")
                // Continue trying to create remaining nonces
            }

            // Brief delay between creations to avoid rate limiting
            if i < needed - 1 {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }

        savePool()
        DebugLogger.log("[NONCE] Replenishment complete. Pool size: \(noncePool.count)", category: "NONCE")
    }

    /// Create a new nonce account on-chain
    /// - Parameter authorityWallet: The wallet that will be the nonce authority and fee payer
    /// - Returns: NonceEntry for the created account
    public func createNonceAccount(authorityWallet: SolanaWallet) async throws -> NonceEntry {
        let authorityAddress = await authorityWallet.address
        let authorityPubkey = await authorityWallet.publicKeyData

        // Generate a new keypair for the nonce account
        let nonceWallet = try SolanaWallet(wordCount: 12)
        let nonceAccountPubkey = await nonceWallet.publicKeyData
        let nonceAccountAddress = await nonceWallet.address

        // Get recent blockhash for the create transaction
        let blockhash = try await rpcClient.getRecentBlockhash()

        // Build CreateNonceAccount transaction
        // This requires two instructions:
        // 1. CreateAccount - allocates space and funds the nonce account
        // 2. InitializeNonceAccount - initializes it as a nonce account
        let message = try buildCreateNonceAccountMessage(
            feePayer: authorityPubkey,
            nonceAccount: nonceAccountPubkey,
            authority: authorityPubkey,
            recentBlockhash: blockhash
        )

        // Sign with both authority (fee payer) and nonce account keypair
        let messageBytes = message.serialize()
        let authoritySignature = try await authorityWallet.sign(messageBytes)
        let nonceAccountSignature = try await nonceWallet.sign(messageBytes)

        // Build signed transaction with both signatures
        let signedTx = try buildSignedTransactionWithTwoSignatures(
            message: message,
            signature1: authoritySignature,
            signature2: nonceAccountSignature
        )

        // Submit transaction
        let txSignature = try await rpcClient.sendTransaction(signedTx)
        try await rpcClient.waitForConfirmation(signature: txSignature, timeout: 30)

        // Fetch the initial nonce value
        let nonceValue = try await fetchNonceValue(address: nonceAccountAddress)

        return NonceEntry(
            address: nonceAccountAddress,
            nonceValue: nonceValue,
            authority: authorityAddress,
            state: .available
        )
    }

    // MARK: - Query Methods

    /// Get the current pool status
    public var poolStatus: (available: Int, reserved: Int, consumed: Int, total: Int) {
        let available = noncePool.filter { $0.state == .available }.count
        let reserved = noncePool.filter { $0.state == .reserved }.count
        let consumed = noncePool.filter { $0.state == .consumed }.count
        return (available, reserved, consumed, noncePool.count)
    }

    /// Check if there are any available nonces
    public var hasAvailableNonce: Bool {
        noncePool.contains { $0.state == .available }
    }

    /// Get all nonce entries (for debugging/UI)
    public var allEntries: [NonceEntry] {
        noncePool
    }

    // MARK: - Private Helpers

    /// Release reservations that have exceeded the timeout
    private func releaseStaleReservations() {
        let now = Date()
        for i in 0..<noncePool.count {
            if noncePool[i].state == .reserved,
               let reservedAt = noncePool[i].reservedAt,
               now.timeIntervalSince(reservedAt) > reservationTimeout {
                noncePool[i].state = .available
                noncePool[i].reservedAt = nil
                DebugLogger.log("[NONCE] Released stale reservation: \(noncePool[i].address)", category: "NONCE")
            }
        }
    }

    /// Refresh nonce values for all available nonces
    private func refreshAvailableNonces() async {
        for i in 0..<noncePool.count {
            guard noncePool[i].state == .available else { continue }

            do {
                let refreshedValue = try await fetchNonceValue(address: noncePool[i].address)
                noncePool[i].nonceValue = refreshedValue
                noncePool[i].updatedAt = Date()
            } catch {
                // Nonce may have been consumed externally
                noncePool[i].state = .consumed
                DebugLogger.log("[NONCE] Nonce \(noncePool[i].address) appears consumed", category: "NONCE")
            }
        }
    }

    /// Fetch the current nonce value from a nonce account
    private func fetchNonceValue(address: String) async throws -> String {
        // Use getAccountInfo RPC method to read nonce account data
        let nonceData = try await rpcClient.getNonceAccount(address: address)
        return nonceData.nonce
    }

    /// Build transaction message to create and initialize a nonce account
    private func buildCreateNonceAccountMessage(
        feePayer: Data,
        nonceAccount: Data,
        authority: Data,
        recentBlockhash: String
    ) throws -> SolanaTransaction.Message {
        guard feePayer.count == 32, nonceAccount.count == 32, authority.count == 32 else {
            throw TransactionError.invalidPublicKey("Keys must be 32 bytes")
        }

        guard let blockhashData = Data(base58Decoding: recentBlockhash), blockhashData.count == 32 else {
            throw TransactionError.invalidBlockhash
        }

        // Nonce account size is 80 bytes
        let nonceAccountSize: UInt64 = 80

        // Account keys order:
        // 0: feePayer (signer, writable) - pays for creation
        // 1: nonceAccount (signer, writable) - new account being created
        // 2: System Program (readonly, unsigned)
        // 3: RecentBlockhashes sysvar (readonly, unsigned) - required for InitializeNonceAccount
        // 4: Rent sysvar (readonly, unsigned) - required for InitializeNonceAccount
        let recentBlockhashesVar = Data(base58Decoding: "SysvarRecentB1telephones11111111111111111")
            ?? Data(base58Decoding: "SysvarRecentBLfefeeeeoooooooo1111111111111")
            ?? sysvarRecentBlockhashesID()
        let rentSysvar = sysvarRentID()

        let accountKeys = [
            feePayer,
            nonceAccount,
            SolanaTransaction.systemProgramId,
            recentBlockhashesVar,
            rentSysvar
        ]

        // Header: 2 required signatures (feePayer + nonceAccount), 0 readonly signed, 3 readonly unsigned
        let header = SolanaTransaction.MessageHeader(
            numRequiredSignatures: 2,
            numReadonlySignedAccounts: 0,
            numReadonlyUnsignedAccounts: 3
        )

        // Instruction 1: CreateAccount
        // Data: [4 bytes LE: instruction index (0)] [8 bytes LE: lamports] [8 bytes LE: space] [32 bytes: owner program]
        var createAccountData = Data()
        var createAccountIndex: UInt32 = 0
        createAccountData.append(contentsOf: withUnsafeBytes(of: &createAccountIndex) { Data($0) })
        var lamports = Self.nonceRentExemptMinimum
        createAccountData.append(contentsOf: withUnsafeBytes(of: &lamports) { Data($0) })
        var space = nonceAccountSize
        createAccountData.append(contentsOf: withUnsafeBytes(of: &space) { Data($0) })
        createAccountData.append(SolanaTransaction.systemProgramId)  // Owner is System Program

        let createAccountInstruction = SolanaTransaction.CompiledInstruction(
            programIdIndex: 2,  // System Program
            accountIndices: [0, 1],  // feePayer, nonceAccount
            data: createAccountData
        )

        // Instruction 2: InitializeNonceAccount
        // Data: [4 bytes LE: instruction index (6)] [32 bytes: authority pubkey]
        var initNonceData = Data()
        var initNonceIndex: UInt32 = 6
        initNonceData.append(contentsOf: withUnsafeBytes(of: &initNonceIndex) { Data($0) })
        initNonceData.append(authority)

        let initNonceInstruction = SolanaTransaction.CompiledInstruction(
            programIdIndex: 2,  // System Program
            accountIndices: [1, 3, 4],  // nonceAccount, RecentBlockhashes, Rent
            data: initNonceData
        )

        return SolanaTransaction.Message(
            header: header,
            accountKeys: accountKeys,
            recentBlockhash: blockhashData,
            instructions: [createAccountInstruction, initNonceInstruction]
        )
    }

    /// Build a signed transaction with two signatures
    private func buildSignedTransactionWithTwoSignatures(
        message: SolanaTransaction.Message,
        signature1: Data,
        signature2: Data
    ) throws -> String {
        guard signature1.count == 64, signature2.count == 64 else {
            throw TransactionError.invalidSignature
        }

        var txData = Data()

        // Signatures (compact array with 2 signatures)
        txData.append(2)  // Compact encoding for 2
        txData.append(signature1)
        txData.append(signature2)

        // Message
        txData.append(message.serialize())

        return txData.base64EncodedString()
    }

    /// Sysvar addresses
    private func sysvarRecentBlockhashesID() -> Data {
        // SysvarRecentB1ockHashes11111111111111111111
        Data([
            0x06, 0xa7, 0xd5, 0x17, 0x18, 0x7b, 0xd1, 0x60,
            0x35, 0xfe, 0x6b, 0x71, 0x7f, 0x1e, 0x17, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
        ])
    }

    private func sysvarRentID() -> Data {
        // SysvarRent111111111111111111111111111111111
        Data([
            0x06, 0xa7, 0xd5, 0x17, 0x18, 0x7b, 0xd1, 0x5b,
            0xd4, 0x57, 0xf2, 0xd2, 0xfc, 0x1a, 0xee, 0xec,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
        ])
    }

    // MARK: - Persistence

    private func savePool() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(noncePool) {
            userDefaults.set(data, forKey: storageKey)
        }
    }

    private func loadPool() {
        guard let data = userDefaults.data(forKey: storageKey) else {
            return
        }

        let decoder = JSONDecoder()
        if let loaded = try? decoder.decode([NonceEntry].self, from: data) {
            noncePool = loaded
        }
    }
}

// MARK: - Errors

public enum NonceError: Error, LocalizedError {
    case poolEmpty
    case nonceRefreshFailed(String)
    case createFailed(String)
    case insufficientBalance
    case invalidNonceAccount

    public var errorDescription: String? {
        switch self {
        case .poolEmpty:
            return "No available nonces in pool"
        case .nonceRefreshFailed(let address):
            return "Failed to refresh nonce value for \(address)"
        case .createFailed(let reason):
            return "Failed to create nonce account: \(reason)"
        case .insufficientBalance:
            return "Insufficient balance to create nonce account"
        case .invalidNonceAccount:
            return "Invalid nonce account data"
        }
    }
}
