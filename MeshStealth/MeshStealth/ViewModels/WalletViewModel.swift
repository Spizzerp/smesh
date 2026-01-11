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

    // Main Wallet State
    @Published var mainWalletAddress: String?
    @Published var mainWalletBalance: Double = 0
    @Published var isAirdropping = false
    @Published var lastSyncAt: Date?

    /// Current network (for UI display)
    let network: SolanaNetwork = .devnet

    // MARK: - Private

    private let walletManager: StealthWalletManager
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    init(walletManager: StealthWalletManager) {
        self.walletManager = walletManager
        setupBindings()
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
