import XCTest
@testable import StealthCore

/// End-to-end roundtrip tests for the complete stealth protocol.
/// These tests verify that:
/// 1. Sender can derive stealth address from meta-address
/// 2. Receiver can detect and recover spending key
/// 3. Derived keys are cryptographically correct
final class CryptoRoundtripTests: XCTestCase {

    override func setUpWithError() throws {
        // Initialize libsodium
        XCTAssertTrue(initializeStealth(), "Failed to initialize sodium")
    }

    // MARK: - Keypair Tests

    func testKeyPairGeneration() throws {
        let keyPair = try StealthKeyPair.generate()

        // Verify key sizes
        XCTAssertEqual(keyPair.spendingPublicKey.count, 32, "Spending pubkey should be 32 bytes")
        XCTAssertEqual(keyPair.viewingPublicKey.count, 32, "Viewing pubkey should be 32 bytes")
        XCTAssertEqual(keyPair.rawSpendingScalar.count, 32, "Spending scalar should be 32 bytes")
        XCTAssertEqual(keyPair.rawViewingPrivateKey.count, 32, "Viewing privkey should be 32 bytes")

        // Verify meta-address
        XCTAssertEqual(keyPair.metaAddress.count, 64, "Meta-address should be 64 bytes")
        XCTAssertFalse(keyPair.metaAddressString.isEmpty, "Meta-address string should not be empty")
    }

    func testKeyPairRestoration() throws {
        let original = try StealthKeyPair.generate()

        let restored = try StealthKeyPair.restore(
            spendingScalar: original.rawSpendingScalar,
            viewingPrivateKey: original.rawViewingPrivateKey
        )

        XCTAssertEqual(restored.spendingPublicKey, original.spendingPublicKey)
        XCTAssertEqual(restored.viewingPublicKey, original.viewingPublicKey)
        XCTAssertEqual(restored.metaAddressString, original.metaAddressString)
    }

    func testMetaAddressParsing() throws {
        let keyPair = try StealthKeyPair.generate()
        let metaStr = keyPair.metaAddressString

        let (spendKey, viewKey) = try StealthKeyPair.parseMetaAddress(metaStr)

        XCTAssertEqual(spendKey, keyPair.spendingPublicKey)
        XCTAssertEqual(viewKey, keyPair.viewingPublicKey)
    }

    func testInvalidMetaAddressRejected() {
        XCTAssertThrowsError(try StealthKeyPair.parseMetaAddress("invalid")) { error in
            XCTAssertEqual(error as? StealthError, .invalidMetaAddress)
        }

        // Too short
        XCTAssertThrowsError(try StealthKeyPair.parseMetaAddress("abc123"))
    }

    // MARK: - Stealth Address Generation Tests

    func testStealthAddressGeneration() throws {
        let receiverKeyPair = try StealthKeyPair.generate()

        let result = try StealthAddressGenerator.generateStealthAddress(
            metaAddressString: receiverKeyPair.metaAddressString
        )

        XCTAssertEqual(result.stealthPublicKey.count, 32)
        XCTAssertEqual(result.ephemeralPublicKey.count, 32)
        XCTAssertFalse(result.stealthAddress.isEmpty)
        XCTAssert(SodiumWrapper.isValidPoint(result.stealthPublicKey), "Stealth pubkey should be valid curve point")
    }

    func testDifferentEphemeralKeysProduceDifferentAddresses() throws {
        let receiverKeyPair = try StealthKeyPair.generate()

        let result1 = try StealthAddressGenerator.generateStealthAddress(
            metaAddressString: receiverKeyPair.metaAddressString
        )
        let result2 = try StealthAddressGenerator.generateStealthAddress(
            metaAddressString: receiverKeyPair.metaAddressString
        )

        // Each call should produce unique stealth address
        XCTAssertNotEqual(result1.stealthAddress, result2.stealthAddress)
        XCTAssertNotEqual(result1.ephemeralPublicKey, result2.ephemeralPublicKey)
        XCTAssertNotEqual(result1.stealthPublicKey, result2.stealthPublicKey)
    }

    func testStealthAddressVerification() throws {
        let receiverKeyPair = try StealthKeyPair.generate()

        let result = try StealthAddressGenerator.generateStealthAddress(
            spendingPublicKey: receiverKeyPair.spendingPublicKey,
            viewingPublicKey: receiverKeyPair.viewingPublicKey
        )

        let verified = try StealthAddressGenerator.verifyStealthAddress(
            stealthAddress: result.stealthAddress,
            spendingPublicKey: receiverKeyPair.spendingPublicKey,
            viewingPublicKey: receiverKeyPair.viewingPublicKey,
            ephemeralPublicKey: result.ephemeralPublicKey,
            viewingPrivateKey: receiverKeyPair.rawViewingPrivateKey
        )

        XCTAssertTrue(verified)
    }

    // MARK: - Scanner Tests

    func testScanDetectsOurTransaction() throws {
        let receiverKeyPair = try StealthKeyPair.generate()
        let scanner = StealthScanner(keyPair: receiverKeyPair)

        // Sender generates stealth address
        let stealthResult = try StealthAddressGenerator.generateStealthAddress(
            metaAddressString: receiverKeyPair.metaAddressString
        )

        // Receiver scans transaction
        let detected = try scanner.scanTransaction(
            stealthAddress: stealthResult.stealthAddress,
            ephemeralPublicKey: stealthResult.ephemeralPublicKey
        )

        XCTAssertNotNil(detected)
        XCTAssertEqual(detected?.stealthAddress, stealthResult.stealthAddress)
        XCTAssertEqual(detected?.viewTag, stealthResult.viewTag)
    }

    func testScanIgnoresOtherTransactions() throws {
        let ourKeyPair = try StealthKeyPair.generate()
        let otherKeyPair = try StealthKeyPair.generate()

        let scanner = StealthScanner(keyPair: ourKeyPair)

        // Stealth address for different receiver
        let stealthResult = try StealthAddressGenerator.generateStealthAddress(
            metaAddressString: otherKeyPair.metaAddressString
        )

        // Our scanner should not detect it
        let detected = try scanner.scanTransaction(
            stealthAddress: stealthResult.stealthAddress,
            ephemeralPublicKey: stealthResult.ephemeralPublicKey
        )

        XCTAssertNil(detected)
    }

    func testDerivedKeyCanSign() throws {
        let receiverKeyPair = try StealthKeyPair.generate()
        let scanner = StealthScanner(keyPair: receiverKeyPair)

        let stealthResult = try StealthAddressGenerator.generateStealthAddress(
            metaAddressString: receiverKeyPair.metaAddressString
        )

        let detected = try scanner.scanTransaction(
            stealthAddress: stealthResult.stealthAddress,
            ephemeralPublicKey: stealthResult.ephemeralPublicKey
        )!

        // Verify the derived private key produces the correct public key
        guard let derivedPubKey = SodiumWrapper.scalarMultBaseNoclamp(
            detected.spendingPrivateKey
        ) else {
            XCTFail("Failed to derive public key from spending key")
            return
        }

        XCTAssertEqual(derivedPubKey, stealthResult.stealthPublicKey)
    }

    func testQuickFilterWorks() throws {
        let receiverKeyPair = try StealthKeyPair.generate()
        let scanner = StealthScanner(keyPair: receiverKeyPair)

        let stealthResult = try StealthAddressGenerator.generateStealthAddress(
            metaAddressString: receiverKeyPair.metaAddressString
        )

        // Correct view tag should match
        let matches = try scanner.quickFilter(
            ephemeralPublicKey: stealthResult.ephemeralPublicKey,
            expectedViewTag: stealthResult.viewTag
        )
        XCTAssertTrue(matches)

        // Wrong view tag should not match
        let wrongTag = stealthResult.viewTag ^ 0xFF
        let noMatch = try scanner.quickFilter(
            ephemeralPublicKey: stealthResult.ephemeralPublicKey,
            expectedViewTag: wrongTag
        )
        XCTAssertFalse(noMatch)
    }

    // MARK: - Complete Protocol Roundtrip

    func testCompleteStealthProtocolRoundtrip() throws {
        // Step 1: Receiver generates stealth keypair
        let receiverKeyPair = try StealthKeyPair.generate()
        let metaAddress = receiverKeyPair.metaAddressString

        // Step 2: Sender generates stealth address from meta-address
        let stealthResult = try StealthAddressGenerator.generateStealthAddress(
            metaAddressString: metaAddress
        )

        // Step 3: Receiver scans and detects payment
        let scanner = StealthScanner(keyPair: receiverKeyPair)
        let detected = try scanner.scanTransaction(
            stealthAddress: stealthResult.stealthAddress,
            ephemeralPublicKey: stealthResult.ephemeralPublicKey
        )

        XCTAssertNotNil(detected)

        // Step 4: Verify derived spending key produces correct public key
        guard let derivedPubKey = SodiumWrapper.scalarMultBaseNoclamp(
            detected!.spendingPrivateKey
        ) else {
            XCTFail("Failed to derive public key")
            return
        }

        XCTAssertEqual(derivedPubKey, stealthResult.stealthPublicKey)

        // Step 5: Verify Solana address matches
        XCTAssertEqual(detected!.stealthAddress, stealthResult.stealthAddress)
    }

    func testMultiplePaymentsToSameReceiver() throws {
        let receiverKeyPair = try StealthKeyPair.generate()
        let scanner = StealthScanner(keyPair: receiverKeyPair)

        var detectedPayments: [DetectedStealthPayment] = []
        var stealthAddresses: Set<String> = []

        // Generate 10 payments to same receiver
        for _ in 0..<10 {
            let result = try StealthAddressGenerator.generateStealthAddress(
                metaAddressString: receiverKeyPair.metaAddressString
            )

            // Each stealth address should be unique
            XCTAssertFalse(stealthAddresses.contains(result.stealthAddress))
            stealthAddresses.insert(result.stealthAddress)

            // Scanner should detect each
            let detected = try scanner.scanTransaction(
                stealthAddress: result.stealthAddress,
                ephemeralPublicKey: result.ephemeralPublicKey
            )

            XCTAssertNotNil(detected)
            detectedPayments.append(detected!)
        }

        // All 10 payments detected with unique spending keys
        XCTAssertEqual(detectedPayments.count, 10)
        let uniqueKeys = Set(detectedPayments.map { $0.spendingPrivateKey.hexString })
        XCTAssertEqual(uniqueKeys.count, 10)
    }

    func testBatchScanning() throws {
        let receiverKeyPair = try StealthKeyPair.generate()
        let otherKeyPair = try StealthKeyPair.generate()
        let scanner = StealthScanner(keyPair: receiverKeyPair)

        // Create mix of transactions - some ours, some not
        var transactions: [(stealthAddress: String, ephemeralPublicKey: Data)] = []

        // 3 transactions for us
        for _ in 0..<3 {
            let result = try StealthAddressGenerator.generateStealthAddress(
                metaAddressString: receiverKeyPair.metaAddressString
            )
            transactions.append((result.stealthAddress, result.ephemeralPublicKey))
        }

        // 2 transactions for someone else
        for _ in 0..<2 {
            let result = try StealthAddressGenerator.generateStealthAddress(
                metaAddressString: otherKeyPair.metaAddressString
            )
            transactions.append((result.stealthAddress, result.ephemeralPublicKey))
        }

        // Batch scan
        let detected = try scanner.scanTransactions(transactions)

        // Should find exactly 3
        XCTAssertEqual(detected.count, 3)
    }

    // MARK: - Edge Cases

    func testEmptyEphemeralKeyRejected() throws {
        let keyPair = try StealthKeyPair.generate()
        let scanner = StealthScanner(keyPair: keyPair)

        XCTAssertThrowsError(
            try scanner.scanTransaction(
                stealthAddress: "someaddress",
                ephemeralPublicKey: Data()
            )
        ) { error in
            XCTAssertEqual(error as? StealthError, .invalidEphemeralKey)
        }
    }

    func testWrongSizeEphemeralKeyRejected() throws {
        let keyPair = try StealthKeyPair.generate()
        let scanner = StealthScanner(keyPair: keyPair)

        XCTAssertThrowsError(
            try scanner.scanTransaction(
                stealthAddress: "someaddress",
                ephemeralPublicKey: Data(repeating: 0, count: 16)  // Wrong size
            )
        ) { error in
            XCTAssertEqual(error as? StealthError, .invalidEphemeralKey)
        }
    }

    // MARK: - Sodium Wrapper Tests

    func testScalarKeyPairConsistency() throws {
        // Generate scalar keypair and verify scalar * G = public key
        guard let (scalar, publicKey) = SodiumWrapper.generateScalarKeyPair() else {
            XCTFail("Failed to generate scalar keypair")
            return
        }

        // Verify: scalar * G should equal publicKey
        guard let derivedPubKey = SodiumWrapper.scalarMultBaseNoclamp(scalar) else {
            XCTFail("Failed to derive public key from scalar")
            return
        }

        XCTAssertEqual(derivedPubKey, publicKey, "scalar * G should equal stored public key")
    }

    func testStealthKeyPairScalarConsistency() throws {
        // Generate stealth keypair and verify scalar * G = spendingPublicKey
        let keyPair = try StealthKeyPair.generate()

        guard let derivedPubKey = SodiumWrapper.scalarMultBaseNoclamp(keyPair.rawSpendingScalar) else {
            XCTFail("Failed to derive public key from scalar")
            return
        }

        XCTAssertEqual(derivedPubKey, keyPair.spendingPublicKey,
                       "rawSpendingScalar * G should equal spendingPublicKey")
    }

    func testStealthMathIdentity() throws {
        // Test the basic stealth math: (m + h) * G should equal M + h * G
        // IMPORTANT: The hash must be reduced mod L for scalarMultBaseNoclamp to work correctly
        let keyPair = try StealthKeyPair.generate()

        // Generate a random "hash" value and reduce it to a valid scalar
        let rawHash = SodiumWrapper.randomBytes(count: 32)
        guard let hash = SodiumWrapper.scalarReduce32(rawHash) else {
            XCTFail("Failed to reduce hash")
            return
        }

        // Method 1: (m + h) * G
        guard let sumScalar = SodiumWrapper.scalarAdd(keyPair.rawSpendingScalar, hash),
              let method1 = SodiumWrapper.scalarMultBaseNoclamp(sumScalar) else {
            XCTFail("Method 1 computation failed")
            return
        }

        // Method 2: M + h * G (both use the reduced hash)
        guard let hashPoint = SodiumWrapper.scalarMultBaseNoclamp(hash),
              let method2 = SodiumWrapper.pointAdd(keyPair.spendingPublicKey, hashPoint) else {
            XCTFail("Method 2 computation failed")
            return
        }

        XCTAssertEqual(method1, method2, "(m + h) * G should equal M + h * G")
    }

    func testPointAdditionWorks() throws {
        // Generate two valid points
        guard let (_, pub1) = SodiumWrapper.generateSigningKeyPair(),
              let (_, pub2) = SodiumWrapper.generateSigningKeyPair() else {
            XCTFail("Failed to generate keypairs")
            return
        }

        // Add them
        guard let sum = SodiumWrapper.pointAdd(pub1, pub2) else {
            XCTFail("Point addition failed")
            return
        }

        XCTAssertEqual(sum.count, 32)
        XCTAssertTrue(SodiumWrapper.isValidPoint(sum))

        // Result should be different from inputs
        XCTAssertNotEqual(sum, pub1)
        XCTAssertNotEqual(sum, pub2)
    }

    func testScalarMultBaseWorks() throws {
        let scalar = SodiumWrapper.randomBytes(count: 32)

        guard let point = SodiumWrapper.scalarMultBase(scalar) else {
            XCTFail("Scalar mult failed")
            return
        }

        XCTAssertEqual(point.count, 32)
        XCTAssertTrue(SodiumWrapper.isValidPoint(point))
    }

    func testScalarAdditionWorks() throws {
        // Use properly generated scalars that are already reduced mod L
        guard let (scalarA, _) = SodiumWrapper.generateScalarKeyPair(),
              let (scalarB, _) = SodiumWrapper.generateScalarKeyPair() else {
            XCTFail("Failed to generate scalar keypairs")
            return
        }

        guard let sum = SodiumWrapper.scalarAdd(scalarA, scalarB) else {
            XCTFail("Scalar addition failed")
            return
        }

        XCTAssertEqual(sum.count, 32)

        // Adding zero to a reduced scalar should return the original
        let zero = Data(repeating: 0, count: 32)
        guard let aPlusZero = SodiumWrapper.scalarAdd(scalarA, zero) else {
            XCTFail("Scalar addition with zero failed")
            return
        }
        XCTAssertEqual(aPlusZero, scalarA, "Adding zero to a reduced scalar should return the same scalar")
    }

    // MARK: - MLKEM768 / Kyber Tests

    func testMLKEMKeyGeneration() throws {
        let (privateKey, publicKey) = try MLKEMWrapper.generateKeyPairData()

        XCTAssertEqual(publicKey.count, MLKEMWrapper.publicKeyBytes, "MLKEM public key should be 1184 bytes")
        // Private key uses integrityCheckedRepresentation which is compact
        XCTAssertGreaterThan(privateKey.count, 0, "MLKEM private key should have data")
    }

    func testMLKEMEncapsulateDecapsulate() throws {
        // Generate keypair
        let (privateKey, publicKey) = try MLKEMWrapper.generateKeyPairData()

        // Encapsulate with public key
        let (ciphertext, sharedSecret) = try MLKEMWrapper.encapsulate(publicKeyData: publicKey)

        XCTAssertEqual(ciphertext.count, MLKEMWrapper.ciphertextBytes, "Ciphertext should be 1088 bytes")
        XCTAssertEqual(sharedSecret.count, MLKEMWrapper.sharedSecretBytes, "Shared secret should be 32 bytes")

        // Decapsulate with private key
        let recoveredSecret = try MLKEMWrapper.decapsulate(
            ciphertextData: ciphertext,
            privateKeyData: privateKey
        )

        XCTAssertEqual(recoveredSecret, sharedSecret, "Decapsulated secret should match encapsulated secret")
    }

    func testMLKEMKeyRestoration() throws {
        let (privateKeyData, publicKeyData) = try MLKEMWrapper.generateKeyPairData()

        // Restore keys from data
        let restoredPriv = MLKEMWrapper.restorePrivateKey(from: privateKeyData)
        let restoredPub = MLKEMWrapper.restorePublicKey(from: publicKeyData)

        XCTAssertNotNil(restoredPriv, "Should restore private key from data")
        XCTAssertNotNil(restoredPub, "Should restore public key from data")
    }

    func testMLKEMValidation() throws {
        let (_, publicKey) = try MLKEMWrapper.generateKeyPairData()

        XCTAssertTrue(MLKEMWrapper.isValidPublicKey(publicKey))
        XCTAssertFalse(MLKEMWrapper.isValidPublicKey(Data(repeating: 0, count: 32)))

        let ciphertext = Data(repeating: 0, count: MLKEMWrapper.ciphertextBytes)
        XCTAssertTrue(MLKEMWrapper.isValidCiphertext(ciphertext))
        XCTAssertFalse(MLKEMWrapper.isValidCiphertext(Data(repeating: 0, count: 32)))
    }

    // MARK: - Hybrid Keypair Tests

    func testHybridKeyPairGeneration() throws {
        let keyPair = try StealthKeyPair.generate(withPostQuantum: true)

        // Classical keys
        XCTAssertEqual(keyPair.spendingPublicKey.count, 32)
        XCTAssertEqual(keyPair.viewingPublicKey.count, 32)
        XCTAssertEqual(keyPair.rawSpendingScalar.count, 32)
        XCTAssertEqual(keyPair.rawViewingPrivateKey.count, 32)

        // MLKEM keys
        XCTAssertTrue(keyPair.hasPostQuantum)
        XCTAssertNotNil(keyPair.mlkemPublicKey)
        XCTAssertNotNil(keyPair.rawMLKEMPrivateKey)
        XCTAssertEqual(keyPair.mlkemPublicKey?.count, MLKEMWrapper.publicKeyBytes)

        // Meta addresses
        XCTAssertEqual(keyPair.metaAddress.count, 64, "Classical meta-address should be 64 bytes")
        XCTAssertEqual(keyPair.hybridMetaAddress.count, 64 + MLKEMWrapper.publicKeyBytes,
                       "Hybrid meta-address should be 1248 bytes")
    }

    func testHybridKeyPairRestoration() throws {
        let original = try StealthKeyPair.generate(withPostQuantum: true)

        let restored = try StealthKeyPair.restore(
            spendingScalar: original.rawSpendingScalar,
            viewingPrivateKey: original.rawViewingPrivateKey,
            mlkemPrivateKey: original.rawMLKEMPrivateKey
        )

        XCTAssertEqual(restored.spendingPublicKey, original.spendingPublicKey)
        XCTAssertEqual(restored.viewingPublicKey, original.viewingPublicKey)
        XCTAssertEqual(restored.mlkemPublicKey, original.mlkemPublicKey)
        XCTAssertTrue(restored.hasPostQuantum)
    }

    func testHybridMetaAddressParsing() throws {
        let keyPair = try StealthKeyPair.generate(withPostQuantum: true)
        let hybridMetaStr = keyPair.hybridMetaAddressString

        let (spendKey, viewKey, mlkemKey) = try StealthKeyPair.parseHybridMetaAddress(hybridMetaStr)

        XCTAssertEqual(spendKey, keyPair.spendingPublicKey)
        XCTAssertEqual(viewKey, keyPair.viewingPublicKey)
        XCTAssertNotNil(mlkemKey)
        XCTAssertEqual(mlkemKey, keyPair.mlkemPublicKey)
    }

    func testClassicalMetaAddressParsingWithHybridParser() throws {
        let keyPair = try StealthKeyPair.generate(withPostQuantum: false)
        let classicalMetaStr = keyPair.metaAddressString

        let (spendKey, viewKey, mlkemKey) = try StealthKeyPair.parseHybridMetaAddress(classicalMetaStr)

        XCTAssertEqual(spendKey, keyPair.spendingPublicKey)
        XCTAssertEqual(viewKey, keyPair.viewingPublicKey)
        XCTAssertNil(mlkemKey, "Classical meta-address should have nil MLKEM key")
    }

    // MARK: - Hybrid Stealth Address Tests

    func testHybridStealthAddressGeneration() throws {
        let receiverKeyPair = try StealthKeyPair.generate(withPostQuantum: true)

        let result = try StealthAddressGenerator.generateHybridStealthAddress(
            spendingPublicKey: receiverKeyPair.spendingPublicKey,
            viewingPublicKey: receiverKeyPair.viewingPublicKey,
            mlkemPublicKey: receiverKeyPair.mlkemPublicKey!
        )

        XCTAssertEqual(result.stealthPublicKey.count, 32)
        XCTAssertEqual(result.ephemeralPublicKey.count, 32)
        XCTAssertTrue(result.isHybrid, "Result should be hybrid")
        XCTAssertNotNil(result.mlkemCiphertext)
        XCTAssertEqual(result.mlkemCiphertext?.count, MLKEMWrapper.ciphertextBytes)
        XCTAssertFalse(result.stealthAddress.isEmpty)
        XCTAssert(SodiumWrapper.isValidPoint(result.stealthPublicKey))
    }

    func testHybridMemoDataFormat() throws {
        let receiverKeyPair = try StealthKeyPair.generate(withPostQuantum: true)

        let result = try StealthAddressGenerator.generateHybridStealthAddress(
            spendingPublicKey: receiverKeyPair.spendingPublicKey,
            viewingPublicKey: receiverKeyPair.viewingPublicKey,
            mlkemPublicKey: receiverKeyPair.mlkemPublicKey!
        )

        // Hybrid memo: R (32) || ciphertext (1088) = 1120 bytes
        XCTAssertEqual(result.memoData.count, 32 + MLKEMWrapper.ciphertextBytes)
        XCTAssertEqual(result.memoData.prefix(32), result.ephemeralPublicKey)
        XCTAssertEqual(Data(result.memoData.suffix(MLKEMWrapper.ciphertextBytes)), result.mlkemCiphertext)
    }

    func testAutoModeDetectsHybridMetaAddress() throws {
        let receiverKeyPair = try StealthKeyPair.generate(withPostQuantum: true)

        let result = try StealthAddressGenerator.generateStealthAddressAuto(
            metaAddressString: receiverKeyPair.hybridMetaAddressString
        )

        XCTAssertTrue(result.isHybrid, "Auto mode should detect hybrid meta-address")
        XCTAssertNotNil(result.mlkemCiphertext)
    }

    func testAutoModeUsesClassicalForClassicalMetaAddress() throws {
        let receiverKeyPair = try StealthKeyPair.generate(withPostQuantum: false)

        let result = try StealthAddressGenerator.generateStealthAddressAuto(
            metaAddressString: receiverKeyPair.metaAddressString
        )

        XCTAssertFalse(result.isHybrid, "Auto mode should use classical for classical meta-address")
        XCTAssertNil(result.mlkemCiphertext)
    }

    // MARK: - Hybrid Scanner Tests

    func testHybridScanDetectsOurTransaction() throws {
        let receiverKeyPair = try StealthKeyPair.generate(withPostQuantum: true)
        let scanner = StealthScanner(keyPair: receiverKeyPair)

        // Sender generates hybrid stealth address
        let stealthResult = try StealthAddressGenerator.generateHybridStealthAddress(
            spendingPublicKey: receiverKeyPair.spendingPublicKey,
            viewingPublicKey: receiverKeyPair.viewingPublicKey,
            mlkemPublicKey: receiverKeyPair.mlkemPublicKey!
        )

        // Receiver scans hybrid transaction
        let detected = try scanner.scanHybridTransaction(
            stealthAddress: stealthResult.stealthAddress,
            ephemeralPublicKey: stealthResult.ephemeralPublicKey,
            mlkemCiphertext: stealthResult.mlkemCiphertext!
        )

        XCTAssertNotNil(detected)
        XCTAssertEqual(detected?.stealthAddress, stealthResult.stealthAddress)
        XCTAssertTrue(detected?.isHybrid ?? false)
    }

    func testHybridScanIgnoresOtherTransactions() throws {
        let ourKeyPair = try StealthKeyPair.generate(withPostQuantum: true)
        let otherKeyPair = try StealthKeyPair.generate(withPostQuantum: true)

        let scanner = StealthScanner(keyPair: ourKeyPair)

        // Stealth address for different receiver
        let stealthResult = try StealthAddressGenerator.generateHybridStealthAddress(
            spendingPublicKey: otherKeyPair.spendingPublicKey,
            viewingPublicKey: otherKeyPair.viewingPublicKey,
            mlkemPublicKey: otherKeyPair.mlkemPublicKey!
        )

        // Our scanner should not detect it
        let detected = try scanner.scanHybridTransaction(
            stealthAddress: stealthResult.stealthAddress,
            ephemeralPublicKey: stealthResult.ephemeralPublicKey,
            mlkemCiphertext: stealthResult.mlkemCiphertext!
        )

        XCTAssertNil(detected)
    }

    func testScanFromMemoHybrid() throws {
        let receiverKeyPair = try StealthKeyPair.generate(withPostQuantum: true)
        let scanner = StealthScanner(keyPair: receiverKeyPair)

        let stealthResult = try StealthAddressGenerator.generateHybridStealthAddress(
            spendingPublicKey: receiverKeyPair.spendingPublicKey,
            viewingPublicKey: receiverKeyPair.viewingPublicKey,
            mlkemPublicKey: receiverKeyPair.mlkemPublicKey!
        )

        // Scan using memo data format
        let detected = try scanner.scanFromMemo(
            stealthAddress: stealthResult.stealthAddress,
            memoData: stealthResult.memoData
        )

        XCTAssertNotNil(detected)
        XCTAssertEqual(detected?.stealthAddress, stealthResult.stealthAddress)
    }

    func testScanFromMemoClassical() throws {
        let receiverKeyPair = try StealthKeyPair.generate(withPostQuantum: false)
        let scanner = StealthScanner(keyPair: receiverKeyPair)

        let stealthResult = try StealthAddressGenerator.generateStealthAddress(
            metaAddressString: receiverKeyPair.metaAddressString
        )

        // Scan using memo data format (classical = just ephemeral key)
        let detected = try scanner.scanFromMemo(
            stealthAddress: stealthResult.stealthAddress,
            memoData: stealthResult.memoData
        )

        XCTAssertNotNil(detected)
        XCTAssertEqual(detected?.stealthAddress, stealthResult.stealthAddress)
    }

    // MARK: - Complete Hybrid Protocol Roundtrip

    func testCompleteHybridProtocolRoundtrip() throws {
        // Step 1: Receiver generates hybrid stealth keypair
        let receiverKeyPair = try StealthKeyPair.generate(withPostQuantum: true)
        let hybridMetaAddress = receiverKeyPair.hybridMetaAddressString

        // Step 2: Sender generates hybrid stealth address from meta-address
        let stealthResult = try StealthAddressGenerator.generateStealthAddressAuto(
            metaAddressString: hybridMetaAddress
        )

        XCTAssertTrue(stealthResult.isHybrid, "Should use hybrid mode")

        // Step 3: Receiver scans and detects payment using memo data
        let scanner = StealthScanner(keyPair: receiverKeyPair)
        let detected = try scanner.scanFromMemo(
            stealthAddress: stealthResult.stealthAddress,
            memoData: stealthResult.memoData
        )

        XCTAssertNotNil(detected)

        // Step 4: Verify derived spending key produces correct public key
        guard let derivedPubKey = SodiumWrapper.scalarMultBaseNoclamp(
            detected!.spendingPrivateKey
        ) else {
            XCTFail("Failed to derive public key")
            return
        }

        XCTAssertEqual(derivedPubKey, stealthResult.stealthPublicKey)
        XCTAssertEqual(detected!.stealthAddress, stealthResult.stealthAddress)
    }

    func testBackwardsCompatibilityWithClassical() throws {
        // Classical sender, classical receiver
        let classicalReceiver = try StealthKeyPair.generate(withPostQuantum: false)

        let stealthResult = try StealthAddressGenerator.generateStealthAddress(
            metaAddressString: classicalReceiver.metaAddressString
        )

        XCTAssertFalse(stealthResult.isHybrid)

        let scanner = StealthScanner(keyPair: classicalReceiver)
        let detected = try scanner.scanTransaction(
            stealthAddress: stealthResult.stealthAddress,
            ephemeralPublicKey: stealthResult.ephemeralPublicKey
        )

        XCTAssertNotNil(detected)
        XCTAssertFalse(detected!.isHybrid)
    }

    func testHybridDerivedKeyCanSign() throws {
        let receiverKeyPair = try StealthKeyPair.generate(withPostQuantum: true)
        let scanner = StealthScanner(keyPair: receiverKeyPair)

        let stealthResult = try StealthAddressGenerator.generateHybridStealthAddress(
            spendingPublicKey: receiverKeyPair.spendingPublicKey,
            viewingPublicKey: receiverKeyPair.viewingPublicKey,
            mlkemPublicKey: receiverKeyPair.mlkemPublicKey!
        )

        let detected = try scanner.scanHybridTransaction(
            stealthAddress: stealthResult.stealthAddress,
            ephemeralPublicKey: stealthResult.ephemeralPublicKey,
            mlkemCiphertext: stealthResult.mlkemCiphertext!
        )!

        // Verify the derived private key produces the correct public key
        guard let derivedPubKey = SodiumWrapper.scalarMultBaseNoclamp(
            detected.spendingPrivateKey
        ) else {
            XCTFail("Failed to derive public key from spending key")
            return
        }

        XCTAssertEqual(derivedPubKey, stealthResult.stealthPublicKey)
    }

    func testMultipleHybridPaymentsToSameReceiver() throws {
        let receiverKeyPair = try StealthKeyPair.generate(withPostQuantum: true)
        let scanner = StealthScanner(keyPair: receiverKeyPair)

        var detectedPayments: [DetectedStealthPayment] = []
        var stealthAddresses: Set<String> = []

        // Generate 5 hybrid payments to same receiver
        for _ in 0..<5 {
            let result = try StealthAddressGenerator.generateHybridStealthAddress(
                spendingPublicKey: receiverKeyPair.spendingPublicKey,
                viewingPublicKey: receiverKeyPair.viewingPublicKey,
                mlkemPublicKey: receiverKeyPair.mlkemPublicKey!
            )

            // Each stealth address should be unique
            XCTAssertFalse(stealthAddresses.contains(result.stealthAddress))
            stealthAddresses.insert(result.stealthAddress)

            // Scanner should detect each
            let detected = try scanner.scanHybridTransaction(
                stealthAddress: result.stealthAddress,
                ephemeralPublicKey: result.ephemeralPublicKey,
                mlkemCiphertext: result.mlkemCiphertext!
            )

            XCTAssertNotNil(detected)
            detectedPayments.append(detected!)
        }

        // All 5 payments detected with unique spending keys
        XCTAssertEqual(detectedPayments.count, 5)
        let uniqueKeys = Set(detectedPayments.map { $0.spendingPrivateKey.hexString })
        XCTAssertEqual(uniqueKeys.count, 5)
    }
}
