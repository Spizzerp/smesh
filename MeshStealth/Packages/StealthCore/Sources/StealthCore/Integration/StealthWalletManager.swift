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
        errorMessage: String? = nil
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

    // MARK: - Private

    private let keychainService: KeychainService
    private let userDefaults: UserDefaults
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
        userDefaults: UserDefaults = .standard
    ) {
        self.keychainService = keychainService
        self.userDefaults = userDefaults
    }

    /// Initialize wallet with existing or new keypair
    public func initialize() async throws {
        // Try to load existing keypair
        if let existing = try? keychainService.loadKeyPair() {
            keyPair = existing
        } else {
            // Generate new keypair
            let newKeyPair = try StealthKeyPair.generate()
            try keychainService.storeKeyPair(newKeyPair)
            keyPair = newKeyPair
        }

        // Load pending payments from storage
        loadPendingPayments()
        loadSettledPayments()
        updatePendingBalance()

        isInitialized = true
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
            payment.status == .received || payment.status == .failed
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

    // MARK: - Reset

    /// Clear all wallet data (for testing/reset)
    public func reset() throws {
        try keychainService.deleteKeyPair()
        keyPair = nil
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
        }
    }
}
