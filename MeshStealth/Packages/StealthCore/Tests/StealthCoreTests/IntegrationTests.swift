import XCTest
import Combine
@testable import StealthCore

/// Tests for Phase 4 Integration components
final class IntegrationTests: XCTestCase {

    // MARK: - PayloadEncryption Tests

    func testPayloadEncryptionServiceInit() {
        let service = PayloadEncryptionService()
        XCTAssertNotNil(service)
    }

    func testPayloadEncryptionRoundtrip() throws {
        let service = PayloadEncryptionService()

        // Create a test payload
        let payload = MeshStealthPayload(
            stealthAddress: "TestStealthAddress123",
            ephemeralPublicKey: Data(repeating: 0xAB, count: 32),
            mlkemCiphertext: nil,
            amount: 1_000_000_000,  // 1 SOL
            tokenMint: nil,
            viewTag: 0x42,
            memo: "Test payment"
        )

        // Generate X25519 keypair for recipient
        let recipientKeyPair = try StealthKeyPair.generate()

        // Encrypt
        let encrypted = try service.encrypt(
            payload: payload,
            recipientViewingKey: recipientKeyPair.viewingPublicKey
        )

        // Verify encrypted structure
        XCTAssertEqual(encrypted.ephemeralPublicKey.count, 32)
        XCTAssertEqual(encrypted.nonce.count, 12)
        XCTAssertEqual(encrypted.tag.count, 16)
        XCTAssertGreaterThan(encrypted.ciphertext.count, 0)

        // Decrypt
        let decrypted = try service.decrypt(
            encrypted: encrypted,
            viewingPrivateKey: recipientKeyPair.rawViewingPrivateKey
        )

        // Verify roundtrip
        XCTAssertEqual(decrypted.stealthAddress, payload.stealthAddress)
        XCTAssertEqual(decrypted.ephemeralPublicKey, payload.ephemeralPublicKey)
        XCTAssertEqual(decrypted.amount, payload.amount)
        XCTAssertEqual(decrypted.viewTag, payload.viewTag)
        XCTAssertEqual(decrypted.memo, payload.memo)
    }

    func testPayloadEncryptionWithHybridPayload() throws {
        let service = PayloadEncryptionService()

        // Create a hybrid payload with MLKEM ciphertext
        let mlkemCiphertext = Data(repeating: 0xCD, count: 1088)
        let payload = MeshStealthPayload(
            stealthAddress: "HybridStealthAddress456",
            ephemeralPublicKey: Data(repeating: 0xEF, count: 32),
            mlkemCiphertext: mlkemCiphertext,
            amount: 500_000_000,  // 0.5 SOL
            tokenMint: "TokenMint123",
            viewTag: 0x99,
            memo: nil
        )

        let recipientKeyPair = try StealthKeyPair.generate()

        // Encrypt and decrypt
        let encrypted = try service.encrypt(
            payload: payload,
            recipientViewingKey: recipientKeyPair.viewingPublicKey
        )

        let decrypted = try service.decrypt(
            encrypted: encrypted,
            viewingPrivateKey: recipientKeyPair.rawViewingPrivateKey
        )

        XCTAssertEqual(decrypted.mlkemCiphertext, mlkemCiphertext)
        XCTAssertEqual(decrypted.tokenMint, "TokenMint123")
        XCTAssertTrue(decrypted.isHybrid)
    }

    func testPayloadEncryptionInvalidKeySizeRejected() {
        let service = PayloadEncryptionService()

        let payload = MeshStealthPayload(
            stealthAddress: "Test",
            ephemeralPublicKey: Data(repeating: 0x00, count: 32),
            mlkemCiphertext: nil,
            amount: 1000,
            tokenMint: nil,
            viewTag: 0,
            memo: nil
        )

        // Invalid key size (should be 32 bytes)
        let badKey = Data(repeating: 0xFF, count: 16)

        XCTAssertThrowsError(try service.encrypt(
            payload: payload,
            recipientViewingKey: badKey
        )) { error in
            if case PayloadEncryptionError.invalidKeySize(let expected, let got) = error {
                XCTAssertEqual(expected, 32)
                XCTAssertEqual(got, 16)
            } else {
                XCTFail("Expected invalidKeySize error")
            }
        }
    }

    func testEncryptedMeshPayloadSerialization() throws {
        let encrypted = EncryptedMeshPayload(
            ephemeralPublicKey: Data(repeating: 0x11, count: 32),
            nonce: Data(repeating: 0x22, count: 12),
            ciphertext: Data(repeating: 0x33, count: 100),
            tag: Data(repeating: 0x44, count: 16)
        )

        // Serialize
        let serialized = try encrypted.serialize()
        XCTAssertGreaterThan(serialized.count, 0)

        // Deserialize
        let deserialized = try EncryptedMeshPayload.deserialize(from: serialized)

        XCTAssertEqual(deserialized.ephemeralPublicKey, encrypted.ephemeralPublicKey)
        XCTAssertEqual(deserialized.nonce, encrypted.nonce)
        XCTAssertEqual(deserialized.ciphertext, encrypted.ciphertext)
        XCTAssertEqual(deserialized.tag, encrypted.tag)
    }

    func testEncryptedMeshPayloadTotalSize() {
        let encrypted = EncryptedMeshPayload(
            ephemeralPublicKey: Data(repeating: 0x11, count: 32),
            nonce: Data(repeating: 0x22, count: 12),
            ciphertext: Data(repeating: 0x33, count: 200),
            tag: Data(repeating: 0x44, count: 16)
        )

        // 32 + 12 + 200 + 16 = 260
        XCTAssertEqual(encrypted.totalSize, 260)
    }

    // MARK: - SettlementConfiguration Tests

    func testSettlementConfigurationDefaults() {
        let config = SettlementConfiguration.default

        XCTAssertEqual(config.maxAttempts, 5)
        XCTAssertEqual(config.retryDelay, 30)
        XCTAssertTrue(config.autoSettle)
        XCTAssertEqual(config.minBalanceForSettlement, 10_000)
        XCTAssertFalse(config.preferWiFi)
        XCTAssertEqual(config.transactionTimeout, 60)
    }

    func testSettlementConfigurationAggressive() {
        let config = SettlementConfiguration.aggressive

        XCTAssertEqual(config.maxAttempts, 10)
        XCTAssertEqual(config.retryDelay, 10)
        XCTAssertEqual(config.minBalanceForSettlement, 5_000)
        XCTAssertFalse(config.preferWiFi)
    }

    func testSettlementConfigurationConservative() {
        let config = SettlementConfiguration.conservative

        XCTAssertEqual(config.maxAttempts, 3)
        XCTAssertEqual(config.retryDelay, 60)
        XCTAssertEqual(config.minBalanceForSettlement, 50_000)
        XCTAssertTrue(config.preferWiFi)
    }

    func testSettlementConfigurationCustom() {
        let config = SettlementConfiguration(
            maxAttempts: 7,
            retryDelay: 45,
            autoSettle: false,
            minBalanceForSettlement: 25_000,
            preferWiFi: true,
            transactionTimeout: 90
        )

        XCTAssertEqual(config.maxAttempts, 7)
        XCTAssertEqual(config.retryDelay, 45)
        XCTAssertFalse(config.autoSettle)
        XCTAssertEqual(config.minBalanceForSettlement, 25_000)
        XCTAssertTrue(config.preferWiFi)
        XCTAssertEqual(config.transactionTimeout, 90)
    }

    // MARK: - SettlementResult Tests

    func testSettlementResultSuccess() {
        let id = UUID()
        let result = SettlementResult(
            paymentId: id,
            success: true,
            signature: "5xyz...",
            attemptNumber: 1
        )

        XCTAssertEqual(result.paymentId, id)
        XCTAssertTrue(result.success)
        XCTAssertEqual(result.signature, "5xyz...")
        XCTAssertNil(result.error)
        XCTAssertEqual(result.attemptNumber, 1)
    }

    func testSettlementResultFailure() {
        let id = UUID()
        let testError = SettlementError.insufficientBalance(required: 10_000, available: 5_000)
        let result = SettlementResult(
            paymentId: id,
            success: false,
            error: testError,
            attemptNumber: 3
        )

        XCTAssertFalse(result.success)
        XCTAssertNil(result.signature)
        XCTAssertNotNil(result.error)
        XCTAssertEqual(result.attemptNumber, 3)
    }

    // MARK: - PendingPayment Tests

    func testPendingPaymentCreation() {
        let payment = PendingPayment(
            stealthAddress: "TestStealthAddr",
            ephemeralPublicKey: Data(repeating: 0x11, count: 32),
            mlkemCiphertext: nil,
            amount: 1_000_000_000,
            tokenMint: nil,
            viewTag: 0x42
        )

        XCTAssertEqual(payment.stealthAddress, "TestStealthAddr")
        XCTAssertEqual(payment.amount, 1_000_000_000)
        XCTAssertEqual(payment.status, .received)
        XCTAssertEqual(payment.settlementAttempts, 0)
        XCTAssertNil(payment.lastAttemptAt)
        XCTAssertNil(payment.settlementSignature)
        XCTAssertFalse(payment.isHybrid)
    }

    func testPendingPaymentHybrid() {
        let payment = PendingPayment(
            stealthAddress: "HybridStealthAddr",
            ephemeralPublicKey: Data(repeating: 0x22, count: 32),
            mlkemCiphertext: Data(repeating: 0x33, count: 1088),
            amount: 500_000_000,
            tokenMint: "TokenMint",
            viewTag: 0x99
        )

        XCTAssertTrue(payment.isHybrid)
        XCTAssertEqual(payment.tokenMint, "TokenMint")
    }

    func testPendingPaymentFromMeshPayload() {
        let meshPayload = MeshStealthPayload(
            stealthAddress: "MeshStealthAddr",
            ephemeralPublicKey: Data(repeating: 0x44, count: 32),
            mlkemCiphertext: nil,
            amount: 2_000_000_000,
            tokenMint: nil,
            viewTag: 0x55,
            memo: "From mesh"
        )

        let payment = PendingPayment(from: meshPayload)

        XCTAssertEqual(payment.stealthAddress, meshPayload.stealthAddress)
        XCTAssertEqual(payment.ephemeralPublicKey, meshPayload.ephemeralPublicKey)
        XCTAssertEqual(payment.amount, meshPayload.amount)
        XCTAssertEqual(payment.viewTag, meshPayload.viewTag)
        XCTAssertEqual(payment.status, .received)
    }

    func testPendingPaymentAmountInSol() {
        let payment = PendingPayment(
            stealthAddress: "Test",
            ephemeralPublicKey: Data(repeating: 0, count: 32),
            mlkemCiphertext: nil,
            amount: 1_500_000_000,  // 1.5 SOL
            tokenMint: nil,
            viewTag: 0
        )

        XCTAssertEqual(payment.amountInSol, 1.5, accuracy: 0.0001)
    }

    // MARK: - PendingPaymentStatus Tests

    func testPendingPaymentStatusValues() {
        XCTAssertEqual(PendingPaymentStatus.received.rawValue, "received")
        XCTAssertEqual(PendingPaymentStatus.settling.rawValue, "settling")
        XCTAssertEqual(PendingPaymentStatus.settled.rawValue, "settled")
        XCTAssertEqual(PendingPaymentStatus.failed.rawValue, "failed")
        XCTAssertEqual(PendingPaymentStatus.expired.rawValue, "expired")
    }

    // MARK: - NetworkStatus Tests

    func testNetworkStatusValues() {
        XCTAssertEqual(NetworkStatus.connected.rawValue, "connected")
        XCTAssertEqual(NetworkStatus.disconnected.rawValue, "disconnected")
        XCTAssertEqual(NetworkStatus.unknown.rawValue, "unknown")
    }

    func testConnectionTypeValues() {
        XCTAssertEqual(ConnectionType.wifi.rawValue, "wifi")
        XCTAssertEqual(ConnectionType.cellular.rawValue, "cellular")
        XCTAssertEqual(ConnectionType.wiredEthernet.rawValue, "wiredEthernet")
        XCTAssertEqual(ConnectionType.other.rawValue, "other")
        XCTAssertEqual(ConnectionType.none.rawValue, "none")
    }

    // MARK: - NetworkReachability Tests

    func testNetworkReachabilityInit() {
        let reachability = NetworkReachability()
        XCTAssertNotNil(reachability)
    }

    // MARK: - SettlementError Tests

    func testSettlementErrorDescriptions() {
        let error1 = SettlementError.insufficientBalance(required: 10_000, available: 5_000)
        XCTAssertTrue(error1.localizedDescription.contains("10000"))
        XCTAssertTrue(error1.localizedDescription.contains("5000"))

        let error2 = SettlementError.noDestinationAddress
        XCTAssertTrue(error2.localizedDescription.contains("destination"))

        let error3 = SettlementError.transactionFailed("timeout")
        XCTAssertTrue(error3.localizedDescription.contains("timeout"))

        let error4 = SettlementError.paymentNotSettled
        XCTAssertTrue(error4.localizedDescription.contains("settled"))

        let error5 = SettlementError.noRentToReclaim
        XCTAssertTrue(error5.localizedDescription.contains("rent"))

        let error6 = SettlementError.pdaNotFound
        XCTAssertTrue(error6.localizedDescription.contains("PDA"))

        let error7 = SettlementError.notImplemented("feature X")
        XCTAssertTrue(error7.localizedDescription.contains("feature X"))
    }

    // MARK: - WalletError Tests

    func testWalletErrorDescriptions() {
        let error1 = WalletError.notInitialized
        XCTAssertTrue(error1.localizedDescription.contains("not initialized"))

        let error2 = WalletError.keyDerivationFailed
        XCTAssertTrue(error2.localizedDescription.contains("derive"))

        let error3 = WalletError.paymentNotFound
        XCTAssertTrue(error3.localizedDescription.contains("not found"))

        let error4 = WalletError.alreadySettled
        XCTAssertTrue(error4.localizedDescription.contains("settled"))
    }

    // MARK: - MeshNetworkError Tests

    func testMeshNetworkErrorDescriptions() {
        let error1 = MeshNetworkError.invalidMetaAddress
        XCTAssertTrue(error1.localizedDescription.contains("meta-address"))

        let error2 = MeshNetworkError.walletNotInitialized
        XCTAssertTrue(error2.localizedDescription.contains("Wallet"))

        let error3 = MeshNetworkError.meshNotActive
        XCTAssertTrue(error3.localizedDescription.contains("not active"))

        let error4 = MeshNetworkError.encryptionFailed
        XCTAssertTrue(error4.localizedDescription.contains("encrypt"))

        struct TestError: Error, LocalizedError {
            var errorDescription: String? { "test error" }
        }
        let error5 = MeshNetworkError.sendFailed(TestError())
        XCTAssertTrue(error5.localizedDescription.contains("test error"))
    }

    // MARK: - PayloadEncryptionError Tests

    func testPayloadEncryptionErrorDescriptions() {
        let error1 = PayloadEncryptionError.invalidKeySize(expected: 32, got: 16)
        XCTAssertTrue(error1.localizedDescription.contains("32"))
        XCTAssertTrue(error1.localizedDescription.contains("16"))

        let error2 = PayloadEncryptionError.invalidNonceSize(expected: 12, got: 8)
        XCTAssertTrue(error2.localizedDescription.contains("nonce"))

        let error3 = PayloadEncryptionError.invalidTagSize(expected: 16, got: 8)
        XCTAssertTrue(error3.localizedDescription.contains("tag"))

        let error4 = PayloadEncryptionError.randomGenerationFailed
        XCTAssertTrue(error4.localizedDescription.contains("random"))

        let error5 = PayloadEncryptionError.invalidPayloadFormat
        XCTAssertTrue(error5.localizedDescription.contains("format"))
    }

    // MARK: - Message Encryption Tests

    func testEncryptDecryptMeshMessage() throws {
        let service = PayloadEncryptionService()
        let recipientKeyPair = try StealthKeyPair.generate()

        let message = MeshMessage(
            type: .stealthPayment,
            ttl: 5,
            originPeerID: "peer123",
            payload: Data("test payload".utf8)
        )

        // Encrypt
        let encrypted = try service.encryptMessage(
            message,
            recipientViewingKey: recipientKeyPair.viewingPublicKey
        )

        // Decrypt
        let decrypted = try service.decryptMessage(
            encrypted,
            viewingPrivateKey: recipientKeyPair.rawViewingPrivateKey
        )

        XCTAssertEqual(decrypted.type, message.type)
        XCTAssertEqual(decrypted.originPeerID, message.originPeerID)
        XCTAssertEqual(decrypted.payload, message.payload)
    }

    // MARK: - Encrypt Data Tests

    func testEncryptDecryptRawData() throws {
        let service = PayloadEncryptionService()
        let recipientKeyPair = try StealthKeyPair.generate()

        let originalData = Data("Hello, World! This is a test message.".utf8)

        // Encrypt
        let encrypted = try service.encryptData(
            originalData,
            recipientViewingKey: recipientKeyPair.viewingPublicKey
        )

        // Decrypt
        let decrypted = try service.decryptData(
            encrypted,
            viewingPrivateKey: recipientKeyPair.rawViewingPrivateKey
        )

        XCTAssertEqual(decrypted, originalData)
    }

    func testEncryptionProducesDifferentCiphertexts() throws {
        let service = PayloadEncryptionService()
        let recipientKeyPair = try StealthKeyPair.generate()
        let data = Data("same data".utf8)

        // Encrypt twice
        let encrypted1 = try service.encryptData(
            data,
            recipientViewingKey: recipientKeyPair.viewingPublicKey
        )
        let encrypted2 = try service.encryptData(
            data,
            recipientViewingKey: recipientKeyPair.viewingPublicKey
        )

        // Should produce different ciphertexts (different ephemeral keys and nonces)
        XCTAssertNotEqual(encrypted1.ciphertext, encrypted2.ciphertext)
        XCTAssertNotEqual(encrypted1.ephemeralPublicKey, encrypted2.ephemeralPublicKey)
        XCTAssertNotEqual(encrypted1.nonce, encrypted2.nonce)
    }

    func testDecryptionFailsWithWrongKey() throws {
        let service = PayloadEncryptionService()
        let recipientKeyPair = try StealthKeyPair.generate()
        let wrongKeyPair = try StealthKeyPair.generate()

        let data = Data("secret data".utf8)

        let encrypted = try service.encryptData(
            data,
            recipientViewingKey: recipientKeyPair.viewingPublicKey
        )

        // Decrypt with wrong key should fail
        XCTAssertThrowsError(try service.decryptData(
            encrypted,
            viewingPrivateKey: wrongKeyPair.rawViewingPrivateKey
        ))
    }
}
