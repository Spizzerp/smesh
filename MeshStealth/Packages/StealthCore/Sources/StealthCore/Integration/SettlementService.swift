import Foundation
import Combine

/// Configuration for settlement behavior
public struct SettlementConfiguration: Sendable {
    /// Maximum settlement attempts before giving up
    public let maxAttempts: Int

    /// Delay between retry attempts (seconds)
    public let retryDelay: TimeInterval

    /// Whether to auto-settle when connectivity is restored
    public let autoSettle: Bool

    /// Minimum balance to attempt settlement (to cover fees)
    public let minBalanceForSettlement: UInt64

    /// Whether to prefer WiFi for settlement
    public let preferWiFi: Bool

    /// Timeout for settlement transactions
    public let transactionTimeout: TimeInterval

    public init(
        maxAttempts: Int = 5,
        retryDelay: TimeInterval = 30,
        autoSettle: Bool = true,
        minBalanceForSettlement: UInt64 = 10_000,  // 0.00001 SOL
        preferWiFi: Bool = false,
        transactionTimeout: TimeInterval = 60
    ) {
        self.maxAttempts = maxAttempts
        self.retryDelay = retryDelay
        self.autoSettle = autoSettle
        self.minBalanceForSettlement = minBalanceForSettlement
        self.preferWiFi = preferWiFi
        self.transactionTimeout = transactionTimeout
    }

    public static let `default` = SettlementConfiguration()

    public static let aggressive = SettlementConfiguration(
        maxAttempts: 10,
        retryDelay: 10,
        autoSettle: true,
        minBalanceForSettlement: 5_000,
        preferWiFi: false,
        transactionTimeout: 120
    )

    public static let conservative = SettlementConfiguration(
        maxAttempts: 3,
        retryDelay: 60,
        autoSettle: true,
        minBalanceForSettlement: 50_000,
        preferWiFi: true,
        transactionTimeout: 30
    )
}

/// Result of a settlement attempt
public struct SettlementResult: Sendable {
    public let paymentId: UUID
    public let success: Bool
    public let signature: String?
    public let error: Error?
    public let attemptNumber: Int

    public init(
        paymentId: UUID,
        success: Bool,
        signature: String? = nil,
        error: Error? = nil,
        attemptNumber: Int = 1
    ) {
        self.paymentId = paymentId
        self.success = success
        self.signature = signature
        self.error = error
        self.attemptNumber = attemptNumber
    }
}

/// Service for settling pending stealth payments on-chain
@MainActor
public class SettlementService: ObservableObject {

    // MARK: - Published State

    /// Whether settlement is currently in progress
    @Published public private(set) var isSettling: Bool = false

    /// Number of payments pending settlement
    @Published public private(set) var pendingCount: Int = 0

    /// Last settlement result
    @Published public private(set) var lastResult: SettlementResult?

    // MARK: - Dependencies

    private let walletManager: StealthWalletManager
    private let networkMonitor: NetworkMonitor
    private let rpcClient: SolanaRPCClient
    private let config: SettlementConfiguration

    // MARK: - Private

    private var cancellables = Set<AnyCancellable>()
    private var settlementTask: Task<Void, Never>?

    /// Publisher for settlement results
    private let resultSubject = PassthroughSubject<SettlementResult, Never>()
    public var settlementResults: AnyPublisher<SettlementResult, Never> {
        resultSubject.eraseToAnyPublisher()
    }

    // MARK: - Initialization

    public init(
        walletManager: StealthWalletManager,
        networkMonitor: NetworkMonitor,
        rpcClient: SolanaRPCClient,
        config: SettlementConfiguration = .default
    ) {
        self.walletManager = walletManager
        self.networkMonitor = networkMonitor
        self.rpcClient = rpcClient
        self.config = config

        setupAutoSettlement()
    }

    private func setupAutoSettlement() {
        guard config.autoSettle else { return }

        // Listen for connectivity changes
        networkMonitor.connectivityChanges
            .filter { $0 }  // Only when connected
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    await self?.settleAllPending()
                }
            }
            .store(in: &cancellables)

        // Update pending count when wallet changes
        walletManager.$pendingPayments
            .map { $0.filter { $0.status == .received || $0.status == .failed }.count }
            .assign(to: &$pendingCount)
    }

    // MARK: - Settlement

    /// Settle all pending payments
    public func settleAllPending() async {
        guard !isSettling else { return }
        guard networkMonitor.isConnected else { return }

        if config.preferWiFi && !networkMonitor.hasWiFi {
            // Wait for WiFi if preferred
            return
        }

        isSettling = true
        defer { isSettling = false }

        let payments = walletManager.getPaymentsForSettlement()

        for payment in payments {
            guard payment.settlementAttempts < config.maxAttempts else {
                continue  // Skip if max attempts reached
            }

            let result = await settlePayment(payment)
            lastResult = result
            resultSubject.send(result)

            if !result.success {
                // Wait before next attempt
                try? await Task.sleep(nanoseconds: UInt64(config.retryDelay * 1_000_000_000))
            }
        }
    }

    /// Settle a single payment
    public func settlePayment(_ payment: PendingPayment) async -> SettlementResult {
        let attemptNumber = payment.settlementAttempts + 1

        // Mark as settling
        walletManager.updatePaymentStatus(id: payment.id, status: .settling)

        do {
            // 1. Derive the spending private key
            let spendingKey = try walletManager.deriveSpendingKey(for: payment)

            // 2. Get current balance of stealth address
            let balance = try await rpcClient.getBalance(pubkey: payment.stealthAddress)

            guard balance >= config.minBalanceForSettlement else {
                throw SettlementError.insufficientBalance(
                    required: config.minBalanceForSettlement,
                    available: balance
                )
            }

            // 3. Get destination address (user's main wallet or derived)
            guard let destinationAddress = getSettlementDestination() else {
                throw SettlementError.noDestinationAddress
            }

            // 4. Build and sign transaction
            let signature = try await buildAndSubmitTransfer(
                from: payment.stealthAddress,
                to: destinationAddress,
                amount: balance - 5000,  // Leave some for fee
                spendingKey: spendingKey
            )

            // 5. Mark as settled
            walletManager.updatePaymentStatus(
                id: payment.id,
                status: .settled,
                signature: signature
            )

            return SettlementResult(
                paymentId: payment.id,
                success: true,
                signature: signature,
                attemptNumber: attemptNumber
            )

        } catch {
            // Mark as failed
            walletManager.updatePaymentStatus(
                id: payment.id,
                status: .failed,
                error: error.localizedDescription
            )

            return SettlementResult(
                paymentId: payment.id,
                success: false,
                error: error,
                attemptNumber: attemptNumber
            )
        }
    }

    /// Cancel any ongoing settlement
    public func cancelSettlement() {
        settlementTask?.cancel()
        settlementTask = nil
        isSettling = false
    }

    // MARK: - Transaction Building

    private func buildAndSubmitTransfer(
        from sourceAddress: String,
        to destinationAddress: String,
        amount: UInt64,
        spendingKey: Data
    ) async throws -> String {
        // Get recent blockhash
        let blockhash = try await rpcClient.getLatestBlockhash()

        // Build transfer instruction
        // Note: In a full implementation, this would:
        // 1. Create a proper Solana transaction
        // 2. Sign with the spending key
        // 3. Submit to the network
        // For now, we'll simulate success

        // TODO: Implement actual transaction building and signing
        // This requires proper ed25519 signing from the derived spending key

        throw SettlementError.notImplemented(
            "Full transaction building requires ed25519 signing integration"
        )
    }

    private func getSettlementDestination() -> String? {
        // In a full implementation, this would return the user's main wallet address
        // For now, return the spending public key from the keypair
        guard let keyPair = walletManager.keyPair else { return nil }
        return SolanaRPCClient.encodePublicKey(keyPair.spendingPublicKey)
    }

    // MARK: - Rent Reclamation

    /// Reclaim rent from CiphertextAccount PDAs after settlement
    public func reclaimRent(for payment: PendingPayment) async throws -> String {
        guard payment.status == .settled else {
            throw SettlementError.paymentNotSettled
        }

        guard payment.isHybrid else {
            // Only hybrid payments have CiphertextAccount PDAs
            throw SettlementError.noRentToReclaim
        }

        // Derive PDA address
        let stealthPubkey = try SolanaRPCClient.decodePublicKey(payment.stealthAddress)
        let (pdaAddress, _) = try StealthPQClient.deriveCiphertextPDA(
            stealthPubkey: stealthPubkey,
            programId: STEALTH_PQ_PROGRAM_ID
        )

        // Check if PDA still exists
        let accountInfo = try await rpcClient.getAccountInfo(pubkey: pdaAddress)
        guard accountInfo != nil else {
            throw SettlementError.pdaNotFound
        }

        // Build reclaim_rent instruction
        // TODO: Implement actual reclaim transaction

        throw SettlementError.notImplemented(
            "Rent reclamation requires transaction signing"
        )
    }
}

// MARK: - Errors

public enum SettlementError: Error, LocalizedError {
    case insufficientBalance(required: UInt64, available: UInt64)
    case noDestinationAddress
    case transactionFailed(String)
    case paymentNotSettled
    case noRentToReclaim
    case pdaNotFound
    case notImplemented(String)

    public var errorDescription: String? {
        switch self {
        case .insufficientBalance(let required, let available):
            return "Insufficient balance: need \(required) lamports, have \(available)"
        case .noDestinationAddress:
            return "No destination address configured"
        case .transactionFailed(let reason):
            return "Transaction failed: \(reason)"
        case .paymentNotSettled:
            return "Payment must be settled before reclaiming rent"
        case .noRentToReclaim:
            return "No rent to reclaim (classical payment)"
        case .pdaNotFound:
            return "CiphertextAccount PDA not found"
        case .notImplemented(let feature):
            return "Not implemented: \(feature)"
        }
    }
}
