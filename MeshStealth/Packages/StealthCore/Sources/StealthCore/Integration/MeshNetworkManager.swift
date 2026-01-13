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

        self.settlementService = SettlementService(
            walletManager: self.walletManager,
            networkMonitor: self.networkMonitor,
            rpcClient: self.rpcClient
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

        // Setup connectivity callback for auto-settlement and balance refresh
        networkMonitor.onConnected = { [weak self] in
            Task { @MainActor in
                // Refresh wallet balance when coming online
                await self?.walletManager.refreshMainWalletBalance()
                // Execute any queued outgoing payments
                await self?.executeQueuedPayments()
                // Settle any pending incoming payments
                await self?.settlementService.settleAllPending()
            }
        }

        // Also refresh balance immediately if already online
        if networkMonitor.isConnected {
            Task {
                await walletManager.refreshMainWalletBalance()
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
        print("[MESH-SEND] Starting mesh payment of \(amount) lamports (online: \(isOnline))")

        // Verify we have a wallet to send from
        guard walletManager.mainWallet != nil else {
            throw MeshNetworkError.walletNotInitialized
        }

        // Parse meta-address
        let (spendingPubKey, viewingPubKey, mlkemPubKey) = try parseMetaAddress(recipientMetaAddress)

        // Generate stealth address
        let stealthResult: StealthAddressResult

        if let mlkemKey = mlkemPubKey {
            // Hybrid mode
            stealthResult = try StealthAddressGenerator.generateHybridStealthAddress(
                spendingPublicKey: spendingPubKey,
                viewingPublicKey: viewingPubKey,
                mlkemPublicKey: mlkemKey
            )
            print("[MESH-SEND] Generated hybrid stealth address: \(stealthResult.stealthAddress)")
        } else {
            // Classical mode
            stealthResult = try StealthAddressGenerator.generateStealthAddress(
                spendingPublicKey: spendingPubKey,
                viewingPublicKey: viewingPubKey
            )
            print("[MESH-SEND] Generated classical stealth address: \(stealthResult.stealthAddress)")
        }

        // Step 1: Create mesh payload and broadcast immediately (works offline)
        let payload = MeshStealthPayload(
            from: stealthResult,
            amount: amount,
            tokenMint: tokenMint,
            memo: memo
        )

        // Broadcast via mesh first (this works offline via BLE)
        try await meshService.sendPayment(payload)
        print("[MESH-SEND] Mesh payload broadcast complete")

        // Step 2: Create outgoing payment intent
        let intent = OutgoingPaymentIntent(
            recipientMetaAddress: recipientMetaAddress,
            stealthAddress: stealthResult.stealthAddress,
            ephemeralPublicKey: stealthResult.ephemeralPublicKey,
            mlkemCiphertext: stealthResult.mlkemCiphertext,
            amount: amount,
            memo: memo
        )

        // Step 3: Queue the payment intent (this also records activity)
        walletManager.queueOutgoingPayment(intent)

        // Step 4: If online, execute immediately; otherwise stay queued
        if isOnline {
            print("[MESH-SEND] Online - executing on-chain transfer immediately")
            try await executeOutgoingPayment(intent)
        } else {
            print("[MESH-SEND] Offline - payment queued for later execution")
        }
    }

    /// Execute a queued outgoing payment on-chain
    private func executeOutgoingPayment(_ intent: OutgoingPaymentIntent) async throws {
        guard let mainWallet = walletManager.mainWallet else {
            throw MeshNetworkError.walletNotInitialized
        }

        // Update status to sending
        walletManager.updateOutgoingIntent(id: intent.id, status: .sending)

        do {
            // Check balance
            let mainAddress = await mainWallet.address
            let balance = try await faucet.getBalance(address: mainAddress)
            let requiredAmount = intent.amount + estimatedFee

            guard balance >= requiredAmount else {
                throw MeshNetworkError.insufficientBalance(available: balance, required: requiredAmount)
            }

            // Build and send transaction
            let blockhash = try await faucet.getRecentBlockhash()
            let fromPubkey = await mainWallet.publicKeyData
            guard let toPubkey = Data(base58Decoding: intent.stealthAddress) else {
                throw MeshNetworkError.invalidStealthAddress
            }

            let message = try SolanaTransaction.buildTransfer(
                from: fromPubkey,
                to: toPubkey,
                lamports: intent.amount,
                recentBlockhash: blockhash
            )

            let messageBytes = message.serialize()
            let signature = try await mainWallet.sign(messageBytes)

            let signedTx = try SolanaTransaction.buildSignedTransaction(
                message: message,
                signature: signature
            )

            let txSignature = try await faucet.sendTransaction(signedTx)
            print("[MESH-SEND] Transaction submitted: \(txSignature)")

            // Wait for confirmation
            try await faucet.waitForConfirmation(signature: txSignature, timeout: 30)
            print("[MESH-SEND] Transaction confirmed!")

            // Update intent status
            walletManager.updateOutgoingIntent(id: intent.id, status: .confirmed, signature: txSignature)

            // Record activity
            walletManager.updateActivityStatus(id: intent.id, status: .completed, signature: txSignature)

            // Refresh balance
            await walletManager.refreshMainWalletBalance()

        } catch {
            print("[MESH-SEND] Transaction failed: \(error)")
            walletManager.updateOutgoingIntent(id: intent.id, status: .failed, error: error.localizedDescription)
            throw error
        }
    }

    /// Execute all queued outgoing payments (called when coming online)
    public func executeQueuedPayments() async {
        let queuedPayments = walletManager.getQueuedOutgoingPayments()
        print("[MESH-SEND] Executing \(queuedPayments.count) queued payments")

        for intent in queuedPayments {
            do {
                try await executeOutgoingPayment(intent)
            } catch {
                print("[MESH-SEND] Failed to execute queued payment \(intent.id): \(error)")
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

    // MARK: - Helpers

    private func parseMetaAddress(_ metaAddress: String) throws -> (Data, Data, Data?) {
        // Try hybrid first
        if let parsed = try? StealthKeyPair.parseHybridMetaAddress(metaAddress) {
            return (parsed.spendingPubKey, parsed.viewingPubKey, parsed.mlkemPubKey)
        }

        // Try classical
        if let parsed = try? StealthKeyPair.parseMetaAddress(metaAddress) {
            return (parsed.spendingPubKey, parsed.viewingPubKey, nil)
        }

        throw MeshNetworkError.invalidMetaAddress
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
