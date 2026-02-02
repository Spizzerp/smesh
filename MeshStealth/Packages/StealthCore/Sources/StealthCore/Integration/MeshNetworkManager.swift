import Foundation
import Combine

/// High-level manager coordinating mesh networking, wallet, and settlement
/// This is the main entry point for app integration
@MainActor
public class MeshNetworkManager: ObservableObject {

    // MARK: - Published State

    /// Whether mesh networking is active
    @Published public private(set) var isMeshActive: Bool = false

    /// Whether we have internet connectivity
    @Published public private(set) var isOnline: Bool = false

    /// Number of connected mesh peers
    @Published public private(set) var connectedPeerCount: Int = 0

    /// Pending payments awaiting settlement
    @Published public private(set) var pendingPaymentCount: Int = 0

    /// Current wallet balance (pending + settled)
    @Published public private(set) var totalBalance: UInt64 = 0

    /// Last error that occurred
    @Published public private(set) var lastError: Error?

    // MARK: - Components

    /// BLE mesh service
    public let meshService: BLEMeshService

    /// Wallet manager
    public let walletManager: StealthWalletManager

    /// Network monitor
    public let networkMonitor: NetworkMonitor

    /// Settlement service
    public let settlementService: SettlementService

    /// Payload encryption service
    public let encryptionService: PayloadEncryptionService

    /// Privacy routing service for enhanced sender anonymity
    public var privacyRoutingService: PrivacyRoutingService?

    /// Durable nonce manager for pre-signed transactions
    public let nonceManager: DurableNonceManager

    // MARK: - Private

    private let rpcClient: SolanaRPCClient
    private let faucet: DevnetFaucet
    private let estimatedFee: UInt64 = 5000  // 0.000005 SOL per signature
    private var cancellables = Set<AnyCancellable>()

    /// Publisher for incoming payments
    private let incomingPaymentSubject = PassthroughSubject<MeshStealthPayload, Never>()
    public var incomingPayments: AnyPublisher<MeshStealthPayload, Never> {
        incomingPaymentSubject.eraseToAnyPublisher()
    }

    // MARK: - Initialization

    public init(
        cluster: SolanaCluster = .devnet,
        meshService: BLEMeshService? = nil,
        walletManager: StealthWalletManager? = nil
    ) {
        // Initialize components
        self.rpcClient = SolanaRPCClient(cluster: cluster)
        self.faucet = DevnetFaucet()
        self.encryptionService = PayloadEncryptionService()
        self.networkMonitor = NetworkMonitor()
        self.walletManager = walletManager ?? StealthWalletManager()
        self.meshService = meshService ?? BLEMeshService()
        self.nonceManager = DurableNonceManager(rpcClient: self.faucet)

        self.settlementService = SettlementService(
            walletManager: self.walletManager,
            networkMonitor: self.networkMonitor,
            rpcClient: self.faucet
        )

        setupBindings()
    }

    private func setupBindings() {
        // Bind mesh service state
        meshService.$isActive
            .receive(on: DispatchQueue.main)
            .assign(to: &$isMeshActive)

        // Bind network state
        networkMonitor.$isConnected
            .assign(to: &$isOnline)

        // Bind peer count
        meshService.$connectedPeers
            .map { $0.count }
            .receive(on: DispatchQueue.main)
            .assign(to: &$connectedPeerCount)

        // Bind pending payments
        walletManager.$pendingPayments
            .map { $0.count }
            .assign(to: &$pendingPaymentCount)

        // Bind balance
        walletManager.$pendingBalance
            .assign(to: &$totalBalance)

        // Subscribe to mesh node payment notifications
        let meshNode = meshService.getNode()

        // Listen for incoming stealth payments via Combine
        meshNode.paymentsReceived
            .receive(on: DispatchQueue.main)
            .sink { [weak self] payload in
                self?.handleIncomingPayment(payload)
            }
            .store(in: &cancellables)
    }

    // MARK: - Lifecycle

    /// Initialize the manager (call on app launch)
    public func initialize() async throws {
        // Initialize wallet
        try await walletManager.initialize()

        // Start network monitoring
        networkMonitor.start()

        // Setup connectivity callback for auto-settlement, balance refresh, and nonce pool
        networkMonitor.onConnected = { [weak self] in
            Task { @MainActor in
                guard let self = self else { return }

                // Refresh wallet balance when coming online
                await self.walletManager.refreshMainWalletBalance()

                // Replenish nonce pool for pre-signed transactions
                if let mainWallet = self.walletManager.mainWallet {
                    do {
                        try await self.nonceManager.replenishPool(authorityWallet: mainWallet)
                    } catch {
                        DebugLogger.error("Failed to replenish nonce pool", error: error, category: "NONCE")
                    }
                }

                // Execute any queued outgoing payments
                await self.executeQueuedPayments()

                // Settle any pending incoming payments
                await self.settlementService.settleAllPending()
            }
        }

        // Also refresh balance and nonce pool immediately if already online
        if networkMonitor.isConnected {
            Task {
                await walletManager.refreshMainWalletBalance()

                // Replenish nonce pool on startup if online
                if let mainWallet = walletManager.mainWallet {
                    do {
                        try await nonceManager.replenishPool(authorityWallet: mainWallet)
                    } catch {
                        DebugLogger.error("Failed to replenish nonce pool on init", error: error, category: "NONCE")
                    }
                }
            }
        }
    }

    /// Start mesh networking
    public func startMesh() {
        meshService.start()
    }

    /// Stop mesh networking
    public func stopMesh() {
        meshService.stop()
    }

    /// Shutdown (call on app termination)
    public func shutdown() {
        stopMesh()
        networkMonitor.stop()
        cancellables.removeAll()
    }

    // MARK: - Privacy Routing Configuration

    /// Configure privacy routing for enhanced anonymity
    /// This enables routing shield/unshield operations through the privacy pool
    /// - Parameter service: The privacy routing service to use (nil to disable)
    public func setPrivacyRoutingService(_ service: PrivacyRoutingService?) {
        self.privacyRoutingService = service
        // Pass to settlement service
        settlementService.privacyRoutingService = service
        // Pass to wallet manager for shield/unshield operations
        walletManager.setPrivacyRoutingService(service)
        DebugLogger.log("Privacy routing \(service != nil ? "enabled" : "disabled")", category: "MeshNetwork")
    }

    // MARK: - Sending Payments

    /// Send a stealth payment to a recipient via mesh
    /// Works both online and offline:
    /// - Online: Sends SOL on-chain immediately, then broadcasts mesh payload
    /// - Offline: Queues on-chain transaction, broadcasts mesh payload for recipient
    /// - Parameters:
    ///   - recipientMetaAddress: Recipient's meta-address (classical or hybrid)
    ///   - amount: Amount in lamports
    ///   - tokenMint: SPL token mint (nil for native SOL)
    ///   - memo: Optional memo for recipient
    public func sendPayment(
        to recipientMetaAddress: String,
        amount: UInt64,
        tokenMint: String? = nil,
        memo: String? = nil
    ) async throws {
        DebugLogger.log("========== STARTING MESH PAYMENT ==========", category: "MESH-SEND")
        DebugLogger.log("Amount: \(amount) lamports (\(Double(amount) / 1_000_000_000) SOL)", category: "MESH-SEND")
        DebugLogger.log("Online: \(isOnline)", category: "MESH-SEND")
        DebugLogger.log("Meta-address length: \(recipientMetaAddress.count) chars", category: "MESH-SEND")
        DebugLogger.log("Meta-address preview: \(recipientMetaAddress.prefix(20))...\(recipientMetaAddress.suffix(10))", category: "MESH-SEND")

        // Verify we have a wallet to send from
        guard walletManager.mainWallet != nil else {
            DebugLogger.error("Wallet not initialized!", category: "MESH-SEND")
            throw MeshNetworkError.walletNotInitialized
        }
        DebugLogger.log("Wallet exists", category: "MESH-SEND")

        // Parse meta-address
        DebugLogger.log("Parsing meta-address...", category: "MESH-SEND")
        let (spendingPubKey, viewingPubKey, mlkemPubKey): (Data, Data, Data?)
        do {
            (spendingPubKey, viewingPubKey, mlkemPubKey) = try parseMetaAddress(recipientMetaAddress)
            DebugLogger.log("Meta-address parsed successfully", category: "MESH-SEND")
            DebugLogger.log("  - Spending pubkey: \(spendingPubKey.count) bytes", category: "MESH-SEND")
            DebugLogger.log("  - Viewing pubkey: \(viewingPubKey.count) bytes", category: "MESH-SEND")
            DebugLogger.log("  - MLKEM pubkey: \(mlkemPubKey?.count ?? 0) bytes (hybrid: \(mlkemPubKey != nil))", category: "MESH-SEND")
        } catch {
            DebugLogger.error("Failed to parse meta-address", error: error, category: "MESH-SEND")
            throw error
        }

        // Generate stealth address
        DebugLogger.log("Generating stealth address...", category: "MESH-SEND")
        let stealthResult: StealthAddressResult

        do {
            if let mlkemKey = mlkemPubKey {
                // Hybrid mode
                DebugLogger.log("Using HYBRID mode (X25519 + MLKEM768)", category: "MESH-SEND")
                stealthResult = try StealthAddressGenerator.generateHybridStealthAddress(
                    spendingPublicKey: spendingPubKey,
                    viewingPublicKey: viewingPubKey,
                    mlkemPublicKey: mlkemKey
                )
                DebugLogger.log("Generated hybrid stealth address: \(stealthResult.stealthAddress)", category: "MESH-SEND")
            } else {
                // Classical mode
                DebugLogger.log("Using CLASSICAL mode (X25519 only)", category: "MESH-SEND")
                stealthResult = try StealthAddressGenerator.generateStealthAddress(
                    spendingPublicKey: spendingPubKey,
                    viewingPublicKey: viewingPubKey
                )
                DebugLogger.log("Generated classical stealth address: \(stealthResult.stealthAddress)", category: "MESH-SEND")
            }
        } catch {
            DebugLogger.error("Failed to generate stealth address", error: error, category: "MESH-SEND")
            throw error
        }

        // Step 1: Create outgoing payment intent FIRST (so it's always queued)
        let intent = OutgoingPaymentIntent(
            recipientMetaAddress: recipientMetaAddress,
            stealthAddress: stealthResult.stealthAddress,
            ephemeralPublicKey: stealthResult.ephemeralPublicKey,
            mlkemCiphertext: stealthResult.mlkemCiphertext,
            amount: amount,
            memo: memo
        )

        // Step 2: Queue the payment intent immediately (this also records activity)
        // Payment is now tracked even if mesh broadcast or on-chain execution fails
        walletManager.queueOutgoingPayment(intent)
        DebugLogger.log("Payment intent queued: \(intent.id)", category: "MESH-SEND")

        // Step 3: Try to pre-sign transaction if nonce available (for receiver-settles flow)
        var preSignedTransaction: String? = nil
        var nonceAccountAddress: String? = nil

        do {
            let nonceEntry = try await nonceManager.reserveNonce()  // Actor-isolated call
            DebugLogger.log("Reserved nonce: \(nonceEntry.address)", category: "MESH-SEND")

            // Build durable nonce transfer
            guard let mainWallet = walletManager.mainWallet else {
                throw MeshNetworkError.walletNotInitialized
            }

            let senderPubkey = await mainWallet.publicKeyData
            guard let stealthAddressPubkey = Data(base58Decoding: stealthResult.stealthAddress) else {
                throw MeshNetworkError.invalidStealthAddress
            }
            guard let nonceAccountPubkey = Data(base58Decoding: nonceEntry.address) else {
                throw MeshNetworkError.invalidStealthAddress
            }

            let message = try SolanaTransaction.buildDurableNonceTransfer(
                from: senderPubkey,
                to: stealthAddressPubkey,
                lamports: amount,
                nonceAccount: nonceAccountPubkey,
                nonceAuthority: senderPubkey,
                nonceValue: nonceEntry.nonceValue
            )

            let signature = try await mainWallet.sign(message.serialize())
            preSignedTransaction = try SolanaTransaction.buildSignedTransaction(
                message: message,
                signature: signature
            )
            nonceAccountAddress = nonceEntry.address

            DebugLogger.log("Pre-signed transaction created (v2 protocol)", category: "MESH-SEND")
        } catch NonceError.poolEmpty {
            // No nonces available - use v1 protocol (sender settles)
            DebugLogger.log("No nonces available - using v1 protocol (sender settles)", category: "MESH-SEND")
        } catch {
            // Pre-signing failed - fall back to v1 protocol
            DebugLogger.error("Pre-signing failed, using v1 protocol", error: error, category: "MESH-SEND")
        }

        // Step 4: Create mesh payload with pre-signed tx if available
        DebugLogger.log("Creating mesh payload...", category: "MESH-SEND")
        let payload = MeshStealthPayload(
            from: stealthResult,
            amount: amount,
            tokenMint: tokenMint,
            memo: memo,
            preSignedTransaction: preSignedTransaction,
            nonceAccountAddress: nonceAccountAddress
        )
        DebugLogger.log("Payload created (v\(payload.protocolVersion.rawValue), estimated size: \(payload.estimatedSize) bytes)", category: "MESH-SEND")

        // Broadcast via mesh (best-effort - payment is already queued for on-chain execution)
        DebugLogger.log("Broadcasting via BLE mesh...", category: "MESH-SEND")
        do {
            try await meshService.sendPayment(payload)
            DebugLogger.log("Mesh payload broadcast complete", category: "MESH-SEND")
        } catch {
            // Mesh broadcast failed (no peers connected) - that's OK, payment is queued
            DebugLogger.log("BLE broadcast failed (no peers?): \(error.localizedDescription) - payment still queued", category: "MESH-SEND")
        }

        // Step 4: If online, try to execute on-chain; otherwise stay queued
        // Network errors are caught and payment stays queued (graceful offline fallback)
        if isOnline {
            do {
                DebugLogger.log("Online - attempting on-chain transfer", category: "MESH-SEND")
                try await executeOutgoingPayment(intent)
            } catch {
                // Network error - queue for later instead of failing
                if isNetworkError(error) {
                    DebugLogger.log("Network unavailable - payment queued for later: \(error.localizedDescription)", category: "MESH-SEND")
                    // Payment already queued at step 2, just log and continue
                    // Don't throw - payment is safely queued
                } else {
                    // Non-network error (e.g., insufficient balance) - re-throw
                    throw error
                }
            }
        } else {
            DebugLogger.log("Offline - payment queued for later execution", category: "MESH-SEND")
        }
    }

    /// Execute a queued outgoing payment on-chain
    private func executeOutgoingPayment(_ intent: OutgoingPaymentIntent) async throws {
        DebugLogger.log("========== EXECUTING ON-CHAIN PAYMENT ==========", category: "MESH-SEND")
        DebugLogger.log("Intent ID: \(intent.id)", category: "MESH-SEND")
        DebugLogger.log("Amount: \(intent.amount) lamports", category: "MESH-SEND")
        DebugLogger.log("To stealth address: \(intent.stealthAddress)", category: "MESH-SEND")

        guard let mainWallet = walletManager.mainWallet else {
            DebugLogger.error("Main wallet not found!", category: "MESH-SEND")
            throw MeshNetworkError.walletNotInitialized
        }

        // Update status to sending
        walletManager.updateOutgoingIntent(id: intent.id, status: .sending)

        do {
            // Check balance
            let mainAddress = await mainWallet.address
            DebugLogger.log("From address: \(mainAddress)", category: "MESH-SEND")

            DebugLogger.log("Fetching balance...", category: "MESH-SEND")
            let balance = try await faucet.getBalance(address: mainAddress)
            let requiredAmount = intent.amount + estimatedFee
            DebugLogger.log("Balance: \(balance) lamports (\(Double(balance) / 1_000_000_000) SOL)", category: "MESH-SEND")
            DebugLogger.log("Required: \(requiredAmount) lamports (\(Double(requiredAmount) / 1_000_000_000) SOL)", category: "MESH-SEND")

            guard balance >= requiredAmount else {
                DebugLogger.error("Insufficient balance!", category: "MESH-SEND")
                throw MeshNetworkError.insufficientBalance(available: balance, required: requiredAmount)
            }
            DebugLogger.log("Balance sufficient", category: "MESH-SEND")

            // Build and send transaction
            DebugLogger.log("Fetching recent blockhash...", category: "MESH-SEND")
            let blockhash = try await faucet.getRecentBlockhash()
            DebugLogger.log("Blockhash: \(blockhash.prefix(20))...", category: "MESH-SEND")

            let fromPubkey = await mainWallet.publicKeyData
            guard let toPubkey = Data(base58Decoding: intent.stealthAddress) else {
                DebugLogger.error("Invalid stealth address encoding!", category: "MESH-SEND")
                throw MeshNetworkError.invalidStealthAddress
            }

            DebugLogger.log("Building transaction...", category: "MESH-SEND")
            let message = try SolanaTransaction.buildTransfer(
                from: fromPubkey,
                to: toPubkey,
                lamports: intent.amount,
                recentBlockhash: blockhash
            )
            DebugLogger.log("Transaction message built", category: "MESH-SEND")

            let messageBytes = message.serialize()
            DebugLogger.log("Signing transaction...", category: "MESH-SEND")
            let signature = try await mainWallet.sign(messageBytes)
            DebugLogger.log("Transaction signed", category: "MESH-SEND")

            let signedTx = try SolanaTransaction.buildSignedTransaction(
                message: message,
                signature: signature
            )

            // Check if privacy routing should be used for sender anonymity
            let txSignature: String
            if let privacyService = privacyRoutingService,
               privacyService.shouldUsePrivacyRouting(for: intent.amount) {
                DebugLogger.log("Using privacy routing via \(privacyService.selectedProtocol.displayName)", category: "MESH-SEND")

                // For outgoing payments from main wallet, we need to first deposit into privacy pool
                // then withdraw to the stealth address
                do {
                    // Deposit from main wallet (requires on-chain tx first, then privacy withdrawal)
                    _ = try await privacyService.deposit(amount: intent.amount)
                    txSignature = try await privacyService.withdraw(
                        amount: intent.amount,
                        destination: intent.stealthAddress
                    ).signature
                    DebugLogger.log("Privacy-routed transaction: \(txSignature)", category: "MESH-SEND")
                } catch {
                    if privacyService.configuration.fallbackToDirect {
                        DebugLogger.error("Privacy routing failed, falling back to direct", error: error, category: "MESH-SEND")
                        txSignature = try await faucet.sendTransaction(signedTx)
                    } else {
                        throw error
                    }
                }
            } else {
                DebugLogger.log("Submitting transaction to network...", category: "MESH-SEND")
                txSignature = try await faucet.sendTransaction(signedTx)
            }
            DebugLogger.log("Transaction submitted: \(txSignature)", category: "MESH-SEND")

            // Wait for confirmation
            DebugLogger.log("Waiting for confirmation (timeout: 30s)...", category: "MESH-SEND")
            try await faucet.waitForConfirmation(signature: txSignature, timeout: 30)
            DebugLogger.log("Transaction confirmed!", category: "MESH-SEND")

            // Update intent status
            walletManager.updateOutgoingIntent(id: intent.id, status: .confirmed, signature: txSignature)

            // Record activity
            walletManager.updateActivityStatus(id: intent.id, status: .completed, signature: txSignature)

            // Refresh balance
            DebugLogger.log("Refreshing balance...", category: "MESH-SEND")
            await walletManager.refreshMainWalletBalance()
            DebugLogger.log("========== PAYMENT COMPLETE ==========", category: "MESH-SEND")

        } catch {
            DebugLogger.log("========== PAYMENT FAILED ==========", category: "MESH-SEND")
            DebugLogger.error("Error type: \(type(of: error))", category: "MESH-SEND")
            DebugLogger.error("\(error)", category: "MESH-SEND")
            DebugLogger.error("Localized: \(error.localizedDescription)", category: "MESH-SEND")
            walletManager.updateOutgoingIntent(id: intent.id, status: .failed, error: error.localizedDescription)
            throw error
        }
    }

    /// Execute all queued outgoing payments (called when coming online)
    public func executeQueuedPayments() async {
        let queuedPayments = walletManager.getQueuedOutgoingPayments()
        DebugLogger.log("Executing \(queuedPayments.count) queued payments", category: "MESH-SEND")

        for intent in queuedPayments {
            do {
                try await executeOutgoingPayment(intent)
            } catch {
                DebugLogger.error("Failed to execute queued payment \(intent.id)", error: error, category: "MESH-SEND")
                // Continue with other payments
            }
        }
    }

    /// Send an encrypted payment (payload is encrypted to recipient)
    public func sendEncryptedPayment(
        to recipientMetaAddress: String,
        amount: UInt64,
        tokenMint: String? = nil,
        memo: String? = nil
    ) async throws {
        // Parse meta-address to get viewing key
        let (spendingPubKey, viewingPubKey, mlkemPubKey) = try parseMetaAddress(recipientMetaAddress)

        // Generate stealth address
        let stealthResult: StealthAddressResult

        if let mlkemKey = mlkemPubKey {
            stealthResult = try StealthAddressGenerator.generateHybridStealthAddress(
                spendingPublicKey: spendingPubKey,
                viewingPublicKey: viewingPubKey,
                mlkemPublicKey: mlkemKey
            )
        } else {
            stealthResult = try StealthAddressGenerator.generateStealthAddress(
                spendingPublicKey: spendingPubKey,
                viewingPublicKey: viewingPubKey
            )
        }

        // Create payload
        let payload = MeshStealthPayload(
            from: stealthResult,
            amount: amount,
            tokenMint: tokenMint,
            memo: memo
        )

        // Encrypt payload
        let encrypted = try encryptionService.encrypt(
            payload: payload,
            recipientViewingKey: viewingPubKey
        )

        // Create encrypted mesh message and broadcast
        let encryptedData = try encrypted.serialize()

        // Wrap in a mesh message
        let message = MeshMessage(
            type: .stealthPayment,
            ttl: DEFAULT_MESSAGE_TTL,
            originPeerID: meshService.getNode().peerID,
            payload: encryptedData
        )

        try await meshService.broadcastMessage(message)
    }

    // MARK: - Receiving Payments

    private func handleIncomingPayment(_ payload: MeshStealthPayload) {
        // Check if this payment is for us
        let isOurs = walletManager.checkStealthAddress(
            address: payload.stealthAddress,
            ephemeralPublicKey: payload.ephemeralPublicKey,
            mlkemCiphertext: payload.mlkemCiphertext
        )

        if isOurs {
            // Add to pending payments
            walletManager.addPendingPayment(from: payload)
            incomingPaymentSubject.send(payload)

            // Try to settle if online
            if isOnline {
                Task {
                    await settlementService.settleAllPending()
                }
            }
        }
    }

    // MARK: - Settlement

    /// Manually trigger settlement of all pending payments
    public func settlePendingPayments() async {
        await settlementService.settleAllPending()
    }

    /// Retry settlement for a specific payment
    /// - Parameter payment: The payment to retry
    /// - Returns: Settlement result
    public func retrySettlement(payment: PendingPayment) async -> SettlementResult {
        await settlementService.settlePayment(payment)
    }

    // MARK: - Helpers

    private func parseMetaAddress(_ metaAddress: String) throws -> (Data, Data, Data?) {
        DebugLogger.log("parseMetaAddress: input length = \(metaAddress.count) chars", category: "MESH-SEND")

        // Check if base58 is valid first
        guard let decodedData = metaAddress.base58DecodedData else {
            DebugLogger.error("parseMetaAddress: Invalid base58 encoding!", category: "MESH-SEND")
            throw MeshNetworkError.invalidMetaAddress
        }
        DebugLogger.log("parseMetaAddress: decoded to \(decodedData.count) bytes", category: "MESH-SEND")

        // Try hybrid first (64 or 1248 bytes)
        do {
            let parsed = try StealthKeyPair.parseHybridMetaAddress(metaAddress)
            DebugLogger.log("parseMetaAddress: Parsed as hybrid/classical format", category: "MESH-SEND")
            return (parsed.spendingPubKey, parsed.viewingPubKey, parsed.mlkemPubKey)
        } catch {
            DebugLogger.log("parseMetaAddress: Hybrid parse failed: \(error)", category: "MESH-SEND")
        }

        // Try classical (exactly 64 bytes)
        do {
            let parsed = try StealthKeyPair.parseMetaAddress(metaAddress)
            DebugLogger.log("parseMetaAddress: Parsed as classical format", category: "MESH-SEND")
            return (parsed.spendingPubKey, parsed.viewingPubKey, nil)
        } catch {
            DebugLogger.log("parseMetaAddress: Classical parse failed: \(error)", category: "MESH-SEND")
        }

        DebugLogger.error("parseMetaAddress: Neither format matched! Expected 64 or 1248 bytes, got \(decodedData.count)", category: "MESH-SEND")
        throw MeshNetworkError.invalidMetaAddress
    }

    /// Check if an error is a network/connectivity error that should trigger queuing
    private func isNetworkError(_ error: Error) -> Bool {
        let nsError = error as NSError

        // URLSession network errors
        if nsError.domain == NSURLErrorDomain {
            let networkCodes: Set<Int> = [
                NSURLErrorTimedOut,
                NSURLErrorCannotFindHost,
                NSURLErrorCannotConnectToHost,
                NSURLErrorNetworkConnectionLost,
                NSURLErrorNotConnectedToInternet,
                NSURLErrorDNSLookupFailed
            ]
            return networkCodes.contains(nsError.code)
        }

        // Check error description for common network messages
        let description = error.localizedDescription.lowercased()
        return description.contains("timed out") ||
               description.contains("network") ||
               description.contains("connection") ||
               description.contains("offline")
    }

    // MARK: - Debug/Status

    /// Get current status summary
    public var statusSummary: String {
        var parts: [String] = []

        parts.append("Mesh: \(isMeshActive ? "Active" : "Inactive")")
        parts.append("Peers: \(connectedPeerCount)")
        parts.append("Online: \(isOnline ? "Yes" : "No")")
        parts.append("Pending: \(pendingPaymentCount)")

        if totalBalance > 0 {
            let sol = Double(totalBalance) / 1_000_000_000
            parts.append("Balance: \(String(format: "%.4f", sol)) SOL")
        }

        return parts.joined(separator: " | ")
    }
}

// MARK: - Errors

public enum MeshNetworkError: Error, LocalizedError {
    case invalidMetaAddress
    case walletNotInitialized
    case meshNotActive
    case encryptionFailed
    case sendFailed(Error)
    case insufficientBalance(available: UInt64, required: UInt64)
    case invalidStealthAddress
    case signingFailed

    public var errorDescription: String? {
        switch self {
        case .invalidMetaAddress:
            return "Invalid recipient meta-address"
        case .walletNotInitialized:
            return "Wallet not initialized"
        case .meshNotActive:
            return "Mesh networking is not active"
        case .encryptionFailed:
            return "Failed to encrypt payment"
        case .sendFailed(let error):
            return "Failed to send payment: \(error.localizedDescription)"
        case .insufficientBalance(let available, let required):
            let availableSol = Double(available) / 1_000_000_000
            let requiredSol = Double(required) / 1_000_000_000
            return String(format: "Insufficient balance: %.4f SOL available, %.4f SOL required", availableSol, requiredSol)
        case .invalidStealthAddress:
            return "Invalid stealth address generated"
        case .signingFailed:
            return "Failed to sign transaction"
        }
    }
}
