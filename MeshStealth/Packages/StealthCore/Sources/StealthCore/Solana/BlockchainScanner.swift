import Foundation

/// Extended payment info that includes on-chain data
public struct OnChainStealthPayment: Sendable {
    /// The core detected payment with spending key
    public let payment: DetectedStealthPayment

    /// Amount in lamports (from on-chain balance)
    public let lamports: UInt64

    /// CiphertextAccount PDA address
    public let ciphertextPDA: String

    public init(payment: DetectedStealthPayment, lamports: UInt64, ciphertextPDA: String) {
        self.payment = payment
        self.lamports = lamports
        self.ciphertextPDA = ciphertextPDA
    }
}

/// Scanner for detecting hybrid stealth payments on Solana
/// Uses the stealth-pq program's PDA-based ciphertext storage
public actor BlockchainScanner {

    private let rpcClient: SolanaRPCClient
    private let stealthPQClient: StealthPQClient
    private let stealthScanner: StealthScanner

    /// Initialize the blockchain scanner
    /// - Parameters:
    ///   - rpcClient: Solana RPC client
    ///   - stealthScanner: Stealth scanner with recipient's viewing keys
    ///   - programId: stealth-pq program ID
    public init(
        rpcClient: SolanaRPCClient,
        stealthScanner: StealthScanner,
        programId: String = STEALTH_PQ_PROGRAM_ID
    ) {
        self.rpcClient = rpcClient
        self.stealthScanner = stealthScanner
        self.stealthPQClient = StealthPQClient(rpcClient: rpcClient, programId: programId)
    }

    // MARK: - Scanning

    /// Scan a list of potential stealth addresses for payments
    /// - Parameter potentialStealthAddresses: Base58-encoded stealth addresses to check
    /// - Returns: Array of detected stealth payments with spending keys
    public func scanForPayments(
        potentialStealthAddresses: [String]
    ) async -> [OnChainStealthPayment] {
        var detected: [OnChainStealthPayment] = []

        for address in potentialStealthAddresses {
            do {
                if let payment = try await scanAddress(address) {
                    detected.append(payment)
                }
            } catch {
                // Log but continue scanning
                print("Error scanning address \(address): \(error)")
            }
        }

        return detected
    }

    /// Scan a single address for a stealth payment
    /// - Parameter stealthAddress: Base58-encoded stealth address
    /// - Returns: Detected payment if found and valid, nil otherwise
    public func scanAddress(_ stealthAddress: String) async throws -> OnChainStealthPayment? {
        // 1. Fetch CiphertextAccount PDA data
        guard let ciphertextData = try await stealthPQClient.getCiphertextAccount(stealthAddress: stealthAddress) else {
            return nil  // No ciphertext stored for this address
        }

        // 2. Get the PDA address
        let (pdaAddress, _) = try await stealthPQClient.deriveCiphertextPDA(stealthAddress: stealthAddress)

        // 3. Attempt to scan using hybrid decryption
        let detectedPayment: DetectedStealthPayment?

        // Check if we have MLKEM ciphertext (non-zero bytes)
        let hasMLKEMCiphertext = ciphertextData.mlkemCiphertext.contains(where: { $0 != 0 })

        if hasMLKEMCiphertext {
            // Hybrid mode: X25519 + MLKEM768
            detectedPayment = try stealthScanner.scanHybridTransaction(
                stealthAddress: stealthAddress,
                ephemeralPublicKey: ciphertextData.ephemeralPubkey,
                mlkemCiphertext: ciphertextData.mlkemCiphertext
            )
        } else {
            // Classical mode: X25519 only
            detectedPayment = try stealthScanner.scanTransaction(
                stealthAddress: stealthAddress,
                ephemeralPublicKey: ciphertextData.ephemeralPubkey
            )
        }

        guard let payment = detectedPayment else {
            return nil  // Not for us
        }

        // 4. Get balance of stealth address
        let balance = try await rpcClient.getBalance(pubkey: stealthAddress)

        // 5. Build on-chain payment
        return OnChainStealthPayment(
            payment: payment,
            lamports: balance,
            ciphertextPDA: pdaAddress
        )
    }

    /// Generate potential stealth addresses from recent program transactions
    /// This is a heuristic approach for discovery
    /// - Parameters:
    ///   - limit: Maximum number of transactions to analyze
    ///   - programId: stealth-pq program ID
    /// - Returns: Array of transaction signatures (for further analysis)
    public func discoverRecentTransactions(
        limit: Int = 100,
        programId: String = STEALTH_PQ_PROGRAM_ID
    ) async throws -> [SignatureInfo] {
        return try await rpcClient.getSignaturesForAddress(
            address: programId,
            limit: limit
        )
    }

    // MARK: - Utility

    /// Check if a stealth address has an associated CiphertextAccount
    /// - Parameter stealthAddress: Base58-encoded stealth address
    /// - Returns: True if ciphertext exists
    public func hasAssociatedCiphertext(_ stealthAddress: String) async throws -> Bool {
        return try await stealthPQClient.ciphertextAccountExists(stealthAddress: stealthAddress)
    }

    /// Get the balance of a stealth address
    /// - Parameter stealthAddress: Base58-encoded stealth address
    /// - Returns: Balance in lamports
    public func getStealthAddressBalance(_ stealthAddress: String) async throws -> UInt64 {
        return try await rpcClient.getBalance(pubkey: stealthAddress)
    }

    /// Get ciphertext account data without attempting to decrypt
    /// - Parameter stealthAddress: Base58-encoded stealth address
    /// - Returns: Raw ciphertext account data
    public func getCiphertextData(_ stealthAddress: String) async throws -> CiphertextAccountData? {
        return try await stealthPQClient.getCiphertextAccount(stealthAddress: stealthAddress)
    }
}

// MARK: - Batch Operations

extension BlockchainScanner {

    /// Batch scan multiple addresses with concurrency limit
    /// - Parameters:
    ///   - addresses: Addresses to scan
    ///   - concurrency: Maximum concurrent requests
    /// - Returns: Array of detected payments
    public func batchScan(
        addresses: [String],
        concurrency: Int = 5
    ) async -> [OnChainStealthPayment] {
        // Process in chunks to limit concurrency
        var results: [OnChainStealthPayment] = []

        for chunk in addresses.chunked(into: concurrency) {
            await withTaskGroup(of: OnChainStealthPayment?.self) { group in
                for address in chunk {
                    group.addTask {
                        try? await self.scanAddress(address)
                    }
                }

                for await result in group {
                    if let payment = result {
                        results.append(payment)
                    }
                }
            }
        }

        return results
    }
}

// MARK: - Array Chunking Extension

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
