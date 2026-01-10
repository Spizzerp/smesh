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

        // Setup connectivity callback for auto-settlement
        networkMonitor.onConnected = { [weak self] in
            Task { @MainActor in
                await self?.settlementService.settleAllPending()
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
        } else {
            // Classical mode
            stealthResult = try StealthAddressGenerator.generateStealthAddress(
                spendingPublicKey: spendingPubKey,
                viewingPublicKey: viewingPubKey
            )
        }

        // Create mesh payload
        let payload = MeshStealthPayload(
            from: stealthResult,
            amount: amount,
            tokenMint: tokenMint,
            memo: memo
        )

        // Send via mesh
        try await meshService.sendPayment(payload)
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
        }
    }
}
