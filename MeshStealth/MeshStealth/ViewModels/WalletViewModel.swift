import Foundation
import Combine
import StealthCore

/// View model for wallet state
@MainActor
class WalletViewModel: ObservableObject {
    // MARK: - Published State

    @Published var isInitialized = false
    @Published var metaAddress: String?
    @Published var hybridMetaAddress: String?
    @Published var pendingBalance: Double = 0
    @Published var pendingPayments: [PendingPayment] = []
    @Published var settledPayments: [PendingPayment] = []
    @Published var activityItems: [ActivityItem] = []
    @Published var outgoingPaymentIntents: [OutgoingPaymentIntent] = []

    // Main Wallet State
    @Published var mainWalletAddress: String?
    @Published var mainWalletBalance: Double = 0
    @Published var isAirdropping = false
    @Published var lastSyncAt: Date?

    // Shield State
    @Published var isShielding = false
    @Published var shieldError: String?
    @Published var lastShieldResult: ShieldResult?

    // Unshield State
    @Published var isUnshielding = false
    @Published var unshieldError: String?
    @Published var lastUnshieldResults: [UnshieldResult] = []

    // Mixing State
    @Published var isMixing = false
    @Published var mixProgress: Double = 0
    @Published var mixStatus: String = ""
    @Published var mixError: String?
    @Published var lastMixResult: MixResult?

    // Settlement State
    @Published var isSettling = false
    @Published var settlementProgress: SettlementProgress?
    @Published var lastSettlementResult: SettlementResult?

    // Privacy Protocol State
    @Published var privacyEnabled = false
    @Published var selectedPrivacyProtocol: PrivacyProtocolId = .direct
    @Published var privacyReady = false
    @Published var privacyPoolBalance: Double = 0
    @Published var privacyError: String?

    /// Current network (for UI display)
    let network: SolanaNetwork = .devnet

    /// Privacy routing service
    let privacyRoutingService = PrivacyRoutingService()

    // MARK: - Private

    private let walletManager: StealthWalletManager
    private var mixingService: MixingService?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    init(walletManager: StealthWalletManager) {
        self.walletManager = walletManager
        setupBindings()
        setupPrivacyBindings()
    }

    private func setupBindings() {
        // Bind initialization state
        walletManager.$isInitialized
            .assign(to: &$isInitialized)

        // Bind meta-addresses
        walletManager.$keyPair
            .map { $0?.metaAddressString }
            .assign(to: &$metaAddress)

        walletManager.$keyPair
            .map { keyPair -> String? in
                guard let kp = keyPair, kp.hasPostQuantum else { return nil }
                return kp.hybridMetaAddressString
            }
            .assign(to: &$hybridMetaAddress)

        // Bind stealth balance (convert lamports to SOL)
        walletManager.$pendingBalance
            .map { Double($0) / 1_000_000_000 }
            .assign(to: &$pendingBalance)

        // Bind payments
        walletManager.$pendingPayments
            .assign(to: &$pendingPayments)

        walletManager.$settledPayments
            .assign(to: &$settledPayments)

        // Bind activity items
        walletManager.$activityItems
            .assign(to: &$activityItems)

        // Bind outgoing payment intents
        walletManager.$outgoingPaymentIntents
            .assign(to: &$outgoingPaymentIntents)

        // Bind main wallet state
        walletManager.$mainWalletBalance
            .map { Double($0) / 1_000_000_000 }
            .assign(to: &$mainWalletBalance)

        walletManager.$isAirdropping
            .assign(to: &$isAirdropping)

        walletManager.$lastSyncAt
            .assign(to: &$lastSyncAt)

        // Load main wallet address when wallet changes
        walletManager.$mainWallet
            .sink { [weak self] wallet in
                Task { @MainActor [weak self] in
                    self?.mainWalletAddress = await wallet?.address
                }
            }
            .store(in: &cancellables)
    }

    private func setupPrivacyBindings() {
        // Bind privacy service state
        privacyRoutingService.$selectedProtocol
            .assign(to: &$selectedPrivacyProtocol)

        privacyRoutingService.$isEnabled
            .assign(to: &$privacyEnabled)

        privacyRoutingService.$isReady
            .assign(to: &$privacyReady)

        privacyRoutingService.$poolBalance
            .map { Double($0) / 1_000_000_000 }
            .assign(to: &$privacyPoolBalance)
    }

    // MARK: - Actions

    /// Get the appropriate meta-address (hybrid if available, classical otherwise)
    var displayMetaAddress: String? {
        hybridMetaAddress ?? metaAddress
    }

    /// Format balance for display
    var formattedBalance: String {
        String(format: "%.4f SOL", pendingBalance)
    }

    /// Check if wallet has post-quantum keys
    var hasPostQuantum: Bool {
        hybridMetaAddress != nil
    }

    /// Reset wallet (for testing)
    func resetWallet() throws {
        try walletManager.reset()
    }

    /// Clear activity history (keeps wallet data)
    func clearActivityHistory() {
        walletManager.clearActivityHistory()
    }

    // MARK: - Main Wallet Actions

    /// Request devnet airdrop
    func requestAirdrop() async throws -> String {
        try await walletManager.requestAirdrop()
    }

    /// Refresh main wallet balance
    func refreshBalance() async {
        await walletManager.refreshMainWalletBalance()
    }

    /// Format main wallet balance for display
    var formattedMainWalletBalance: String {
        String(format: "%.4f SOL", mainWalletBalance)
    }

    /// Total balance (main + stealth pending)
    var totalBalance: Double {
        mainWalletBalance + pendingBalance
    }

    /// Format total balance for display
    var formattedTotalBalance: String {
        String(format: "%.4f SOL", totalBalance)
    }

    /// Stealth balance (alias for clarity in UI)
    var stealthBalance: Double {
        pendingBalance
    }

    // MARK: - Shield Operations

    /// Shield funds from main wallet to stealth address
    /// Automatically performs 1-5 hops after shield for privacy
    /// - Parameter sol: Amount in SOL to shield
    func shield(sol: Double) async throws {
        guard sol > 0 else { return }

        isShielding = true
        isMixing = true  // Show mixing indicator during auto-mix
        shieldError = nil
        mixStatus = "Shielding and mixing..."
        defer {
            isShielding = false
            isMixing = false
            mixStatus = ""
        }

        do {
            let result = try await walletManager.shieldSol(sol)
            lastShieldResult = result
        } catch {
            shieldError = error.localizedDescription
            throw error
        }
    }

    /// Check if shield is available (has main wallet balance)
    var canShield: Bool {
        mainWalletBalance > 0.000005  // Need at least fee amount
    }

    /// Maximum amount that can be shielded (balance minus estimated fee)
    var maxShieldAmount: Double {
        max(0, mainWalletBalance - 0.000005)
    }

    // MARK: - Unshield Operations

    /// Unshield all pending payments back to main wallet
    func unshieldAll() async throws {
        guard canUnshield else { return }

        isUnshielding = true
        unshieldError = nil
        defer { isUnshielding = false }  // Always reset flag

        do {
            let results = try await walletManager.unshieldAll()
            lastUnshieldResults = results
        } catch {
            unshieldError = error.localizedDescription
            throw error
        }
    }

    /// Unshield a specific payment
    func unshield(payment: PendingPayment, sol: Double? = nil) async throws {
        isUnshielding = true
        unshieldError = nil
        defer { isUnshielding = false }  // Always reset flag

        do {
            let result = try await walletManager.unshieldSol(sol, payment: payment)
            lastUnshieldResults = [result]
        } catch {
            unshieldError = error.localizedDescription
            throw error
        }
    }

    /// Check if unshield is available (has stealth balance)
    var canUnshield: Bool {
        stealthBalance > 0.000005  // Need at least fee amount
    }

    /// Maximum amount that can be unshielded (stealth balance minus estimated fees)
    var maxUnshieldAmount: Double {
        // Each payment needs a fee, so estimate based on number of payments
        let feePerPayment = 0.000005
        let totalFees = feePerPayment * Double(pendingPayments.count)
        return max(0, stealthBalance - totalFees)
    }

    // MARK: - Mix Operations

    /// Unshield all payments with automatic pre-mix for privacy
    /// Each payment gets 1-5 hops before being sent to main wallet
    func unshieldWithMix() async throws {
        guard canUnshield else { return }

        // Initialize mixing service lazily
        if mixingService == nil {
            mixingService = MixingService(walletManager: walletManager)
        }

        isUnshielding = true
        isMixing = true
        unshieldError = nil
        mixStatus = "Mixing before unshield..."

        defer {
            isUnshielding = false
            isMixing = false
            mixStatus = ""
        }

        let results = await mixingService!.unshieldAllWithMix()
        lastUnshieldResults = results

        if results.isEmpty && !pendingPayments.isEmpty {
            unshieldError = "Failed to unshield payments"
        }
    }

    // MARK: - Privacy Protocol

    /// Set the privacy protocol
    func setPrivacyProtocol(_ protocolId: PrivacyProtocolId) async {
        privacyError = nil
        do {
            try await privacyRoutingService.setProtocol(protocolId)

            // Set the wallet key for the privacy provider (needed for signing transactions)
            if protocolId != .direct {
                if let secretKey = await walletManager.mainWalletSecretKey {
                    await privacyRoutingService.setWallet(secretKey)
                } else {
                    print("[WalletVM] Warning: No wallet key available for privacy protocol")
                }
            }
        } catch {
            privacyError = error.localizedDescription
        }
    }

    /// Enable or disable privacy routing
    func setPrivacyEnabled(_ enabled: Bool) {
        privacyRoutingService.setEnabled(enabled)
    }

    /// Initialize the privacy service
    func initializePrivacy() async {
        guard selectedPrivacyProtocol != .direct else { return }
        privacyError = nil
        do {
            try await privacyRoutingService.initialize()

            // Set the wallet key after initialization
            if let secretKey = await walletManager.mainWalletSecretKey {
                await privacyRoutingService.setWallet(secretKey)
            }
        } catch {
            privacyError = error.localizedDescription
        }
    }

    /// Privacy status string for display
    var privacyStatusString: String {
        privacyRoutingService.statusString
    }

    /// Prize value of selected protocol
    var privacyPrizeValue: UInt {
        privacyRoutingService.prizeValue
    }

    // MARK: - Mnemonic / Backup

    /// Get the wallet mnemonic for backup display
    func getMnemonic() async -> [String]? {
        await walletManager.walletMnemonic
    }

    /// Import wallet from mnemonic phrase
    func importWallet(mnemonic: [String]) async throws {
        try await walletManager.importWallet(mnemonic: mnemonic)
        // Refresh the main wallet address after import
        mainWalletAddress = await walletManager.mainWalletAddress
    }

    // MARK: - Settlement

    /// Get pending payments needing settlement
    var paymentsNeedingSettlement: [PendingPayment] {
        pendingPayments.filter { payment in
            !payment.isShielded && (payment.status == .received || payment.status == .failed)
        }
    }

    /// Format next retry time for a payment
    func formatNextRetryTime(_ payment: PendingPayment) -> String? {
        guard let nextRetry = payment.nextRetryAt else { return nil }

        if nextRetry <= Date() {
            return "RETRY_NOW"
        }

        let seconds = Int(nextRetry.timeIntervalSince(Date()))
        if seconds < 60 {
            return "RETRY:\(seconds)s"
        } else {
            let minutes = seconds / 60
            return "RETRY:\(minutes)m"
        }
    }
}

// MARK: - Settlement Progress

/// Progress of settlement operation
public struct SettlementProgress {
    public let total: Int
    public let completed: Int
    public let currentPaymentId: UUID?
    public let status: String

    public init(
        total: Int,
        completed: Int,
        currentPaymentId: UUID? = nil,
        status: String
    ) {
        self.total = total
        self.completed = completed
        self.currentPaymentId = currentPaymentId
        self.status = status
    }

    /// Progress percentage (0-1)
    public var progress: Double {
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total)
    }
}

// MARK: - Solana Network

enum SolanaNetwork: String, CaseIterable {
    case devnet = "Devnet"
    case mainnet = "Mainnet"

    var rpcEndpoint: String {
        switch self {
        case .devnet: return "https://api.devnet.solana.com"
        case .mainnet: return "https://api.mainnet-beta.solana.com"
        }
    }

    var explorerBaseURL: String {
        switch self {
        case .devnet: return "https://explorer.solana.com/?cluster=devnet"
        case .mainnet: return "https://explorer.solana.com"
        }
    }
}
