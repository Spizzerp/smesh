import Foundation

/// Service for requesting devnet SOL airdrops
public actor DevnetFaucet {
    private let rpcEndpoint: URL

    /// Initialize with default Solana devnet RPC
    public init(rpcEndpoint: URL = URL(string: "https://api.devnet.solana.com")!) {
        self.rpcEndpoint = rpcEndpoint
    }

    /// Request an airdrop of SOL to the specified address
    /// - Parameters:
    ///   - address: Base58 Solana address
    ///   - lamports: Amount in lamports (1 SOL = 1_000_000_000 lamports). Default is 1 SOL.
    /// - Returns: Transaction signature
    public func requestAirdrop(to address: String, lamports: UInt64 = 1_000_000_000) async throws -> String {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "requestAirdrop",
            "params": [address, lamports]
        ]

        var request = URLRequest(url: rpcEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        // Check HTTP status - specifically handle 429 rate limiting
        if let httpResponse = response as? HTTPURLResponse {
            if httpResponse.statusCode == 429 {
                throw FaucetError.rateLimited
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                throw FaucetError.httpError(statusCode: httpResponse.statusCode)
            }
        }

        let rpcResponse = try JSONDecoder().decode(AirdropResponse.self, from: data)

        if let error = rpcResponse.error {
            // Check for rate limiting
            if error.message.lowercased().contains("rate") ||
               error.message.lowercased().contains("limit") {
                throw FaucetError.rateLimited
            }
            throw FaucetError.rpcError(code: error.code, message: error.message)
        }

        guard let signature = rpcResponse.result else {
            throw FaucetError.noSignature
        }

        return signature
    }

    /// Check balance of an address
    /// - Parameter address: Base58 Solana address
    /// - Returns: Balance in lamports
    public func getBalance(address: String) async throws -> UInt64 {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "getBalance",
            "params": [address, ["commitment": "confirmed"]]
        ]

        var request = URLRequest(url: rpcEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        // Check HTTP status
        if let httpResponse = response as? HTTPURLResponse {
            guard (200...299).contains(httpResponse.statusCode) else {
                throw FaucetError.httpError(statusCode: httpResponse.statusCode)
            }
        }

        let rpcResponse = try JSONDecoder().decode(BalanceResponse.self, from: data)

        if let error = rpcResponse.error {
            throw FaucetError.rpcError(code: error.code, message: error.message)
        }

        return rpcResponse.result?.value ?? 0
    }

    /// Get recent blockhash for transaction construction
    /// - Returns: Base58-encoded blockhash
    public func getRecentBlockhash() async throws -> String {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "getLatestBlockhash",
            "params": [["commitment": "confirmed"]]
        ]

        var request = URLRequest(url: rpcEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse {
            guard (200...299).contains(httpResponse.statusCode) else {
                throw FaucetError.httpError(statusCode: httpResponse.statusCode)
            }
        }

        let rpcResponse = try JSONDecoder().decode(FaucetBlockhashResponse.self, from: data)

        if let error = rpcResponse.error {
            throw FaucetError.rpcError(code: error.code, message: error.message)
        }

        guard let blockhash = rpcResponse.result?.value.blockhash else {
            throw FaucetError.rpcError(code: -1, message: "No blockhash returned")
        }

        return blockhash
    }

    /// Send a signed transaction to the network
    /// - Parameter signedTransaction: Base64-encoded signed transaction
    /// - Returns: Transaction signature
    public func sendTransaction(_ signedTransaction: String) async throws -> String {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": 1,
            "method": "sendTransaction",
            "params": [
                signedTransaction,
                ["encoding": "base64", "preflightCommitment": "confirmed"]
            ]
        ]

        var request = URLRequest(url: rpcEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)

        if let httpResponse = response as? HTTPURLResponse {
            guard (200...299).contains(httpResponse.statusCode) else {
                throw FaucetError.httpError(statusCode: httpResponse.statusCode)
            }
        }

        let rpcResponse = try JSONDecoder().decode(SendTransactionResponse.self, from: data)

        if let error = rpcResponse.error {
            throw FaucetError.rpcError(code: error.code, message: error.message)
        }

        guard let signature = rpcResponse.result else {
            throw FaucetError.noSignature
        }

        return signature
    }

    /// Wait for a transaction to be confirmed
    /// - Parameters:
    ///   - signature: Transaction signature to wait for
    ///   - timeout: Maximum time to wait in seconds
    public func waitForConfirmation(signature: String, timeout: TimeInterval = 30) async throws {
        let startTime = Date()

        while Date().timeIntervalSince(startTime) < timeout {
            let body: [String: Any] = [
                "jsonrpc": "2.0",
                "id": 1,
                "method": "getSignatureStatuses",
                "params": [[signature]]
            ]

            var request = URLRequest(url: rpcEndpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (data, _) = try await URLSession.shared.data(for: request)
            let response = try JSONDecoder().decode(FaucetSignatureStatusResponse.self, from: data)

            if let status = response.result?.value.first,
               let unwrappedStatus = status {
                // Check for transaction execution error FIRST
                if unwrappedStatus.err != nil {
                    print("[RPC] Transaction \(signature.prefix(20))... FAILED with error")
                    throw FaucetError.transactionFailed("Transaction failed on-chain (signature verified but execution failed)")
                }

                // Then check confirmation status
                if let confirmationStatus = unwrappedStatus.confirmationStatus,
                   confirmationStatus == "confirmed" || confirmationStatus == "finalized" {
                    print("[RPC] Transaction \(signature.prefix(20))... confirmed successfully")
                    return
                }
            }

            // Wait before checking again
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
        }

        throw FaucetError.confirmationTimeout
    }
}

// MARK: - Response Types

struct AirdropResponse: Decodable {
    let jsonrpc: String
    let id: Int
    let result: String?
    let error: RPCError?
}

struct BalanceResponse: Decodable {
    let jsonrpc: String
    let id: Int
    let result: BalanceResult?
    let error: RPCError?
}

struct BalanceResult: Decodable {
    let context: RPCContext?
    let value: UInt64
}

private struct FaucetBlockhashResponse: Decodable {
    let jsonrpc: String
    let id: Int
    let result: FaucetBlockhashResultWrapper?
    let error: RPCError?
}

private struct FaucetBlockhashResultWrapper: Decodable {
    let context: RPCContext?
    let value: FaucetBlockhashValue
}

private struct FaucetBlockhashValue: Decodable {
    let blockhash: String
    let lastValidBlockHeight: UInt64
}

private struct SendTransactionResponse: Decodable {
    let jsonrpc: String
    let id: Int
    let result: String?
    let error: RPCError?
}

struct RPCContext: Decodable {
    let slot: UInt64?
    let apiVersion: String?
}

struct RPCError: Decodable {
    let code: Int
    let message: String
}

struct FaucetSignatureStatusResponse: Decodable {
    let result: FaucetSignatureStatusResult?
}

struct FaucetSignatureStatusResult: Decodable {
    let context: RPCContext?
    let value: [FaucetSignatureStatus?]
}

struct FaucetSignatureStatus: Decodable {
    let slot: UInt64?
    let confirmations: Int?
    let confirmationStatus: String?
    let err: AnyCodable?
}

// Helper for handling arbitrary JSON in error field
struct AnyCodable: Decodable {
    init(from decoder: Decoder) throws {
        // Just consume the value, we don't need to store it
        _ = try? decoder.singleValueContainer()
    }
}

// MARK: - Errors

/// Errors that can occur when interacting with the devnet faucet
public enum FaucetError: Error, LocalizedError {
    case rpcError(code: Int, message: String)
    case httpError(statusCode: Int)
    case noSignature
    case rateLimited
    case confirmationTimeout
    case transactionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .rpcError(let code, let message):
            return "RPC Error (\(code)): \(message)"
        case .httpError(let statusCode):
            return "HTTP Error: \(statusCode)"
        case .noSignature:
            return "No signature returned from airdrop request"
        case .rateLimited:
            return "Rate limited by devnet faucet. Try again in 24 hours, or fund from an external wallet (copy your address and use a web faucet)."
        case .confirmationTimeout:
            return "Transaction confirmation timed out"
        case .transactionFailed(let reason):
            return "Transaction failed: \(reason)"
        }
    }
}

// MARK: - Convenience Extensions

extension DevnetFaucet {
    /// Request 1 SOL airdrop (convenience method)
    public func requestOneSol(to address: String) async throws -> String {
        try await requestAirdrop(to: address, lamports: 1_000_000_000)
    }

    /// Request 2 SOL airdrop (maximum typically allowed)
    public func requestTwoSol(to address: String) async throws -> String {
        try await requestAirdrop(to: address, lamports: 2_000_000_000)
    }

    /// Get balance formatted as SOL
    public func getBalanceInSol(address: String) async throws -> Double {
        let lamports = try await getBalance(address: address)
        return Double(lamports) / 1_000_000_000.0
    }
}
