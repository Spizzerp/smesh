import XCTest
@testable import StealthCore

/// Tests for the mesh networking layer (Phase 3)
final class MeshLayerTests: XCTestCase {

    // MARK: - MeshPayload Tests

    func testMeshStealthPayloadCreation() {
        let payload = MeshStealthPayload(
            stealthAddress: "11111111111111111111111111111111",
            ephemeralPublicKey: Data(repeating: 0xAB, count: 32),
            mlkemCiphertext: nil,
            amount: 1_000_000_000,
            tokenMint: nil,
            viewTag: 42,
            memo: "Test payment"
        )

        XCTAssertEqual(payload.stealthAddress, "11111111111111111111111111111111")
        XCTAssertEqual(payload.ephemeralPublicKey.count, 32)
        XCTAssertNil(payload.mlkemCiphertext)
        XCTAssertEqual(payload.amount, 1_000_000_000)
        XCTAssertNil(payload.tokenMint)
        XCTAssertEqual(payload.viewTag, 42)
        XCTAssertEqual(payload.memo, "Test payment")
        XCTAssertFalse(payload.isHybrid)
    }

    func testMeshStealthPayloadHybridMode() {
        let payload = MeshStealthPayload(
            stealthAddress: "11111111111111111111111111111111",
            ephemeralPublicKey: Data(repeating: 0xAB, count: 32),
            mlkemCiphertext: Data(repeating: 0xCD, count: 1088),
            amount: 500_000_000,
            tokenMint: "TokenMintAddress123",
            viewTag: 100,
            memo: nil
        )

        XCTAssertTrue(payload.isHybrid)
        XCTAssertEqual(payload.mlkemCiphertext?.count, 1088)
        XCTAssertEqual(payload.tokenMint, "TokenMintAddress123")
    }

    func testMeshStealthPayloadEstimatedSize() {
        // Classical payload
        let classicalPayload = MeshStealthPayload(
            stealthAddress: "11111111111111111111111111111111",
            ephemeralPublicKey: Data(repeating: 0, count: 32),
            mlkemCiphertext: nil,
            amount: 100,
            tokenMint: nil,
            viewTag: 0,
            memo: nil
        )
        XCTAssertGreaterThan(classicalPayload.estimatedSize, 80)

        // Hybrid payload with MLKEM
        let hybridPayload = MeshStealthPayload(
            stealthAddress: "11111111111111111111111111111111",
            ephemeralPublicKey: Data(repeating: 0, count: 32),
            mlkemCiphertext: Data(repeating: 0, count: 1088),
            amount: 100,
            tokenMint: nil,
            viewTag: 0,
            memo: nil
        )
        XCTAssertGreaterThan(hybridPayload.estimatedSize, classicalPayload.estimatedSize + 1000)
    }

    func testMeshMessageCreation() throws {
        let payload = MeshStealthPayload(
            stealthAddress: "TestAddress123",
            ephemeralPublicKey: Data(repeating: 0xAA, count: 32),
            mlkemCiphertext: nil,
            amount: 100,
            tokenMint: nil,
            viewTag: 1,
            memo: nil
        )

        let message = try MeshMessage.stealthPayment(
            payload: payload,
            originPeerID: "peer-123",
            ttl: 5
        )

        XCTAssertEqual(message.type, .stealthPayment)
        XCTAssertEqual(message.ttl, 5)
        XCTAssertEqual(message.originPeerID, "peer-123")
        XCTAssertFalse(message.isExpired())
    }

    func testMeshMessageTTLClamping() throws {
        let payload = MeshStealthPayload(
            stealthAddress: "TestAddress",
            ephemeralPublicKey: Data(repeating: 0, count: 32),
            mlkemCiphertext: nil,
            amount: 1,
            tokenMint: nil,
            viewTag: 0,
            memo: nil
        )

        // TTL should be clamped to MAX_MESSAGE_TTL
        let message = try MeshMessage.stealthPayment(
            payload: payload,
            originPeerID: "peer",
            ttl: 100  // Way above MAX_MESSAGE_TTL (10)
        )

        XCTAssertEqual(message.ttl, MAX_MESSAGE_TTL)
    }

    func testMeshMessageForwarding() throws {
        let payload = MeshStealthPayload(
            stealthAddress: "TestAddress",
            ephemeralPublicKey: Data(repeating: 0, count: 32),
            mlkemCiphertext: nil,
            amount: 1,
            tokenMint: nil,
            viewTag: 0,
            memo: nil
        )

        let original = try MeshMessage.stealthPayment(
            payload: payload,
            originPeerID: "peer",
            ttl: 5
        )

        let forwarded = original.forwarded()
        XCTAssertNotNil(forwarded)
        XCTAssertEqual(forwarded!.ttl, 4)
        XCTAssertEqual(forwarded!.id, original.id)  // Same ID
        XCTAssertEqual(forwarded!.originPeerID, original.originPeerID)

        // Forward again
        let forwarded2 = forwarded!.forwarded()
        XCTAssertEqual(forwarded2!.ttl, 3)
    }

    func testMeshMessageTTLExhaustion() throws {
        let payload = MeshStealthPayload(
            stealthAddress: "TestAddress",
            ephemeralPublicKey: Data(repeating: 0, count: 32),
            mlkemCiphertext: nil,
            amount: 1,
            tokenMint: nil,
            viewTag: 0,
            memo: nil
        )

        let message = try MeshMessage.stealthPayment(
            payload: payload,
            originPeerID: "peer",
            ttl: 1
        )

        // Should not be forwardable with TTL=1
        let forwarded = message.forwarded()
        XCTAssertNil(forwarded)
    }

    func testMeshMessageSerialization() throws {
        let payload = MeshStealthPayload(
            stealthAddress: "TestStealth",
            ephemeralPublicKey: Data(repeating: 0xBB, count: 32),
            mlkemCiphertext: nil,
            amount: 999,
            tokenMint: nil,
            viewTag: 55,
            memo: "Hello"
        )

        let original = try MeshMessage.stealthPayment(
            payload: payload,
            originPeerID: "sender-peer",
            ttl: 7
        )

        // Serialize
        let data = try original.serialize()
        XCTAssertGreaterThan(data.count, 0)

        // Deserialize
        let decoded = try MeshMessage.deserialize(from: data)

        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.type, original.type)
        XCTAssertEqual(decoded.ttl, original.ttl)
        XCTAssertEqual(decoded.originPeerID, original.originPeerID)

        // Decode payload
        let decodedPayload = try decoded.decodeStealthPayload()
        XCTAssertEqual(decodedPayload.stealthAddress, payload.stealthAddress)
        XCTAssertEqual(decodedPayload.amount, payload.amount)
    }

    func testMeshMessageAcknowledgment() {
        let originalID = MessageID()
        let ack = MeshMessage.acknowledgment(
            forMessageID: originalID,
            originPeerID: "ack-peer"
        )

        XCTAssertEqual(ack.type, .acknowledgment)
        XCTAssertEqual(ack.ttl, 3)  // Acks have lower TTL
        XCTAssertEqual(ack.originPeerID, "ack-peer")
    }

    func testPeerCapabilities() {
        let defaultCaps = PeerCapabilities()
        XCTAssertTrue(defaultCaps.supportsHybrid)
        XCTAssertTrue(defaultCaps.canRelay)
        XCTAssertFalse(defaultCaps.hasConnectivity)
        XCTAssertEqual(defaultCaps.maxMessageSize, 4096)
        XCTAssertEqual(defaultCaps.protocolVersion, 1)

        let customCaps = PeerCapabilities(
            supportsHybrid: false,
            canRelay: false,
            hasConnectivity: true,
            maxMessageSize: 2048,
            protocolVersion: 2
        )
        XCTAssertFalse(customCaps.supportsHybrid)
        XCTAssertFalse(customCaps.canRelay)
        XCTAssertTrue(customCaps.hasConnectivity)
    }

    // MARK: - MeshNode Tests

    func testMeshNodeInitialization() async {
        let node = MeshNode()
        let peers = await node.getAllPeers()
        XCTAssertTrue(peers.isEmpty)

        let stats = await node.getStatistics()
        XCTAssertEqual(stats.messagesReceived, 0)
        XCTAssertEqual(stats.messagesSent, 0)
    }

    func testMeshNodeCustomPeerID() async {
        let node = MeshNode(peerID: "custom-peer-id")
        XCTAssertEqual(node.peerID, "custom-peer-id")
    }

    func testMeshNodeAddPeer() async {
        let node = MeshNode()

        let peer = MeshPeer(
            id: "peer-1",
            name: "Test Peer",
            rssi: -50,
            connectionState: .disconnected
        )

        await node.addPeer(peer)

        let peers = await node.getAllPeers()
        XCTAssertEqual(peers.count, 1)
        XCTAssertEqual(peers.first?.id, "peer-1")
        XCTAssertEqual(peers.first?.name, "Test Peer")

        let stats = await node.getStatistics()
        XCTAssertEqual(stats.peersDiscovered, 1)
    }

    func testMeshNodeUpdatePeer() async {
        let node = MeshNode()

        let peer = MeshPeer(
            id: "peer-1",
            name: "Test",
            rssi: -50,
            connectionState: .disconnected
        )
        await node.addPeer(peer)

        await node.updatePeer(id: "peer-1") { peer in
            peer.connectionState = .connected
        }

        let updated = await node.getPeer(id: "peer-1")
        XCTAssertEqual(updated?.connectionState, .connected)
    }

    func testMeshNodeRemovePeer() async {
        let node = MeshNode()

        let peer = MeshPeer(id: "peer-1", name: "Test", rssi: -50, connectionState: .disconnected)
        await node.addPeer(peer)

        let peersBeforeRemove = await node.getAllPeers()
        XCTAssertEqual(peersBeforeRemove.count, 1)

        await node.removePeer(id: "peer-1")

        let peersAfterRemove = await node.getAllPeers()
        XCTAssertEqual(peersAfterRemove.count, 0)
    }

    func testMeshNodeGetConnectedPeers() async {
        let node = MeshNode()

        let peer1 = MeshPeer(id: "peer-1", connectionState: .connected)
        let peer2 = MeshPeer(id: "peer-2", connectionState: .disconnected)
        let peer3 = MeshPeer(id: "peer-3", connectionState: .connected)

        await node.addPeer(peer1)
        await node.addPeer(peer2)
        await node.addPeer(peer3)

        let connected = await node.getConnectedPeers()
        XCTAssertEqual(connected.count, 2)
    }

    func testMeshNodeProcessDuplicateMessage() async throws {
        let node = MeshNode()

        let payload = MeshStealthPayload(
            stealthAddress: "TestAddress",
            ephemeralPublicKey: Data(repeating: 0, count: 32),
            mlkemCiphertext: nil,
            amount: 1,
            tokenMint: nil,
            viewTag: 0,
            memo: nil
        )
        let message = try MeshMessage.stealthPayment(payload: payload, originPeerID: "sender")

        // First process should work
        let result1 = await node.processIncomingMessage(message)
        XCTAssertNotEqual(result1, .duplicate)

        // Second process of same message should be duplicate
        let result2 = await node.processIncomingMessage(message)
        XCTAssertEqual(result2, .duplicate)

        let stats = await node.getStatistics()
        XCTAssertEqual(stats.duplicatesFiltered, 1)
    }

    func testMeshNodeProcessExpiredMessage() async throws {
        let node = MeshNode()

        let payload = MeshStealthPayload(
            stealthAddress: "TestAddress",
            ephemeralPublicKey: Data(repeating: 0, count: 32),
            mlkemCiphertext: nil,
            amount: 1,
            tokenMint: nil,
            viewTag: 0,
            memo: nil
        )

        // Create message with old timestamp
        let oldDate = Date().addingTimeInterval(-7200)  // 2 hours ago
        let message = MeshMessage(
            type: .stealthPayment,
            ttl: 5,
            originPeerID: "sender",
            createdAt: oldDate,
            payload: try JSONEncoder().encode(payload)
        )

        let result = await node.processIncomingMessage(message)
        XCTAssertEqual(result, .expired)

        let stats = await node.getStatistics()
        XCTAssertEqual(stats.messagesDropped, 1)
    }

    func testMeshNodeStatistics() async {
        let node = MeshNode()

        await node.recordMessageSent(bytes: 100)
        await node.recordMessageSent(bytes: 200)
        await node.recordMessageRelayed()
        await node.recordBytesReceived(50)

        let stats = await node.getStatistics()
        XCTAssertEqual(stats.messagesSent, 2)
        XCTAssertEqual(stats.bytesSent, 300)
        XCTAssertEqual(stats.messagesRelayed, 1)
        XCTAssertEqual(stats.bytesReceived, 50)
    }

    func testMeshNodeQueueMessage() async throws {
        let node = MeshNode()

        let payload = MeshStealthPayload(
            stealthAddress: "TestAddress",
            ephemeralPublicKey: Data(repeating: 0, count: 32),
            mlkemCiphertext: nil,
            amount: 1,
            tokenMint: nil,
            viewTag: 0,
            memo: nil
        )
        let message = try MeshMessage.stealthPayment(payload: payload, originPeerID: "sender")

        await node.queueMessage(message)

        let pending = await node.getPendingMessages(forPeer: "any")
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.id, message.id)
    }

    // MARK: - MeshPeer Tests

    func testMeshPeerIsConnected() {
        let disconnected = MeshPeer(id: "1", connectionState: .disconnected)
        XCTAssertFalse(disconnected.isConnected)

        let connecting = MeshPeer(id: "2", connectionState: .connecting)
        XCTAssertFalse(connecting.isConnected)

        let connected = MeshPeer(id: "3", connectionState: .connected)
        XCTAssertTrue(connected.isConnected)
    }

    func testMeshPeerIsStale() {
        var peer = MeshPeer(id: "1", connectionState: .disconnected)

        // Just created, shouldn't be stale
        XCTAssertFalse(peer.isStale(timeout: 30))

        // Mark seen updates timestamp
        peer.markSeen()
        XCTAssertFalse(peer.isStale(timeout: 30))
    }

    // MARK: - MessageRelay Tests

    func testMessageRelayConfiguration() {
        let defaultConfig = RelayConfiguration.default
        XCTAssertEqual(defaultConfig.maxStoredMessages, 100)
        XCTAssertEqual(defaultConfig.messageExpiry, 3600)
        XCTAssertTrue(defaultConfig.enableRelay)

        let lowPowerConfig = RelayConfiguration.lowPower
        XCTAssertEqual(lowPowerConfig.maxStoredMessages, 50)
        XCTAssertEqual(lowPowerConfig.messageExpiry, 1800)

        let aggressiveConfig = RelayConfiguration.aggressive
        XCTAssertEqual(aggressiveConfig.maxStoredMessages, 200)
        XCTAssertEqual(aggressiveConfig.maxMessagesPerCycle, 20)
    }

    func testMessageRelayStoreMessage() async throws {
        let node = MeshNode()
        let relay = MessageRelay(meshNode: node)

        let payload = MeshStealthPayload(
            stealthAddress: "TestAddress",
            ephemeralPublicKey: Data(repeating: 0, count: 32),
            mlkemCiphertext: nil,
            amount: 100,
            tokenMint: nil,
            viewTag: 1,
            memo: nil
        )
        let message = try MeshMessage.stealthPayment(payload: payload, originPeerID: "sender")

        await relay.storeMessage(message)

        let stored = await relay.getMessage(id: message.id)
        XCTAssertNotNil(stored)
        XCTAssertEqual(stored?.id, message.id)
    }

    func testMessageRelayDuplicateNotStored() async throws {
        let node = MeshNode()
        let relay = MessageRelay(meshNode: node)

        let payload = MeshStealthPayload(
            stealthAddress: "TestAddress",
            ephemeralPublicKey: Data(repeating: 0, count: 32),
            mlkemCiphertext: nil,
            amount: 100,
            tokenMint: nil,
            viewTag: 1,
            memo: nil
        )
        let message = try MeshMessage.stealthPayment(payload: payload, originPeerID: "sender")

        await relay.storeMessage(message)
        await relay.storeMessage(message)  // Try to store again

        let allStored = await relay.getAllStoredMessages()
        XCTAssertEqual(allStored.count, 1)
    }

    func testMessageRelayMarkAcknowledged() async throws {
        let node = MeshNode()
        let relay = MessageRelay(meshNode: node)

        let payload = MeshStealthPayload(
            stealthAddress: "TestAddress",
            ephemeralPublicKey: Data(repeating: 0, count: 32),
            mlkemCiphertext: nil,
            amount: 100,
            tokenMint: nil,
            viewTag: 1,
            memo: nil
        )
        let message = try MeshMessage.stealthPayment(payload: payload, originPeerID: "sender")

        await relay.storeMessage(message)
        let storedMessage = await relay.getMessage(id: message.id)
        XCTAssertNotNil(storedMessage)

        await relay.markAcknowledged(id: message.id)

        // Message should be removed after acknowledgment
        let removedMessage = await relay.getMessage(id: message.id)
        XCTAssertNil(removedMessage)
    }

    func testMessageRelayGetMessagesForRelay() async throws {
        let node = MeshNode()
        let relay = MessageRelay(meshNode: node)

        // Store some messages
        for i in 0..<5 {
            let payload = MeshStealthPayload(
                stealthAddress: "Address\(i)",
                ephemeralPublicKey: Data(repeating: UInt8(i), count: 32),
                mlkemCiphertext: nil,
                amount: UInt64(i * 100),
                tokenMint: nil,
                viewTag: UInt8(i),
                memo: nil
            )
            let message = try MeshMessage.stealthPayment(payload: payload, originPeerID: "sender")
            await relay.storeMessage(message)
        }

        let forRelay = await relay.getMessagesForRelay()
        XCTAssertGreaterThan(forRelay.count, 0)
        XCTAssertLessThanOrEqual(forRelay.count, 10)  // Default maxMessagesPerCycle
    }

    func testMessageRelayStatistics() async throws {
        let node = MeshNode()
        let relay = MessageRelay(meshNode: node)

        let payload = MeshStealthPayload(
            stealthAddress: "TestAddress",
            ephemeralPublicKey: Data(repeating: 0, count: 32),
            mlkemCiphertext: nil,
            amount: 100,
            tokenMint: nil,
            viewTag: 1,
            memo: nil
        )
        let message = try MeshMessage.stealthPayment(payload: payload, originPeerID: "sender")
        await relay.storeMessage(message)

        let stats = await relay.getStatistics()
        XCTAssertEqual(stats.storedMessageCount, 1)
    }

    // MARK: - MeshError Tests

    func testMeshErrorDescriptions() {
        XCTAssertNotNil(MeshError.invalidMessageType.errorDescription)
        XCTAssertNotNil(MeshError.payloadTooLarge(size: 5000, max: 4096).errorDescription)
        XCTAssertNotNil(MeshError.ttlExhausted.errorDescription)
        XCTAssertNotNil(MeshError.bluetoothUnavailable.errorDescription)
        XCTAssertNotNil(MeshError.peerNotFound("test-peer").errorDescription)
    }

    // MARK: - Service UUID Constants

    func testMeshServiceUUIDs() {
        XCTAssertFalse(MESH_SERVICE_UUID.isEmpty)
        XCTAssertFalse(MESH_MESSAGE_CHARACTERISTIC_UUID.isEmpty)
        XCTAssertFalse(MESH_DISCOVERY_CHARACTERISTIC_UUID.isEmpty)

        // UUIDs should be valid format
        XCTAssertTrue(MESH_SERVICE_UUID.contains("-"))
        XCTAssertEqual(MESH_SERVICE_UUID.count, 36)  // Standard UUID length with dashes
    }

    // MARK: - Integration Tests

    func testEndToEndMessageFlow() async throws {
        // Simulate a complete message flow from sender to relay to receiver

        // 1. Sender creates stealth address result
        let receiver = try StealthKeyPair.generate()
        let result = try StealthAddressGenerator.generateStealthAddress(
            spendingPublicKey: receiver.spendingPublicKey,
            viewingPublicKey: receiver.viewingPublicKey
        )

        // 2. Create mesh payload
        let payload = MeshStealthPayload(
            from: result,
            amount: 500_000_000,  // 0.5 SOL
            tokenMint: nil,
            memo: "Test mesh payment"
        )

        // 3. Wrap in mesh message
        let message = try MeshMessage.stealthPayment(
            payload: payload,
            originPeerID: "sender-device-123",
            ttl: 5
        )

        // 4. Relay node receives and processes
        let relayNode = MeshNode(peerID: "relay-node-456")
        let processResult = await relayNode.processIncomingMessage(message)

        // Should want to relay (TTL > 1)
        if case .relay(let forwardMessage) = processResult {
            XCTAssertEqual(forwardMessage.ttl, 4)
            XCTAssertEqual(forwardMessage.id, message.id)

            // 5. Receiver node gets the relayed message
            let receiverNode = MeshNode(peerID: "receiver-device-789")
            let receiveResult = await receiverNode.processIncomingMessage(forwardMessage)

            if case .relay(let finalMessage) = receiveResult {
                XCTAssertEqual(finalMessage.ttl, 3)

                // Decode and verify payload integrity
                let decodedPayload = try finalMessage.decodeStealthPayload()
                XCTAssertEqual(decodedPayload.stealthAddress, result.stealthAddress)
                XCTAssertEqual(decodedPayload.amount, 500_000_000)
            } else if case .processed = receiveResult {
                // Also acceptable
            }
        } else if case .processed = processResult {
            // Message was processed without relay (acceptable)
        } else {
            XCTFail("Unexpected process result: \(processResult)")
        }
    }
}
