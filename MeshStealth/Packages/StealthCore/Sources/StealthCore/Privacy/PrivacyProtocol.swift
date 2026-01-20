import Foundation

// MARK: - Privacy Protocol Abstraction

/// Protocol defining a privacy-enhancing transfer mechanism
/// Implementations include ShadowWire (Radr) and Privacy Cash
public protocol PrivacyProtocol: Actor {
    /// Unique identifier for this protocol
    var protocolId: PrivacyProtocolId { get }

    /// Human-readable name for UI
    var displayName: String { get }

    /// Whether this protocol is currently available and ready
    var isAvailable: Bool { get async }

    /// Initialize the protocol (load SDKs, setup state)
    func initialize() async throws

    /// Deposit funds into the privacy pool
    /// - Parameters:
    ///   - amount: Amount in lamports to deposit
    ///   - token: Token mint address (nil for native SOL)
    /// - Returns: Deposit result with commitment/proof
    func deposit(amount: UInt64, token: String?) async throws -> PrivacyDepositResult

    /// Withdraw funds from the privacy pool to a destination
    /// - Parameters:
    ///   - amount: Amount in lamports to withdraw
    ///   - token: Token mint address (nil for native SOL)
    ///   - destination: Destination address to receive funds
    /// - Returns: Withdraw result with transaction signature
    func withdraw(amount: UInt64, token: String?, destination: String) async throws -> PrivacyWithdrawResult

    /// Internal transfer within the privacy pool (hidden amount)
    /// - Parameters:
    ///   - amount: Amount in lamports to transfer
    ///   - recipient: Recipient identifier within the pool
    /// - Returns: Transfer result
    func transfer(amount: UInt64, recipient: String) async throws -> PrivacyTransferResult

    /// Get the current balance in the privacy pool
    /// - Parameter token: Token mint address (nil for native SOL)
    /// - Returns: Balance in lamports
    func getBalance(token: String?) async throws -> UInt64

    /// Shutdown and cleanup
    func shutdown() async
}

// MARK: - Protocol Identifiers

/// Supported privacy protocols
public enum PrivacyProtocolId: String, Codable, CaseIterable, Sendable {
    /// Radr Labs ShadowWire - Bulletproof-based private transfers
    case shadowWire = "shadowwire"

    /// Privacy Cash - Zero-knowledge pool
    case privacyCash = "privacy_cash"

    /// Direct transfer (no privacy enhancement)
    case direct = "direct"

    public var displayName: String {
        switch self {
        case .shadowWire: return "ShadowWire"
        case .privacyCash: return "Privacy Cash"
        case .direct: return "Direct"
        }
    }

    public var description: String {
        switch self {
        case .shadowWire: return "Radr Labs privacy pool with Bulletproof proofs"
        case .privacyCash: return "Zero-knowledge privacy pool"
        case .direct: return "Standard on-chain transfer"
        }
    }

    /// Hackathon prize value
    public var prizeValue: UInt {
        switch self {
        case .shadowWire: return 15_000
        case .privacyCash: return 6_000
        case .direct: return 0
        }
    }
}

// MARK: - Result Types

/// Result of a privacy deposit operation
public struct PrivacyDepositResult: Sendable {
    /// Transaction signature on Solana
    public let signature: String

    /// Commitment or note for later withdrawal
    public let commitment: Data

    /// Amount deposited in lamports
    public let amount: UInt64

    /// Token mint (nil for SOL)
    public let token: String?

    /// Timestamp of deposit
    public let timestamp: Date

    public init(
        signature: String,
        commitment: Data,
        amount: UInt64,
        token: String?,
        timestamp: Date = Date()
    ) {
        self.signature = signature
        self.commitment = commitment
        self.amount = amount
        self.token = token
        self.timestamp = timestamp
    }
}

/// Result of a privacy withdrawal operation
public struct PrivacyWithdrawResult: Sendable {
    /// Transaction signature on Solana
    public let signature: String

    /// Amount withdrawn in lamports
    public let amount: UInt64

    /// Destination address
    public let destination: String

    /// Token mint (nil for SOL)
    public let token: String?

    /// Timestamp of withdrawal
    public let timestamp: Date

    public init(
        signature: String,
        amount: UInt64,
        destination: String,
        token: String?,
        timestamp: Date = Date()
    ) {
        self.signature = signature
        self.amount = amount
        self.destination = destination
        self.token = token
        self.timestamp = timestamp
    }
}

/// Result of a privacy transfer operation
public struct PrivacyTransferResult: Sendable {
    /// Transaction or proof identifier
    public let identifier: String

    /// Amount transferred in lamports
    public let amount: UInt64

    /// Whether the transfer was internal (within pool) or external
    public let isInternal: Bool

    /// Timestamp of transfer
    public let timestamp: Date

    public init(
        identifier: String,
        amount: UInt64,
        isInternal: Bool,
        timestamp: Date = Date()
    ) {
        self.identifier = identifier
        self.amount = amount
        self.isInternal = isInternal
        self.timestamp = timestamp
    }
}

// MARK: - Errors

/// Errors from privacy protocol operations
public enum PrivacyProtocolError: Error, LocalizedError {
    case notInitialized
    case sdkLoadFailed(String)
    case depositFailed(String)
    case withdrawFailed(String)
    case transferFailed(String)
    case insufficientPoolBalance(available: UInt64, required: UInt64)
    case invalidAmount
    case invalidDestination
    case proofGenerationFailed
    case proofVerificationFailed
    case networkError(String)
    case timeout
    case protocolNotAvailable(PrivacyProtocolId)
    case jsExecutionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "Privacy protocol not initialized"
        case .sdkLoadFailed(let reason):
            return "Failed to load SDK: \(reason)"
        case .depositFailed(let reason):
            return "Deposit failed: \(reason)"
        case .withdrawFailed(let reason):
            return "Withdrawal failed: \(reason)"
        case .transferFailed(let reason):
            return "Transfer failed: \(reason)"
        case .insufficientPoolBalance(let available, let required):
            let availableSol = Double(available) / 1_000_000_000
            let requiredSol = Double(required) / 1_000_000_000
            return String(format: "Insufficient pool balance: %.4f SOL available, %.4f SOL required", availableSol, requiredSol)
        case .invalidAmount:
            return "Invalid transfer amount"
        case .invalidDestination:
            return "Invalid destination address"
        case .proofGenerationFailed:
            return "Failed to generate zero-knowledge proof"
        case .proofVerificationFailed:
            return "Zero-knowledge proof verification failed"
        case .networkError(let reason):
            return "Network error: \(reason)"
        case .timeout:
            return "Operation timed out"
        case .protocolNotAvailable(let id):
            return "Privacy protocol '\(id.displayName)' is not available"
        case .jsExecutionFailed(let reason):
            return "JavaScript execution failed: \(reason)"
        }
    }
}

// MARK: - Configuration

/// Configuration for privacy protocol behavior
public struct PrivacyProtocolConfiguration: Sendable {
    /// Which protocol to use
    public let protocolId: PrivacyProtocolId

    /// Whether to automatically use privacy routing when available
    public let autoRoute: Bool

    /// Minimum amount to route through privacy (to cover overhead)
    public let minAmountForPrivacy: UInt64

    /// Timeout for privacy operations
    public let operationTimeout: TimeInterval

    /// Whether to fallback to direct transfer on failure
    public let fallbackToDirect: Bool

    public init(
        protocolId: PrivacyProtocolId = .direct,
        autoRoute: Bool = true,
        minAmountForPrivacy: UInt64 = 100_000, // 0.0001 SOL
        operationTimeout: TimeInterval = 120,
        fallbackToDirect: Bool = true
    ) {
        self.protocolId = protocolId
        self.autoRoute = autoRoute
        self.minAmountForPrivacy = minAmountForPrivacy
        self.operationTimeout = operationTimeout
        self.fallbackToDirect = fallbackToDirect
    }

    public static let `default` = PrivacyProtocolConfiguration()

    public static let shadowWire = PrivacyProtocolConfiguration(
        protocolId: .shadowWire,
        autoRoute: true
    )

    public static let privacyCash = PrivacyProtocolConfiguration(
        protocolId: .privacyCash,
        autoRoute: true
    )
}

// MARK: - Transfer Mode

/// Mode for privacy transfers
public enum PrivacyTransferMode: String, Sendable {
    /// Internal transfer within privacy pool
    case `internal` = "internal"

    /// External transfer (withdrawal to destination)
    case external = "external"
}
