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

        // Bind balance (convert lamports to SOL)
        walletManager.$pendingBalance
            .map { Double($0) / 1_000_000_000 }
            .assign(to: &$pendingBalance)

        // Bind payments
        walletManager.$pendingPayments
            .assign(to: &$pendingPayments)

        walletManager.$settledPayments
            .assign(to: &$settledPayments)
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
}
