import XCTest
@testable import StealthCore

/// Tests for DurableNonceManager
final class DurableNonceManagerTests: XCTestCase {

    // MARK: - Pool Management Tests

    func testInitialPoolIsEmpty() async {
        // Create manager with isolated storage
        let userDefaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let manager = DurableNonceManager(
            rpcClient: DevnetFaucet(),
            userDefaults: userDefaults,
            targetPoolSize: 3
        )

        let status = await manager.poolStatus
        XCTAssertEqual(status.total, 0, "Initial pool should be empty")
        XCTAssertEqual(status.available, 0)
        XCTAssertEqual(status.reserved, 0)
        XCTAssertEqual(status.consumed, 0)
    }

    func testHasAvailableNonceWhenEmpty() async {
        let userDefaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let manager = DurableNonceManager(
            rpcClient: DevnetFaucet(),
            userDefaults: userDefaults
        )

        let hasNonce = await manager.hasAvailableNonce
        XCTAssertFalse(hasNonce, "Empty pool should not have available nonces")
    }

    func testReserveNonceThrowsWhenPoolEmpty() async {
        let userDefaults = UserDefaults(suiteName: "test.\(UUID().uuidString)")!
        let manager = DurableNonceManager(
            rpcClient: DevnetFaucet(),
            userDefaults: userDefaults
        )

        do {
            _ = try await manager.reserveNonce()
            XCTFail("Expected poolEmpty error")
        } catch NonceError.poolEmpty {
            // Expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Nonce Entry Tests

    func testNonceEntryCreation() {
        let entry = NonceEntry(
            address: "DemoNonce111111111111111111111111111111111",
            nonceValue: "GfVcyD4kkTrj5t7Q5xPe2JvmJAo9Xs5KXLZ7wQx5Z4Te",
            authority: "5YNmS1R9nNSCDzb5a7mMJ1dwK9uHeAAF4CmPEwKgVWr8"
        )

        XCTAssertEqual(entry.state, .available)
        XCTAssertNil(entry.reservedAt)
        XCTAssertEqual(entry.id, entry.address)
    }

    func testNonceStateTransitions() {
        var entry = NonceEntry(
            address: "DemoNonce111111111111111111111111111111111",
            nonceValue: "GfVcyD4kkTrj5t7Q5xPe2JvmJAo9Xs5KXLZ7wQx5Z4Te",
            authority: "5YNmS1R9nNSCDzb5a7mMJ1dwK9uHeAAF4CmPEwKgVWr8"
        )

        XCTAssertEqual(entry.state, .available)

        entry.state = .reserved
        entry.reservedAt = Date()
        XCTAssertEqual(entry.state, .reserved)
        XCTAssertNotNil(entry.reservedAt)

        entry.state = .consumed
        entry.reservedAt = nil
        XCTAssertEqual(entry.state, .consumed)
        XCTAssertNil(entry.reservedAt)
    }

    // MARK: - Durable Nonce Transfer Tests

    func testBuildDurableNonceTransfer() throws {
        let senderPubkey = Data(repeating: 1, count: 32)
        let recipientPubkey = Data(repeating: 2, count: 32)
        let nonceAccountPubkey = Data(repeating: 3, count: 32)
        let nonceValue = "GfVcyD4kkTrj5t7Q5xPe2JvmJAo9Xs5KXLZ7wQx5Z4Te"

        let message = try SolanaTransaction.buildDurableNonceTransfer(
            from: senderPubkey,
            to: recipientPubkey,
            lamports: 1_000_000,
            nonceAccount: nonceAccountPubkey,
            nonceAuthority: senderPubkey,
            nonceValue: nonceValue
        )

        // Verify message structure
        XCTAssertEqual(message.header.numRequiredSignatures, 1)
        XCTAssertEqual(message.header.numReadonlySignedAccounts, 0)
        XCTAssertEqual(message.header.numReadonlyUnsignedAccounts, 2)

        // Verify account keys
        XCTAssertEqual(message.accountKeys.count, 5)
        XCTAssertEqual(message.accountKeys[0], senderPubkey)
        XCTAssertEqual(message.accountKeys[1], nonceAccountPubkey)
        XCTAssertEqual(message.accountKeys[2], recipientPubkey)

        // Verify instructions (2: AdvanceNonce + Transfer)
        XCTAssertEqual(message.instructions.count, 2)

        // First instruction should be AdvanceNonceAccount
        let advanceInstruction = message.instructions[0]
        XCTAssertEqual(advanceInstruction.programIdIndex, 3)  // System Program

        // Second instruction should be Transfer
        let transferInstruction = message.instructions[1]
        XCTAssertEqual(transferInstruction.programIdIndex, 3)  // System Program
    }

    func testBuildDurableNonceTransferInvalidKeys() {
        let invalidPubkey = Data(repeating: 1, count: 16)  // Too short
        let validPubkey = Data(repeating: 2, count: 32)

        XCTAssertThrowsError(try SolanaTransaction.buildDurableNonceTransfer(
            from: invalidPubkey,
            to: validPubkey,
            lamports: 1000,
            nonceAccount: validPubkey,
            nonceAuthority: validPubkey,
            nonceValue: "GfVcyD4kkTrj5t7Q5xPe2JvmJAo9Xs5KXLZ7wQx5Z4Te"
        )) { error in
            guard case TransactionError.invalidPublicKey = error else {
                XCTFail("Expected invalidPublicKey error")
                return
            }
        }
    }

    // MARK: - Mesh Payload v2 Tests

    func testMeshStealthPayloadV1() {
        let payload = MeshStealthPayload(
            stealthAddress: "5YNmS1R9nNSCDzb5a7mMJ1dwK9uHeAAF4CmPEwKgVWr8",
            ephemeralPublicKey: Data(repeating: 1, count: 32),
            amount: 1_000_000,
            viewTag: 42
        )

        XCTAssertEqual(payload.protocolVersion, .v1)
        XCTAssertNil(payload.preSignedTransaction)
        XCTAssertNil(payload.nonceAccountAddress)
        XCTAssertFalse(payload.supportsReceiverSettlement)
    }

    func testMeshStealthPayloadV2() {
        let payload = MeshStealthPayload(
            stealthAddress: "5YNmS1R9nNSCDzb5a7mMJ1dwK9uHeAAF4CmPEwKgVWr8",
            ephemeralPublicKey: Data(repeating: 1, count: 32),
            amount: 1_000_000,
            viewTag: 42,
            protocolVersion: .v2,
            preSignedTransaction: "base64encodedtransaction==",
            nonceAccountAddress: "NonceAccount111111111111111111111111111111"
        )

        XCTAssertEqual(payload.protocolVersion, .v2)
        XCTAssertNotNil(payload.preSignedTransaction)
        XCTAssertNotNil(payload.nonceAccountAddress)
        XCTAssertTrue(payload.supportsReceiverSettlement)
    }

    func testMeshStealthPayloadV2WithoutPreSignedTx() {
        let payload = MeshStealthPayload(
            stealthAddress: "5YNmS1R9nNSCDzb5a7mMJ1dwK9uHeAAF4CmPEwKgVWr8",
            ephemeralPublicKey: Data(repeating: 1, count: 32),
            amount: 1_000_000,
            viewTag: 42,
            protocolVersion: .v2,
            preSignedTransaction: nil
        )

        XCTAssertEqual(payload.protocolVersion, .v2)
        XCTAssertFalse(payload.supportsReceiverSettlement, "V2 without pre-signed tx should not support receiver settlement")
    }

    // MARK: - Pending Payment Tests

    func testPendingPaymentFromV2Payload() {
        let payload = MeshStealthPayload(
            stealthAddress: "5YNmS1R9nNSCDzb5a7mMJ1dwK9uHeAAF4CmPEwKgVWr8",
            ephemeralPublicKey: Data(repeating: 1, count: 32),
            amount: 1_000_000,
            viewTag: 42,
            protocolVersion: .v2,
            preSignedTransaction: "base64encodedtransaction==",
            nonceAccountAddress: "NonceAccount111111111111111111111111111111"
        )

        let payment = PendingPayment(from: payload)

        XCTAssertEqual(payment.preSignedTransaction, "base64encodedtransaction==")
        XCTAssertEqual(payment.nonceAccountAddress, "NonceAccount111111111111111111111111111111")
        XCTAssertTrue(payment.supportsReceiverSettlement)
        XCTAssertNil(payment.settledBy)
    }

    func testPendingPaymentFromV1Payload() {
        let payload = MeshStealthPayload(
            stealthAddress: "5YNmS1R9nNSCDzb5a7mMJ1dwK9uHeAAF4CmPEwKgVWr8",
            ephemeralPublicKey: Data(repeating: 1, count: 32),
            amount: 1_000_000,
            viewTag: 42
        )

        let payment = PendingPayment(from: payload)

        XCTAssertNil(payment.preSignedTransaction)
        XCTAssertNil(payment.nonceAccountAddress)
        XCTAssertFalse(payment.supportsReceiverSettlement)
    }

    // MARK: - Settlement Result Tests

    func testSettlementResultSettledBySender() {
        let result = SettlementResult(
            paymentId: UUID(),
            success: true,
            signature: "txsig123",
            settledBy: .sender
        )

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.settledBy, .sender)
    }

    func testSettlementResultSettledByReceiver() {
        let result = SettlementResult(
            paymentId: UUID(),
            success: true,
            signature: "txsig456",
            settledBy: .receiver
        )

        XCTAssertTrue(result.success)
        XCTAssertEqual(result.settledBy, .receiver)
    }

    // MARK: - Persistence Tests

    func testNonceEntryCodable() throws {
        let entry = NonceEntry(
            address: "DemoNonce111111111111111111111111111111111",
            nonceValue: "GfVcyD4kkTrj5t7Q5xPe2JvmJAo9Xs5KXLZ7wQx5Z4Te",
            authority: "5YNmS1R9nNSCDzb5a7mMJ1dwK9uHeAAF4CmPEwKgVWr8",
            state: .reserved,
            reservedAt: Date()
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(entry)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(NonceEntry.self, from: data)

        XCTAssertEqual(decoded.address, entry.address)
        XCTAssertEqual(decoded.nonceValue, entry.nonceValue)
        XCTAssertEqual(decoded.authority, entry.authority)
        XCTAssertEqual(decoded.state, entry.state)
    }
}
