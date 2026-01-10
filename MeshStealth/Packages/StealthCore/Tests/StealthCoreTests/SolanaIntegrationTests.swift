import XCTest
@testable import StealthCore

/// Integration tests for Solana RPC client and stealth-pq program
/// Note: These tests require network access to devnet
final class SolanaIntegrationTests: XCTestCase {

    // MARK: - RPC Client Tests

    func testSolanaRPCClientInit() {
        // Test initialization with different clusters
        let devnetClient = SolanaRPCClient(cluster: .devnet)
        XCTAssertNotNil(devnetClient)

        let mainnetClient = SolanaRPCClient(cluster: .mainnetBeta)
        XCTAssertNotNil(mainnetClient)

        let customClient = SolanaRPCClient(url: URL(string: "https://rpc.helius.xyz")!)
        XCTAssertNotNil(customClient)
    }

    func testLamportsToSolConversion() {
        XCTAssertEqual(SolanaRPCClient.lamportsToSol(1_000_000_000), 1.0)
        XCTAssertEqual(SolanaRPCClient.lamportsToSol(500_000_000), 0.5)
        XCTAssertEqual(SolanaRPCClient.lamportsToSol(1), 0.000000001)
    }

    func testSolToLamportsConversion() {
        XCTAssertEqual(SolanaRPCClient.solToLamports(1.0), 1_000_000_000)
        XCTAssertEqual(SolanaRPCClient.solToLamports(0.5), 500_000_000)
        XCTAssertEqual(SolanaRPCClient.solToLamports(0.000000001), 1)
    }

    func testPublicKeyValidation() {
        // Valid 32-byte Base58 public key
        let validKey = "11111111111111111111111111111111"  // System program
        XCTAssertTrue(SolanaRPCClient.isValidPublicKey(validKey))

        // Invalid keys
        XCTAssertFalse(SolanaRPCClient.isValidPublicKey("invalid"))
        XCTAssertFalse(SolanaRPCClient.isValidPublicKey(""))
        XCTAssertFalse(SolanaRPCClient.isValidPublicKey("abc123"))
    }

    func testDecodePublicKey() throws {
        let systemProgram = "11111111111111111111111111111111"
        let decoded = try SolanaRPCClient.decodePublicKey(systemProgram)
        XCTAssertEqual(decoded.count, 32)
        // System program decodes successfully - that's all we need to verify
    }

    func testEncodePublicKey() {
        let zeros = Data(repeating: 0, count: 32)
        let encoded = SolanaRPCClient.encodePublicKey(zeros)
        XCTAssertEqual(encoded, "11111111111111111111111111111111")
    }

    // MARK: - StealthPQ Client Tests

    func testStealthPQProgramID() {
        XCTAssertEqual(STEALTH_PQ_PROGRAM_ID, "5YXYyH7i9WnQz1Hzh8kEuxSU5ws3n1Kor2KdTxnJkv6y")
    }

    func testDeriveCiphertextPDA() throws {
        // Test PDA derivation with a known stealth address
        let testStealthAddress = "11111111111111111111111111111111"
        let stealthPubkey = try SolanaRPCClient.decodePublicKey(testStealthAddress)

        let (pdaAddress, bump) = try StealthPQClient.deriveCiphertextPDA(
            stealthPubkey: stealthPubkey,
            programId: STEALTH_PQ_PROGRAM_ID
        )

        // PDA should be a valid Base58 address
        XCTAssertTrue(SolanaRPCClient.isValidPublicKey(pdaAddress))

        // Bump should be in valid range
        XCTAssertLessThanOrEqual(bump, 255)
    }

    func testBuildInitCiphertextData() {
        let ephemeralPubkey = Data(repeating: 0xAB, count: 32)
        let ciphertextPart1 = Data(repeating: 0xCD, count: 512)

        let instructionData = StealthPQClient.buildInitCiphertextData(
            ephemeralPubkey: ephemeralPubkey,
            ciphertextPart1: ciphertextPart1
        )

        // 8 (discriminator) + 32 (ephemeral) + 4 (vec length) + 512 (data) = 556 bytes
        XCTAssertEqual(instructionData.count, 556)

        // Check discriminator is present (first 8 bytes)
        let discriminator = instructionData.prefix(8)
        XCTAssertEqual(discriminator.count, 8)
    }

    func testBuildCompleteCiphertextData() {
        let ciphertextPart2 = Data(repeating: 0xEF, count: 576)
        let offset: UInt16 = 512

        let instructionData = StealthPQClient.buildCompleteCiphertextData(
            ciphertextPart2: ciphertextPart2,
            offset: offset
        )

        // 8 (discriminator) + 4 (vec length) + 576 (data) + 2 (offset) = 590 bytes
        XCTAssertEqual(instructionData.count, 590)
    }

    func testBuildTransferToStealthData() {
        let lamports: UInt64 = 1_000_000_000  // 1 SOL

        let instructionData = StealthPQClient.buildTransferToStealthData(lamports: lamports)

        // 8 (discriminator) + 8 (lamports) = 16 bytes
        XCTAssertEqual(instructionData.count, 16)

        // Verify lamports encoding (little-endian after discriminator)
        let lamportsData = instructionData.suffix(8)
        let decodedLamports = lamportsData.withUnsafeBytes { $0.load(as: UInt64.self) }
        XCTAssertEqual(decodedLamports, lamports)
    }

    func testBuildReclaimRentData() {
        let instructionData = StealthPQClient.buildReclaimRentData()

        // Just discriminator (8 bytes)
        XCTAssertEqual(instructionData.count, 8)
    }

    func testCiphertextAccountDataParsing() {
        // Build a mock account data matching the on-chain format
        // [8 discriminator] + [32 stealth_pubkey] + [32 ephemeral] + [1088 ciphertext] + [8 timestamp] + [1 bump]
        var mockData = Data(repeating: 0, count: 1169)

        // Set discriminator (first 8 bytes)
        let discriminator = Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08])
        mockData.replaceSubrange(0..<8, with: discriminator)

        // Set stealth pubkey (bytes 8-40)
        let stealthPubkey = Data(repeating: 0xAA, count: 32)
        mockData.replaceSubrange(8..<40, with: stealthPubkey)

        // Set ephemeral pubkey (bytes 40-72)
        let ephemeralPubkey = Data(repeating: 0xBB, count: 32)
        mockData.replaceSubrange(40..<72, with: ephemeralPubkey)

        // Set ciphertext (bytes 72-1160)
        let ciphertext = Data(repeating: 0xCC, count: 1088)
        mockData.replaceSubrange(72..<1160, with: ciphertext)

        // Set timestamp (bytes 1160-1168) - use a known value
        var timestamp: Int64 = 1704067200  // 2024-01-01 00:00:00 UTC
        withUnsafeBytes(of: &timestamp) { bytes in
            mockData.replaceSubrange(1160..<1168, with: bytes)
        }

        // Set bump (byte 1168)
        mockData[1168] = 254

        // Parse the data
        let parsed = CiphertextAccountData.parse(from: mockData)

        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed!.stealthPubkey, stealthPubkey)
        XCTAssertEqual(parsed!.ephemeralPubkey, ephemeralPubkey)
        XCTAssertEqual(parsed!.mlkemCiphertext, ciphertext)
        XCTAssertEqual(parsed!.createdAt, timestamp)
        XCTAssertEqual(parsed!.bump, 254)
    }

    func testCiphertextAccountDataParsingTooShort() {
        // Data that's too short should return nil
        let shortData = Data(repeating: 0, count: 100)
        XCTAssertNil(CiphertextAccountData.parse(from: shortData))
    }

    // MARK: - Network Tests (require devnet access)

    func testDevnetGetBalance() async throws {
        let client = SolanaRPCClient(cluster: .devnet)

        // System program should have 0 balance (it's a program, not an account)
        let systemProgram = "11111111111111111111111111111111"
        let balance = try await client.getBalance(pubkey: systemProgram)

        // System program address should have 0 or very small balance
        // (We just verify we can make the RPC call)
        XCTAssertGreaterThanOrEqual(balance, 0)
    }

    func testDevnetGetLatestBlockhash() async throws {
        let client = SolanaRPCClient(cluster: .devnet)

        let blockhash = try await client.getLatestBlockhash()

        // Blockhash should be a valid Base58 string
        XCTAssertFalse(blockhash.blockhash.isEmpty)
        XCTAssertGreaterThan(blockhash.lastValidBlockHeight, 0)
    }

    func testDevnetGetAccountInfo() async throws {
        let client = SolanaRPCClient(cluster: .devnet)

        // Query the stealth-pq program account
        let programInfo = try await client.getAccountInfo(pubkey: STEALTH_PQ_PROGRAM_ID)

        XCTAssertNotNil(programInfo)
        XCTAssertTrue(programInfo!.executable)  // Programs are executable
        XCTAssertEqual(programInfo!.owner, "BPFLoaderUpgradeab1e11111111111111111111111")
    }

    func testDevnetGetSignaturesForAddress() async throws {
        let client = SolanaRPCClient(cluster: .devnet)

        // Get recent signatures for the stealth-pq program
        let signatures = try await client.getSignaturesForAddress(
            address: STEALTH_PQ_PROGRAM_ID,
            limit: 10
        )

        // We should have at least some transactions from our tests
        // (Even if empty, the call should succeed)
        XCTAssertNotNil(signatures)
    }

    // MARK: - Integration Flow Tests

    func testEndToEndPDADerivation() async throws {
        // Generate a test stealth keypair
        let receiver = try StealthKeyPair.generate()

        // Generate a stealth address
        let result = try StealthAddressGenerator.generateStealthAddress(
            spendingPublicKey: receiver.spendingPublicKey,
            viewingPublicKey: receiver.viewingPublicKey
        )

        // Derive PDA for this stealth address
        let (pdaAddress, bump) = try StealthPQClient.deriveCiphertextPDA(
            stealthPubkey: result.stealthPublicKey,
            programId: STEALTH_PQ_PROGRAM_ID
        )

        XCTAssertTrue(SolanaRPCClient.isValidPublicKey(pdaAddress))
        XCTAssertLessThanOrEqual(bump, 255)

        // The PDA should be deterministic - same inputs = same outputs
        let (pdaAddress2, bump2) = try StealthPQClient.deriveCiphertextPDA(
            stealthPubkey: result.stealthPublicKey,
            programId: STEALTH_PQ_PROGRAM_ID
        )

        XCTAssertEqual(pdaAddress, pdaAddress2)
        XCTAssertEqual(bump, bump2)
    }

    func testBlockchainScannerInit() async {
        let rpcClient = SolanaRPCClient(cluster: .devnet)
        let keyPair = try! StealthKeyPair.generate()
        let stealthScanner = StealthScanner(keyPair: keyPair)

        let blockchainScanner = BlockchainScanner(
            rpcClient: rpcClient,
            stealthScanner: stealthScanner
        )

        // Scanner should be initialized
        XCTAssertNotNil(blockchainScanner)
    }
}
