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
        parentActivityId: UUID? = nil
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

    public init(
        id: UUID = UUID(),
        stealthAddress: String,
        ephemeralPublicKey: Data,
        mlkemCiphertext: Data?,
        amount: UInt64,
        tokenMint: String?,
        viewTag: UInt8,
        receivedAt: Date = Date(),
        status: PendingPaymentStatus = .received,
        settlementAttempts: Int = 0,
        lastAttemptAt: Date? = nil,
        settlementSignature: String? = nil,
        errorMessage: String? = nil,
        isShielded: Bool = false,
        hopCount: Int = 0,
        originalPaymentId: UUID? = nil,
        parentPaymentId: UUID? = nil
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
        self.settlementSignature = settlementSignature
        self.errorMessage = errorMessage
        self.isShielded = isShielded
        self.hopCount = hopCount
        self.originalPaymentId = originalPaymentId
        self.parentPaymentId = parentPaymentId
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
        self.settlementSignature = nil
        self.errorMessage = nil
        self.isShielded = false  // Mesh payments are not shielded
        self.hopCount = 0
        self.originalPaymentId = nil
        self.parentPaymentId = nil
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
            // Generate new stealth keypair
            let newKeyPair = try StealthKeyPair.generate()
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
        print("[DERIVE-KEY] Deriving spending key for payment \(payment.id)")
        print("[DERIVE-KEY] Stealth address: \(payment.stealthAddress)")
        print("[DERIVE-KEY] Ephemeral key: \(payment.ephemeralPublicKey.base58EncodedString)")
        print("[DERIVE-KEY] Is hybrid: \(payment.isHybrid)")

        guard let keyPair = keyPair else {
            print("[DERIVE-KEY] ERROR: keyPair is nil")
            throw WalletError.notInitialized
        }

        let scanner = StealthScanner(keyPair: keyPair)

        if let ciphertext = payment.mlkemCiphertext {
            // Hybrid derivation
            print("[DERIVE-KEY] Using hybrid derivation (MLKEM ciphertext present, \(ciphertext.count) bytes)")
            guard let result = try scanner.scanHybridTransaction(
                stealthAddress: payment.stealthAddress,
                ephemeralPublicKey: payment.ephemeralPublicKey,
                mlkemCiphertext: ciphertext
            ) else {
                print("[DERIVE-KEY] ERROR: Hybrid scan returned nil - stealth address doesn't match our keys")
                throw WalletError.keyDerivationFailed
            }
            print("[DERIVE-KEY] Hybrid derivation successful")
            return result.spendingPrivateKey
        } else {
            // Classical derivation
            print("[DERIVE-KEY] Using classical derivation")
            guard let result = try scanner.scanTransaction(
                stealthAddress: payment.stealthAddress,
                ephemeralPublicKey: payment.ephemeralPublicKey
            ) else {
                print("[DERIVE-KEY] ERROR: Classical scan returned nil - stealth address doesn't match our keys")
                throw WalletError.keyDerivationFailed
            }
            print("[DERIVE-KEY] Classical derivation successful")
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
            print("Failed to refresh balance: \(error)")
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

        outgoingPaymentIntents[index].status = status
        outgoingPaymentIntents[index].attempts += 1

        if let sig = signature {
            outgoingPaymentIntents[index].transactionSignature = sig
        }

        if let err = error {
            outgoingPaymentIntents[index].errorMessage = err
        }

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
        error: String? = nil
    ) {
        guard let index = activityItems.firstIndex(where: { $0.id == id }) else {
            return
        }

        activityItems[index].status = status

        if let sig = signature {
            activityItems[index].transactionSignature = sig
        }

        if let err = error {
            activityItems[index].errorMessage = err
        }

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

    /// Shield funds from main wallet to a stealth address (self-deposit)
    /// Automatically performs 1-5 random hops after the initial shield for privacy
    /// - Parameter lamports: Amount to shield in lamports
    /// - Returns: ShieldResult with transaction details
    public func shield(lamports: UInt64) async throws -> ShieldResult {
        guard let mainWallet = mainWallet, let keyPair = keyPair else {
            throw WalletError.notInitialized
        }

        if shieldService == nil {
            shieldService = ShieldService(rpcClient: faucet)
        }

        // Step 1: Initial shield (main → first stealth address)
        print("[SHIELD] Starting shield of \(lamports) lamports")
        let result = try await shieldService!.shield(
            lamports: lamports,
            mainWallet: mainWallet,
            stealthKeyPair: keyPair
        )
        print("[SHIELD] Initial shield complete: \(result.stealthAddress)")

        // Step 2: Create initial payment record
        var currentPayment = PendingPayment(
            stealthAddress: result.stealthAddress,
            ephemeralPublicKey: result.ephemeralPublicKey,
            mlkemCiphertext: result.mlkemCiphertext,
            amount: result.amount,
            tokenMint: nil,
            viewTag: result.viewTag,
            status: .received,
            isShielded: true
        )
        addPendingPayment(currentPayment)

        // Record shield activity BEFORE hops so we have the parent ID
        let shieldActivityId = recordShieldActivity(amount: lamports, stealthAddress: result.stealthAddress, signature: result.signature)

        // Step 3: Auto-mix with 1-5 random hops for privacy
        let hopCount = Int.random(in: 1...5)
        print("[SHIELD] Starting auto-mix with \(hopCount) hops")

        for i in 0..<hopCount {
            // Brief delay between hops (2-5 seconds)
            if i > 0 {
                let delay = Int.random(in: 2...5)
                print("[SHIELD] Waiting \(delay)s before hop \(i + 1)...")
                try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            }

            do {
                print("[SHIELD] Performing auto-mix hop \(i + 1) of \(hopCount)")
                let hopResult = try await hop(payment: currentPayment, parentActivityId: shieldActivityId)

                // Wait for state propagation
                try? await Task.sleep(nanoseconds: 2_000_000_000)

                // Find the new payment created by hop
                guard let newPayment = pendingPayments.first(where: {
                    $0.stealthAddress == hopResult.destinationStealthAddress
                }) else {
                    print("[SHIELD] Warning: Could not find new payment after hop \(i + 1), stopping auto-mix")
                    break
                }
                currentPayment = newPayment
                print("[SHIELD] Auto-mix hop \(i + 1) complete: \(currentPayment.stealthAddress)")
            } catch {
                // If hop fails, stop hopping but keep existing payment
                print("[SHIELD] Auto-mix hop \(i + 1) failed: \(error), stopping auto-mix")
                break
            }
        }

        print("[SHIELD] Auto-mix complete. Final payment at: \(currentPayment.stealthAddress)")

        // Refresh balance after all hops complete
        try await Task.sleep(nanoseconds: 1_000_000_000)
        await refreshMainWalletBalance()

        return result
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
        print("[WM-UNSHIELD] Starting unshield for payment \(payment.id)")
        print("[WM-UNSHIELD] Stealth address: \(payment.stealthAddress)")
        print("[WM-UNSHIELD] Ephemeral key: \(payment.ephemeralPublicKey.base58EncodedString)")
        print("[WM-UNSHIELD] Is hybrid: \(payment.isHybrid)")
        print("[WM-UNSHIELD] Hop count: \(payment.hopCount)")

        guard let mainWallet = mainWallet, let _ = keyPair else {
            print("[WM-UNSHIELD] ERROR: Wallet not initialized")
            throw WalletError.notInitialized
        }

        // Derive spending key for this payment
        print("[WM-UNSHIELD] Deriving spending key...")
        let spendingKey: Data
        do {
            spendingKey = try deriveSpendingKey(for: payment)
            print("[WM-UNSHIELD] Spending key derived successfully")
        } catch {
            print("[WM-UNSHIELD] ERROR: Failed to derive spending key: \(error)")
            throw error
        }

        if shieldService == nil {
            shieldService = ShieldService(rpcClient: faucet)
        }

        let mainAddress = await mainWallet.address
        print("[WM-UNSHIELD] Main wallet address: \(mainAddress)")

        let result = try await shieldService!.unshield(
            payment: payment,
            mainWalletAddress: mainAddress,
            spendingKey: spendingKey,
            lamports: lamports
        )

        print("[WM-UNSHIELD] Unshield transaction completed: \(result.signature)")

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
                print("Failed to unshield payment \(payment.id): \(error)")
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
        print("[WM-HOP] Starting hop for payment \(payment.id)")
        print("[WM-HOP] Source stealth address: \(payment.stealthAddress)")
        print("[WM-HOP] Source ephemeral key: \(payment.ephemeralPublicKey.base58EncodedString)")
        print("[WM-HOP] Source is hybrid: \(payment.isHybrid)")

        guard let keyPair = keyPair else {
            print("[WM-HOP] ERROR: Wallet not initialized")
            throw WalletError.notInitialized
        }

        // Derive spending key for this payment
        print("[WM-HOP] Deriving spending key for source payment...")
        let spendingKey = try deriveSpendingKey(for: payment)
        print("[WM-HOP] Spending key derived successfully")

        if shieldService == nil {
            shieldService = ShieldService(rpcClient: faucet)
        }

        let result = try await shieldService!.hop(
            payment: payment,
            stealthKeyPair: keyPair,
            spendingKey: spendingKey,
            lamports: lamports
        )

        print("[WM-HOP] Hop transaction completed")
        print("[WM-HOP] New stealth address: \(result.destinationStealthAddress)")
        print("[WM-HOP] New ephemeral key: \(result.ephemeralPublicKey.base58EncodedString)")
        print("[WM-HOP] New amount: \(result.amount) lamports")
        print("[WM-HOP] Signature: \(result.signature)")

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

        print("[WM-HOP] Created new payment:")
        print("[WM-HOP]   ID: \(newPayment.id)")
        print("[WM-HOP]   Address: \(newPayment.stealthAddress)")
        print("[WM-HOP]   Ephemeral: \(newPayment.ephemeralPublicKey.base58EncodedString)")
        print("[WM-HOP]   Is hybrid: \(newPayment.isHybrid)")

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

        print("[WM-HOP] Hop complete. pendingPayments count: \(pendingPayments.count)")

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
        }
    }
}
