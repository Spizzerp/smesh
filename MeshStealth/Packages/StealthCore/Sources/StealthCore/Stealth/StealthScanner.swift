import Foundation
import CryptoKit

/// Represents a detected stealth payment addressed to us
public struct DetectedStealthPayment: Identifiable, Codable, Equatable {
    /// Unique identifier
    public let id: UUID

    /// The stealth address that received funds
    public let stealthAddress: String

    /// The stealth public key (32 bytes)
    public let stealthPublicKey: Data

    /// The derived spending private key for this stealth address
    /// Can be used to sign transactions from this address
    public let spendingPrivateKey: Data

    /// The ephemeral public key from the transaction
    public let ephemeralPublicKey: Data

    /// View tag for this payment
    public let viewTag: UInt8

    /// MLKEM768 ciphertext if hybrid mode was used (1088 bytes)
    public let mlkemCiphertext: Data?

    /// When the payment was detected
    public let detectedAt: Date

    /// Whether this payment was detected using hybrid mode
    public var isHybrid: Bool {
        mlkemCiphertext != nil
    }

    public init(
        id: UUID = UUID(),
        stealthAddress: String,
        stealthPublicKey: Data,
        spendingPrivateKey: Data,
        ephemeralPublicKey: Data,
        viewTag: UInt8,
        mlkemCiphertext: Data? = nil,
        detectedAt: Date = Date()
    ) {
        self.id = id
        self.stealthAddress = stealthAddress
        self.stealthPublicKey = stealthPublicKey
        self.spendingPrivateKey = spendingPrivateKey
        self.ephemeralPublicKey = ephemeralPublicKey
        self.viewTag = viewTag
        self.mlkemCiphertext = mlkemCiphertext
        self.detectedAt = detectedAt
    }
}

/// Scans transactions for stealth payments addressed to a keypair.
///
/// The scanner uses the viewing private key to compute shared secrets
/// with ephemeral keys from transactions, then checks if the derived
/// stealth address matches the transaction destination.
public struct StealthScanner {

    /// The keypair to scan for
    private let keyPair: StealthKeyPair

    /// Initialize scanner with a stealth keypair
    /// - Parameter keyPair: The stealth keypair to scan for payments to
    public init(keyPair: StealthKeyPair) {
        self.keyPair = keyPair
    }

    /// Quick filter using view tag (optimization for scanning many transactions)
    ///
    /// Use this as a fast pre-filter before doing the full scan.
    /// If the view tag doesn't match, the transaction is definitely not ours.
    ///
    /// - Parameters:
    ///   - ephemeralPublicKey: The ephemeral key from transaction memo (32 bytes)
    ///   - expectedViewTag: The view tag from transaction
    /// - Returns: true if view tag matches (warrants full check), false if definitely not ours
    /// - Throws: StealthError if computation fails
    public func quickFilter(ephemeralPublicKey: Data, expectedViewTag: UInt8) throws -> Bool {
        // Compute shared secret
        let sharedSecret = try keyPair.computeSharedSecret(ephemeralPubKey: ephemeralPublicKey)

        // Hash and check first byte
        let hashData = Data(SHA256.hash(data: sharedSecret))
        return hashData[0] == expectedViewTag
    }

    /// Check if a transaction is addressed to this keypair and derive spending key
    ///
    /// This performs the full stealth address derivation check:
    /// 1. Computes shared secret: S = v * R
    /// 2. Derives expected stealth pubkey: P' = M + SHA256(S) * G
    /// 3. Checks if P' matches the transaction destination
    /// 4. If match, derives the spending private key: p = m + SHA256(S)
    ///
    /// - Parameters:
    ///   - stealthAddress: The destination address of the transaction (base58)
    ///   - ephemeralPublicKey: The ephemeral key from transaction memo (32 bytes)
    /// - Returns: DetectedStealthPayment if addressed to us, nil otherwise
    /// - Throws: StealthError if cryptographic operations fail
    public func scanTransaction(
        stealthAddress: String,
        ephemeralPublicKey: Data
    ) throws -> DetectedStealthPayment? {
        guard ephemeralPublicKey.count == 32 else {
            throw StealthError.invalidEphemeralKey
        }

        // 1. Compute shared secret: S = X25519(v, R)
        let sharedSecret = try keyPair.computeSharedSecret(ephemeralPubKey: ephemeralPublicKey)

        // 2. Hash shared secret: s_h = SHA256(S)
        let hashData = Data(SHA256.hash(data: sharedSecret))
        let viewTag = hashData[0]

        // 3. Reduce hash to valid scalar (SHA-256 output can be > L)
        guard let reducedHash = SodiumWrapper.scalarReduce32(hashData) else {
            throw StealthError.keyDerivationFailed
        }

        // 4. Compute hash * G using reduced hash
        guard let hashPoint = SodiumWrapper.scalarMultBaseNoclamp(reducedHash) else {
            throw StealthError.keyDerivationFailed
        }

        // 4. Compute expected stealth pubkey: P' = M + hash(S)*G
        guard let expectedPubKey = SodiumWrapper.pointAdd(
            keyPair.spendingPublicKey,
            hashPoint
        ) else {
            throw StealthError.pointAdditionFailed
        }

        // 5. Encode expected address and compare
        let expectedAddress = expectedPubKey.base58EncodedString

        // Not addressed to us
        guard expectedAddress == stealthAddress else {
            return nil
        }

        // 7. Transaction is ours! Derive spending key: p = m + hash(S) (mod L)
        // Use the reduced hash for consistency with hashPoint calculation
        let spendingKey = try keyPair.deriveStealthSpendingKey(sharedSecretHash: reducedHash)

        return DetectedStealthPayment(
            stealthAddress: stealthAddress,
            stealthPublicKey: expectedPubKey,
            spendingPrivateKey: spendingKey,
            ephemeralPublicKey: ephemeralPublicKey,
            viewTag: viewTag,
            mlkemCiphertext: nil
        )
    }

    /// Scan a hybrid transaction (X25519 + MLKEM768)
    ///
    /// This performs the full hybrid stealth address derivation check:
    /// 1. Computes classical shared secret: S_classical = X25519(v, R)
    /// 2. Decapsulates MLKEM768: S_kyber = Decaps(ciphertext, k)
    /// 3. Combined secret: S = SHA256(S_classical || S_kyber)
    /// 4. Derives expected stealth pubkey: P' = M + SHA256(S) * G
    /// 5. Checks if P' matches the transaction destination
    /// 6. If match, derives the spending private key: p = m + SHA256(S)
    ///
    /// - Parameters:
    ///   - stealthAddress: The destination address of the transaction (base58)
    ///   - ephemeralPublicKey: The ephemeral X25519 key from transaction memo (32 bytes)
    ///   - mlkemCiphertext: The MLKEM768 ciphertext from transaction memo (1088 bytes)
    /// - Returns: DetectedStealthPayment if addressed to us, nil otherwise
    /// - Throws: StealthError if cryptographic operations fail
    public func scanHybridTransaction(
        stealthAddress: String,
        ephemeralPublicKey: Data,
        mlkemCiphertext: Data
    ) throws -> DetectedStealthPayment? {
        guard ephemeralPublicKey.count == 32 else {
            throw StealthError.invalidEphemeralKey
        }
        guard mlkemCiphertext.count == MLKEMWrapper.ciphertextBytes else {
            throw StealthError.invalidMLKEMCiphertext
        }
        guard keyPair.hasPostQuantum else {
            throw StealthError.invalidMLKEMPrivateKey
        }

        // 1. Compute hybrid shared secret: S = SHA256(S_classical || S_kyber)
        let combinedSecret = try keyPair.computeHybridSharedSecret(
            ephemeralPubKey: ephemeralPublicKey,
            mlkemCiphertext: mlkemCiphertext
        )

        // 2. Hash combined secret: s_h = SHA256(S)
        let hashData = Data(SHA256.hash(data: combinedSecret))
        let viewTag = hashData[0]

        // 3. Reduce hash to valid scalar (SHA-256 output can be > L)
        guard let reducedHash = SodiumWrapper.scalarReduce32(hashData) else {
            throw StealthError.keyDerivationFailed
        }

        // 4. Compute hash * G using reduced hash
        guard let hashPoint = SodiumWrapper.scalarMultBaseNoclamp(reducedHash) else {
            throw StealthError.keyDerivationFailed
        }

        // 5. Compute expected stealth pubkey: P' = M + hash(S)*G
        guard let expectedPubKey = SodiumWrapper.pointAdd(
            keyPair.spendingPublicKey,
            hashPoint
        ) else {
            throw StealthError.pointAdditionFailed
        }

        // 6. Encode expected address and compare
        let expectedAddress = expectedPubKey.base58EncodedString

        // Not addressed to us
        guard expectedAddress == stealthAddress else {
            return nil
        }

        // 7. Transaction is ours! Derive spending key: p = m + hash(S) (mod L)
        let spendingKey = try keyPair.deriveStealthSpendingKey(sharedSecretHash: reducedHash)

        return DetectedStealthPayment(
            stealthAddress: stealthAddress,
            stealthPublicKey: expectedPubKey,
            spendingPrivateKey: spendingKey,
            ephemeralPublicKey: ephemeralPublicKey,
            viewTag: viewTag,
            mlkemCiphertext: mlkemCiphertext
        )
    }

    /// Scan a transaction with automatic mode detection
    /// Uses hybrid mode if ciphertext is provided and keypair has PQ keys
    /// - Parameters:
    ///   - stealthAddress: The destination address (base58)
    ///   - ephemeralPublicKey: The ephemeral X25519 key (32 bytes)
    ///   - mlkemCiphertext: Optional MLKEM768 ciphertext (1088 bytes)
    /// - Returns: DetectedStealthPayment if addressed to us, nil otherwise
    public func scanTransactionAuto(
        stealthAddress: String,
        ephemeralPublicKey: Data,
        mlkemCiphertext: Data? = nil
    ) throws -> DetectedStealthPayment? {
        if let ciphertext = mlkemCiphertext, keyPair.hasPostQuantum {
            return try scanHybridTransaction(
                stealthAddress: stealthAddress,
                ephemeralPublicKey: ephemeralPublicKey,
                mlkemCiphertext: ciphertext
            )
        } else {
            return try scanTransaction(
                stealthAddress: stealthAddress,
                ephemeralPublicKey: ephemeralPublicKey
            )
        }
    }

    /// Parse memo data and scan automatically
    /// Memo format: R (32 bytes) for classical, R (32) || ciphertext (1088) for hybrid
    /// - Parameters:
    ///   - stealthAddress: The destination address (base58)
    ///   - memoData: The raw memo data containing ephemeral key and optionally ciphertext
    /// - Returns: DetectedStealthPayment if addressed to us, nil otherwise
    public func scanFromMemo(
        stealthAddress: String,
        memoData: Data
    ) throws -> DetectedStealthPayment? {
        let classicalSize = 32
        let hybridSize = 32 + MLKEMWrapper.ciphertextBytes  // 32 + 1088 = 1120

        switch memoData.count {
        case classicalSize:
            return try scanTransaction(
                stealthAddress: stealthAddress,
                ephemeralPublicKey: memoData
            )

        case hybridSize:
            let ephemeralKey = memoData.prefix(32)
            let ciphertext = memoData.suffix(MLKEMWrapper.ciphertextBytes)
            return try scanTransactionAuto(
                stealthAddress: stealthAddress,
                ephemeralPublicKey: Data(ephemeralKey),
                mlkemCiphertext: Data(ciphertext)
            )

        default:
            throw StealthError.invalidEphemeralKey
        }
    }

    /// Scan a transaction using raw bytes for the stealth public key
    /// - Parameters:
    ///   - stealthPublicKey: The destination public key (32 bytes)
    ///   - ephemeralPublicKey: The ephemeral key from memo (32 bytes)
    /// - Returns: DetectedStealthPayment if addressed to us, nil otherwise
    public func scanTransactionByPubKey(
        stealthPublicKey: Data,
        ephemeralPublicKey: Data
    ) throws -> DetectedStealthPayment? {
        guard stealthPublicKey.count == 32 else {
            throw StealthError.invalidStealthAddress
        }

        let stealthAddress = stealthPublicKey.base58EncodedString

        return try scanTransaction(
            stealthAddress: stealthAddress,
            ephemeralPublicKey: ephemeralPublicKey
        )
    }

    /// Batch scan multiple transactions
    /// - Parameter transactions: Array of (stealthAddress, ephemeralPublicKey) tuples
    /// - Returns: Array of detected payments (may be empty)
    public func scanTransactions(
        _ transactions: [(stealthAddress: String, ephemeralPublicKey: Data)]
    ) throws -> [DetectedStealthPayment] {
        var detected: [DetectedStealthPayment] = []

        for tx in transactions {
            if let payment = try scanTransaction(
                stealthAddress: tx.stealthAddress,
                ephemeralPublicKey: tx.ephemeralPublicKey
            ) {
                detected.append(payment)
            }
        }

        return detected
    }

    /// Batch scan with optional view tag pre-filtering
    /// - Parameters:
    ///   - transactions: Array of (stealthAddress, ephemeralPublicKey, viewTag) tuples
    ///   - useViewTagFilter: If true, skip full scan when view tag doesn't match
    /// - Returns: Array of detected payments
    public func scanTransactionsWithViewTags(
        _ transactions: [(stealthAddress: String, ephemeralPublicKey: Data, viewTag: UInt8)],
        useViewTagFilter: Bool = true
    ) throws -> [DetectedStealthPayment] {
        var detected: [DetectedStealthPayment] = []

        for tx in transactions {
            // Quick filter with view tag
            if useViewTagFilter {
                let tagMatches = try quickFilter(
                    ephemeralPublicKey: tx.ephemeralPublicKey,
                    expectedViewTag: tx.viewTag
                )
                if !tagMatches {
                    continue // Definitely not ours
                }
            }

            // Full scan
            if let payment = try scanTransaction(
                stealthAddress: tx.stealthAddress,
                ephemeralPublicKey: tx.ephemeralPublicKey
            ) {
                detected.append(payment)
            }
        }

        return detected
    }
}
