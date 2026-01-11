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

/// Errors from shield operations
public enum ShieldError: Error, LocalizedError {
    case notInitialized
    case insufficientBalance(available: UInt64, required: UInt64)
    case stealthAddressGenerationFailed
    case transactionFailed(String)
    case signingFailed

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
}
