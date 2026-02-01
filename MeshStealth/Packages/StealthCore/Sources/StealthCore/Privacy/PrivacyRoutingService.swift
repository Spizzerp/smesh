import Foundation
import Combine

// MARK: - Privacy Routing Service

/// Main coordinator for privacy protocol routing
/// Manages protocol selection and routes transactions through privacy pools
@MainActor
public class PrivacyRoutingService: ObservableObject {

    // MARK: - Published State

    /// Currently selected privacy protocol
    @Published public var selectedProtocol: PrivacyProtocolId = .direct

    /// Whether privacy routing is enabled
    @Published public var isEnabled: Bool = false

    /// Whether the selected protocol is ready
    @Published public private(set) var isReady: Bool = false

    /// Whether running in simulation mode (no real transactions)
    @Published public private(set) var isSimulationMode: Bool = false

    /// Current pool balance (if any)
    @Published public private(set) var poolBalance: UInt64 = 0

    /// Last error
    @Published public private(set) var lastError: Error?

    // MARK: - Configuration

    public var configuration: PrivacyProtocolConfiguration {
        didSet {
            selectedProtocol = configuration.protocolId
            isEnabled = configuration.autoRoute && configuration.protocolId != .direct
        }
    }

    // MARK: - Providers

    private var shadowWireProvider: ShadowWireProvider?
    private var privacyCashProvider: PrivacyCashProvider?

    /// Get the currently active provider
    private var activeProvider: (any PrivacyProtocol)? {
        get async {
            switch selectedProtocol {
            case .shadowWire:
                return shadowWireProvider
            case .privacyCash:
                return privacyCashProvider
            case .direct:
                return nil
            }
        }
    }

    // MARK: - Private

    private var initializationTask: Task<Void, Error>?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    public init(configuration: PrivacyProtocolConfiguration = .default) {
        self.configuration = configuration
        self.selectedProtocol = configuration.protocolId
        self.isEnabled = configuration.autoRoute && configuration.protocolId != .direct

        // Create providers
        self.shadowWireProvider = ShadowWireProvider(config: .devnet)
        self.privacyCashProvider = PrivacyCashProvider(config: .devnet)

        setupBindings()
    }

    private func setupBindings() {
        // Update readiness when protocol changes
        $selectedProtocol
            .sink { [weak self] protocolId in
                Task { @MainActor in
                    await self?.updateReadiness()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Lifecycle

    /// Initialize the selected privacy protocol
    public func initialize() async throws {
        // Cancel any existing initialization
        initializationTask?.cancel()

        DebugLogger.log("[PrivacyRouting] Initializing privacy protocol: \(selectedProtocol.displayName)")

        guard selectedProtocol != .direct else {
            DebugLogger.log("[PrivacyRouting] Direct mode - no initialization needed")
            isReady = true
            return
        }

        isReady = false
        lastError = nil

        initializationTask = Task {
            do {
                switch selectedProtocol {
                case .shadowWire:
                    DebugLogger.log("[PrivacyRouting] Starting ShadowWire provider initialization...")
                    try await shadowWireProvider?.initialize()
                    DebugLogger.log("[PrivacyRouting] ShadowWire provider initialization complete")
                case .privacyCash:
                    DebugLogger.log("[PrivacyRouting] Starting PrivacyCash provider initialization...")
                    try await privacyCashProvider?.initialize()
                    DebugLogger.log("[PrivacyRouting] PrivacyCash provider initialization complete")
                case .direct:
                    break
                }

                await updateReadiness()
                await refreshPoolBalance()

                DebugLogger.log("[PrivacyRouting] \(selectedProtocol.displayName) initialized successfully, isReady=\(isReady)")

            } catch {
                DebugLogger.log("[PrivacyRouting] \(selectedProtocol.displayName) initialization FAILED: \(error)")
                lastError = error
                isReady = false
                throw error
            }
        }

        try await initializationTask?.value
    }

    /// Shutdown all providers
    public func shutdown() async {
        initializationTask?.cancel()

        await shadowWireProvider?.shutdown()
        await privacyCashProvider?.shutdown()

        isReady = false
        poolBalance = 0
    }

    // MARK: - Routing

    /// Route a transfer through the privacy protocol
    /// - Parameters:
    ///   - from: Source stealth address
    ///   - to: Destination address (stealth or regular)
    ///   - amount: Amount in lamports
    ///   - spendingKey: Spending key for source address
    /// - Returns: Transaction signature
    public func routeTransfer(
        from sourceAddress: String,
        to destinationAddress: String,
        amount: UInt64,
        spendingKey: Data
    ) async throws -> String {

        // Check if routing is enabled and ready
        guard isEnabled && isReady else {
            throw PrivacyProtocolError.protocolNotAvailable(selectedProtocol)
        }

        // Check minimum amount
        guard amount >= configuration.minAmountForPrivacy else {
            DebugLogger.log("[PrivacyRouting] Amount \(amount) below minimum \(configuration.minAmountForPrivacy), skipping privacy routing")
            throw PrivacyProtocolError.invalidAmount
        }

        DebugLogger.log("[PrivacyRouting] Routing \(amount) lamports via \(selectedProtocol.displayName)")

        do {
            let signature: String

            switch selectedProtocol {
            case .shadowWire:
                guard let provider = shadowWireProvider else {
                    throw PrivacyProtocolError.notInitialized
                }
                signature = try await provider.routeSettlement(
                    from: sourceAddress,
                    to: destinationAddress,
                    amount: amount,
                    spendingKey: spendingKey
                )

            case .privacyCash:
                guard let provider = privacyCashProvider else {
                    throw PrivacyProtocolError.notInitialized
                }
                signature = try await provider.routeSettlement(
                    from: sourceAddress,
                    to: destinationAddress,
                    amount: amount,
                    spendingKey: spendingKey
                )

            case .direct:
                throw PrivacyProtocolError.protocolNotAvailable(.direct)
            }

            // Refresh pool balance after routing
            await refreshPoolBalance()

            return signature

        } catch {
            lastError = error

            // Fallback to direct transfer if configured
            if configuration.fallbackToDirect {
                DebugLogger.log("[PrivacyRouting] Privacy routing failed, will use direct transfer: \(error)")
                throw error // Let caller handle fallback
            }

            throw error
        }
    }

    /// Deposit funds into the privacy pool
    /// - Parameters:
    ///   - amount: Amount in lamports
    ///   - token: Token mint (nil for SOL)
    /// - Returns: Deposit result
    public func deposit(amount: UInt64, token: String? = nil) async throws -> PrivacyDepositResult {
        guard isEnabled && isReady else {
            throw PrivacyProtocolError.protocolNotAvailable(selectedProtocol)
        }

        let result: PrivacyDepositResult

        switch selectedProtocol {
        case .shadowWire:
            guard let provider = shadowWireProvider else {
                throw PrivacyProtocolError.notInitialized
            }
            result = try await provider.deposit(amount: amount, token: token)

        case .privacyCash:
            guard let provider = privacyCashProvider else {
                throw PrivacyProtocolError.notInitialized
            }
            result = try await provider.deposit(amount: amount, token: token)

        case .direct:
            throw PrivacyProtocolError.protocolNotAvailable(.direct)
        }

        await refreshPoolBalance()
        return result
    }

    /// Withdraw funds from the privacy pool
    /// - Parameters:
    ///   - amount: Amount in lamports
    ///   - token: Token mint (nil for SOL)
    ///   - destination: Destination address
    /// - Returns: Withdraw result
    public func withdraw(amount: UInt64, token: String? = nil, destination: String) async throws -> PrivacyWithdrawResult {
        guard isEnabled && isReady else {
            throw PrivacyProtocolError.protocolNotAvailable(selectedProtocol)
        }

        let result: PrivacyWithdrawResult

        switch selectedProtocol {
        case .shadowWire:
            guard let provider = shadowWireProvider else {
                throw PrivacyProtocolError.notInitialized
            }
            result = try await provider.withdraw(amount: amount, token: token, destination: destination)

        case .privacyCash:
            guard let provider = privacyCashProvider else {
                throw PrivacyProtocolError.notInitialized
            }
            result = try await provider.withdraw(amount: amount, token: token, destination: destination)

        case .direct:
            throw PrivacyProtocolError.protocolNotAvailable(.direct)
        }

        await refreshPoolBalance()
        return result
    }

    // MARK: - Status

    /// Update readiness state and simulation mode
    private func updateReadiness() async {
        switch selectedProtocol {
        case .direct:
            isReady = true
            isSimulationMode = false
        case .shadowWire:
            isReady = await shadowWireProvider?.isAvailable ?? false
            isSimulationMode = await shadowWireProvider?.isSimulationMode ?? true
        case .privacyCash:
            isReady = await privacyCashProvider?.isAvailable ?? false
            isSimulationMode = await privacyCashProvider?.isSimulationMode ?? false
        }

        if isSimulationMode && selectedProtocol != .direct {
            DebugLogger.log("[PrivacyRouting] Running in SIMULATION mode - transactions will be simulated")
        }
    }

    /// Refresh pool balance from provider
    public func refreshPoolBalance() async {
        guard selectedProtocol != .direct else {
            poolBalance = 0
            return
        }

        do {
            switch selectedProtocol {
            case .shadowWire:
                poolBalance = try await shadowWireProvider?.getBalance(token: nil) ?? 0
            case .privacyCash:
                poolBalance = try await privacyCashProvider?.getBalance(token: nil) ?? 0
            case .direct:
                poolBalance = 0
            }
        } catch {
            DebugLogger.log("[PrivacyRouting] Failed to refresh pool balance: \(error)")
        }
    }

    // MARK: - Configuration Updates

    /// Set the active privacy protocol
    public func setProtocol(_ protocolId: PrivacyProtocolId) async throws {
        guard protocolId != selectedProtocol else { return }

        selectedProtocol = protocolId
        isEnabled = protocolId != .direct

        if protocolId != .direct {
            try await initialize()
        } else {
            isReady = true
            poolBalance = 0
        }
    }

    /// Enable or disable privacy routing
    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled && selectedProtocol != .direct
    }

    /// Set the wallet for transaction signing
    /// - Parameter secretKey: The wallet's secret key (64 bytes ed25519)
    public func setWallet(_ secretKey: Data) async {
        DebugLogger.log("[PrivacyRouting] Setting wallet for \(selectedProtocol.displayName) (key length: \(secretKey.count) bytes)")

        guard secretKey.count == 64 else {
            DebugLogger.log("[PrivacyRouting] ERROR: Invalid secret key length \(secretKey.count), expected 64")
            return
        }

        switch selectedProtocol {
        case .privacyCash:
            DebugLogger.log("[PrivacyRouting] Forwarding wallet to PrivacyCash provider")
            await privacyCashProvider?.setWallet(secretKey)
        case .shadowWire:
            DebugLogger.log("[PrivacyRouting] Forwarding wallet to ShadowWire provider")
            await shadowWireProvider?.setWallet(secretKey)
        case .direct:
            DebugLogger.log("[PrivacyRouting] Direct mode - no wallet passthrough needed")
        }
    }

    // MARK: - Status Display

    /// Get a human-readable status string
    public var statusString: String {
        if !isEnabled {
            return "Privacy: Off"
        }

        if !isReady {
            return "\(selectedProtocol.displayName): Initializing..."
        }

        let modeStr = isSimulationMode ? " (SIM)" : ""

        if poolBalance > 0 {
            let sol = Double(poolBalance) / 1_000_000_000
            return "\(selectedProtocol.displayName)\(modeStr): \(String(format: "%.4f", sol)) SOL"
        }

        return "\(selectedProtocol.displayName)\(modeStr): Ready"
    }

    /// Prize value of the selected protocol
    public var prizeValue: UInt {
        selectedProtocol.prizeValue
    }
}

// MARK: - Convenience Extensions

extension PrivacyRoutingService {
    /// Check if a transfer should use privacy routing
    /// - Parameter amount: Amount to transfer
    /// - Returns: Whether privacy routing should be used
    public func shouldUsePrivacyRouting(for amount: UInt64) -> Bool {
        isEnabled &&
        isReady &&
        selectedProtocol != .direct &&
        amount >= configuration.minAmountForPrivacy
    }
}
