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

/// Who settled the payment
public enum SettledBy: String, Codable, Sendable {
    case sender    // Sender came online and executed tx
    case receiver  // Receiver broadcast pre-signed tx
    case relay     // A relay node broadcast the tx
    case unknown   // Legacy or untracked
}

/// Result of a settlement attempt
public struct SettlementResult: Sendable {
    public let paymentId: UUID
    public let success: Bool
    public let signature: String?
    public let error: Error?
    public let attemptNumber: Int
    public let settledBy: SettledBy

    public init(
        paymentId: UUID,
        success: Bool,
        signature: String? = nil,
        error: Error? = nil,
        attemptNumber: Int = 1,
        settledBy: SettledBy = .unknown
    ) {
        self.paymentId = paymentId
        self.success = success
        self.signature = signature
        self.error = error
        self.attemptNumber = attemptNumber
        self.settledBy = settledBy
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
    private let rpcClient: DevnetFaucet
    private let config: SettlementConfiguration
    private let estimatedFee: UInt64 = 5000  // 0.000005 SOL per signature

    /// Optional privacy routing service for enhanced privacy during settlement
    public var privacyRoutingService: PrivacyRoutingService?

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
        rpcClient: DevnetFaucet = DevnetFaucet(),
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

            // Check if payment is due for retry
            if let nextRetry = payment.nextRetryAt, nextRetry > Date() {
                continue  // Not time yet
            }

            let result = await settlePayment(payment)
            lastResult = result
            resultSubject.send(result)

            if !result.success {
                // Exponential backoff before next payment
                let delay = calculateBackoffDelay(attempt: result.attemptNumber)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    /// Calculate exponential backoff delay
    /// - Parameter attempt: Current attempt number (1-based)
    /// - Returns: Delay in seconds
    private func calculateBackoffDelay(attempt: Int) -> TimeInterval {
        // Exponential backoff: 30s, 60s, 120s, 240s, 480s (capped at 8 minutes)
        let baseDelay = config.retryDelay  // 30 seconds default
        let maxDelay: TimeInterval = 480   // 8 minutes cap
        let delay = baseDelay * pow(2.0, Double(attempt - 1))
        return min(delay, maxDelay)
    }

    /// Settle a single payment
    /// Tries receiver settlement first (pre-signed tx), then falls back to existing flow
    /// Settles to a NEW stealth address (privacy hop) rather than main wallet
    public func settlePayment(_ payment: PendingPayment) async -> SettlementResult {
        let attemptNumber = payment.settlementAttempts + 1

        // Mark as settling
        walletManager.updatePaymentStatus(id: payment.id, status: .settling)

        // STEP 0: Try receiver settlement first if pre-signed tx available
        if let preSignedTx = payment.preSignedTransaction {
            DebugLogger.log("[SETTLE] Attempting receiver settlement with pre-signed tx", category: "SETTLE")

            do {
                let txSignature = try await rpcClient.sendTransaction(preSignedTx)
                DebugLogger.log("[SETTLE] Pre-signed tx broadcast: \(txSignature)", category: "SETTLE")

                // Wait for confirmation
                try await rpcClient.waitForConfirmation(signature: txSignature, timeout: config.transactionTimeout)
                DebugLogger.log("[SETTLE] Pre-signed tx confirmed!", category: "SETTLE")

                // Success! Funds are now at stealth address
                // Mark payment as awaiting funds (needs another settlement pass to move to privacy hop)
                walletManager.updatePaymentStatus(
                    id: payment.id,
                    status: .received,  // Reset to received so next pass processes it
                    signature: txSignature
                )

                return SettlementResult(
                    paymentId: payment.id,
                    success: true,
                    signature: txSignature,
                    attemptNumber: attemptNumber,
                    settledBy: .receiver
                )

            } catch let error as FaucetError {
                // Check if nonce was already consumed (sender may have settled)
                if isNonceConsumedError(error) {
                    DebugLogger.log("[SETTLE] Nonce already consumed - checking if funds arrived", category: "SETTLE")

                    // Check if funds arrived at stealth address
                    do {
                        let balance = try await rpcClient.getBalance(address: payment.stealthAddress)
                        if balance >= payment.amount - 10000 {  // Allow for small fee differences
                            DebugLogger.log("[SETTLE] Funds present - sender already settled", category: "SETTLE")
                            // Continue to normal settlement flow below
                        } else {
                            DebugLogger.log("[SETTLE] No funds at stealth address - payment may have failed", category: "SETTLE")
                            throw SettlementError.transactionFailed("Pre-signed tx consumed but no funds arrived")
                        }
                    } catch {
                        DebugLogger.error("[SETTLE] Error checking funds after nonce consumed", error: error, category: "SETTLE")
                    }
                } else {
                    DebugLogger.log("[SETTLE] Pre-signed tx failed: \(error.localizedDescription)", category: "SETTLE")
                    // Continue to existing settlement flow
                }
            } catch {
                DebugLogger.log("[SETTLE] Pre-signed tx failed: \(error.localizedDescription)", category: "SETTLE")
                // Continue to existing settlement flow
            }
        }

        // EXISTING FLOW: Derive spending key and transfer out
        do {
            // 1. Derive the spending private key
            DebugLogger.log("[SETTLE] Deriving spending key for payment \(payment.id)")
            let spendingKey = try walletManager.deriveSpendingKey(for: payment)

            // 2. Get current balance of stealth address
            let balance = try await rpcClient.getBalance(address: payment.stealthAddress)
            DebugLogger.log("[SETTLE] Balance: \(balance) lamports")

            guard balance >= config.minBalanceForSettlement else {
                throw SettlementError.insufficientBalance(
                    required: config.minBalanceForSettlement,
                    available: balance
                )
            }

            // 3. Generate new stealth destination (privacy hop to ourselves)
            let destination = try getSettlementDestination()
            DebugLogger.log("[SETTLE] New stealth destination: \(destination.address)")

            // 4. Calculate transfer amount (leave fee for transaction)
            let transferAmount = balance - estimatedFee

            // 5. Build and submit transaction
            let signature = try await buildAndSubmitTransfer(
                from: payment.stealthAddress,
                to: destination.address,
                amount: transferAmount,
                spendingKey: spendingKey
            )
            DebugLogger.log("[SETTLE] Transaction confirmed: \(signature)")

            // 6. Create new PendingPayment for the destination
            let newPayment = PendingPayment(
                stealthAddress: destination.address,
                ephemeralPublicKey: destination.ephemeralKey,
                mlkemCiphertext: destination.ciphertext,
                amount: transferAmount,
                tokenMint: payment.tokenMint,
                viewTag: destination.viewTag,
                status: .received,
                isShielded: true,  // Treat as shielded (skip auto-settlement)
                hopCount: payment.hopCount + 1,
                originalPaymentId: payment.originalPaymentId ?? payment.id,
                parentPaymentId: payment.id
            )
            walletManager.addPendingPayment(newPayment)
            DebugLogger.log("[SETTLE] Created new payment at destination: \(newPayment.id)")

            // 7. Mark original as settled
            walletManager.updatePaymentStatus(
                id: payment.id,
                status: .settled,
                signature: signature
            )

            // 8. Record hop activity
            walletManager.recordHopActivity(
                amount: transferAmount,
                stealthAddress: destination.address,
                hopCount: newPayment.hopCount,
                signature: signature,
                parentActivityId: nil
            )

            return SettlementResult(
                paymentId: payment.id,
                success: true,
                signature: signature,
                attemptNumber: attemptNumber,
                settledBy: .sender  // We derived the key and settled ourselves
            )

        } catch {
            DebugLogger.log("[SETTLE] Settlement failed: \(error)")

            // Calculate next retry time with exponential backoff
            let delay = calculateBackoffDelay(attempt: attemptNumber)
            let nextRetryAt = Date().addingTimeInterval(delay)

            // Mark as failed with next retry time
            walletManager.updatePaymentStatusWithRetry(
                id: payment.id,
                status: .failed,
                error: error.localizedDescription,
                nextRetryAt: nextRetryAt
            )

            return SettlementResult(
                paymentId: payment.id,
                success: false,
                error: error,
                attemptNumber: attemptNumber,
                settledBy: .unknown
            )
        }
    }

    /// Check if error indicates nonce was already consumed
    private func isNonceConsumedError(_ error: FaucetError) -> Bool {
        switch error {
        case .rpcError(_, let message):
            // Common error messages for consumed nonce
            let lowercased = message.lowercased()
            return lowercased.contains("blockhash not found") ||
                   lowercased.contains("nonce") ||
                   lowercased.contains("already processed") ||
                   lowercased.contains("transaction already processed")
        case .transactionFailed(let reason):
            let lowercased = reason.lowercased()
            return lowercased.contains("nonce") ||
                   lowercased.contains("blockhash")
        default:
            return false
        }
    }

    /// Cancel any ongoing settlement
    public func cancelSettlement() {
        settlementTask?.cancel()
        settlementTask = nil
        isSettling = false
    }

    // MARK: - Transaction Building

    /// Build and submit a transfer from a stealth address
    /// Follows the same pattern as ShieldService
    /// Optionally routes through privacy protocol for enhanced anonymity
    private func buildAndSubmitTransfer(
        from sourceAddress: String,
        to destinationAddress: String,
        amount: UInt64,
        spendingKey: Data
    ) async throws -> String {
        DebugLogger.log("[SETTLE-TX] Building transfer from \(sourceAddress) to \(destinationAddress)")
        DebugLogger.log("[SETTLE-TX] Amount: \(amount) lamports")

        // Check if privacy routing should be used
        if let privacyService = privacyRoutingService,
           privacyService.shouldUsePrivacyRouting(for: amount) {
            DebugLogger.log("[SETTLE-TX] Using privacy routing via \(privacyService.selectedProtocol.displayName)")

            do {
                let txSignature = try await privacyService.routeTransfer(
                    from: sourceAddress,
                    to: destinationAddress,
                    amount: amount,
                    spendingKey: spendingKey
                )
                DebugLogger.log("[SETTLE-TX] Privacy-routed transaction: \(txSignature)")
                return txSignature
            } catch {
                // Check if fallback is enabled
                if privacyService.configuration.fallbackToDirect {
                    DebugLogger.log("[SETTLE-TX] Privacy routing failed, falling back to direct: \(error)")
                    // Continue with direct transfer below
                } else {
                    throw SettlementError.transactionFailed("Privacy routing failed: \(error.localizedDescription)")
                }
            }
        }

        // Direct transfer (no privacy routing)
        DebugLogger.log("[SETTLE-TX] Using direct transfer")

        // 1. Create wallet from spending key (raw scalar, not seed-expanded)
        let stealthWallet: SolanaWallet
        do {
            stealthWallet = try SolanaWallet(stealthScalar: spendingKey)
        } catch {
            throw SettlementError.transactionFailed("Failed to create wallet from spending key: \(error.localizedDescription)")
        }

        // 2. Verify derived address matches source
        let derivedAddress = await stealthWallet.address
        guard derivedAddress == sourceAddress else {
            DebugLogger.log("[SETTLE-TX] Address mismatch!")
            DebugLogger.log("[SETTLE-TX]   Expected: \(sourceAddress)")
            DebugLogger.log("[SETTLE-TX]   Derived:  \(derivedAddress)")
            throw SettlementError.transactionFailed("Spending key mismatch - derived address doesn't match source")
        }

        // 3. Get recent blockhash
        let blockhash = try await rpcClient.getRecentBlockhash()

        // 4. Build transfer transaction
        let fromPubkey = await stealthWallet.publicKeyData
        guard let toPubkey = Data(base58Decoding: destinationAddress) else {
            throw SettlementError.transactionFailed("Invalid destination address")
        }

        let message = try SolanaTransaction.buildTransfer(
            from: fromPubkey,
            to: toPubkey,
            lamports: amount,
            recentBlockhash: blockhash
        )

        // 5. Sign with stealth wallet
        let messageBytes = message.serialize()
        let signature: Data
        do {
            signature = try await stealthWallet.sign(messageBytes)
        } catch {
            throw SettlementError.transactionFailed("Failed to sign transaction: \(error.localizedDescription)")
        }

        // 6. Build signed transaction
        let signedTx = try SolanaTransaction.buildSignedTransaction(
            message: message,
            signature: signature
        )

        // 7. Submit and wait for confirmation
        let txSignature: String
        do {
            txSignature = try await rpcClient.sendTransaction(signedTx)
        } catch {
            throw SettlementError.transactionFailed("Failed to send transaction: \(error.localizedDescription)")
        }

        // 8. Wait for confirmation with configured timeout
        try await rpcClient.waitForConfirmation(
            signature: txSignature,
            timeout: config.transactionTimeout
        )

        return txSignature
    }

    /// Settlement destination info
    private struct SettlementDestination {
        let address: String
        let ephemeralKey: Data
        let ciphertext: Data?
        let viewTag: UInt8
    }

    /// Generate a new stealth address as settlement destination
    /// This provides a privacy hop - funds settle to a NEW stealth address rather than main wallet
    private func getSettlementDestination() throws -> SettlementDestination {
        guard let keyPair = walletManager.keyPair else {
            throw SettlementError.noDestinationAddress
        }

        // Use hybrid meta-address if post-quantum keys available
        let metaAddress = keyPair.hasPostQuantum
            ? keyPair.hybridMetaAddressString
            : keyPair.metaAddressString

        // Generate new stealth address (to ourselves) for privacy
        let result = try StealthAddressGenerator.generateStealthAddressAuto(
            metaAddressString: metaAddress
        )

        return SettlementDestination(
            address: result.stealthAddress,
            ephemeralKey: result.ephemeralPublicKey,
            ciphertext: result.mlkemCiphertext,
            viewTag: result.viewTag
        )
    }

    // MARK: - Rent Reclamation

    /// Reclaim rent from CiphertextAccount PDAs after settlement
    /// Note: This is a stub - rent reclamation requires the on-chain Stealth-PQ program
    public func reclaimRent(for payment: PendingPayment) async throws -> String {
        guard payment.status == .settled else {
            throw SettlementError.paymentNotSettled
        }

        guard payment.isHybrid else {
            // Only hybrid payments have CiphertextAccount PDAs
            throw SettlementError.noRentToReclaim
        }

        // TODO: Implement actual rent reclamation when Stealth-PQ program is deployed
        // This requires:
        // 1. Deriving the CiphertextAccount PDA
        // 2. Checking if PDA still exists
        // 3. Building and signing reclaim_rent instruction
        // 4. Submitting transaction

        throw SettlementError.notImplemented(
            "Rent reclamation requires Stealth-PQ program deployment"
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
