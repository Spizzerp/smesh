import Foundation
import CryptoKit

/// Unique identifier for mesh messages
public typealias MessageID = UUID

/// Maximum TTL for mesh messages (prevents infinite relay)
public let MAX_MESSAGE_TTL: UInt8 = 10

/// Default TTL for new messages
public let DEFAULT_MESSAGE_TTL: UInt8 = 5

/// Service UUID for stealth mesh BLE service
public let MESH_SERVICE_UUID = "7E57EA17-1234-5678-9ABC-DEF012345678"

/// Characteristic UUID for mesh message exchange
public let MESH_MESSAGE_CHARACTERISTIC_UUID = "7E57EA17-1234-5678-9ABC-DEF012345679"

/// Characteristic UUID for peer discovery/handshake
public let MESH_DISCOVERY_CHARACTERISTIC_UUID = "7E57EA17-1234-5678-9ABC-DEF01234567A"

// MARK: - Mesh Stealth Payload

/// Protocol version for MeshStealthPayload
/// - Version 1: Original format (sender settles)
/// - Version 2: Pre-signed transaction support (receiver can settle)
public enum MeshPayloadProtocolVersion: Int, Codable, Sendable {
    case v1 = 1  // Original: sender settles when online
    case v2 = 2  // Pre-signed tx: receiver can settle

    public static let current: MeshPayloadProtocolVersion = .v2
}

/// Payload for stealth payment transmitted over mesh network
/// Contains all data needed for recipient to claim funds when online
public struct MeshStealthPayload: Codable, Sendable, Equatable {
    /// Base58-encoded stealth address (destination)
    public let stealthAddress: String

    /// Ephemeral X25519 public key (32 bytes)
    public let ephemeralPublicKey: Data

    /// MLKEM768 ciphertext (1,088 bytes) - nil for classical-only mode
    public let mlkemCiphertext: Data?

    /// Amount in lamports (for SOL) or smallest unit (for SPL tokens)
    public let amount: UInt64

    /// SPL token mint address (nil for native SOL)
    public let tokenMint: String?

    /// View tag for quick filtering (first byte of hashed secret)
    public let viewTag: UInt8

    /// Sender-provided memo (optional, for recipient context)
    public let memo: String?

    // MARK: - Pre-Signed Transaction Support (v2)

    /// Protocol version (1 = sender settles, 2 = supports receiver settlement)
    public let protocolVersion: MeshPayloadProtocolVersion

    /// Pre-signed transaction (base64 encoded) that receiver can broadcast
    /// Only present in v2 payloads when sender had a durable nonce available
    public let preSignedTransaction: String?

    /// Nonce account address used for the pre-signed transaction
    /// Receiver uses this to track which nonce was consumed
    public let nonceAccountAddress: String?

    /// When the pre-signed transaction was created
    /// Helps receiver decide if tx might have been superseded
    public let preSignedAt: Date?

    public init(
        stealthAddress: String,
        ephemeralPublicKey: Data,
        mlkemCiphertext: Data? = nil,
        amount: UInt64,
        tokenMint: String? = nil,
        viewTag: UInt8,
        memo: String? = nil,
        protocolVersion: MeshPayloadProtocolVersion = .v1,
        preSignedTransaction: String? = nil,
        nonceAccountAddress: String? = nil,
        preSignedAt: Date? = nil
    ) {
        self.stealthAddress = stealthAddress
        self.ephemeralPublicKey = ephemeralPublicKey
        self.mlkemCiphertext = mlkemCiphertext
        self.amount = amount
        self.tokenMint = tokenMint
        self.viewTag = viewTag
        self.memo = memo
        self.protocolVersion = protocolVersion
        self.preSignedTransaction = preSignedTransaction
        self.nonceAccountAddress = nonceAccountAddress
        self.preSignedAt = preSignedAt
    }

    /// Create from a StealthAddressResult
    public init(
        from result: StealthAddressResult,
        amount: UInt64,
        tokenMint: String? = nil,
        memo: String? = nil,
        preSignedTransaction: String? = nil,
        nonceAccountAddress: String? = nil
    ) {
        self.stealthAddress = result.stealthAddress
        self.ephemeralPublicKey = result.ephemeralPublicKey
        self.mlkemCiphertext = result.mlkemCiphertext
        self.amount = amount
        self.tokenMint = tokenMint
        self.viewTag = result.viewTag
        self.memo = memo

        // Set v2 fields based on whether pre-signed tx is provided
        if preSignedTransaction != nil {
            self.protocolVersion = .v2
            self.preSignedTransaction = preSignedTransaction
            self.nonceAccountAddress = nonceAccountAddress
            self.preSignedAt = Date()
        } else {
            self.protocolVersion = .v1
            self.preSignedTransaction = nil
            self.nonceAccountAddress = nil
            self.preSignedAt = nil
        }
    }

    /// Whether this payload uses hybrid (post-quantum) mode
    public var isHybrid: Bool {
        mlkemCiphertext != nil
    }

    /// Whether this payload supports receiver settlement
    /// Receiver can broadcast the pre-signed transaction when they come online
    public var supportsReceiverSettlement: Bool {
        protocolVersion == .v2 && preSignedTransaction != nil
    }

    /// Estimated size in bytes when serialized
    public var estimatedSize: Int {
        var size = 44 + 32 + 8 + 1  // stealthAddress + ephemeral + amount + viewTag
        if let ciphertext = mlkemCiphertext {
            size += ciphertext.count
        }
        if let mint = tokenMint {
            size += mint.count
        }
        if let memo = memo {
            size += memo.utf8.count
        }
        return size
    }
}

// MARK: - Mesh Message Envelope

/// Type of mesh message
public enum MeshMessageType: UInt8, Codable, Sendable {
    /// Stealth payment payload
    case stealthPayment = 1

    /// Acknowledgment of received message
    case acknowledgment = 2

    /// Peer discovery announcement
    case discovery = 3

    /// Heartbeat/keepalive
    case heartbeat = 4

    /// Request peer's meta-address for payment
    case metaAddressRequest = 5

    /// Response with meta-address
    case metaAddressResponse = 6

    // MARK: - Chat Message Types

    /// Request to start encrypted chat session
    case chatRequest = 10

    /// Accept chat session request
    case chatAccept = 11

    /// Decline chat session request
    case chatDecline = 12

    /// Encrypted chat message
    case chatMessage = 13

    /// End chat session
    case chatEnd = 15
}

// MARK: - Meta-Address Exchange Payloads

/// Request for a peer's meta-address (for proximity-based payment initiation)
public struct MetaAddressRequest: Codable, Sendable, Equatable {
    /// Requester's peer ID
    public let requesterPeerID: String

    /// Requester's display name (optional)
    public let requesterName: String?

    /// Whether requester prefers hybrid (PQ) meta-address
    public let preferHybrid: Bool

    public init(
        requesterPeerID: String,
        requesterName: String? = nil,
        preferHybrid: Bool = true
    ) {
        self.requesterPeerID = requesterPeerID
        self.requesterName = requesterName
        self.preferHybrid = preferHybrid
    }
}

/// Response containing a meta-address
public struct MetaAddressResponse: Codable, Sendable, Equatable {
    /// Responder's peer ID
    public let responderPeerID: String

    /// Responder's display name (optional)
    public let responderName: String?

    /// The meta-address (classical or hybrid based on request)
    public let metaAddress: String

    /// Whether this is a hybrid (PQ) meta-address
    public let isHybrid: Bool

    public init(
        responderPeerID: String,
        responderName: String? = nil,
        metaAddress: String,
        isHybrid: Bool
    ) {
        self.responderPeerID = responderPeerID
        self.responderName = responderName
        self.metaAddress = metaAddress
        self.isHybrid = isHybrid
    }
}

/// Envelope wrapping mesh payloads with routing metadata
public struct MeshMessage: Codable, Sendable, Identifiable {
    /// Unique message identifier (for deduplication)
    public let id: MessageID

    /// Message type
    public let type: MeshMessageType

    /// Time-to-live: decremented on each hop, dropped when 0
    public var ttl: UInt8

    /// Original sender's peer ID (for acknowledgments)
    public let originPeerID: String

    /// Timestamp when message was created
    public let createdAt: Date

    /// The actual payload (JSON-encoded MeshStealthPayload for stealth payments)
    public let payload: Data

    /// Digital signature of payload by origin peer (optional)
    public let signature: Data?

    public init(
        id: MessageID = MessageID(),
        type: MeshMessageType,
        ttl: UInt8 = DEFAULT_MESSAGE_TTL,
        originPeerID: String,
        createdAt: Date = Date(),
        payload: Data,
        signature: Data? = nil
    ) {
        self.id = id
        self.type = type
        self.ttl = min(ttl, MAX_MESSAGE_TTL)
        self.originPeerID = originPeerID
        self.createdAt = createdAt
        self.payload = payload
        self.signature = signature
    }

    /// Create a stealth payment message
    public static func stealthPayment(
        payload: MeshStealthPayload,
        originPeerID: String,
        ttl: UInt8 = DEFAULT_MESSAGE_TTL
    ) throws -> MeshMessage {
        let encoder = JSONEncoder()
        let payloadData = try encoder.encode(payload)

        return MeshMessage(
            type: .stealthPayment,
            ttl: ttl,
            originPeerID: originPeerID,
            payload: payloadData
        )
    }

    /// Create an acknowledgment message
    public static func acknowledgment(
        forMessageID messageID: MessageID,
        originPeerID: String
    ) -> MeshMessage {
        let ackData = messageID.uuidString.data(using: .utf8) ?? Data()

        return MeshMessage(
            type: .acknowledgment,
            ttl: 3,  // Acks don't need to travel far
            originPeerID: originPeerID,
            payload: ackData
        )
    }

    /// Create a discovery announcement
    public static func discovery(
        peerID: String,
        capabilities: PeerCapabilities
    ) throws -> MeshMessage {
        let encoder = JSONEncoder()
        let capData = try encoder.encode(capabilities)

        return MeshMessage(
            type: .discovery,
            ttl: 1,  // Discovery is local only
            originPeerID: peerID,
            payload: capData
        )
    }

    /// Create a meta-address request message
    public static func metaAddressRequest(
        request: MetaAddressRequest
    ) throws -> MeshMessage {
        let encoder = JSONEncoder()
        let requestData = try encoder.encode(request)

        return MeshMessage(
            type: .metaAddressRequest,
            ttl: 1,  // Direct peer-to-peer only
            originPeerID: request.requesterPeerID,
            payload: requestData
        )
    }

    /// Create a meta-address response message
    public static func metaAddressResponse(
        response: MetaAddressResponse
    ) throws -> MeshMessage {
        let encoder = JSONEncoder()
        let responseData = try encoder.encode(response)

        return MeshMessage(
            type: .metaAddressResponse,
            ttl: 1,  // Direct peer-to-peer only
            originPeerID: response.responderPeerID,
            payload: responseData
        )
    }

    /// Decode the meta-address request payload
    public func decodeMetaAddressRequest() throws -> MetaAddressRequest {
        guard type == .metaAddressRequest else {
            throw MeshError.invalidMessageType
        }
        let decoder = JSONDecoder()
        return try decoder.decode(MetaAddressRequest.self, from: payload)
    }

    /// Decode the meta-address response payload
    public func decodeMetaAddressResponse() throws -> MetaAddressResponse {
        guard type == .metaAddressResponse else {
            throw MeshError.invalidMessageType
        }
        let decoder = JSONDecoder()
        return try decoder.decode(MetaAddressResponse.self, from: payload)
    }

    // MARK: - Chat Message Helpers

    /// Create a chat request message
    public static func chatRequest(
        request: ChatRequest,
        originPeerID: String
    ) throws -> MeshMessage {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let requestData = try encoder.encode(request)

        return MeshMessage(
            type: .chatRequest,
            ttl: 1,  // Direct peer-to-peer only
            originPeerID: originPeerID,
            payload: requestData
        )
    }

    /// Create a chat accept message
    public static func chatAccept(
        accept: ChatAccept,
        originPeerID: String
    ) throws -> MeshMessage {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let acceptData = try encoder.encode(accept)

        return MeshMessage(
            type: .chatAccept,
            ttl: 1,
            originPeerID: originPeerID,
            payload: acceptData
        )
    }

    /// Create a chat decline message
    public static func chatDecline(
        decline: ChatDecline,
        originPeerID: String
    ) throws -> MeshMessage {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let declineData = try encoder.encode(decline)

        return MeshMessage(
            type: .chatDecline,
            ttl: 1,
            originPeerID: originPeerID,
            payload: declineData
        )
    }

    /// Create an encrypted chat message
    public static func chatMessage(
        payload: ChatMessagePayload,
        originPeerID: String
    ) throws -> MeshMessage {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let messageData = try encoder.encode(payload)

        return MeshMessage(
            type: .chatMessage,
            ttl: 1,  // Direct peer-to-peer only
            originPeerID: originPeerID,
            payload: messageData
        )
    }

    /// Create a chat end message
    public static func chatEnd(
        end: ChatEnd,
        originPeerID: String
    ) throws -> MeshMessage {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let endData = try encoder.encode(end)

        return MeshMessage(
            type: .chatEnd,
            ttl: 1,
            originPeerID: originPeerID,
            payload: endData
        )
    }

    /// Decode chat request payload
    public func decodeChatRequest() throws -> ChatRequest {
        guard type == .chatRequest else {
            throw MeshError.invalidMessageType
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ChatRequest.self, from: payload)
    }

    /// Decode chat accept payload
    public func decodeChatAccept() throws -> ChatAccept {
        guard type == .chatAccept else {
            throw MeshError.invalidMessageType
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ChatAccept.self, from: payload)
    }

    /// Decode chat decline payload
    public func decodeChatDecline() throws -> ChatDecline {
        guard type == .chatDecline else {
            throw MeshError.invalidMessageType
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ChatDecline.self, from: payload)
    }

    /// Decode chat message payload
    public func decodeChatMessage() throws -> ChatMessagePayload {
        guard type == .chatMessage else {
            throw MeshError.invalidMessageType
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ChatMessagePayload.self, from: payload)
    }

    /// Decode chat end payload
    public func decodeChatEnd() throws -> ChatEnd {
        guard type == .chatEnd else {
            throw MeshError.invalidMessageType
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ChatEnd.self, from: payload)
    }

    /// Decrement TTL for forwarding
    /// Returns nil if message should be dropped (TTL exhausted)
    public func forwarded() -> MeshMessage? {
        guard ttl > 1 else { return nil }

        return MeshMessage(
            id: id,
            type: type,
            ttl: ttl - 1,
            originPeerID: originPeerID,
            createdAt: createdAt,
            payload: payload,
            signature: signature
        )
    }

    /// Decode the stealth payment payload
    public func decodeStealthPayload() throws -> MeshStealthPayload {
        guard type == .stealthPayment else {
            throw MeshError.invalidMessageType
        }
        let decoder = JSONDecoder()
        return try decoder.decode(MeshStealthPayload.self, from: payload)
    }

    /// Check if message has expired based on age
    public func isExpired(maxAge: TimeInterval = 3600) -> Bool {
        return Date().timeIntervalSince(createdAt) > maxAge
    }

    /// Serialize message for transmission
    public func serialize() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    /// Deserialize message from received data
    public static func deserialize(from data: Data) throws -> MeshMessage {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(MeshMessage.self, from: data)
    }
}

// MARK: - Peer Capabilities

/// Capabilities announced during peer discovery
public struct PeerCapabilities: Codable, Sendable, Equatable {
    /// Whether peer supports hybrid (PQ) mode
    public let supportsHybrid: Bool

    /// Whether peer can relay messages (vs receive-only)
    public let canRelay: Bool

    /// Whether peer has internet connectivity
    public let hasConnectivity: Bool

    /// Maximum message size peer can handle
    public let maxMessageSize: Int

    /// Protocol version
    public let protocolVersion: Int

    public init(
        supportsHybrid: Bool = true,
        canRelay: Bool = true,
        hasConnectivity: Bool = false,
        maxMessageSize: Int = 4096,
        protocolVersion: Int = 1
    ) {
        self.supportsHybrid = supportsHybrid
        self.canRelay = canRelay
        self.hasConnectivity = hasConnectivity
        self.maxMessageSize = maxMessageSize
        self.protocolVersion = protocolVersion
    }
}

// MARK: - Errors

/// Errors that can occur in mesh operations
public enum MeshError: Error, LocalizedError {
    case invalidMessageType
    case payloadTooLarge(size: Int, max: Int)
    case ttlExhausted
    case messageExpired
    case duplicateMessage
    case serializationFailed(Error)
    case deserializationFailed(Error)
    case bluetoothUnavailable
    case bluetoothUnauthorized
    case peerNotFound(String)
    case connectionFailed(Error)
    case transmissionFailed(Error)
    case writeTimeout
    case serviceNotReady

    public var errorDescription: String? {
        switch self {
        case .invalidMessageType:
            return "Invalid message type for this operation"
        case .payloadTooLarge(let size, let max):
            return "Payload size \(size) exceeds maximum \(max)"
        case .ttlExhausted:
            return "Message TTL exhausted"
        case .messageExpired:
            return "Message has expired"
        case .duplicateMessage:
            return "Duplicate message already processed"
        case .serializationFailed(let error):
            return "Serialization failed: \(error.localizedDescription)"
        case .deserializationFailed(let error):
            return "Deserialization failed: \(error.localizedDescription)"
        case .bluetoothUnavailable:
            return "Bluetooth is not available"
        case .bluetoothUnauthorized:
            return "Bluetooth access not authorized"
        case .peerNotFound(let peerID):
            return "Peer not found: \(peerID)"
        case .connectionFailed(let error):
            return "Connection failed: \(error.localizedDescription)"
        case .transmissionFailed(let error):
            return "Transmission failed: \(error.localizedDescription)"
        case .writeTimeout:
            return "Write operation timed out"
        case .serviceNotReady:
            return "BLE service is not ready"
        }
    }
}

// MARK: - Message Hash for Deduplication

extension MeshMessage {
    /// Compute a hash for deduplication (based on ID only for simplicity)
    public var deduplicationKey: String {
        id.uuidString
    }
}
