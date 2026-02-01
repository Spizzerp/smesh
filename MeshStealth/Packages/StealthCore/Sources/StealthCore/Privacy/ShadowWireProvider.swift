import Foundation
import WebKit

// MARK: - ShadowWire Privacy Provider

/// Radr Labs ShadowWire integration
/// Uses Bulletproof proofs for private on-chain transfers with hidden amounts
/// Prize: $15,000
///
/// SDK API Reference:
/// ```typescript
/// const client = new ShadowWireClient({ debug: true });
/// await client.deposit({ amount, token: 'SOL' });
/// await client.withdraw({ amount, destination, token });
/// await client.transfer({ amount, recipient, mode: 'internal' | 'external' });
/// ```
public actor ShadowWireProvider: PrivacyProtocol {

    // MARK: - Protocol Properties

    public let protocolId: PrivacyProtocolId = .shadowWire
    public let displayName: String = "ShadowWire"

    public var isAvailable: Bool {
        get async { isInitialized && webViewBridge != nil }
    }

    /// Whether running in simulation mode (no merchant key = simulated transactions)
    public var isSimulationMode: Bool {
        get async { config.merchantKey == nil }
    }

    // MARK: - Private Properties

    private var webViewBridge: WebViewBridge?
    private var isInitialized = false

    /// Stored commitments for withdrawals
    private var commitments: [Data] = []

    /// Pool balance cache
    private var cachedPoolBalance: UInt64 = 0

    // MARK: - Configuration

    /// ShadowWire configuration
    public struct Configuration: Sendable {
        /// RPC endpoint for Solana
        public let rpcEndpoint: String

        /// Whether to enable debug logging in SDK
        public let debug: Bool

        /// Network (devnet/mainnet)
        public let network: String

        /// Merchant API key from Radr Labs (required for real transactions)
        /// Get one at: https://radrlabs.io or check if devnet allows keyless access
        public let merchantKey: String?

        public init(
            rpcEndpoint: String = "https://api.devnet.solana.com",
            debug: Bool = true,
            network: String = "devnet",
            merchantKey: String? = nil
        ) {
            self.rpcEndpoint = rpcEndpoint
            self.debug = debug
            self.network = network
            self.merchantKey = merchantKey
        }

        public static let devnet = Configuration()
        public static let mainnet = Configuration(
            rpcEndpoint: "https://api.mainnet-beta.solana.com",
            debug: false,
            network: "mainnet",
            merchantKey: nil  // Must be set for mainnet
        )
    }

    private let config: Configuration

    // MARK: - Initialization

    public init(config: Configuration = .devnet) {
        self.config = config
    }

    // MARK: - Protocol Methods

    public func initialize() async throws {
        guard !isInitialized else { return }

        DebugLogger.log("[ShadowWire] Initializing provider...")

        // Load the bundled SDK JavaScript
        let sdkBundle = try loadSDKBundle()

        // Create WebView bridge (needed for WASM Bulletproof proofs)
        let bridge = await WebViewBridge(
            bundledJS: sdkBundle,
            globalObjectName: "shadowWire",
            operationTimeout: 120 // Proof generation can be slow
        )

        try await bridge.initialize()

        // Initialize the SDK with our configuration
        var initParams: [String: Any] = [
            "rpcEndpoint": config.rpcEndpoint,
            "debug": config.debug,
            "network": config.network
        ]

        // Add merchantKey if provided (required for real transactions on ShadowWire)
        if let merchantKey = config.merchantKey {
            initParams["merchantKey"] = merchantKey
            DebugLogger.log("[ShadowWire] Using merchant key for initialization")
        } else {
            DebugLogger.log("[ShadowWire] WARNING: No merchantKey provided - may fail for real transactions")
        }

        let initResult = try await bridge.execute(method: "init", params: initParams)

        guard initResult.success else {
            throw PrivacyProtocolError.sdkLoadFailed(initResult.error ?? "Unknown initialization error")
        }

        self.webViewBridge = bridge
        self.isInitialized = true

        DebugLogger.log("[ShadowWire] Provider initialized successfully")
    }

    public func deposit(amount: UInt64, token: String?) async throws -> PrivacyDepositResult {
        guard let bridge = webViewBridge else {
            throw PrivacyProtocolError.notInitialized
        }

        DebugLogger.log("[ShadowWire] Depositing \(amount) lamports into privacy pool")

        let result = try await bridge.execute(method: "deposit", params: [
            "amount": amount,
            "token": token ?? "SOL"
        ])

        guard result.success, let data = result.data else {
            throw PrivacyProtocolError.depositFailed(result.error ?? "Unknown deposit error")
        }

        // Parse result
        guard let signature = data["signature"] as? String,
              let commitmentHex = data["commitment"] as? String else {
            throw PrivacyProtocolError.depositFailed("Invalid response format")
        }

        // Convert commitment hex to Data
        let commitment = Data(hexString: commitmentHex) ?? Data()

        // Store commitment for later withdrawal
        commitments.append(commitment)
        cachedPoolBalance += amount

        return PrivacyDepositResult(
            signature: signature,
            commitment: commitment,
            amount: amount,
            token: token
        )
    }

    public func withdraw(amount: UInt64, token: String?, destination: String) async throws -> PrivacyWithdrawResult {
        guard let bridge = webViewBridge else {
            throw PrivacyProtocolError.notInitialized
        }

        guard cachedPoolBalance >= amount else {
            throw PrivacyProtocolError.insufficientPoolBalance(available: cachedPoolBalance, required: amount)
        }

        DebugLogger.log("[ShadowWire] Withdrawing \(amount) lamports to \(destination)")

        let result = try await bridge.execute(method: "withdraw", params: [
            "amount": amount,
            "destination": destination,
            "token": token ?? "SOL"
        ])

        guard result.success, let data = result.data else {
            throw PrivacyProtocolError.withdrawFailed(result.error ?? "Unknown withdrawal error")
        }

        guard let signature = data["signature"] as? String else {
            throw PrivacyProtocolError.withdrawFailed("Invalid response format")
        }

        cachedPoolBalance -= amount

        return PrivacyWithdrawResult(
            signature: signature,
            amount: amount,
            destination: destination,
            token: token
        )
    }

    public func transfer(amount: UInt64, recipient: String) async throws -> PrivacyTransferResult {
        guard let bridge = webViewBridge else {
            throw PrivacyProtocolError.notInitialized
        }

        DebugLogger.log("[ShadowWire] Internal transfer of \(amount) lamports")

        let result = try await bridge.execute(method: "transfer", params: [
            "amount": amount,
            "recipient": recipient,
            "mode": "internal"
        ])

        guard result.success, let data = result.data else {
            throw PrivacyProtocolError.transferFailed(result.error ?? "Unknown transfer error")
        }

        let identifier = data["proofId"] as? String ?? UUID().uuidString

        return PrivacyTransferResult(
            identifier: identifier,
            amount: amount,
            isInternal: true
        )
    }

    public func getBalance(token: String?) async throws -> UInt64 {
        guard let bridge = webViewBridge else {
            throw PrivacyProtocolError.notInitialized
        }

        let result = try await bridge.execute(method: "getBalance", params: [
            "token": token ?? "SOL"
        ])

        guard result.success, let data = result.data,
              let balance = data["balance"] as? UInt64 else {
            // Return cached balance if live query fails
            return cachedPoolBalance
        }

        cachedPoolBalance = balance
        return balance
    }

    public func shutdown() async {
        await webViewBridge?.shutdown()
        webViewBridge = nil
        isInitialized = false
        commitments.removeAll()
        cachedPoolBalance = 0
        DebugLogger.log("[ShadowWire] Provider shut down")
    }

    /// Set the wallet for transaction signing
    /// - Parameter secretKey: The wallet's secret key (64 bytes ed25519)
    public func setWallet(_ secretKey: Data) async {
        guard let bridge = webViewBridge else {
            DebugLogger.log("[ShadowWire] Cannot set wallet - not initialized")
            return
        }

        // Convert to base58 for the JS SDK
        let base58Key = secretKey.base58EncodedString

        do {
            let result = try await bridge.execute(method: "setWallet", params: [
                "spendingKey": base58Key
            ])

            if result.success {
                DebugLogger.log("[ShadowWire] Wallet set successfully")
            } else {
                DebugLogger.log("[ShadowWire] Failed to set wallet: \(result.error ?? "unknown")")
            }
        } catch {
            DebugLogger.log("[ShadowWire] Error setting wallet: \(error)")
        }
    }

    // MARK: - ShadowWire-Specific Methods

    /// Route a settlement through ShadowWire for privacy
    /// - Parameters:
    ///   - from: Source stealth address
    ///   - to: Destination stealth address
    ///   - amount: Amount in lamports
    ///   - spendingKey: Spending key for source address
    /// - Returns: Transaction signature
    public func routeSettlement(
        from sourceAddress: String,
        to destinationAddress: String,
        amount: UInt64,
        spendingKey: Data
    ) async throws -> String {

        DebugLogger.log("[ShadowWire] Routing settlement through privacy pool")
        DebugLogger.log("[ShadowWire]   From: \(sourceAddress)")
        DebugLogger.log("[ShadowWire]   To: \(destinationAddress)")
        DebugLogger.log("[ShadowWire]   Amount: \(amount) lamports")

        // Step 1: Deposit from source stealth address into pool
        let depositResult = try await depositFromStealth(
            sourceAddress: sourceAddress,
            amount: amount,
            spendingKey: spendingKey
        )
        DebugLogger.log("[ShadowWire]   Deposit tx: \(depositResult.signature)")

        // Step 2: Wait for deposit confirmation
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2s

        // Step 3: Withdraw to destination stealth address
        let withdrawResult = try await withdraw(
            amount: amount,
            token: nil,
            destination: destinationAddress
        )
        DebugLogger.log("[ShadowWire]   Withdraw tx: \(withdrawResult.signature)")

        return withdrawResult.signature
    }

    /// Deposit funds from a stealth address into the privacy pool
    /// This requires signing with the stealth spending key
    private func depositFromStealth(
        sourceAddress: String,
        amount: UInt64,
        spendingKey: Data
    ) async throws -> PrivacyDepositResult {
        guard let bridge = webViewBridge else {
            throw PrivacyProtocolError.notInitialized
        }

        let result = try await bridge.execute(method: "depositFrom", params: [
            "sourceAddress": sourceAddress,
            "amount": amount,
            "spendingKey": spendingKey.base58EncodedString,
            "token": "SOL"
        ])

        guard result.success, let data = result.data else {
            throw PrivacyProtocolError.depositFailed(result.error ?? "Unknown deposit error")
        }

        guard let signature = data["signature"] as? String,
              let commitmentHex = data["commitment"] as? String else {
            throw PrivacyProtocolError.depositFailed("Invalid response format")
        }

        let commitment = Data(hexString: commitmentHex) ?? Data()
        commitments.append(commitment)
        cachedPoolBalance += amount

        return PrivacyDepositResult(
            signature: signature,
            commitment: commitment,
            amount: amount,
            token: nil
        )
    }

    // MARK: - SDK Bundle Loading

    private func loadSDKBundle() throws -> String {
        DebugLogger.log("[ShadowWire] Loading SDK bundle from Bundle.module...")

        guard let bundleURL = Bundle.module.url(forResource: "shadowwire-bundle", withExtension: "js") else {
            // Debug: List what resources are available
            #if DEBUG
            if let resourcePath = Bundle.module.resourcePath {
                DebugLogger.log("[ShadowWire] Resource path: \(resourcePath)")
                if let contents = try? FileManager.default.contentsOfDirectory(atPath: resourcePath) {
                    DebugLogger.log("[ShadowWire] Available resources: \(contents.joined(separator: ", "))")
                }
            }
            #endif

            throw PrivacyProtocolError.sdkLoadFailed("shadowwire-bundle.js not found in Bundle.module")
        }

        DebugLogger.log("[ShadowWire] Found bundle at: \(bundleURL.path)")

        let bundleContent = try String(contentsOf: bundleURL, encoding: .utf8)
        let bundleSize = bundleContent.count
        DebugLogger.log("[ShadowWire] Loaded SDK bundle (\(bundleSize) chars)")

        // Validate bundle looks correct
        guard bundleSize > 100_000 && bundleContent.contains("ShadowWireBundle") else {
            throw PrivacyProtocolError.sdkLoadFailed("Bundle appears invalid (size=\(bundleSize), missing ShadowWireBundle marker)")
        }

        DebugLogger.log("[ShadowWire] Bundle validation passed")
        return bundleContent
    }
}
