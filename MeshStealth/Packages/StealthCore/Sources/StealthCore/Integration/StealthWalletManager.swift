import Foundation
import Combine

/// Status of a pending stealth payment
public enum PendingPaymentStatus: String, Codable, Sendable {
    case awaitingFunds  // Received via mesh, waiting for on-chain funds from sender
    case received       // On-chain balance confirmed, awaiting unshield
    case settling       // Unshield transaction in progress
    case settled        // Successfully unshielded to main wallet
    case failed         // Failed (will retry)
    case expired        // Payment expired before settlement
}

// MARK: - Outgoing Payment Intent (Sender-Side Queue)

/// Status of an outgoing payment intent
public enum OutgoingPaymentStatus: String, Codable, Sendable {
    case queued         // Waiting to send on-chain (offline)
    case sending        // Transaction in progress
    case confirmed      // Transaction confirmed on-chain
    case failed         // Failed (will retry)
}

/// An outgoing payment intent queued for when sender comes online
public struct OutgoingPaymentIntent: Codable, Sendable, Identifiable {
    public let id: UUID
    public let recipientMetaAddress: String
    public let stealthAddress: String
    public let ephemeralPublicKey: Data
    public let mlkemCiphertext: Data?
    public let amount: UInt64
    public let memo: String?
    public let createdAt: Date
    public var status: OutgoingPaymentStatus
    public var transactionSignature: String?
    public var errorMessage: String?
    public var attempts: Int

    public init(
        id: UUID = UUID(),
        recipientMetaAddress: String,
        stealthAddress: String,
        ephemeralPublicKey: Data,
        mlkemCiphertext: Data?,
        amount: UInt64,
        memo: String?,
        createdAt: Date = Date(),
        status: OutgoingPaymentStatus = .queued,
        transactionSignature: String? = nil,
        errorMessage: String? = nil,
        attempts: Int = 0
    ) {
        self.id = id
        self.recipientMetaAddress = recipientMetaAddress
        self.stealthAddress = stealthAddress
        self.ephemeralPublicKey = ephemeralPublicKey
        self.mlkemCiphertext = mlkemCiphertext
        self.amount = amount
        self.memo = memo
        self.createdAt = createdAt
        self.status = status
        self.transactionSignature = transactionSignature
        self.errorMessage = errorMessage
        self.attempts = attempts
    }

    /// Amount in SOL
    public var amountInSol: Double {
        Double(amount) / 1_000_000_000
    }
}

// MARK: - Activity Feed

/// Type of activity for the unified activity feed
public enum ActivityType: String, Codable, Sendable {
    case shield         // Main wallet → Stealth (self-deposit)
    case unshield       // Stealth → Main wallet (withdraw)
    case meshSend       // Outgoing payment to another user
    case meshReceive    // Incoming payment from another user
    case hop            // Stealth → Stealth (privacy mixing)
    case airdrop        // Devnet faucet funding
}

/// Status of an activity item
public enum ActivityStatus: String, Codable, Sendable {
    case pending        // Awaiting action (sync, confirmation, etc.)
    case inProgress     // Transaction in flight
    case completed      // Successfully completed
    case failed         // Failed
}

/// A unified activity item for the activity feed
public struct ActivityItem: Codable, Sendable, Identifiable {
    public let id: UUID
    public let type: ActivityType
    public let amount: UInt64
    public let timestamp: Date
    public var status: ActivityStatus

    // Optional fields based on type
    public let stealthAddress: String?
    public var transactionSignature: String?
    public let hopCount: Int?
    public var errorMessage: String?

    // For mesh payments
    public let peerName: String?

    // For linking hops to parent shield/unshield
    public let parentActivityId: UUID?

    // For settlement retry scheduling
    public var nextRetryAt: Date?

    public init(
        id: UUID = UUID(),
        type: ActivityType,
        amount: UInt64,
        timestamp: Date = Date(),
        status: ActivityStatus = .pending,
        stealthAddress: String? = nil,
        transactionSignature: String? = nil,
        hopCount: Int? = nil,
        errorMessage: String? = nil,
        peerName: String? = nil,
        parentActivityId: UUID? = nil,
        nextRetryAt: Date? = nil
    ) {
        self.id = id
        self.type = type
        self.amount = amount
        self.timestamp = timestamp
        self.status = status
        self.stealthAddress = stealthAddress
        self.transactionSignature = transactionSignature
        self.hopCount = hopCount
        self.errorMessage = errorMessage
        self.peerName = peerName
        self.parentActivityId = parentActivityId
        self.nextRetryAt = nextRetryAt
    }

    /// Amount in SOL
    public var amountInSol: Double {
        Double(amount) / 1_000_000_000
    }

    /// Whether this item needs sync (pending and not completed)
    public var needsSync: Bool {
        status == .pending || status == .inProgress
    }

    /// Whether this is a child activity (hop belonging to a shield/unshield)
    public var isChildActivity: Bool {
        parentActivityId != nil
    }
}

/// A pending stealth payment awaiting settlement
public struct PendingPayment: Codable, Sendable, Identifiable {
    /// Unique identifier
    public let id: UUID

    /// The stealth address funds were sent to
    public let stealthAddress: String

    /// Ephemeral public key for deriving spending key
    public let ephemeralPublicKey: Data

    /// MLKEM ciphertext (for hybrid mode)
    public let mlkemCiphertext: Data?

    /// Amount in lamports
    public let amount: UInt64

    /// Token mint (nil for native SOL)
    public let tokenMint: String?

    /// View tag for quick filtering
    public let viewTag: UInt8

    /// When this payment was received
    public let receivedAt: Date

    /// Current status
    public var status: PendingPaymentStatus

    /// Number of settlement attempts
    public var settlementAttempts: Int

    /// Last settlement attempt timestamp
    public var lastAttemptAt: Date?

    /// Next retry time (for exponential backoff)
    public var nextRetryAt: Date?

    /// Settlement transaction signature (when settled)
    public var settlementSignature: String?

    /// Error message if failed
    public var errorMessage: String?

    /// Whether this payment was self-shielded (vs received via mesh)
    /// Shielded payments skip auto-settlement since they're already on-chain
    public let isShielded: Bool

    /// Number of hops this payment has undergone (0 = original, 1+ = hopped)
    public let hopCount: Int

    /// ID of the original payment (for hop chains) - nil if this is the original
    public let originalPaymentId: UUID?

    /// ID of the parent payment (if this is a hop result) - nil if not a hop
    public let parentPaymentId: UUID?

    /// ID grouping payments that were split from the same source (for mixing)
    public let splitGroupId: UUID?

    /// Whether this payment is part of a split (for mixing)
    public let isSplitPart: Bool

    // MARK: - Pre-Signed Transaction Support (v2 protocol)

    /// Pre-signed transaction (base64) that receiver can broadcast
    /// Allows "receiver settles" flow without waiting for sender
    public let preSignedTransaction: String?

    /// Nonce account address used for pre-signed transaction
    public let nonceAccountAddress: String?

    /// Who settled this payment
    public var settledBy: SettledBy?

    public init(
        id: UUID = UUID(),
        stealthAddress: String,
        ephemeralPublicKey: Data,
        mlkemCiphertext: Data?,
        amount: UInt64,
        tokenMint: String? = nil,
        viewTag: UInt8 = 0,
        receivedAt: Date = Date(),
        status: PendingPaymentStatus = .received,
        settlementAttempts: Int = 0,
        lastAttemptAt: Date? = nil,
        nextRetryAt: Date? = nil,
        settlementSignature: String? = nil,
        errorMessage: String? = nil,
        isShielded: Bool = false,
        hopCount: Int = 0,
        originalPaymentId: UUID? = nil,
        parentPaymentId: UUID? = nil,
        splitGroupId: UUID? = nil,
        isSplitPart: Bool = false,
        preSignedTransaction: String? = nil,
        nonceAccountAddress: String? = nil,
        settledBy: SettledBy? = nil
    ) {
        self.id = id
        self.stealthAddress = stealthAddress
        self.ephemeralPublicKey = ephemeralPublicKey
        self.mlkemCiphertext = mlkemCiphertext
        self.amount = amount
        self.tokenMint = tokenMint
        self.viewTag = viewTag
        self.receivedAt = receivedAt
        self.status = status
        self.settlementAttempts = settlementAttempts
        self.lastAttemptAt = lastAttemptAt
        self.nextRetryAt = nextRetryAt
        self.settlementSignature = settlementSignature
        self.errorMessage = errorMessage
        self.isShielded = isShielded
        self.hopCount = hopCount
        self.originalPaymentId = originalPaymentId
        self.parentPaymentId = parentPaymentId
        self.splitGroupId = splitGroupId
        self.isSplitPart = isSplitPart
        self.preSignedTransaction = preSignedTransaction
        self.nonceAccountAddress = nonceAccountAddress
        self.settledBy = settledBy
    }

    /// Create from mesh payload
    public init(from payload: MeshStealthPayload) {
        self.id = UUID()
        self.stealthAddress = payload.stealthAddress
        self.ephemeralPublicKey = payload.ephemeralPublicKey
        self.mlkemCiphertext = payload.mlkemCiphertext
        self.amount = payload.amount
        self.tokenMint = payload.tokenMint
        self.viewTag = payload.viewTag
        self.receivedAt = Date()
        self.status = .received
        self.settlementAttempts = 0
        self.lastAttemptAt = nil
        self.nextRetryAt = nil
        self.settlementSignature = nil
        self.errorMessage = nil
        self.isShielded = false  // Mesh payments are not shielded
        self.hopCount = 0
        self.originalPaymentId = nil
        self.parentPaymentId = nil
        self.splitGroupId = nil
        self.isSplitPart = false
        // v2 protocol: store pre-signed transaction for receiver settlement
        self.preSignedTransaction = payload.preSignedTransaction
        self.nonceAccountAddress = payload.nonceAccountAddress
        self.settledBy = nil
    }

    /// Whether this payment supports receiver settlement (has pre-signed tx)
    public var supportsReceiverSettlement: Bool {
        preSignedTransaction != nil
    }

    /// Whether this payment is hybrid (post-quantum)
    public var isHybrid: Bool {
        mlkemCiphertext != nil
    }

    /// Amount in SOL
    public var amountInSol: Double {
        Double(amount) / 1_000_000_000
    }
}

/// Manages wallet state including pending payments and balances
@MainActor
public class StealthWalletManager: ObservableObject {

    // MARK: - Published State

    /// User's stealth keypair
    @Published public private(set) var keyPair: StealthKeyPair?

    /// Main Solana wallet (visible, for funding)
    @Published public private(set) var mainWallet: SolanaWallet?

    /// Main wallet balance in lamports
    @Published public private(set) var mainWalletBalance: UInt64 = 0

    /// Pending payments awaiting settlement
    @Published public private(set) var pendingPayments: [PendingPayment] = []

    /// Settled payments history
    @Published public private(set) var settledPayments: [PendingPayment] = []

    /// Total pending balance (in lamports)
    @Published public private(set) var pendingBalance: UInt64 = 0

    /// Whether wallet is initialized
    @Published public private(set) var isInitialized: Bool = false

    /// Last sync timestamp
    @Published public private(set) var lastSyncAt: Date?

    /// Whether airdrop is in progress
    @Published public private(set) var isAirdropping: Bool = false

    /// Outgoing payment intents queued for when online
    @Published public private(set) var outgoingPaymentIntents: [OutgoingPaymentIntent] = []

    /// Unified activity feed
    @Published public private(set) var activityItems: [ActivityItem] = []

    // MARK: - Private

    private let keychainService: KeychainService
    private let userDefaults: UserDefaults
    private let faucet: DevnetFaucet
    private let pendingPaymentsKey = "meshstealth.pending_payments"
    private let settledPaymentsKey = "meshstealth.settled_payments"
    private let outgoingIntentsKey = "meshstealth.outgoing_intents"
    private let activityItemsKey = "meshstealth.activity_items"

    /// Publisher for new payments
    private let newPaymentSubject = PassthroughSubject<PendingPayment, Never>()
    public var newPayments: AnyPublisher<PendingPayment, Never> {
        newPaymentSubject.eraseToAnyPublisher()
    }

    /// Publisher for settled payments
    private let settledPaymentSubject = PassthroughSubject<PendingPayment, Never>()
    public var settledPaymentNotifications: AnyPublisher<PendingPayment, Never> {
        settledPaymentSubject.eraseToAnyPublisher()
    }

    // MARK: - Initialization

    public init(
        keychainService: KeychainService = KeychainService(),
        userDefaults: UserDefaults = .standard,
        faucet: DevnetFaucet = DevnetFaucet()
    ) {
        self.keychainService = keychainService
        self.userDefaults = userDefaults
        self.faucet = faucet
    }

    /// Initialize wallet with existing or new keypair
    public func initialize() async throws {
        // Try to load existing stealth keypair
        if let existing = try? keychainService.loadKeyPair() {
            keyPair = existing
        } else {
            // Generate new stealth keypair with post-quantum (MLKEM768) support
            let newKeyPair = try StealthKeyPair.generate(withPostQuantum: true)
            try keychainService.storeKeyPair(newKeyPair)
            keyPair = newKeyPair
        }

        // Initialize main wallet
        try await initializeMainWallet()

        // Load pending payments from storage
        loadPendingPayments()
        loadSettledPayments()
        loadOutgoingIntents()
        loadActivityItems()
        updatePendingBalance()

        isInitialized = true
    }

    /// Initialize or restore the main Solana wallet
    /// Priority: 1) Stored mnemonic, 2) Stored secret key, 3) Generate new
    private func initializeMainWallet() async throws {
        // Try to restore from mnemonic first (preferred)
        if let mnemonic = try keychainService.loadMnemonic() {
            mainWallet = try SolanaWallet(mnemonic: mnemonic)
        }
        // Fall back to stored secret key (legacy or mnemonic-less restore)
        else if let storedKey = try keychainService.loadMainWalletKey() {
            mainWallet = try SolanaWallet(secretKey: storedKey)
        }
        // Generate new wallet with mnemonic
        else {
            let newWallet = try SolanaWallet(wordCount: 12)

            // Store mnemonic for backup
            if let mnemonic = await newWallet.mnemonic {
                try keychainService.storeMnemonic(mnemonic)
            }

            // Also store secret key for quick restore
            let secretKey = await newWallet.secretKeyData
            try keychainService.storeMainWalletKey(secretKey)

            mainWallet = newWallet
        }

        // DON'T refresh balance during init - breaks offline startup
        // Balance will refresh when:
        // 1. User manually refreshes
        // 2. Network comes online (via MeshNetworkManager.onConnected callback)
        // 3. Before any transaction that needs balance
        mainWalletBalance = 0
    }

    /// Get the wallet mnemonic for backup (if available)
    public var walletMnemonic: [String]? {
        get async {
            await mainWallet?.mnemonic
        }
    }

    /// Get the main wallet's secret key for privacy protocol integration
    /// This is needed for Privacy Cash and ShadowWire to sign transactions
    public var mainWalletSecretKey: Data? {
        get async {
            await mainWallet?.secretKeyData
        }
    }

    /// Import wallet from mnemonic phrase
    /// - Parameter mnemonic: Array of BIP-39 words
    public func importWallet(mnemonic: [String]) async throws {
        let wallet = try SolanaWallet(mnemonic: mnemonic)

        // Store mnemonic and secret key
        try keychainService.storeMnemonic(mnemonic)
        let secretKey = await wallet.secretKeyData
        try keychainService.storeMainWalletKey(secretKey)

        mainWallet = wallet
        await refreshMainWalletBalance()
    }

    /// Import existing keypair (from restored StealthKeyPair)
    public func importKeyPair(_ imported: StealthKeyPair) async throws {
        try keychainService.storeKeyPair(imported)
        keyPair = imported
        isInitialized = true
    }

    // MARK: - Payment Management

    /// Add a new pending payment (received via mesh)
    public func addPendingPayment(_ payment: PendingPayment) {
        // Check for duplicates
        guard !pendingPayments.contains(where: { $0.id == payment.id }) else {
            return
        }

        pendingPayments.append(payment)
        savePendingPayments()
        updatePendingBalance()

        newPaymentSubject.send(payment)
    }

    /// Add pending payment from mesh payload
    public func addPendingPayment(from payload: MeshStealthPayload) {
        let payment = PendingPayment(from: payload)
        addPendingPayment(payment)

        // Record mesh receive activity (mesh payments are not shielded)
        recordMeshReceiveActivity(
            amount: payload.amount,
            stealthAddress: payload.stealthAddress,
            peerName: nil,
            isPending: true  // Will be updated when funds arrive on-chain
        )
    }

    /// Update payment status
    public func updatePaymentStatus(
        id: UUID,
        status: PendingPaymentStatus,
        signature: String? = nil,
        error: String? = nil
    ) {
        guard let index = pendingPayments.firstIndex(where: { $0.id == id }) else {
            return
        }

        pendingPayments[index].status = status
        pendingPayments[index].settlementAttempts += 1
        pendingPayments[index].lastAttemptAt = Date()

        if let sig = signature {
            pendingPayments[index].settlementSignature = sig
        }

        if let err = error {
            pendingPayments[index].errorMessage = err
        }

        if status == .settled {
            // Move to settled list
            let settled = pendingPayments.remove(at: index)
            settledPayments.insert(settled, at: 0)
            saveSettledPayments()
            settledPaymentSubject.send(settled)
        }

        savePendingPayments()
        updatePendingBalance()
    }

    /// Update payment status with next retry time (for exponential backoff)
    public func updatePaymentStatusWithRetry(
        id: UUID,
        status: PendingPaymentStatus,
        error: String? = nil,
        nextRetryAt: Date?
    ) {
        guard let index = pendingPayments.firstIndex(where: { $0.id == id }) else {
            return
        }

        pendingPayments[index].status = status
        pendingPayments[index].settlementAttempts += 1
        pendingPayments[index].lastAttemptAt = Date()
        pendingPayments[index].nextRetryAt = nextRetryAt

        if let err = error {
            pendingPayments[index].errorMessage = err
        }

        savePendingPayments()
        updatePendingBalance()
    }

    /// Get payments ready for settlement
    public func getPaymentsForSettlement() -> [PendingPayment] {
        pendingPayments.filter { payment in
            // Only settle mesh-received payments, not self-shielded ones
            (payment.status == .received || payment.status == .failed) && !payment.isShielded
        }
    }

    /// Remove expired payments
    public func pruneExpiredPayments(maxAge: TimeInterval = 86400 * 7) {
        let cutoff = Date().addingTimeInterval(-maxAge)

        pendingPayments.removeAll { payment in
            payment.receivedAt < cutoff && payment.status != .settling
        }

        savePendingPayments()
        updatePendingBalance()
    }

    // MARK: - Scanner Integration

    /// Check if a stealth address belongs to us
    public func checkStealthAddress(
        address: String,
        ephemeralPublicKey: Data,
        mlkemCiphertext: Data? = nil
    ) -> Bool {
        guard let keyPair = keyPair else { return false }

        let scanner = StealthScanner(keyPair: keyPair)

        if let ciphertext = mlkemCiphertext {
            // Hybrid scan
            return (try? scanner.scanHybridTransaction(
                stealthAddress: address,
                ephemeralPublicKey: ephemeralPublicKey,
                mlkemCiphertext: ciphertext
            )) != nil
        } else {
            // Classical scan
            return (try? scanner.scanTransaction(
                stealthAddress: address,
                ephemeralPublicKey: ephemeralPublicKey
            )) != nil
        }
    }

    /// Derive spending key for a payment we received
    public func deriveSpendingKey(for payment: PendingPayment) throws -> Data {
        DebugLogger.log("Deriving spending key for payment \(payment.id)", category: "DERIVE-KEY")
        DebugLogger.log("Stealth address: \(payment.stealthAddress)", category: "DERIVE-KEY")
        DebugLogger.log("Ephemeral key: \(payment.ephemeralPublicKey.base58EncodedString)", category: "DERIVE-KEY")
        DebugLogger.log("Is hybrid: \(payment.isHybrid)", category: "DERIVE-KEY")

        guard let keyPair = keyPair else {
            DebugLogger.error("keyPair is nil", category: "DERIVE-KEY")
            throw WalletError.notInitialized
        }

        let scanner = StealthScanner(keyPair: keyPair)

        if let ciphertext = payment.mlkemCiphertext {
            // Hybrid derivation
            DebugLogger.log("Using hybrid derivation (MLKEM ciphertext present, \(ciphertext.count) bytes)", category: "DERIVE-KEY")
            guard let result = try scanner.scanHybridTransaction(
                stealthAddress: payment.stealthAddress,
                ephemeralPublicKey: payment.ephemeralPublicKey,
                mlkemCiphertext: ciphertext
            ) else {
                DebugLogger.error("Hybrid scan returned nil - stealth address doesn't match our keys", category: "DERIVE-KEY")
                throw WalletError.keyDerivationFailed
            }
            DebugLogger.log("Hybrid derivation successful", category: "DERIVE-KEY")
            return result.spendingPrivateKey
        } else {
            // Classical derivation
            DebugLogger.log("Using classical derivation", category: "DERIVE-KEY")
            guard let result = try scanner.scanTransaction(
                stealthAddress: payment.stealthAddress,
                ephemeralPublicKey: payment.ephemeralPublicKey
            ) else {
                DebugLogger.error("Classical scan returned nil - stealth address doesn't match our keys", category: "DERIVE-KEY")
                throw WalletError.keyDerivationFailed
            }
            DebugLogger.log("Classical derivation successful", category: "DERIVE-KEY")
            return result.spendingPrivateKey
        }
    }

    // MARK: - Meta Address

    /// Get the meta-address for receiving payments
    public var metaAddress: String? {
        keyPair?.metaAddressString
    }

    /// Get the hybrid meta-address (with MLKEM public key)
    public var hybridMetaAddress: String? {
        guard let keyPair = keyPair, keyPair.hasPostQuantum else { return nil }
        return keyPair.hybridMetaAddressString
    }

    // MARK: - Main Wallet

    /// Get main wallet address for display/funding
    public var mainWalletAddress: String? {
        get async {
            await mainWallet?.address
        }
    }

    /// Main wallet balance in SOL
    public var mainWalletBalanceInSol: Double {
        Double(mainWalletBalance) / 1_000_000_000.0
    }

    /// Refresh the main wallet balance from the network
    @discardableResult
    public func refreshMainWalletBalance() async -> UInt64 {
        guard let address = await mainWallet?.address else {
            mainWalletBalance = 0
            return 0
        }

        do {
            let balance = try await faucet.getBalance(address: address)
            mainWalletBalance = balance
            lastSyncAt = Date()
            return balance
        } catch {
            // Log error but don't throw - balance refresh is best-effort
            DebugLogger.error("Failed to refresh balance", error: error, category: "WALLET")
            return mainWalletBalance
        }
    }

    /// Request devnet airdrop to main wallet
    /// - Parameter lamports: Amount to request (default 1 SOL)
    /// - Returns: Transaction signature
    public func requestAirdrop(lamports: UInt64 = 1_000_000_000) async throws -> String {
        guard let address = await mainWallet?.address else {
            throw WalletError.notInitialized
        }

        isAirdropping = true
        defer { isAirdropping = false }

        let signature = try await faucet.requestAirdrop(to: address, lamports: lamports)

        // Wait for confirmation and refresh balance
        try await faucet.waitForConfirmation(signature: signature, timeout: 30)
        await refreshMainWalletBalance()

        // Record airdrop activity
        recordAirdropActivity(amount: lamports, signature: signature)

        return signature
    }

    /// Request 1 SOL airdrop (convenience)
    public func requestOneSolAirdrop() async throws -> String {
        try await requestAirdrop(lamports: 1_000_000_000)
    }

    // MARK: - Persistence

    private func savePendingPayments() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(pendingPayments) {
            userDefaults.set(data, forKey: pendingPaymentsKey)
        }
    }

    private func loadPendingPayments() {
        guard let data = userDefaults.data(forKey: pendingPaymentsKey) else {
            return
        }

        let decoder = JSONDecoder()
        if let loaded = try? decoder.decode([PendingPayment].self, from: data) {
            pendingPayments = loaded
        }
    }

    private func saveSettledPayments() {
        let encoder = JSONEncoder()
        // Only keep last 100 settled payments
        let toSave = Array(settledPayments.prefix(100))
        if let data = try? encoder.encode(toSave) {
            userDefaults.set(data, forKey: settledPaymentsKey)
        }
    }

    private func loadSettledPayments() {
        guard let data = userDefaults.data(forKey: settledPaymentsKey) else {
            return
        }

        let decoder = JSONDecoder()
        if let loaded = try? decoder.decode([PendingPayment].self, from: data) {
            settledPayments = loaded
        }
    }

    private func updatePendingBalance() {
        pendingBalance = pendingPayments
            .filter { $0.status == .received || $0.status == .failed || $0.status == .awaitingFunds }
            .reduce(0) { $0 + $1.amount }
    }

    // MARK: - Outgoing Payment Intent Persistence

    private func saveOutgoingIntents() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(outgoingPaymentIntents) {
            userDefaults.set(data, forKey: outgoingIntentsKey)
        }
    }

    private func loadOutgoingIntents() {
        guard let data = userDefaults.data(forKey: outgoingIntentsKey) else {
            return
        }

        let decoder = JSONDecoder()
        if let loaded = try? decoder.decode([OutgoingPaymentIntent].self, from: data) {
            outgoingPaymentIntents = loaded
        }
    }

    // MARK: - Activity Items Persistence

    private func saveActivityItems() {
        let encoder = JSONEncoder()
        // Only keep last 200 activity items
        let toSave = Array(activityItems.prefix(200))
        if let data = try? encoder.encode(toSave) {
            userDefaults.set(data, forKey: activityItemsKey)
        }
    }

    private func loadActivityItems() {
        guard let data = userDefaults.data(forKey: activityItemsKey) else {
            return
        }

        let decoder = JSONDecoder()
        if let loaded = try? decoder.decode([ActivityItem].self, from: data) {
            activityItems = loaded
        }
    }

    // MARK: - Outgoing Payment Queue Management

    /// Queue an outgoing payment for later execution (when offline)
    public func queueOutgoingPayment(_ intent: OutgoingPaymentIntent) {
        outgoingPaymentIntents.append(intent)
        saveOutgoingIntents()

        // Also add to activity feed
        let activity = ActivityItem(
            id: intent.id,
            type: .meshSend,
            amount: intent.amount,
            timestamp: intent.createdAt,
            status: .pending,
            stealthAddress: intent.stealthAddress
        )
        addActivityItem(activity)
    }

    /// Update outgoing payment intent status
    public func updateOutgoingIntent(
        id: UUID,
        status: OutgoingPaymentStatus,
        signature: String? = nil,
        error: String? = nil
    ) {
        guard let index = outgoingPaymentIntents.firstIndex(where: { $0.id == id }) else {
            return
        }

        // Create a new OutgoingPaymentIntent with updated values to trigger @Published
        // (In-place modification of struct properties doesn't notify SwiftUI)
        let current = outgoingPaymentIntents[index]
        outgoingPaymentIntents[index] = OutgoingPaymentIntent(
            id: current.id,
            recipientMetaAddress: current.recipientMetaAddress,
            stealthAddress: current.stealthAddress,
            ephemeralPublicKey: current.ephemeralPublicKey,
            mlkemCiphertext: current.mlkemCiphertext,
            amount: current.amount,
            memo: current.memo,
            createdAt: current.createdAt,
            status: status,
            transactionSignature: signature ?? current.transactionSignature,
            errorMessage: error ?? current.errorMessage,
            attempts: current.attempts + 1
        )

        saveOutgoingIntents()

        // Update corresponding activity item
        let activityStatus: ActivityStatus = switch status {
        case .queued: .pending
        case .sending: .inProgress
        case .confirmed: .completed
        case .failed: .failed
        }
        updateActivityStatus(id: id, status: activityStatus, signature: signature, error: error)
    }

    /// Get queued outgoing payments that need to be executed
    public func getQueuedOutgoingPayments() -> [OutgoingPaymentIntent] {
        outgoingPaymentIntents.filter { $0.status == .queued || $0.status == .failed }
    }

    /// Remove confirmed outgoing payment from queue
    public func removeConfirmedOutgoingPayment(id: UUID) {
        outgoingPaymentIntents.removeAll { $0.id == id }
        saveOutgoingIntents()
    }

    // MARK: - Activity Feed Management

    /// Add an activity item to the feed
    public func addActivityItem(_ item: ActivityItem) {
        // Insert at the beginning (most recent first)
        activityItems.insert(item, at: 0)
        saveActivityItems()
    }

    /// Update an activity item's status
    public func updateActivityStatus(
        id: UUID,
        status: ActivityStatus,
        signature: String? = nil,
        error: String? = nil,
        nextRetryAt: Date? = nil
    ) {
        guard let index = activityItems.firstIndex(where: { $0.id == id }) else {
            return
        }

        // Create a new ActivityItem with updated values to trigger @Published
        // (In-place modification of struct properties doesn't notify SwiftUI)
        let current = activityItems[index]
        activityItems[index] = ActivityItem(
            id: current.id,
            type: current.type,
            amount: current.amount,
            timestamp: current.timestamp,
            status: status,
            stealthAddress: current.stealthAddress,
            transactionSignature: signature ?? current.transactionSignature,
            hopCount: current.hopCount,
            errorMessage: error ?? current.errorMessage,
            peerName: current.peerName,
            parentActivityId: current.parentActivityId,
            nextRetryAt: nextRetryAt
        )

        saveActivityItems()
    }

    /// Update an activity item's amount (e.g., after calculating actual fees)
    public func updateActivityAmount(id: UUID, amount: UInt64) {
        guard let index = activityItems.firstIndex(where: { $0.id == id }) else {
            return
        }

        // ActivityItem.amount is let, so we need to replace the whole item
        let current = activityItems[index]
        activityItems[index] = ActivityItem(
            id: current.id,
            type: current.type,
            amount: amount,
            timestamp: current.timestamp,
            status: current.status,
            stealthAddress: current.stealthAddress,
            transactionSignature: current.transactionSignature,
            hopCount: current.hopCount,
            errorMessage: current.errorMessage,
            peerName: current.peerName,
            parentActivityId: current.parentActivityId,
            nextRetryAt: current.nextRetryAt
        )

        saveActivityItems()
    }

    /// Record a shield activity
    @discardableResult
    public func recordShieldActivity(amount: UInt64, stealthAddress: String, signature: String) -> UUID {
        let activity = ActivityItem(
            type: .shield,
            amount: amount,
            status: .completed,
            stealthAddress: stealthAddress,
            transactionSignature: signature
        )
        addActivityItem(activity)
        return activity.id
    }

    /// Record an unshield activity
    @discardableResult
    public func recordUnshieldActivity(amount: UInt64, stealthAddress: String, signature: String) -> UUID {
        let activity = ActivityItem(
            type: .unshield,
            amount: amount,
            status: .completed,
            stealthAddress: stealthAddress,
            transactionSignature: signature
        )
        addActivityItem(activity)
        return activity.id
    }

    /// Record a mesh receive activity
    public func recordMeshReceiveActivity(amount: UInt64, stealthAddress: String, peerName: String? = nil, isPending: Bool = false) {
        let activity = ActivityItem(
            type: .meshReceive,
            amount: amount,
            status: isPending ? .pending : .completed,
            stealthAddress: stealthAddress,
            peerName: peerName
        )
        addActivityItem(activity)
    }

    /// Record an airdrop activity
    public func recordAirdropActivity(amount: UInt64, signature: String) {
        let activity = ActivityItem(
            type: .airdrop,
            amount: amount,
            status: .completed,
            transactionSignature: signature
        )
        addActivityItem(activity)
    }

    /// Record a hop activity
    public func recordHopActivity(amount: UInt64, stealthAddress: String, hopCount: Int, signature: String, parentActivityId: UUID? = nil) {
        let activity = ActivityItem(
            type: .hop,
            amount: amount,
            status: .completed,
            stealthAddress: stealthAddress,
            transactionSignature: signature,
            hopCount: hopCount,
            parentActivityId: parentActivityId
        )
        addActivityItem(activity)
    }

    /// Get activity items that need sync (pending or in progress)
    public var pendingSyncItems: [ActivityItem] {
        activityItems.filter { $0.needsSync }
    }

    // MARK: - Shield Operations

    private var shieldService: ShieldService?
    private var _privacyRoutingService: PrivacyRoutingService?

    /// Set the privacy routing service for privacy-enhanced shield/unshield operations
    /// When set, unshield operations will route through the privacy pool
    public func setPrivacyRoutingService(_ service: PrivacyRoutingService?) {
        _privacyRoutingService = service
        // Update existing shield service if any
        Task {
            await shieldService?.setPrivacyRoutingService(service)
        }
    }

    /// Lazily create or return the shield service with privacy routing configured
    private func getOrCreateShieldService() async -> ShieldService {
        if let existing = shieldService {
            return existing
        }
        let service = ShieldService(rpcClient: faucet)
        await service.setPrivacyRoutingService(_privacyRoutingService)
        shieldService = service
        return service
    }

    /// Shield funds from main wallet to a stealth address (self-deposit)
    /// Automatically performs split/hop/recombine mixing after the initial shield for privacy
    /// When privacy routing is enabled, routes through privacy pool: main → pool → stealth
    /// - Parameter lamports: Amount to shield in lamports
    /// - Returns: ShieldResult with transaction details
    public func shield(lamports: UInt64) async throws -> ShieldResult {
        guard let mainWallet = mainWallet, let keyPair = keyPair else {
            throw WalletError.notInitialized
        }

        let shieldSvc = await getOrCreateShieldService()

        // Step 1: Initial shield
        // If privacy routing is enabled, use pool routing: main → pool → stealth
        // Otherwise, direct transfer: main → stealth
        DebugLogger.log("Starting shield of \(lamports) lamports", category: "SHIELD")

        let result: ShieldResult
        if let privacyService = _privacyRoutingService,
           await privacyService.shouldUsePrivacyRouting(for: lamports) {
            DebugLogger.log("Using privacy pool routing via \(await privacyService.selectedProtocol.displayName)", category: "SHIELD")
            DebugLogger.log("This will: main → pool → stealth (breaking on-chain link)", category: "SHIELD")
            result = try await shieldSvc.shieldWithPrivacy(
                lamports: lamports,
                mainWallet: mainWallet,
                stealthKeyPair: keyPair
            )
        } else {
            if _privacyRoutingService != nil {
                DebugLogger.log("Privacy routing available but not enabled for this amount", category: "SHIELD")
            } else {
                DebugLogger.log("No privacy routing configured, using direct transfer", category: "SHIELD")
            }
            result = try await shieldSvc.shield(
                lamports: lamports,
                mainWallet: mainWallet,
                stealthKeyPair: keyPair
            )
        }
        DebugLogger.log("Initial shield complete: \(result.stealthAddress)", category: "SHIELD")

        // Step 2: Create initial payment record
        let initialPayment = PendingPayment(
            stealthAddress: result.stealthAddress,
            ephemeralPublicKey: result.ephemeralPublicKey,
            mlkemCiphertext: result.mlkemCiphertext,
            amount: result.amount,
            tokenMint: nil,
            viewTag: result.viewTag,
            status: .received,
            isShielded: true
        )
        addPendingPayment(initialPayment)

        // Record shield activity BEFORE mixing so we have the parent ID
        let shieldActivityId = recordShieldActivity(amount: lamports, stealthAddress: result.stealthAddress, signature: result.signature)

        // Step 3: Auto-mix using split/hop/recombine for proper privacy
        // Minimum amount for split mixing (0.01 SOL)
        let minForSplitMix: UInt64 = 10_000_000

        if initialPayment.amount >= minForSplitMix {
            // Use proper split/hop/recombine mixing
            DebugLogger.log("Starting split/hop/recombine mixing", category: "SHIELD")
            do {
                let finalPayment = try await mixAfterShield(
                    payment: initialPayment,
                    parentActivityId: shieldActivityId
                )
                DebugLogger.log("Mix complete. Final payment at: \(finalPayment.stealthAddress)", category: "SHIELD")
            } catch {
                DebugLogger.error("Mix failed, keeping initial payment", error: error, category: "SHIELD")
            }
        } else {
            // For small amounts, do simple hops (1-3)
            DebugLogger.log("Amount too small for split mixing, using simple hops", category: "SHIELD")
            var currentPayment = initialPayment
            let hopCount = Int.random(in: 1...3)

            for i in 0..<hopCount {
                if i > 0 {
                    let delay = Int.random(in: 2...4)
                    try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
                }

                do {
                    let hopResult = try await hop(payment: currentPayment, parentActivityId: shieldActivityId)
                    try? await Task.sleep(nanoseconds: 1_500_000_000)

                    guard let newPayment = pendingPayments.first(where: {
                        $0.stealthAddress == hopResult.destinationStealthAddress
                    }) else {
                        break
                    }
                    currentPayment = newPayment
                } catch {
                    DebugLogger.error("Hop \(i + 1) failed, stopping", error: error, category: "SHIELD")
                    break
                }
            }
            DebugLogger.log("Simple mix complete. Final payment at: \(currentPayment.stealthAddress)", category: "SHIELD")
        }

        // Refresh balance after mixing complete
        try await Task.sleep(nanoseconds: 1_000_000_000)
        await refreshMainWalletBalance()

        return result
    }

    /// Mix a payment after shielding using split/hop/recombine
    /// - Parameters:
    ///   - payment: The shielded payment to mix
    ///   - parentActivityId: Parent activity ID for grouping
    /// - Returns: Final payment after mixing
    private func mixAfterShield(payment: PendingPayment, parentActivityId: UUID) async throws -> PendingPayment {
        DebugLogger.log("Starting split/hop/recombine for shielded payment", category: "SHIELD-MIX")

        // Phase 1: SPLIT into 2-4 random parts
        let numParts = Int.random(in: 2...4)
        DebugLogger.log("Phase 1: Splitting into \(numParts) parts", category: "SHIELD-MIX")

        let splitPayments = try await splitPayment(
            payment: payment,
            parts: numParts,
            parentActivityId: parentActivityId
        )

        DebugLogger.log("Split complete: \(splitPayments.count) parts", category: "SHIELD-MIX")
        for (idx, p) in splitPayments.enumerated() {
            DebugLogger.log("  Part \(idx + 1): \(p.amount) lamports", category: "SHIELD-MIX")
        }

        // Brief pause after split
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        // Phase 2: HOP each split independently (1-3 hops each)
        DebugLogger.log("Phase 2: Hopping each split", category: "SHIELD-MIX")
        var hoppedPayments: [PendingPayment] = []

        for (idx, splitPayment) in splitPayments.enumerated() {
            let hopsForThisSplit = Int.random(in: 1...3)
            var currentPayment = splitPayment

            for hopIdx in 0..<hopsForThisSplit {
                if hopIdx > 0 {
                    let delay = Int.random(in: 1...3)
                    try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
                }

                do {
                    let result = try await hop(payment: currentPayment, parentActivityId: parentActivityId)
                    try? await Task.sleep(nanoseconds: 1_500_000_000)

                    guard let newPayment = pendingPayments.first(where: {
                        $0.stealthAddress == result.destinationStealthAddress
                    }) else {
                        break
                    }
                    currentPayment = newPayment
                } catch {
                    DebugLogger.error("Hop failed for split \(idx + 1)", error: error, category: "SHIELD-MIX")
                    break
                }
            }

            hoppedPayments.append(currentPayment)

            if idx < splitPayments.count - 1 {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }

        DebugLogger.log("Hopping complete. \(hoppedPayments.count) payments ready for recombine", category: "SHIELD-MIX")

        // Phase 3: RECOMBINE all splits into a single address
        DebugLogger.log("Phase 3: Recombining", category: "SHIELD-MIX")

        let finalPayment = try await recombinePayments(
            hoppedPayments,
            parentActivityId: parentActivityId
        )

        DebugLogger.log("Recombine complete!", category: "SHIELD-MIX")
        DebugLogger.log("Final address: \(finalPayment.stealthAddress)", category: "SHIELD-MIX")
        DebugLogger.log("Final amount: \(finalPayment.amount) lamports", category: "SHIELD-MIX")

        return finalPayment
    }

    /// Shield funds with amount in SOL (convenience)
    /// - Parameter sol: Amount to shield in SOL
    /// - Returns: ShieldResult with transaction details
    public func shieldSol(_ sol: Double) async throws -> ShieldResult {
        let lamports = UInt64(sol * 1_000_000_000)
        return try await shield(lamports: lamports)
    }

    /// Unshield funds from a pending payment back to main wallet
    /// - Parameters:
    ///   - payment: The pending payment to unshield
    ///   - lamports: Amount to unshield (nil = all available)
    /// - Returns: UnshieldResult with transaction details
    public func unshield(payment: PendingPayment, lamports: UInt64? = nil, skipActivityRecord: Bool = false) async throws -> UnshieldResult {
        DebugLogger.log("Starting unshield for payment \(payment.id)", category: "WM-UNSHIELD")
        DebugLogger.log("Stealth address: \(payment.stealthAddress)", category: "WM-UNSHIELD")
        DebugLogger.log("Ephemeral key: \(payment.ephemeralPublicKey.base58EncodedString)", category: "WM-UNSHIELD")
        DebugLogger.log("Is hybrid: \(payment.isHybrid)", category: "WM-UNSHIELD")
        DebugLogger.log("Hop count: \(payment.hopCount)", category: "WM-UNSHIELD")

        guard let mainWallet = mainWallet, let _ = keyPair else {
            DebugLogger.error("Wallet not initialized", category: "WM-UNSHIELD")
            throw WalletError.notInitialized
        }

        // Derive spending key for this payment
        DebugLogger.log("Deriving spending key...", category: "WM-UNSHIELD")
        let spendingKey: Data
        do {
            spendingKey = try deriveSpendingKey(for: payment)
            DebugLogger.log("Spending key derived successfully", category: "WM-UNSHIELD")
        } catch {
            DebugLogger.error("Failed to derive spending key", error: error, category: "WM-UNSHIELD")
            throw error
        }

        let shieldSvc = await getOrCreateShieldService()

        let mainAddress = await mainWallet.address
        DebugLogger.log("Main wallet address: \(mainAddress)", category: "WM-UNSHIELD")

        let result = try await shieldSvc.unshield(
            payment: payment,
            mainWalletAddress: mainAddress,
            spendingKey: spendingKey,
            lamports: lamports
        )

        DebugLogger.log("Unshield transaction completed: \(result.signature)", category: "WM-UNSHIELD")

        // Record unshield activity (unless already recorded by caller)
        if !skipActivityRecord {
            recordUnshieldActivity(amount: result.amount, stealthAddress: payment.stealthAddress, signature: result.signature)
        }

        // Remove from pending payments and refresh balances
        pendingPayments.removeAll { $0.id == payment.id }
        savePendingPayments()
        updatePendingBalance()

        // Wait for RPC to propagate before refreshing balance
        try await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second delay
        await refreshMainWalletBalance()

        return result
    }

    /// Unshield with amount in SOL (convenience)
    /// - Parameters:
    ///   - sol: Amount to unshield in SOL (nil = all available)
    ///   - payment: The pending payment to unshield
    /// - Returns: UnshieldResult with transaction details
    public func unshieldSol(_ sol: Double?, payment: PendingPayment) async throws -> UnshieldResult {
        let lamports = sol.map { UInt64($0 * 1_000_000_000) }
        return try await unshield(payment: payment, lamports: lamports)
    }

    /// Unshield all pending payments to main wallet
    /// - Returns: Array of UnshieldResults for each successful unshield
    public func unshieldAll() async throws -> [UnshieldResult] {
        var results: [UnshieldResult] = []

        // Get payments that can be unshielded
        let paymentsToUnshield = pendingPayments.filter {
            $0.status == .received || $0.status == .failed
        }

        for payment in paymentsToUnshield {
            do {
                let result = try await unshield(payment: payment)
                results.append(result)
            } catch {
                // Log error but continue with other payments
                DebugLogger.error("Failed to unshield payment \(payment.id)", error: error, category: "WM-UNSHIELD")
            }
        }

        return results
    }

    // MARK: - Hop Operations

    /// Hop funds from one stealth address to another stealth address
    /// This improves privacy by breaking the direct link between stealth addresses
    /// - Parameters:
    ///   - payment: The pending payment to hop from
    ///   - lamports: Amount to hop (nil = all available)
    ///   - parentActivityId: Optional parent activity ID to link this hop to (for shield/unshield grouping)
    /// - Returns: HopResult with the new stealth address and transaction details
    public func hop(payment: PendingPayment, lamports: UInt64? = nil, parentActivityId: UUID? = nil) async throws -> HopResult {
        DebugLogger.log("Starting hop for payment \(payment.id)", category: "WM-HOP")
        DebugLogger.log("Source stealth address: \(payment.stealthAddress)", category: "WM-HOP")
        DebugLogger.log("Source ephemeral key: \(payment.ephemeralPublicKey.base58EncodedString)", category: "WM-HOP")
        DebugLogger.log("Source is hybrid: \(payment.isHybrid)", category: "WM-HOP")

        guard let keyPair = keyPair else {
            DebugLogger.error("Wallet not initialized", category: "WM-HOP")
            throw WalletError.notInitialized
        }

        // Derive spending key for this payment
        DebugLogger.log("Deriving spending key for source payment...", category: "WM-HOP")
        let spendingKey = try deriveSpendingKey(for: payment)
        DebugLogger.log("Spending key derived successfully", category: "WM-HOP")

        let shieldSvc = await getOrCreateShieldService()

        let result = try await shieldSvc.hop(
            payment: payment,
            stealthKeyPair: keyPair,
            spendingKey: spendingKey,
            lamports: lamports
        )

        DebugLogger.log("Hop transaction completed", category: "WM-HOP")
        DebugLogger.log("New stealth address: \(result.destinationStealthAddress)", category: "WM-HOP")
        DebugLogger.log("New ephemeral key: \(result.ephemeralPublicKey.base58EncodedString)", category: "WM-HOP")
        DebugLogger.log("New amount: \(result.amount) lamports", category: "WM-HOP")
        DebugLogger.log("Signature: \(result.signature)", category: "WM-HOP")

        // Remove source payment from pending
        pendingPayments.removeAll { $0.id == payment.id }

        // Add new stealth address as pending payment with incremented hop count
        let newPayment = PendingPayment(
            stealthAddress: result.destinationStealthAddress,
            ephemeralPublicKey: result.ephemeralPublicKey,
            mlkemCiphertext: result.mlkemCiphertext,
            amount: result.amount,
            tokenMint: nil,
            viewTag: result.viewTag,
            status: .received,
            isShielded: true,  // Skip auto-settlement
            hopCount: payment.hopCount + 1,
            originalPaymentId: payment.originalPaymentId ?? payment.id,
            parentPaymentId: payment.id
        )

        DebugLogger.log("Created new payment:", category: "WM-HOP")
        DebugLogger.log("  ID: \(newPayment.id)", category: "WM-HOP")
        DebugLogger.log("  Address: \(newPayment.stealthAddress)", category: "WM-HOP")
        DebugLogger.log("  Ephemeral: \(newPayment.ephemeralPublicKey.base58EncodedString)", category: "WM-HOP")
        DebugLogger.log("  Is hybrid: \(newPayment.isHybrid)", category: "WM-HOP")

        addPendingPayment(newPayment)

        savePendingPayments()
        updatePendingBalance()

        // Record hop activity
        recordHopActivity(
            amount: result.amount,
            stealthAddress: result.destinationStealthAddress,
            hopCount: newPayment.hopCount,
            signature: result.signature,
            parentActivityId: parentActivityId
        )

        DebugLogger.log("Hop complete. pendingPayments count: \(pendingPayments.count)", category: "WM-HOP")

        return result
    }

    /// Hop with amount in SOL (convenience)
    /// - Parameters:
    ///   - sol: Amount to hop in SOL (nil = all available)
    ///   - payment: The pending payment to hop from
    /// - Returns: HopResult with the new stealth address and transaction details
    public func hopSol(_ sol: Double?, payment: PendingPayment) async throws -> HopResult {
        let lamports = sol.map { UInt64($0 * 1_000_000_000) }
        return try await hop(payment: payment, lamports: lamports)
    }

    // MARK: - Split Operations (for mixing)

    /// Minimum lamports per split (0.001 SOL)
    private let minSplitAmount: UInt64 = 1_000_000

    /// Fee per transaction (approximately 0.00001 SOL)
    private let feePerTransaction: UInt64 = 10_000

    /// Split a payment into multiple random-sized parts for privacy mixing
    /// - Parameters:
    ///   - payment: Source payment to split
    ///   - parts: Number of parts (default: random 2-4)
    ///   - parentActivityId: Optional parent activity ID to link splits to
    /// - Returns: Array of new payments representing the splits
    public func splitPayment(
        payment: PendingPayment,
        parts: Int? = nil,
        parentActivityId: UUID? = nil
    ) async throws -> [PendingPayment] {
        DebugLogger.log("======== splitPayment starting ========", category: "SPLIT")
        DebugLogger.log("Source payment ID: \(payment.id)", category: "SPLIT")
        DebugLogger.log("Source amount: \(payment.amount) lamports", category: "SPLIT")

        guard let keyPair = keyPair else {
            throw WalletError.notInitialized
        }

        // Determine number of splits (2-4 if not specified)
        let numParts = parts ?? Int.random(in: 2...4)
        DebugLogger.log("Splitting into \(numParts) parts", category: "SPLIT")

        // Calculate available amount after accounting for transaction fees
        let totalFees = UInt64(numParts) * feePerTransaction
        guard payment.amount > totalFees + (UInt64(numParts) * minSplitAmount) else {
            DebugLogger.error("Insufficient balance for \(numParts) splits", category: "SPLIT")
            throw WalletError.insufficientBalance
        }

        let availableAmount = payment.amount - totalFees

        // Generate random split amounts
        let splitAmounts = generateRandomSplits(totalAmount: availableAmount, parts: numParts)
        DebugLogger.log("Split amounts: \(splitAmounts.map { "\($0) lamports" })", category: "SPLIT")

        // Derive spending key for the source payment
        let spendingKey = try deriveSpendingKey(for: payment)

        let shieldSvc = await getOrCreateShieldService()

        // Create a group ID to link all splits together
        let splitGroupId = UUID()
        var newPayments: [PendingPayment] = []

        // Execute splits sequentially (could optimize to parallel later)
        for (index, amount) in splitAmounts.enumerated() {
            let isLastSplit = (index == splitAmounts.count - 1)
            DebugLogger.log("Creating split \(index + 1) of \(numParts): \(amount) lamports\(isLastSplit ? " (closing account)" : "")", category: "SPLIT")

            // Generate new stealth address for this split (use hybrid meta-address)
            let metaAddress = keyPair.hybridMetaAddressString
            let stealthResult = try StealthAddressGenerator.generateStealthAddressAuto(
                metaAddressString: metaAddress
            )

            // Send funds to the new stealth address
            // On last split, send ALL remaining balance (nil) to close the source account
            // This avoids Solana rent issues where leftover lamports are below rent-exempt threshold
            let signature = try await shieldSvc.sendFromStealth(
                fromStealthAddress: payment.stealthAddress,
                spendingKey: spendingKey,
                toAddress: stealthResult.stealthAddress,
                lamports: isLastSplit ? nil : amount
            )

            DebugLogger.log("Split \(index + 1) transaction: \(signature)", category: "SPLIT")

            // Create new pending payment for this split
            let newPayment = PendingPayment(
                stealthAddress: stealthResult.stealthAddress,
                ephemeralPublicKey: stealthResult.ephemeralPublicKey,
                mlkemCiphertext: stealthResult.mlkemCiphertext,
                amount: amount,
                tokenMint: nil,
                viewTag: stealthResult.viewTag,
                status: .received,
                isShielded: true,
                hopCount: payment.hopCount,  // Preserve hop count
                originalPaymentId: payment.originalPaymentId ?? payment.id,
                parentPaymentId: payment.id,
                splitGroupId: splitGroupId,
                isSplitPart: true
            )

            newPayments.append(newPayment)
            addPendingPayment(newPayment)

            // Record activity for this split (as a hop with split indication)
            recordHopActivity(
                amount: amount,
                stealthAddress: stealthResult.stealthAddress,
                hopCount: newPayment.hopCount,
                signature: signature,
                parentActivityId: parentActivityId
            )

            // Brief delay between splits to avoid rate limiting
            if index < splitAmounts.count - 1 {
                try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5s
            }
        }

        // Remove the original payment (it's now split)
        pendingPayments.removeAll { $0.id == payment.id }
        savePendingPayments()
        updatePendingBalance()

        DebugLogger.log("======== splitPayment complete ========", category: "SPLIT")
        DebugLogger.log("Created \(newPayments.count) split payments", category: "SPLIT")
        return newPayments
    }

    /// Generate random amounts that sum to the total
    private func generateRandomSplits(totalAmount: UInt64, parts: Int) -> [UInt64] {
        guard parts > 1 else { return [totalAmount] }

        // Generate random weights
        let weights = (0..<parts).map { _ in Double.random(in: 0.15...1.0) }
        let totalWeight = weights.reduce(0, +)

        // Normalize to proportions
        let proportions = weights.map { $0 / totalWeight }

        // Calculate amounts ensuring minimum per split
        var amounts = proportions.map { UInt64(Double(totalAmount) * $0) }

        // Ensure minimum amount per split
        for i in 0..<amounts.count {
            if amounts[i] < minSplitAmount {
                amounts[i] = minSplitAmount
            }
        }

        // Adjust to ensure total matches (put remainder in last split)
        let currentTotal = amounts.reduce(0, +)
        if currentTotal < totalAmount {
            amounts[amounts.count - 1] += (totalAmount - currentTotal)
        } else if currentTotal > totalAmount {
            // Reduce from largest splits if we're over
            let excess = currentTotal - totalAmount
            if let maxIdx = amounts.enumerated().max(by: { $0.element < $1.element })?.offset,
               amounts[maxIdx] > minSplitAmount + excess {
                amounts[maxIdx] -= excess
            }
        }

        return amounts
    }

    // MARK: - Recombine Operations (for mixing)

    /// Recombine multiple payments into a single stealth address
    /// - Parameters:
    ///   - payments: Array of payments to combine
    ///   - parentActivityId: Optional parent activity ID to link recombine to
    /// - Returns: Single combined payment
    public func recombinePayments(
        _ payments: [PendingPayment],
        parentActivityId: UUID? = nil
    ) async throws -> PendingPayment {
        DebugLogger.log("======== recombinePayments starting ========", category: "RECOMBINE")
        DebugLogger.log("Combining \(payments.count) payments", category: "RECOMBINE")

        guard !payments.isEmpty else {
            throw WalletError.paymentNotFound
        }

        guard let keyPair = keyPair else {
            throw WalletError.notInitialized
        }

        let shieldSvc = await getOrCreateShieldService()

        // Generate a single new stealth address for the combined funds (use hybrid meta-address)
        let metaAddress = keyPair.hybridMetaAddressString
        let finalResult = try StealthAddressGenerator.generateStealthAddressAuto(
            metaAddressString: metaAddress
        )

        DebugLogger.log("Final destination: \(finalResult.stealthAddress)", category: "RECOMBINE")

        var totalAmount: UInt64 = 0
        var signatures: [String] = []

        // Send each payment to the combined address
        for (index, payment) in payments.enumerated() {
            DebugLogger.log("Processing payment \(index + 1) of \(payments.count) (closing account)", category: "RECOMBINE")
            DebugLogger.log("  Source: \(payment.stealthAddress)", category: "RECOMBINE")
            DebugLogger.log("  Expected amount: \(payment.amount) lamports", category: "RECOMBINE")

            // Derive spending key for this payment
            let spendingKey = try deriveSpendingKey(for: payment)

            // Get actual balance before sending (may differ from recorded amount)
            let actualBalance = try await faucet.getBalance(address: payment.stealthAddress)
            let estimatedSendAmount = actualBalance > feePerTransaction
                ? actualBalance - feePerTransaction
                : 0

            // Send ALL to the combined address (nil closes the source account)
            // This avoids Solana rent issues and ensures exact balance transfer
            let signature = try await shieldSvc.sendFromStealth(
                fromStealthAddress: payment.stealthAddress,
                spendingKey: spendingKey,
                toAddress: finalResult.stealthAddress,
                lamports: nil  // Send ALL, closing the account
            )

            DebugLogger.log("Transaction \(index + 1): \(signature)", category: "RECOMBINE")
            signatures.append(signature)
            totalAmount += estimatedSendAmount

            // Remove this payment from pending
            pendingPayments.removeAll { $0.id == payment.id }

            // Brief delay between transactions
            if index < payments.count - 1 {
                try? await Task.sleep(nanoseconds: 500_000_000)  // 0.5s
            }
        }

        // Create the combined payment
        let maxHopCount = payments.map { $0.hopCount }.max() ?? 0
        let combinedPayment = PendingPayment(
            stealthAddress: finalResult.stealthAddress,
            ephemeralPublicKey: finalResult.ephemeralPublicKey,
            mlkemCiphertext: finalResult.mlkemCiphertext,
            amount: totalAmount,
            tokenMint: nil,
            viewTag: finalResult.viewTag,
            status: .received,
            isShielded: true,
            hopCount: maxHopCount + 1,  // Increment hop count for recombine
            originalPaymentId: payments.first?.originalPaymentId,
            parentPaymentId: nil,  // No single parent for recombined
            splitGroupId: nil,  // Recombined payment is no longer split
            isSplitPart: false
        )

        addPendingPayment(combinedPayment)
        savePendingPayments()
        updatePendingBalance()

        // Record recombine as a hop activity
        recordHopActivity(
            amount: totalAmount,
            stealthAddress: finalResult.stealthAddress,
            hopCount: combinedPayment.hopCount,
            signature: signatures.first ?? "combined",
            parentActivityId: parentActivityId
        )

        DebugLogger.log("======== recombinePayments complete ========", category: "RECOMBINE")
        DebugLogger.log("Combined payment: \(combinedPayment.stealthAddress)", category: "RECOMBINE")
        DebugLogger.log("Total amount: \(totalAmount) lamports", category: "RECOMBINE")

        return combinedPayment
    }

    // MARK: - Reset

    /// Clear all wallet data (for testing/reset)
    /// Clear activity history (keeps wallet and pending payments)
    public func clearActivityHistory() {
        activityItems = []
        outgoingPaymentIntents = []
        userDefaults.removeObject(forKey: activityItemsKey)
        userDefaults.removeObject(forKey: outgoingIntentsKey)
    }

    public func reset() throws {
        try keychainService.deleteKeyPair()
        try? keychainService.deleteMainWalletKey()
        keyPair = nil
        mainWallet = nil
        mainWalletBalance = 0
        pendingPayments = []
        settledPayments = []
        activityItems = []
        outgoingPaymentIntents = []
        pendingBalance = 0
        isInitialized = false

        userDefaults.removeObject(forKey: pendingPaymentsKey)
        userDefaults.removeObject(forKey: settledPaymentsKey)
        userDefaults.removeObject(forKey: activityItemsKey)
        userDefaults.removeObject(forKey: outgoingIntentsKey)
    }
}

// MARK: - Errors

public enum WalletError: Error, LocalizedError {
    case notInitialized
    case keyDerivationFailed
    case paymentNotFound
    case alreadySettled
    case invalidMnemonic
    case invalidKeyLength
    case signingFailed
    case insufficientBalance

    public var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "Wallet is not initialized"
        case .keyDerivationFailed:
            return "Failed to derive spending key for payment"
        case .paymentNotFound:
            return "Payment not found"
        case .alreadySettled:
            return "Payment has already been settled"
        case .invalidMnemonic:
            return "Invalid mnemonic phrase"
        case .invalidKeyLength:
            return "Invalid key length (expected 32 or 64 bytes)"
        case .signingFailed:
            return "Failed to sign message"
        case .insufficientBalance:
            return "Insufficient balance for operation"
        }
    }
}
