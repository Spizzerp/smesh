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

    /// Mix a single payment before unshielding using split/hop/recombine for proper privacy
    /// 1. Split into 2-4 random parts with varying amounts
    /// 2. Each split hops 1-3 times independently
    /// 3. Recombine all parts into a single final address
    /// - Parameters:
    ///   - payment: The payment to mix before unshield
    ///   - parentActivityId: Optional parent activity ID for activity grouping
    /// - Returns: The final payment after mixing (to use for unshield)
    public func mixBeforeUnshield(payment: PendingPayment, parentActivityId: UUID? = nil) async throws -> PendingPayment {
        print("[MIX] ======== mixBeforeUnshield starting (split/hop/recombine) ========")
        print("[MIX] Payment ID: \(payment.id)")
        print("[MIX] Initial stealth address: \(payment.stealthAddress)")
        print("[MIX] Initial amount: \(payment.amount) lamports")
        print("[MIX] Parent activity ID: \(parentActivityId?.uuidString ?? "none")")

        // Minimum amount needed for proper mixing:
        // At least 2 splits with min amount + fees for split, hops, and recombine
        let minForProperMix: UInt64 = 10_000_000  // 0.01 SOL minimum for proper mixing

        // If amount is too small for proper mixing, fall back to simple hops
        if payment.amount < minForProperMix {
            print("[MIX] Amount too small for split mixing, using simple hops")
            return try await simpleHopMix(payment: payment, parentActivityId: parentActivityId)
        }

        // Phase 1: SPLIT into 2-4 random parts
        print("[MIX] ======== Phase 1: SPLIT ========")
        statusMessage = "Splitting payment..."

        let numParts = Int.random(in: 2...4)
        print("[MIX] Splitting into \(numParts) parts")

        var splitPayments: [PendingPayment]
        do {
            splitPayments = try await walletManager.splitPayment(
                payment: payment,
                parts: numParts,
                parentActivityId: parentActivityId
            )
            print("[MIX] Split complete: \(splitPayments.count) parts created")
            for (idx, p) in splitPayments.enumerated() {
                print("[MIX]   Part \(idx + 1): \(p.amount) lamports at \(p.stealthAddress.prefix(12))...")
            }
        } catch {
            print("[MIX] Split failed: \(error), falling back to simple hops")
            return try await simpleHopMix(payment: payment, parentActivityId: parentActivityId)
        }

        // Brief pause after split
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        // Phase 2: HOP each split independently (1-3 hops each)
        print("[MIX] ======== Phase 2: HOP each split ========")
        statusMessage = "Hopping splits..."

        var hoppedPayments: [PendingPayment] = []

        for (idx, splitPayment) in splitPayments.enumerated() {
            print("[MIX] Processing split \(idx + 1) of \(splitPayments.count)")

            let hopsForThisSplit = Int.random(in: 1...3)
            var currentPayment = splitPayment

            for hopIdx in 0..<hopsForThisSplit {
                print("[MIX]   Hop \(hopIdx + 1) of \(hopsForThisSplit) for split \(idx + 1)")
                statusMessage = "Hopping split \(idx + 1)/\(splitPayments.count), hop \(hopIdx + 1)/\(hopsForThisSplit)..."

                // Brief delay between hops
                if hopIdx > 0 {
                    let delay = Int.random(in: 1...3)
                    try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
                }

                do {
                    let result = try await walletManager.hop(payment: currentPayment, parentActivityId: parentActivityId)

                    // Wait for state propagation
                    try? await Task.sleep(nanoseconds: 1_500_000_000)

                    // Find the new payment
                    guard let newPayment = walletManager.pendingPayments.first(where: {
                        $0.stealthAddress == result.destinationStealthAddress
                    }) else {
                        print("[MIX]   WARNING: Could not find hopped payment, using current")
                        break
                    }

                    currentPayment = newPayment
                    print("[MIX]   Hop complete: now at \(currentPayment.stealthAddress.prefix(12))...")
                } catch {
                    print("[MIX]   Hop \(hopIdx + 1) failed: \(error), stopping hops for this split")
                    break
                }
            }

            hoppedPayments.append(currentPayment)
            print("[MIX] Split \(idx + 1) finished with \(currentPayment.hopCount) total hops")

            // Brief pause between processing splits
            if idx < splitPayments.count - 1 {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }

        print("[MIX] All splits hopped. Total hopped payments: \(hoppedPayments.count)")

        // Phase 3: RECOMBINE all splits into a single address
        print("[MIX] ======== Phase 3: RECOMBINE ========")
        statusMessage = "Recombining splits..."

        let finalPayment: PendingPayment
        do {
            finalPayment = try await walletManager.recombinePayments(
                hoppedPayments,
                parentActivityId: parentActivityId
            )
            print("[MIX] Recombine complete!")
            print("[MIX] Final address: \(finalPayment.stealthAddress)")
            print("[MIX] Final amount: \(finalPayment.amount) lamports")
        } catch {
            print("[MIX] Recombine failed: \(error)")
            // If recombine fails, return the first hopped payment (partial success)
            if let firstHopped = hoppedPayments.first {
                print("[MIX] Returning first hopped payment as fallback")
                return firstHopped
            }
            throw error
        }

        print("[MIX] ======== mixBeforeUnshield complete (split/hop/recombine) ========")
        print("[MIX] Original amount: \(payment.amount) lamports")
        print("[MIX] Final amount: \(finalPayment.amount) lamports")
        print("[MIX] Fee overhead: \(payment.amount - finalPayment.amount) lamports")

        return finalPayment
    }

    /// Simple hop-based mixing for small amounts (fallback when split isn't viable)
    private func simpleHopMix(payment: PendingPayment, parentActivityId: UUID? = nil) async throws -> PendingPayment {
        print("[MIX] Using simple hop mixing")

        guard payment.amount > minBalanceForHop else {
            print("[MIX] ERROR: Insufficient balance for any mixing")
            throw MixingError.insufficientBalance
        }

        let hops = Int.random(in: 1...3)
        var currentPayment = payment

        for hopIndex in 0..<hops {
            if hopIndex > 0 {
                let delay = Int.random(in: 2...4)
                try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            }

            let result = try await walletManager.hop(payment: currentPayment, parentActivityId: parentActivityId)
            try? await Task.sleep(nanoseconds: 1_500_000_000)

            guard let newPayment = walletManager.pendingPayments.first(where: {
                $0.stealthAddress == result.destinationStealthAddress
            }) else {
                throw MixingError.paymentNotFound
            }

            currentPayment = newPayment
        }

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

        guard !payments.isEmpty else {
            print("[UNSHIELD-MIX] No eligible payments")
            return []
        }

        // Calculate total amount for the parent activity
        let totalAmount = payments.reduce(0) { $0 + $1.amount }

        // Create ONE parent unshield activity for the entire operation
        let parentActivityId = walletManager.recordUnshieldActivity(
            amount: totalAmount,
            stealthAddress: payments.first?.stealthAddress ?? "",
            signature: "pending"
        )
        print("[UNSHIELD-MIX] Created parent activity: \(parentActivityId)")

        var results: [UnshieldResult] = []
        let totalPayments = payments.count

        for (index, payment) in payments.enumerated() {
            print("[UNSHIELD-MIX] -------- Processing payment \(index + 1) of \(totalPayments) --------")
            print("[UNSHIELD-MIX] Payment ID: \(payment.id)")
            print("[UNSHIELD-MIX] Stealth address: \(payment.stealthAddress)")

            mixProgress = Double(index) / Double(totalPayments)
            statusMessage = "Mixing & unshielding payment \(index + 1) of \(totalPayments)..."

            do {
                // Mix first (1-5 quick hops) - pass the parent activity ID so hops link to it
                print("[UNSHIELD-MIX] Starting mix phase...")
                let mixedPayment = try await mixBeforeUnshield(payment: payment, parentActivityId: parentActivityId)

                print("[UNSHIELD-MIX] Mix complete. Now unshielding...")
                print("[UNSHIELD-MIX] Mixed payment ID: \(mixedPayment.id)")
                print("[UNSHIELD-MIX] Mixed payment address: \(mixedPayment.stealthAddress)")
                print("[UNSHIELD-MIX] Mixed payment ephemeral: \(mixedPayment.ephemeralPublicKey.base58EncodedString)")

                // Then unshield to main wallet (skip recording, we have the parent)
                let result = try await walletManager.unshield(payment: mixedPayment, skipActivityRecord: true)
                print("[UNSHIELD-MIX] Unshield successful! Signature: \(result.signature)")

                results.append(result)
            } catch {
                // Log error but continue with other payments
                print("[UNSHIELD-MIX] ERROR: Failed to mix+unshield payment \(payment.id): \(error)")
                print("[UNSHIELD-MIX] Error details: \(error.localizedDescription)")
            }
        }

        // Update the parent activity with final status
        let finalAmount = results.reduce(0) { $0 + $1.amount }
        let finalSignature = results.last?.signature ?? "failed"
        if results.isEmpty {
            walletManager.updateActivityStatus(id: parentActivityId, status: .failed, error: "All unshields failed")
        } else {
            walletManager.updateActivityStatus(id: parentActivityId, status: .completed, signature: finalSignature)
            // Update the amount to reflect actual unshielded amount
            walletManager.updateActivityAmount(id: parentActivityId, amount: finalAmount)
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
