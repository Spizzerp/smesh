import Foundation
import Base58Swift

/// Errors that can occur during Solana RPC operations
public enum SolanaError: Error, LocalizedError {
    case invalidURL
    case networkError(Error)
    case rpcError(code: Int, message: String)
    case decodingError(String)
    case invalidBase58
    case invalidPublicKey
    case transactionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid RPC URL"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .rpcError(let code, let message):
            return "RPC error \(code): \(message)"
        case .decodingError(let message):
            return "Decoding error: \(message)"
        case .invalidBase58:
            return "Invalid Base58 encoding"
        case .invalidPublicKey:
            return "Invalid public key"
        case .transactionFailed(let reason):
            return "Transaction failed: \(reason)"
        }
    }
}

/// Solana network cluster configuration
public enum SolanaCluster: Sendable {
    case mainnetBeta
    case devnet
    case testnet
    case custom(URL)

    public var url: URL {
        switch self {
        case .mainnetBeta:
            return URL(string: "https://api.mainnet-beta.solana.com")!
        case .devnet:
            return URL(string: "https://api.devnet.solana.com")!
        case .testnet:
            return URL(string: "https://api.testnet.solana.com")!
        case .custom(let url):
            return url
        }
    }
}

/// Account information from Solana RPC
public struct AccountInfo: Codable, Sendable {
    public let data: [String]
    public let executable: Bool
    public let lamports: UInt64
    public let owner: String
    public let rentEpoch: UInt64
    public let space: UInt64?
}

/// Transaction signature information
public struct SignatureInfo: Codable, Sendable {
    public let signature: String
    public let slot: UInt64
    public let err: String?
    public let memo: String?
    public let blockTime: Int64?
}

/// Blockhash response from Solana RPC
public struct BlockhashResult: Codable, Sendable {
    public let blockhash: String
    public let lastValidBlockHeight: UInt64
}

/// Minimal Solana RPC client using JSON-RPC over HTTP
/// Designed for hackathon use - no WebSocket subscriptions
public actor SolanaRPCClient {

    private let endpoint: URL
    private let session: URLSession
    private var requestId: Int = 0

    /// Initialize with a cluster endpoint
    /// - Parameter cluster: The Solana cluster to connect to
    public init(cluster: SolanaCluster = .devnet) {
        self.endpoint = cluster.url

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    /// Initialize with a custom RPC URL (e.g., Helius)
    /// - Parameter url: Custom RPC endpoint URL
    public init(url: URL) {
        self.endpoint = url

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        self.session = URLSession(configuration: config)
    }

    // MARK: - Public Methods

    /// Get the balance of an account in lamports
    /// - Parameter pubkey: Base58-encoded public key
    /// - Returns: Balance in lamports
    public func getBalance(pubkey: String) async throws -> UInt64 {
        let params: [Any] = [pubkey]
        let result: RPCResult<GetBalanceResponse> = try await request(method: "getBalance", params: params)
        return result.value.value
    }

    /// Get the latest blockhash for transaction building
    /// - Returns: Blockhash and last valid block height
    public func getLatestBlockhash() async throws -> BlockhashResult {
        let params: [Any] = [["commitment": "finalized"]]
        let result: RPCResult<GetBlockhashResponse> = try await request(method: "getLatestBlockhash", params: params)
        return result.value.value
    }

    /// Send a signed transaction
    /// - Parameters:
    ///   - signedTransaction: Base64-encoded signed transaction
    ///   - skipPreflight: Whether to skip preflight checks
    /// - Returns: Transaction signature
    public func sendTransaction(
        signedTransaction: Data,
        skipPreflight: Bool = false
    ) async throws -> String {
        let base64Tx = signedTransaction.base64EncodedString()
        let params: [Any] = [
            base64Tx,
            [
                "encoding": "base64",
                "skipPreflight": skipPreflight,
                "preflightCommitment": "confirmed"
            ]
        ]
        let result: RPCResult<String> = try await request(method: "sendTransaction", params: params)
        return result.value
    }

    /// Get account information including data
    /// - Parameters:
    ///   - pubkey: Base58-encoded public key
    ///   - encoding: Data encoding (default: base64)
    /// - Returns: Account info or nil if account doesn't exist
    public func getAccountInfo(pubkey: String, encoding: String = "base64") async throws -> AccountInfo? {
        let params: [Any] = [
            pubkey,
            ["encoding": encoding]
        ]
        let result: RPCResult<GetAccountInfoResponse> = try await request(method: "getAccountInfo", params: params)
        return result.value.value
    }

    /// Get transaction signatures for an address
    /// - Parameters:
    ///   - address: Base58-encoded address
    ///   - limit: Maximum number of signatures to return
    ///   - before: Get signatures before this signature
    /// - Returns: Array of signature information
    public func getSignaturesForAddress(
        address: String,
        limit: Int = 100,
        before: String? = nil
    ) async throws -> [SignatureInfo] {
        var options: [String: Any] = ["limit": limit]
        if let before = before {
            options["before"] = before
        }
        let params: [Any] = [address, options]
        let result: RPCResult<[SignatureInfo]> = try await request(method: "getSignaturesForAddress", params: params)
        return result.value
    }

    /// Confirm a transaction by checking its status
    /// - Parameters:
    ///   - signature: Transaction signature to check
    ///   - commitment: Commitment level
    /// - Returns: True if confirmed, false otherwise
    public func confirmTransaction(signature: String, commitment: String = "confirmed") async throws -> Bool {
        // Use getSignatureStatuses for confirmation
        let params: [Any] = [[signature]]
        let result: RPCResult<GetSignatureStatusesResponse> = try await request(method: "getSignatureStatuses", params: params)

        guard let status = result.value.value.first, let status = status else {
            return false
        }

        return status.confirmationStatus == "confirmed" || status.confirmationStatus == "finalized"
    }

    /// Request an airdrop (devnet/testnet only)
    /// - Parameters:
    ///   - pubkey: Base58-encoded public key
    ///   - lamports: Amount of lamports to airdrop
    /// - Returns: Transaction signature
    public func requestAirdrop(pubkey: String, lamports: UInt64) async throws -> String {
        let params: [Any] = [pubkey, lamports]
        let result: RPCResult<String> = try await request(method: "requestAirdrop", params: params)
        return result.value
    }

    // MARK: - Private Methods

    private func nextRequestId() -> Int {
        requestId += 1
        return requestId
    }

    private func request<T: Codable>(method: String, params: [Any]) async throws -> RPCResult<T> {
        let id = nextRequestId()

        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        ]

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw SolanaError.networkError(URLError(.badServerResponse))
        }

        guard httpResponse.statusCode == 200 else {
            throw SolanaError.networkError(URLError(.badServerResponse))
        }

        // Parse response
        let decoder = JSONDecoder()
        let rpcResponse = try decoder.decode(RPCResponse<T>.self, from: data)

        if let error = rpcResponse.error {
            throw SolanaError.rpcError(code: error.code, message: error.message)
        }

        guard let result = rpcResponse.result else {
            throw SolanaError.decodingError("No result in response")
        }

        return RPCResult(value: result)
    }
}

// MARK: - Internal Response Types

private struct RPCResult<T> {
    let value: T
}

private struct RPCResponse<T: Codable>: Codable {
    let jsonrpc: String
    let id: Int
    let result: T?
    let error: RPCErrorResponse?
}

private struct RPCErrorResponse: Codable {
    let code: Int
    let message: String
}

private struct GetBalanceResponse: Codable {
    let value: UInt64
}

private struct GetBlockhashResponse: Codable {
    let value: BlockhashResult
}

private struct GetAccountInfoResponse: Codable {
    let value: AccountInfo?
}

private struct GetSignatureStatusesResponse: Codable {
    let value: [SignatureStatus?]
}

private struct SignatureStatus: Codable {
    let slot: UInt64?
    let confirmations: UInt64?
    let confirmationStatus: String?
    let err: String?
}

// MARK: - Utility Extensions

extension SolanaRPCClient {

    /// Convert lamports to SOL
    public static func lamportsToSol(_ lamports: UInt64) -> Double {
        return Double(lamports) / 1_000_000_000
    }

    /// Convert SOL to lamports
    public static func solToLamports(_ sol: Double) -> UInt64 {
        return UInt64(sol * 1_000_000_000)
    }

    /// Validate a Base58 public key
    public static func isValidPublicKey(_ pubkey: String) -> Bool {
        guard let decoded = Base58.base58Decode(pubkey) else {
            return false
        }
        return decoded.count == 32
    }

    /// Decode a Base58 public key to bytes
    public static func decodePublicKey(_ pubkey: String) throws -> Data {
        guard let decoded = Base58.base58Decode(pubkey) else {
            throw SolanaError.invalidBase58
        }
        guard decoded.count == 32 else {
            throw SolanaError.invalidPublicKey
        }
        return Data(decoded)
    }

    /// Encode bytes to Base58 public key
    public static func encodePublicKey(_ data: Data) -> String {
        return Base58.base58Encode([UInt8](data))
    }
}
