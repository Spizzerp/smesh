import Foundation

/// Result of a shield operation
public struct ShieldResult: Sendable {
    /// The stealth address funds were sent to
    public let stealthAddress: String
    /// Ephemeral public key for derivation
    public let ephemeralPublicKey: Data
    /// MLKEM ciphertext (if hybrid mode)
    public let mlkemCiphertext: Data?
    /// Amount shielded in lamports
    public let amount: UInt64
    /// Transaction signature
    public let signature: String
    /// View tag for fast filtering
    public let viewTag: UInt8
}

/// Result of an unshield operation
public struct UnshieldResult: Sendable {
    /// The stealth address funds were taken from
    public let stealthAddress: String
    /// Amount unshielded in lamports
    public let amount: UInt64
    /// Transaction signature
    public let signature: String
    /// The payment ID that was unshielded
    public let paymentId: UUID
}

/// Result of a hop operation (stealth-to-stealth transfer for privacy)
public struct HopResult: Sendable {
    /// The source stealth address funds were taken from
    public let sourceStealthAddress: String
    /// The destination stealth address funds were sent to
    public let destinationStealthAddress: String
    /// Ephemeral public key for deriving spending key of destination
    public let ephemeralPublicKey: Data
    /// MLKEM ciphertext (if hybrid mode)
    public let mlkemCiphertext: Data?
    /// Amount transferred in lamports
    public let amount: UInt64
    /// Transaction signature
    public let signature: String
    /// View tag for fast filtering
    public let viewTag: UInt8
    /// The payment ID that was hopped from
    public let sourcePaymentId: UUID
}

/// Errors from shield operations
public enum ShieldError: Error, LocalizedError {
    case notInitialized
    case insufficientBalance(available: UInt64, required: UInt64)
    case stealthAddressGenerationFailed
    case transactionFailed(String)
    case signingFailed
    case keyDerivationFailed
    case paymentNotFound
    case stealthAddressEmpty

    public var errorDescription: String? {
        switch self {
        case .notInitialized:
            return "Wallet not initialized"
        case .insufficientBalance(let available, let required):
            let availableSol = Double(available) / 1_000_000_000
            let requiredSol = Double(required) / 1_000_000_000
            return String(format: "Insufficient balance: %.4f SOL available, %.4f SOL required", availableSol, requiredSol)
        case .stealthAddressGenerationFailed:
            return "Failed to generate stealth address"
        case .transactionFailed(let msg):
            return "Transaction failed: \(msg)"
        case .signingFailed:
            return "Failed to sign transaction"
        case .keyDerivationFailed:
            return "Failed to derive spending key for stealth address"
        case .paymentNotFound:
            return "Payment not found"
        case .stealthAddressEmpty:
            return "Stealth address has no balance"
        }
    }
}

/// Service for shielding funds from main wallet to stealth addresses
/// "Shield" moves public funds to private stealth addresses
public actor ShieldService {

    private let rpcClient: DevnetFaucet
    private let estimatedFee: UInt64 = 5000  // 0.000005 SOL per signature

    public init(rpcClient: DevnetFaucet = DevnetFaucet()) {
        self.rpcClient = rpcClient
    }

    /// Shield funds from main wallet to a stealth address
    /// Generates a stealth address for ourselves and transfers SOL to it
    /// - Parameters:
    ///   - lamports: Amount to shield in lamports
    ///   - mainWallet: The main wallet to transfer from
    ///   - stealthKeyPair: Our stealth keypair (to generate self-stealth address)
    /// - Returns: ShieldResult with the generated stealth address and transaction details
    public func shield(
        lamports: UInt64,
        mainWallet: SolanaWallet,
        stealthKeyPair: StealthKeyPair
    ) async throws -> ShieldResult {

        // 1. Check balance
        let mainAddress = await mainWallet.address
        let balance = try await rpcClient.getBalance(address: mainAddress)
        let requiredAmount = lamports + estimatedFee

        guard balance >= requiredAmount else {
            throw ShieldError.insufficientBalance(available: balance, required: requiredAmount)
        }

        // 2. Generate stealth address for ourselves using our own meta-address
        // Use hybrid meta-address which automatically includes PQ keys if available
        let metaAddress = stealthKeyPair.hybridMetaAddressString

        let stealthResult: StealthAddressResult
        do {
            stealthResult = try StealthAddressGenerator.generateStealthAddressAuto(
                metaAddressString: metaAddress
            )
        } catch {
            throw ShieldError.stealthAddressGenerationFailed
        }

        // 3. Get recent blockhash
        let blockhash = try await rpcClient.getRecentBlockhash()

        // 4. Build transfer transaction
        let fromPubkey = await mainWallet.publicKeyData
        guard let toPubkey = Data(base58Decoding: stealthResult.stealthAddress) else {
            throw ShieldError.stealthAddressGenerationFailed
        }

        let message = try SolanaTransaction.buildTransfer(
            from: fromPubkey,
            to: toPubkey,
            lamports: lamports,
            recentBlockhash: blockhash
        )

        // 5. Sign with main wallet
        let messageBytes = message.serialize()
        let signature: Data
        do {
            signature = try await mainWallet.sign(messageBytes)
        } catch {
            throw ShieldError.signingFailed
        }

        // 6. Build and send signed transaction
        let signedTx = try SolanaTransaction.buildSignedTransaction(
            message: message,
            signature: signature
        )

        let txSignature: String
        do {
            txSignature = try await rpcClient.sendTransaction(signedTx)
        } catch let error as FaucetError {
            throw ShieldError.transactionFailed(error.localizedDescription)
        } catch {
            throw ShieldError.transactionFailed(error.localizedDescription)
        }

        // 7. Wait for confirmation
        try await rpcClient.waitForConfirmation(signature: txSignature, timeout: 30)

        return ShieldResult(
            stealthAddress: stealthResult.stealthAddress,
            ephemeralPublicKey: stealthResult.ephemeralPublicKey,
            mlkemCiphertext: stealthResult.mlkemCiphertext,
            amount: lamports,
            signature: txSignature,
            viewTag: stealthResult.viewTag
        )
    }

    /// Shield funds with amount in SOL (convenience)
    public func shieldSol(
        _ sol: Double,
        mainWallet: SolanaWallet,
        stealthKeyPair: StealthKeyPair
    ) async throws -> ShieldResult {
        let lamports = UInt64(sol * 1_000_000_000)
        return try await shield(
            lamports: lamports,
            mainWallet: mainWallet,
            stealthKeyPair: stealthKeyPair
        )
    }

    // MARK: - Unshield Operations

    /// Unshield funds from a stealth address back to main wallet
    /// - Parameters:
    ///   - payment: The pending payment to unshield
    ///   - mainWalletAddress: The main wallet address to receive funds
    ///   - spendingKey: The derived spending key for this stealth address (32 bytes)
    ///   - lamports: Amount to unshield (nil = all available minus fee)
    /// - Returns: UnshieldResult with transaction details
    public func unshield(
        payment: PendingPayment,
        mainWalletAddress: String,
        spendingKey: Data,
        lamports: UInt64? = nil
    ) async throws -> UnshieldResult {

        print("[UNSHIELD] Starting unshield for payment \(payment.id)")
        print("[UNSHIELD] Stealth address: \(payment.stealthAddress)")
        print("[UNSHIELD] Ephemeral key: \(payment.ephemeralPublicKey.base58EncodedString)")
        print("[UNSHIELD] Hop count: \(payment.hopCount)")
        print("[UNSHIELD] Is hybrid: \(payment.isHybrid)")

        // 1. Check stealth address balance
        let stealthBalance = try await rpcClient.getBalance(address: payment.stealthAddress)
        print("[UNSHIELD] Stealth balance: \(stealthBalance) lamports")

        guard stealthBalance > estimatedFee else {
            print("[UNSHIELD] ERROR: Balance (\(stealthBalance)) <= fee (\(estimatedFee)) - stealthAddressEmpty")
            throw ShieldError.stealthAddressEmpty
        }

        // 2. Determine amount to transfer (all minus fee, or specified amount)
        let transferAmount = lamports ?? (stealthBalance - estimatedFee)

        guard stealthBalance >= transferAmount + estimatedFee else {
            throw ShieldError.insufficientBalance(available: stealthBalance, required: transferAmount + estimatedFee)
        }

        // 3. Create wallet from spending key (raw scalar, not seed-expanded)
        // The spending key is a raw scalar derived as: p = m + hash(S) mod L
        // We must use stealthScalar init, NOT privateKeyData which treats it as a seed
        let stealthWallet: SolanaWallet
        do {
            stealthWallet = try SolanaWallet(stealthScalar: spendingKey)
        } catch {
            throw ShieldError.keyDerivationFailed
        }

        // 4. Verify the derived wallet matches the stealth address
        let derivedAddress = await stealthWallet.address
        guard derivedAddress == payment.stealthAddress else {
            // Debug: Log the mismatch for troubleshooting
            print("Stealth address mismatch!")
            print("  Expected: \(payment.stealthAddress)")
            print("  Derived:  \(derivedAddress)")
            throw ShieldError.keyDerivationFailed
        }

        // 5. Get recent blockhash
        let blockhash = try await rpcClient.getRecentBlockhash()

        // 6. Build transfer transaction: stealth address → main wallet
        let fromPubkey = await stealthWallet.publicKeyData
        guard let toPubkey = Data(base58Decoding: mainWalletAddress) else {
            throw ShieldError.transactionFailed("Invalid main wallet address")
        }

        let message = try SolanaTransaction.buildTransfer(
            from: fromPubkey,
            to: toPubkey,
            lamports: transferAmount,
            recentBlockhash: blockhash
        )

        // 7. Sign with stealth wallet
        let messageBytes = message.serialize()
        let signature: Data
        do {
            signature = try await stealthWallet.sign(messageBytes)
        } catch {
            throw ShieldError.signingFailed
        }

        // 8. Build and send signed transaction
        let signedTx = try SolanaTransaction.buildSignedTransaction(
            message: message,
            signature: signature
        )

        let txSignature: String
        do {
            txSignature = try await rpcClient.sendTransaction(signedTx)
        } catch let error as FaucetError {
            throw ShieldError.transactionFailed(error.localizedDescription)
        } catch {
            throw ShieldError.transactionFailed(error.localizedDescription)
        }

        // 9. Wait for confirmation
        try await rpcClient.waitForConfirmation(signature: txSignature, timeout: 30)

        return UnshieldResult(
            stealthAddress: payment.stealthAddress,
            amount: transferAmount,
            signature: txSignature,
            paymentId: payment.id
        )
    }

    /// Unshield with amount in SOL (convenience)
    public func unshieldSol(
        _ sol: Double?,
        payment: PendingPayment,
        mainWalletAddress: String,
        spendingKey: Data
    ) async throws -> UnshieldResult {
        let lamports = sol.map { UInt64($0 * 1_000_000_000) }
        return try await unshield(
            payment: payment,
            mainWalletAddress: mainWalletAddress,
            spendingKey: spendingKey,
            lamports: lamports
        )
    }

    // MARK: - Hop Operations (Stealth-to-Stealth for Privacy)

    /// Hop funds from one stealth address to a new stealth address
    /// This creates an intermediate step to improve unlinking privacy
    /// - Parameters:
    ///   - payment: The pending payment to hop from
    ///   - stealthKeyPair: User's stealth keypair (to generate new self-stealth address)
    ///   - spendingKey: The derived spending key for the source stealth address (32 bytes)
    ///   - lamports: Amount to hop (nil = all available minus fee)
    /// - Returns: HopResult with the new stealth address and transaction details
    public func hop(
        payment: PendingPayment,
        stealthKeyPair: StealthKeyPair,
        spendingKey: Data,
        lamports: UInt64? = nil
    ) async throws -> HopResult {

        // 1. Check source stealth address balance
        let sourceBalance = try await rpcClient.getBalance(address: payment.stealthAddress)

        guard sourceBalance > estimatedFee else {
            throw ShieldError.stealthAddressEmpty
        }

        // 2. Determine amount to transfer
        let transferAmount = lamports ?? (sourceBalance - estimatedFee)

        guard sourceBalance >= transferAmount + estimatedFee else {
            throw ShieldError.insufficientBalance(available: sourceBalance, required: transferAmount + estimatedFee)
        }

        // 3. Generate new stealth address for ourselves
        let metaAddress = stealthKeyPair.hybridMetaAddressString

        let stealthResult: StealthAddressResult
        do {
            stealthResult = try StealthAddressGenerator.generateStealthAddressAuto(
                metaAddressString: metaAddress
            )
        } catch {
            throw ShieldError.stealthAddressGenerationFailed
        }

        // 4. Create wallet from source stealth spending key
        let sourceWallet: SolanaWallet
        do {
            sourceWallet = try SolanaWallet(stealthScalar: spendingKey)
        } catch {
            throw ShieldError.keyDerivationFailed
        }

        // 5. Verify the derived wallet matches the source stealth address
        let derivedAddress = await sourceWallet.address
        guard derivedAddress == payment.stealthAddress else {
            print("Stealth address mismatch in hop!")
            print("  Expected: \(payment.stealthAddress)")
            print("  Derived:  \(derivedAddress)")
            throw ShieldError.keyDerivationFailed
        }

        // 6. Get recent blockhash
        let blockhash = try await rpcClient.getRecentBlockhash()

        // 7. Build transfer transaction: source stealth -> new stealth
        let fromPubkey = await sourceWallet.publicKeyData
        guard let toPubkey = Data(base58Decoding: stealthResult.stealthAddress) else {
            throw ShieldError.stealthAddressGenerationFailed
        }

        let message = try SolanaTransaction.buildTransfer(
            from: fromPubkey,
            to: toPubkey,
            lamports: transferAmount,
            recentBlockhash: blockhash
        )

        // 8. Sign with source stealth wallet
        let messageBytes = message.serialize()
        let signature: Data
        do {
            signature = try await sourceWallet.sign(messageBytes)
        } catch {
            throw ShieldError.signingFailed
        }

        // 9. Build and send signed transaction
        let signedTx = try SolanaTransaction.buildSignedTransaction(
            message: message,
            signature: signature
        )

        let txSignature: String
        do {
            txSignature = try await rpcClient.sendTransaction(signedTx)
        } catch let error as FaucetError {
            throw ShieldError.transactionFailed(error.localizedDescription)
        } catch {
            throw ShieldError.transactionFailed(error.localizedDescription)
        }

        // 10. Wait for confirmation
        try await rpcClient.waitForConfirmation(signature: txSignature, timeout: 30)

        // 11. Verify funds arrived at destination (with retry for RPC propagation)
        print("[HOP] Transaction confirmed: \(txSignature)")
        print("[HOP] Source: \(payment.stealthAddress)")
        print("[HOP] Destination: \(stealthResult.stealthAddress)")
        print("[HOP] Amount: \(transferAmount) lamports")

        // Wait a moment for RPC to propagate
        try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

        // Verify destination balance
        let destBalance = try await rpcClient.getBalance(address: stealthResult.stealthAddress)
        print("[HOP] Destination balance after hop: \(destBalance) lamports")

        if destBalance < transferAmount {
            print("[HOP] WARNING: Destination balance (\(destBalance)) less than transfer amount (\(transferAmount))")
            print("[HOP] This may indicate the transaction failed or RPC hasn't propagated yet")
        }

        // Verify we can derive the spending key for the destination
        print("[HOP] Ephemeral public key: \(stealthResult.ephemeralPublicKey.base58EncodedString)")
        if let ciphertext = stealthResult.mlkemCiphertext {
            print("[HOP] MLKEM ciphertext present (\(ciphertext.count) bytes) - hybrid mode")
        } else {
            print("[HOP] Classical mode (no MLKEM ciphertext)")
        }

        return HopResult(
            sourceStealthAddress: payment.stealthAddress,
            destinationStealthAddress: stealthResult.stealthAddress,
            ephemeralPublicKey: stealthResult.ephemeralPublicKey,
            mlkemCiphertext: stealthResult.mlkemCiphertext,
            amount: transferAmount,
            signature: txSignature,
            viewTag: stealthResult.viewTag,
            sourcePaymentId: payment.id
        )
    }

    /// Hop with amount in SOL (convenience)
    public func hopSol(
        _ sol: Double?,
        payment: PendingPayment,
        stealthKeyPair: StealthKeyPair,
        spendingKey: Data
    ) async throws -> HopResult {
        let lamports = sol.map { UInt64($0 * 1_000_000_000) }
        return try await hop(
            payment: payment,
            stealthKeyPair: stealthKeyPair,
            spendingKey: spendingKey,
            lamports: lamports
        )
    }

    // MARK: - Generic Stealth Transfer (for splits/recombines)

    /// Send funds from a stealth address to any destination address
    /// Used for split and recombine operations during mixing
    /// - Parameters:
    ///   - fromStealthAddress: Source stealth address
    ///   - spendingKey: The spending key for the source stealth address
    ///   - toAddress: Destination address (can be stealth or regular)
    ///   - lamports: Amount to send
    /// - Returns: Transaction signature
    public func sendFromStealth(
        fromStealthAddress: String,
        spendingKey: Data,
        toAddress: String,
        lamports: UInt64
    ) async throws -> String {
        print("[SEND-STEALTH] Sending \(lamports) lamports")
        print("[SEND-STEALTH] From: \(fromStealthAddress)")
        print("[SEND-STEALTH] To: \(toAddress)")

        // 1. Check source balance
        let sourceBalance = try await rpcClient.getBalance(address: fromStealthAddress)

        guard sourceBalance >= lamports + estimatedFee else {
            throw ShieldError.insufficientBalance(available: sourceBalance, required: lamports + estimatedFee)
        }

        // 2. Create wallet from spending key
        let sourceWallet: SolanaWallet
        do {
            sourceWallet = try SolanaWallet(stealthScalar: spendingKey)
        } catch {
            throw ShieldError.keyDerivationFailed
        }

        // 3. Verify the derived wallet matches the source address
        let derivedAddress = await sourceWallet.address
        guard derivedAddress == fromStealthAddress else {
            print("[SEND-STEALTH] Address mismatch!")
            print("[SEND-STEALTH]   Expected: \(fromStealthAddress)")
            print("[SEND-STEALTH]   Derived:  \(derivedAddress)")
            throw ShieldError.keyDerivationFailed
        }

        // 4. Get recent blockhash
        let blockhash = try await rpcClient.getRecentBlockhash()

        // 5. Build transfer transaction
        let fromPubkey = await sourceWallet.publicKeyData
        guard let toPubkey = Data(base58Decoding: toAddress) else {
            throw ShieldError.transactionFailed("Invalid destination address")
        }

        let message = try SolanaTransaction.buildTransfer(
            from: fromPubkey,
            to: toPubkey,
            lamports: lamports,
            recentBlockhash: blockhash
        )

        // 6. Sign with source wallet
        let messageBytes = message.serialize()
        let signature: Data
        do {
            signature = try await sourceWallet.sign(messageBytes)
        } catch {
            throw ShieldError.signingFailed
        }

        // 7. Build and send signed transaction
        let signedTx = try SolanaTransaction.buildSignedTransaction(
            message: message,
            signature: signature
        )

        let txSignature: String
        do {
            txSignature = try await rpcClient.sendTransaction(signedTx)
        } catch let error as FaucetError {
            throw ShieldError.transactionFailed(error.localizedDescription)
        } catch {
            throw ShieldError.transactionFailed(error.localizedDescription)
        }

        // 8. Wait for confirmation
        try await rpcClient.waitForConfirmation(signature: txSignature, timeout: 30)

        print("[SEND-STEALTH] Transaction confirmed: \(txSignature)")
        return txSignature
    }
}
