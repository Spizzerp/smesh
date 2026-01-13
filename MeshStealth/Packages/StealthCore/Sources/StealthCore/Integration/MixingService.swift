import Foundation

/// Configuration for mixing behavior
public struct MixingConfiguration: Sendable {
    /// Minimum hops per payment
    public let minHops: Int
    /// Maximum hops per payment
    public let maxHops: Int
    /// Minimum delay between hops (seconds)
    public let minDelaySeconds: Int
    /// Maximum delay between hops (seconds)
    public let maxDelaySeconds: Int

    public init(
        minHops: Int = 1,
        maxHops: Int = 3,
        minDelaySeconds: Int = 30,
        maxDelaySeconds: Int = 120
    ) {
        self.minHops = minHops
        self.maxHops = maxHops
        self.minDelaySeconds = minDelaySeconds
        self.maxDelaySeconds = maxDelaySeconds
    }

    public static let `default` = MixingConfiguration(
        minHops: 1, maxHops: 3, minDelaySeconds: 30, maxDelaySeconds: 120
    )

    public static let aggressive = MixingConfiguration(
        minHops: 2, maxHops: 5, minDelaySeconds: 10, maxDelaySeconds: 60
    )

    public static let quick = MixingConfiguration(
        minHops: 1, maxHops: 2, minDelaySeconds: 2, maxDelaySeconds: 5
    )
}

/// Result of a mix operation
public struct MixResult: Sendable {
    /// Number of payments that were processed
    public let totalPaymentsMixed: Int
    /// Total number of hops performed across all payments
    public let totalHopsPerformed: Int
    /// Individual hop results
    public let hopResults: [HopResult]
    /// Errors encountered (mixing continues on error)
    public let errors: [String]

    public init(
        totalPaymentsMixed: Int,
        totalHopsPerformed: Int,
        hopResults: [HopResult],
        errors: [String]
    ) {
        self.totalPaymentsMixed = totalPaymentsMixed
        self.totalHopsPerformed = totalHopsPerformed
        self.hopResults = hopResults
        self.errors = errors
    }

    /// Whether mixing completed without errors
    public var isSuccess: Bool {
        errors.isEmpty
    }
}

/// Errors specific to mixing operations
public enum MixingError: Error, LocalizedError {
    case alreadyMixing
    case paymentNotFound
    case insufficientBalance
    case noPaymentsToMix
    case walletNotInitialized

    public var errorDescription: String? {
        switch self {
        case .alreadyMixing:
            return "Mixing already in progress"
        case .paymentNotFound:
            return "Payment not found after hop"
        case .insufficientBalance:
            return "Insufficient balance for mixing (need to cover fees)"
        case .noPaymentsToMix:
            return "No eligible payments to mix"
        case .walletNotInitialized:
            return "Wallet not initialized"
        }
    }
}

/// Service for mixing stealth payments via time-delayed random hops
/// Improves privacy by breaking correlation between stealth addresses
@MainActor
public class MixingService: ObservableObject {

    // MARK: - Published State

    /// Whether mixing is currently in progress
    @Published public private(set) var isMixing: Bool = false

    /// Progress of current mix operation (0.0 - 1.0)
    @Published public private(set) var mixProgress: Double = 0.0

    /// Status message for current operation
    @Published public private(set) var statusMessage: String = ""

    // MARK: - Private

    private let walletManager: StealthWalletManager
    private let config: MixingConfiguration

    /// Minimum balance required to hop (must cover transaction fee)
    private let minBalanceForHop: UInt64 = 6_000  // ~0.000006 SOL

    // MARK: - Initialization

    public init(
        walletManager: StealthWalletManager,
        config: MixingConfiguration = .default
    ) {
        self.walletManager = walletManager
        self.config = config
    }

    // MARK: - Mix All Payments

    /// Mix all eligible pending payments with random hops
    /// Each payment gets a random number of hops (minHops...maxHops)
    /// with random delays between hops
    public func mixAll() async -> MixResult {
        guard !isMixing else {
            return MixResult(
                totalPaymentsMixed: 0,
                totalHopsPerformed: 0,
                hopResults: [],
                errors: [MixingError.alreadyMixing.localizedDescription]
            )
        }

        isMixing = true
        mixProgress = 0.0
        statusMessage = "Starting mix..."
        defer {
            isMixing = false
            mixProgress = 1.0
            statusMessage = ""
        }

        // Get eligible payments (received, has enough balance for fees)
        let payments = walletManager.pendingPayments.filter {
            $0.status == .received && $0.amount > minBalanceForHop
        }

        guard !payments.isEmpty else {
            return MixResult(
                totalPaymentsMixed: 0,
                totalHopsPerformed: 0,
                hopResults: [],
                errors: [MixingError.noPaymentsToMix.localizedDescription]
            )
        }

        var allHopResults: [HopResult] = []
        var errors: [String] = []
        let totalPayments = payments.count

        for (index, payment) in payments.enumerated() {
            // Update progress
            mixProgress = Double(index) / Double(totalPayments)
            statusMessage = "Mixing payment \(index + 1) of \(totalPayments)..."

            // Determine random number of hops for this payment
            let hopsForThisPayment = Int.random(in: config.minHops...config.maxHops)
            var currentPayment = payment

            for hopIndex in 0..<hopsForThisPayment {
                // Random delay between hops (except first hop)
                if hopIndex > 0 {
                    let delaySeconds = Int.random(in: config.minDelaySeconds...config.maxDelaySeconds)
                    statusMessage = "Waiting \(delaySeconds)s before hop \(hopIndex + 1)..."
                    try? await Task.sleep(nanoseconds: UInt64(delaySeconds) * 1_000_000_000)
                }

                statusMessage = "Hop \(hopIndex + 1) of \(hopsForThisPayment) for payment \(index + 1)..."

                do {
                    let result = try await walletManager.hop(payment: currentPayment)
                    allHopResults.append(result)

                    // Find the new payment created by this hop
                    if let newPayment = walletManager.pendingPayments.first(where: {
                        $0.stealthAddress == result.destinationStealthAddress
                    }) {
                        currentPayment = newPayment
                    } else {
                        // Payment not found - this shouldn't happen but handle gracefully
                        errors.append("Payment not found after hop \(hopIndex + 1)")
                        break
                    }
                } catch {
                    errors.append("Hop failed for payment \(payment.id.uuidString.prefix(8)): \(error.localizedDescription)")
                    break  // Stop hopping this payment on error
                }
            }
        }

        return MixResult(
            totalPaymentsMixed: totalPayments,
            totalHopsPerformed: allHopResults.count,
            hopResults: allHopResults,
            errors: errors
        )
    }

    // MARK: - Mix Before Unshield

    /// Mix a single payment before unshielding (1-5 random hops)
    /// Used automatically when unshielding to add privacy
    /// - Parameter payment: The payment to mix before unshield
    /// - Returns: The final payment after mixing (to use for unshield)
    public func mixBeforeUnshield(payment: PendingPayment, parentActivityId: UUID? = nil) async throws -> PendingPayment {
        print("[MIX] ======== mixBeforeUnshield starting ========")
        print("[MIX] Payment ID: \(payment.id)")
        print("[MIX] Initial stealth address: \(payment.stealthAddress)")
        print("[MIX] Initial amount: \(payment.amount) lamports")
        print("[MIX] Initial ephemeral key: \(payment.ephemeralPublicKey.base58EncodedString)")
        print("[MIX] Is hybrid: \(payment.isHybrid)")
        print("[MIX] Parent activity ID: \(parentActivityId?.uuidString ?? "none")")

        guard payment.amount > minBalanceForHop else {
            print("[MIX] ERROR: Insufficient balance (\(payment.amount) <= \(minBalanceForHop))")
            throw MixingError.insufficientBalance
        }

        // 1-5 random hops before unshield for privacy
        let hops = Int.random(in: 1...5)
        var currentPayment = payment

        print("[MIX] Will perform \(hops) hop(s)")

        for hopIndex in 0..<hops {
            print("[MIX] -------- Hop \(hopIndex + 1) of \(hops) --------")
            print("[MIX] Current payment ID: \(currentPayment.id)")
            print("[MIX] Current stealth address: \(currentPayment.stealthAddress)")
            print("[MIX] Current ephemeral key: \(currentPayment.ephemeralPublicKey.base58EncodedString)")

            // Brief delay between hops (2-5 seconds)
            if hopIndex > 0 {
                let delaySeconds = Int.random(in: 2...5)
                print("[MIX] Waiting \(delaySeconds) seconds before hop...")
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds) * 1_000_000_000)
            }

            let result = try await walletManager.hop(payment: currentPayment, parentActivityId: parentActivityId)
            print("[MIX] Hop completed successfully!")
            print("[MIX] Result destination address: \(result.destinationStealthAddress)")
            print("[MIX] Result ephemeral key: \(result.ephemeralPublicKey.base58EncodedString)")
            print("[MIX] Result amount: \(result.amount) lamports")
            print("[MIX] Transaction signature: \(result.signature)")

            // Wait for state to update (increased from 0.5s to 2s)
            print("[MIX] Waiting 2 seconds for state to propagate...")
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds

            // Find the new payment
            print("[MIX] Searching for new payment in pending list...")
            print("[MIX] Looking for address: \(result.destinationStealthAddress)")
            print("[MIX] Current pending payments:")
            for (idx, p) in walletManager.pendingPayments.enumerated() {
                print("[MIX]   [\(idx)] \(p.id): \(p.stealthAddress) (hop: \(p.hopCount))")
            }

            guard let newPayment = walletManager.pendingPayments.first(where: {
                $0.stealthAddress == result.destinationStealthAddress
            }) else {
                print("[MIX] ERROR: Could not find new payment with address \(result.destinationStealthAddress)")
                throw MixingError.paymentNotFound
            }

            print("[MIX] Found new payment: \(newPayment.id)")
            print("[MIX] New payment address: \(newPayment.stealthAddress)")
            print("[MIX] New payment ephemeral: \(newPayment.ephemeralPublicKey.base58EncodedString)")
            print("[MIX] Addresses match: \(newPayment.stealthAddress == result.destinationStealthAddress)")
            print("[MIX] Ephemeral keys match: \(newPayment.ephemeralPublicKey == result.ephemeralPublicKey)")

            currentPayment = newPayment
        }

        print("[MIX] ======== mixBeforeUnshield complete ========")
        print("[MIX] Final payment ID: \(currentPayment.id)")
        print("[MIX] Final stealth address: \(currentPayment.stealthAddress)")
        print("[MIX] Final ephemeral key: \(currentPayment.ephemeralPublicKey.base58EncodedString)")
        print("[MIX] Final hop count: \(currentPayment.hopCount)")
        return currentPayment
    }

    // MARK: - Unshield With Mix

    /// Unshield all payments with automatic pre-mix for privacy
    /// Each payment gets 1-2 hops before being sent to main wallet
    public func unshieldAllWithMix() async -> [UnshieldResult] {
        print("[UNSHIELD-MIX] ======== Starting unshieldAllWithMix ========")

        guard !isMixing else {
            print("[UNSHIELD-MIX] Already mixing, returning empty")
            return []
        }

        isMixing = true
        statusMessage = "Preparing to unshield with mixing..."
        defer {
            isMixing = false
            statusMessage = ""
        }

        let payments = walletManager.pendingPayments.filter {
            $0.status == .received && $0.amount > minBalanceForHop
        }

        print("[UNSHIELD-MIX] Found \(payments.count) eligible payments")
        for (idx, p) in payments.enumerated() {
            print("[UNSHIELD-MIX]   [\(idx)] \(p.id): \(p.stealthAddress) - \(p.amount) lamports")
        }

        var results: [UnshieldResult] = []
        let totalPayments = payments.count

        for (index, payment) in payments.enumerated() {
            print("[UNSHIELD-MIX] -------- Processing payment \(index + 1) of \(totalPayments) --------")
            print("[UNSHIELD-MIX] Payment ID: \(payment.id)")
            print("[UNSHIELD-MIX] Stealth address: \(payment.stealthAddress)")

            mixProgress = Double(index) / Double(totalPayments)
            statusMessage = "Mixing & unshielding payment \(index + 1) of \(totalPayments)..."

            // Create unshield activity BEFORE mixing so hops can link to it
            let unshieldActivityId = walletManager.recordUnshieldActivity(
                amount: payment.amount,
                stealthAddress: payment.stealthAddress,
                signature: "pending"  // Will be updated after unshield completes
            )

            do {
                // Mix first (1-5 quick hops) - pass the unshield activity ID
                print("[UNSHIELD-MIX] Starting mix phase...")
                let mixedPayment = try await mixBeforeUnshield(payment: payment, parentActivityId: unshieldActivityId)

                print("[UNSHIELD-MIX] Mix complete. Now unshielding...")
                print("[UNSHIELD-MIX] Mixed payment ID: \(mixedPayment.id)")
                print("[UNSHIELD-MIX] Mixed payment address: \(mixedPayment.stealthAddress)")
                print("[UNSHIELD-MIX] Mixed payment ephemeral: \(mixedPayment.ephemeralPublicKey.base58EncodedString)")

                // Then unshield to main wallet (don't record activity again, just update)
                let result = try await walletManager.unshield(payment: mixedPayment, skipActivityRecord: true)
                print("[UNSHIELD-MIX] Unshield successful! Signature: \(result.signature)")

                // Update the activity with the real signature
                walletManager.updateActivityStatus(id: unshieldActivityId, status: .completed, signature: result.signature)

                results.append(result)
            } catch {
                // Log error but continue with other payments
                print("[UNSHIELD-MIX] ERROR: Failed to mix+unshield payment \(payment.id): \(error)")
                print("[UNSHIELD-MIX] Error details: \(error.localizedDescription)")
                // Mark activity as failed
                walletManager.updateActivityStatus(id: unshieldActivityId, status: .failed, error: error.localizedDescription)
            }
        }

        print("[UNSHIELD-MIX] ======== unshieldAllWithMix complete ========")
        print("[UNSHIELD-MIX] Successfully unshielded \(results.count) of \(totalPayments) payments")
        mixProgress = 1.0
        return results
    }

    // MARK: - Status

    /// Number of payments eligible for mixing
    public var eligiblePaymentCount: Int {
        walletManager.pendingPayments.filter {
            $0.status == .received && $0.amount > minBalanceForHop
        }.count
    }

    /// Whether there are payments that can be mixed
    public var canMix: Bool {
        eligiblePaymentCount > 0 && !isMixing
    }
}
