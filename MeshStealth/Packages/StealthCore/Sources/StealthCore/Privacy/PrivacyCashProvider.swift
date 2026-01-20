import Foundation
import JavaScriptCore

// MARK: - Privacy Cash Provider

/// Privacy Cash integration using JavaScriptCore
/// Lighter weight than ShadowWire as it doesn't require WASM
/// Prize: $6,000
///
/// SDK API Reference:
/// ```typescript
/// // SOL
/// await deposit(amount);
/// await withdraw(amount, recipientAddress);
/// const balance = await getPrivateBalance();
///
/// // SPL tokens
/// await depositSPL(amount, mint);
/// await withdrawSPL(amount, recipientAddress, mint);
/// ```
public actor PrivacyCashProvider: PrivacyProtocol {

    // MARK: - Protocol Properties

    public let protocolId: PrivacyProtocolId = .privacyCash
    public let displayName: String = "Privacy Cash"

    public var isAvailable: Bool {
        get async { isInitialized && jsBridge != nil }
    }

    // MARK: - Private Properties

    private var jsBridge: JSContextBridge?
    private var isInitialized = false

    /// Pool balance cache
    private var cachedPoolBalance: UInt64 = 0
    private var cachedTokenBalances: [String: UInt64] = [:]

    // MARK: - Configuration

    public struct Configuration: Sendable {
        /// RPC endpoint for Solana
        public let rpcEndpoint: String

        /// Network (devnet/mainnet)
        public let network: String

        public init(
            rpcEndpoint: String = "https://api.devnet.solana.com",
            network: String = "devnet"
        ) {
            self.rpcEndpoint = rpcEndpoint
            self.network = network
        }

        public static let devnet = Configuration()
        public static let mainnet = Configuration(
            rpcEndpoint: "https://api.mainnet-beta.solana.com",
            network: "mainnet"
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

        print("[PrivacyCash] Initializing provider...")

        // Load the bundled SDK JavaScript
        let sdkBundle = try loadSDKBundle()

        // Create JSContext bridge (no WASM needed)
        let bridge = JSContextBridge(
            bundledJS: sdkBundle,
            globalObjectName: "privacyCash"
        )

        try await bridge.initialize()

        // Initialize the SDK with our configuration
        let initResult = try await bridge.execute(method: "init", params: [
            "rpcEndpoint": config.rpcEndpoint,
            "network": config.network
        ])

        guard initResult.success else {
            throw PrivacyProtocolError.sdkLoadFailed(initResult.error ?? "Unknown initialization error")
        }

        self.jsBridge = bridge
        self.isInitialized = true

        print("[PrivacyCash] Provider initialized successfully")
    }

    public func deposit(amount: UInt64, token: String?) async throws -> PrivacyDepositResult {
        guard let bridge = jsBridge else {
            throw PrivacyProtocolError.notInitialized
        }

        print("[PrivacyCash] Depositing \(amount) lamports\(token.map { " (\($0))" } ?? "")")

        let method = token == nil ? "deposit" : "depositSPL"
        var params: [String: Any] = ["amount": amount]
        if let token = token {
            params["mint"] = token
        }

        let result = try await bridge.execute(method: method, params: params)

        guard result.success, let data = result.data,
              let signature = data["signature"] as? String else {
            throw PrivacyProtocolError.depositFailed(result.error ?? "Invalid response format")
        }

        // Update cached balance
        if let token = token {
            cachedTokenBalances[token, default: 0] += amount
        } else {
            cachedPoolBalance += amount
        }

        // Parse commitment if present
        let commitmentHex = data["commitment"] as? String
        let commitment = commitmentHex.flatMap { Data(hexString: $0) } ?? Data()

        return PrivacyDepositResult(
            signature: signature,
            commitment: commitment,
            amount: amount,
            token: token
        )
    }

    public func withdraw(amount: UInt64, token: String?, destination: String) async throws -> PrivacyWithdrawResult {
        guard let bridge = jsBridge else {
            throw PrivacyProtocolError.notInitialized
        }

        // Check cached balance
        let availableBalance = token == nil ? cachedPoolBalance : (cachedTokenBalances[token!] ?? 0)
        guard availableBalance >= amount else {
            throw PrivacyProtocolError.insufficientPoolBalance(available: availableBalance, required: amount)
        }

        print("[PrivacyCash] Withdrawing \(amount) lamports to \(destination)")

        let method = token == nil ? "withdraw" : "withdrawSPL"
        var params: [String: Any] = [
            "amount": amount,
            "recipientAddress": destination
        ]
        if let token = token {
            params["mint"] = token
        }

        let result = try await bridge.execute(method: method, params: params)

        guard result.success, let data = result.data,
              let signature = data["signature"] as? String else {
            throw PrivacyProtocolError.withdrawFailed(result.error ?? "Invalid response format")
        }

        // Update cached balance
        if let token = token {
            cachedTokenBalances[token, default: 0] -= min(amount, cachedTokenBalances[token] ?? 0)
        } else {
            cachedPoolBalance -= min(amount, cachedPoolBalance)
        }

        return PrivacyWithdrawResult(
            signature: signature,
            amount: amount,
            destination: destination,
            token: token
        )
    }

    public func transfer(amount: UInt64, recipient: String) async throws -> PrivacyTransferResult {
        guard let bridge = jsBridge else {
            throw PrivacyProtocolError.notInitialized
        }

        print("[PrivacyCash] Internal transfer of \(amount) lamports to \(recipient)")

        let result = try await bridge.execute(method: "transfer", params: [
            "amount": amount,
            "recipient": recipient
        ])

        let identifier: String
        if result.success, let data = result.data,
           let txId = data["transactionId"] as? String {
            identifier = txId
        } else {
            identifier = UUID().uuidString
        }

        return PrivacyTransferResult(
            identifier: identifier,
            amount: amount,
            isInternal: true
        )
    }

    public func getBalance(token: String?) async throws -> UInt64 {
        guard let bridge = jsBridge else {
            throw PrivacyProtocolError.notInitialized
        }

        let method = token == nil ? "getPrivateBalance" : "getPrivateBalanceSPL"
        var params: [String: Any] = [:]
        if let token = token {
            params["mint"] = token
        }

        let result = try await bridge.execute(method: method, params: params)

        if result.success, let data = result.data,
           let balance = data["balance"] as? UInt64 {
            // Update cache
            if let token = token {
                cachedTokenBalances[token] = balance
            } else {
                cachedPoolBalance = balance
            }
            return balance
        }

        // Return cached balance if live query fails
        return token == nil ? cachedPoolBalance : (cachedTokenBalances[token!] ?? 0)
    }

    public func shutdown() async {
        await jsBridge?.shutdown()
        jsBridge = nil
        isInitialized = false
        cachedPoolBalance = 0
        cachedTokenBalances.removeAll()
        print("[PrivacyCash] Provider shut down")
    }

    /// Set the wallet for transaction signing
    /// - Parameter secretKey: The wallet's secret key (64 bytes ed25519)
    public func setWallet(_ secretKey: Data) async {
        guard let bridge = jsBridge else {
            print("[PrivacyCash] Cannot set wallet - not initialized")
            return
        }

        // Convert to base58 for the JS SDK
        let base58Key = secretKey.base58EncodedString

        do {
            let result = try await bridge.execute(method: "setOwner", params: [
                "owner": base58Key
            ])

            if result.success {
                print("[PrivacyCash] Wallet set successfully")
            } else {
                print("[PrivacyCash] Failed to set wallet: \(result.error ?? "unknown")")
            }
        } catch {
            print("[PrivacyCash] Error setting wallet: \(error)")
        }
    }

    // MARK: - Privacy Cash-Specific Methods

    /// Route a settlement through Privacy Cash
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

        print("[PrivacyCash] Routing settlement through privacy pool")
        print("[PrivacyCash]   From: \(sourceAddress)")
        print("[PrivacyCash]   To: \(destinationAddress)")
        print("[PrivacyCash]   Amount: \(amount) lamports")

        // Step 1: Deposit from source into pool
        let depositResult = try await depositFromStealth(
            sourceAddress: sourceAddress,
            amount: amount,
            spendingKey: spendingKey
        )
        print("[PrivacyCash]   Deposit tx: \(depositResult.signature)")

        // Step 2: Wait for confirmation
        try await Task.sleep(nanoseconds: 2_000_000_000) // 2s

        // Step 3: Withdraw to destination
        let withdrawResult = try await withdraw(
            amount: amount,
            token: nil,
            destination: destinationAddress
        )
        print("[PrivacyCash]   Withdraw tx: \(withdrawResult.signature)")

        return withdrawResult.signature
    }

    /// Deposit funds from a stealth address
    private func depositFromStealth(
        sourceAddress: String,
        amount: UInt64,
        spendingKey: Data
    ) async throws -> PrivacyDepositResult {
        guard let bridge = jsBridge else {
            throw PrivacyProtocolError.notInitialized
        }

        let result = try await bridge.execute(method: "depositFrom", params: [
            "sourceAddress": sourceAddress,
            "amount": amount,
            "spendingKey": spendingKey.base64EncodedString()
        ])

        guard result.success, let data = result.data,
              let signature = data["signature"] as? String else {
            throw PrivacyProtocolError.depositFailed(result.error ?? "Invalid response format")
        }

        cachedPoolBalance += amount

        let commitmentHex = data["commitment"] as? String
        let commitment = commitmentHex.flatMap { Data(hexString: $0) } ?? Data()

        return PrivacyDepositResult(
            signature: signature,
            commitment: commitment,
            amount: amount,
            token: nil
        )
    }

    // MARK: - SDK Bundle Loading

    private func loadSDKBundle() throws -> String {
        // Try to load from bundle resources
        if let bundleURL = Bundle.module.url(forResource: "privacycash-bundle", withExtension: "js"),
           let bundleContent = try? String(contentsOf: bundleURL, encoding: .utf8) {
            return bundleContent
        }

        // Fallback: Use placeholder SDK for development
        return Self.placeholderSDK
    }

    /// Placeholder SDK for development/testing
    private static let placeholderSDK = """
    (function() {
        console.log('[PrivacyCash] Loading placeholder SDK...');

        var privacyCash = {
            _initialized: false,
            _config: null,
            _balance: 0,
            _tokenBalances: {},

            init: function(config) {
                console.log('[PrivacyCash] Initializing with config:', JSON.stringify(config));
                this._config = config;
                this._initialized = true;
                return { success: true };
            },

            deposit: function(params) {
                if (!this._initialized) throw new Error('Not initialized');
                console.log('[PrivacyCash] Deposit:', JSON.stringify(params));

                var amount = params.amount || 0;
                this._balance += amount;

                var signature = Array(88).fill(0).map(function() {
                    return 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'[
                        Math.floor(Math.random() * 62)
                    ];
                }).join('');

                return {
                    signature: signature,
                    commitment: '0x' + Array(64).fill(0).map(function() {
                        return Math.floor(Math.random() * 16).toString(16);
                    }).join('')
                };
            },

            depositSPL: function(params) {
                if (!this._initialized) throw new Error('Not initialized');
                var mint = params.mint;
                var amount = params.amount || 0;
                this._tokenBalances[mint] = (this._tokenBalances[mint] || 0) + amount;
                return this.deposit(params);
            },

            depositFrom: function(params) {
                return this.deposit(params);
            },

            withdraw: function(params) {
                if (!this._initialized) throw new Error('Not initialized');
                console.log('[PrivacyCash] Withdraw:', JSON.stringify(params));

                var amount = params.amount || 0;
                if (this._balance < amount) {
                    throw new Error('Insufficient pool balance');
                }
                this._balance -= amount;

                var signature = Array(88).fill(0).map(function() {
                    return 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789'[
                        Math.floor(Math.random() * 62)
                    ];
                }).join('');

                return { signature: signature };
            },

            withdrawSPL: function(params) {
                if (!this._initialized) throw new Error('Not initialized');
                var mint = params.mint;
                var amount = params.amount || 0;
                if ((this._tokenBalances[mint] || 0) < amount) {
                    throw new Error('Insufficient token balance');
                }
                this._tokenBalances[mint] -= amount;
                return this.withdraw(params);
            },

            transfer: function(params) {
                if (!this._initialized) throw new Error('Not initialized');
                console.log('[PrivacyCash] Transfer:', JSON.stringify(params));
                return {
                    transactionId: 'tx_' + Date.now() + '_' + Math.random().toString(36).substr(2, 9)
                };
            },

            getPrivateBalance: function(params) {
                if (!this._initialized) throw new Error('Not initialized');
                return { balance: this._balance };
            },

            getPrivateBalanceSPL: function(params) {
                if (!this._initialized) throw new Error('Not initialized');
                var mint = params.mint;
                return { balance: this._tokenBalances[mint] || 0 };
            }
        };

        // Export to global scope (for JSContext)
        this.privacyCash = privacyCash;

        console.log('[PrivacyCash] Placeholder SDK loaded');
    })();
    """
}
