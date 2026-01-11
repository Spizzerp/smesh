import Foundation
import Combine

/// Status of a pending stealth payment
public enum PendingPaymentStatus: String, Codable, Sendable {
    case received       // Received via mesh, awaiting settlement
    case settling       // Settlement transaction in progress
    case settled        // Successfully settled on-chain
    case failed         // Settlement failed (will retry)
    case expired        // Payment expired before settlement
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
        isShielded: Bool = false
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

    // MARK: - Private

    private let keychainService: KeychainService
    private let userDefaults: UserDefaults
    private let faucet: DevnetFaucet
    private let pendingPaymentsKey = "meshstealth.pending_payments"
    private let settledPaymentsKey = "meshstealth.settled_payments"

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

        // Refresh balance
        await refreshMainWalletBalance()
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
        guard let keyPair = keyPair else {
            throw WalletError.notInitialized
        }

        let scanner = StealthScanner(keyPair: keyPair)

        if let ciphertext = payment.mlkemCiphertext {
            // Hybrid derivation
            guard let result = try scanner.scanHybridTransaction(
                stealthAddress: payment.stealthAddress,
                ephemeralPublicKey: payment.ephemeralPublicKey,
                mlkemCiphertext: ciphertext
            ) else {
                throw WalletError.keyDerivationFailed
            }
            return result.spendingPrivateKey
        } else {
            // Classical derivation
            guard let result = try scanner.scanTransaction(
                stealthAddress: payment.stealthAddress,
                ephemeralPublicKey: payment.ephemeralPublicKey
            ) else {
                throw WalletError.keyDerivationFailed
            }
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
            .filter { $0.status == .received || $0.status == .failed }
            .reduce(0) { $0 + $1.amount }
    }

    // MARK: - Shield Operations

    private var shieldService: ShieldService?

    /// Shield funds from main wallet to a stealth address (self-deposit)
    /// - Parameter lamports: Amount to shield in lamports
    /// - Returns: ShieldResult with transaction details
    public func shield(lamports: UInt64) async throws -> ShieldResult {
        guard let mainWallet = mainWallet, let keyPair = keyPair else {
            throw WalletError.notInitialized
        }

        if shieldService == nil {
            shieldService = ShieldService(rpcClient: faucet)
        }

        let result = try await shieldService!.shield(
            lamports: lamports,
            mainWallet: mainWallet,
            stealthKeyPair: keyPair
        )

        // Add as pending payment (so it shows in stealth balance)
        let payment = PendingPayment(
            stealthAddress: result.stealthAddress,
            ephemeralPublicKey: result.ephemeralPublicKey,
            mlkemCiphertext: result.mlkemCiphertext,
            amount: result.amount,
            tokenMint: nil,
            viewTag: result.viewTag,
            status: .received,  // Funds are in stealth address, ready to unshield
            isShielded: true    // Skip auto-settlement (already on-chain)
        )
        addPendingPayment(payment)

        // Wait for RPC to propagate before refreshing balance
        try await Task.sleep(nanoseconds: 1_000_000_000)  // 1 second delay
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
    public func unshield(payment: PendingPayment, lamports: UInt64? = nil) async throws -> UnshieldResult {
        guard let mainWallet = mainWallet, let keyPair = keyPair else {
            throw WalletError.notInitialized
        }

        // Derive spending key for this payment
        let spendingKey = try deriveSpendingKey(for: payment)

        if shieldService == nil {
            shieldService = ShieldService(rpcClient: faucet)
        }

        let mainAddress = await mainWallet.address

        let result = try await shieldService!.unshield(
            payment: payment,
            mainWalletAddress: mainAddress,
            spendingKey: spendingKey,
            lamports: lamports
        )

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

    // MARK: - Reset

    /// Clear all wallet data (for testing/reset)
    public func reset() throws {
        try keychainService.deleteKeyPair()
        try? keychainService.deleteMainWalletKey()
        keyPair = nil
        mainWallet = nil
        mainWalletBalance = 0
        pendingPayments = []
        settledPayments = []
        pendingBalance = 0
        isInitialized = false

        userDefaults.removeObject(forKey: pendingPaymentsKey)
        userDefaults.removeObject(forKey: settledPaymentsKey)
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
