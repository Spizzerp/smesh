import Foundation

// MARK: - Chat Request

/// Initial chat request sent to start an encrypted session.
///
/// Contains the initiator's X25519 and ML-KEM public keys for
/// hybrid post-quantum key exchange.
public struct ChatRequest: Codable, Sendable, Equatable {
    /// Unique session identifier
    public let sessionID: UUID

    /// Requester's peer ID
    public let requesterPeerID: String

    /// Requester's display name (optional)
    public let requesterName: String?

    /// Requester's X25519 public key (32 bytes)
    public let x25519PublicKey: Data

    /// Requester's ML-KEM 768 public key (1,184 bytes)
    public let mlkemPublicKey: Data

    /// Timestamp when request was created
    public let timestamp: Date

    public init(
        sessionID: UUID = UUID(),
        requesterPeerID: String,
        requesterName: String? = nil,
        x25519PublicKey: Data,
        mlkemPublicKey: Data,
        timestamp: Date = Date()
    ) {
        self.sessionID = sessionID
        self.requesterPeerID = requesterPeerID
        self.requesterName = requesterName
        self.x25519PublicKey = x25519PublicKey
        self.mlkemPublicKey = mlkemPublicKey
        self.timestamp = timestamp
    }

    /// Validate the request payload sizes
    public var isValid: Bool {
        x25519PublicKey.count == 32 && mlkemPublicKey.count == 1184
    }
}

// MARK: - Chat Accept

/// Response accepting a chat request with key exchange data.
///
/// Contains the responder's X25519 public key, ML-KEM public key,
/// and the ML-KEM ciphertext encapsulating the shared secret.
public struct ChatAccept: Codable, Sendable, Equatable {
    /// Session ID being accepted
    public let sessionID: UUID

    /// Responder's peer ID
    public let responderPeerID: String

    /// Responder's display name (optional)
    public let responderName: String?

    /// Responder's X25519 public key (32 bytes)
    public let x25519PublicKey: Data

    /// Responder's ML-KEM 768 public key (1,184 bytes)
    public let mlkemPublicKey: Data

    /// ML-KEM ciphertext encapsulated to requester's public key (1,088 bytes)
    public let mlkemCiphertext: Data

    /// Timestamp when response was created
    public let timestamp: Date

    public init(
        sessionID: UUID,
        responderPeerID: String,
        responderName: String? = nil,
        x25519PublicKey: Data,
        mlkemPublicKey: Data,
        mlkemCiphertext: Data,
        timestamp: Date = Date()
    ) {
        self.sessionID = sessionID
        self.responderPeerID = responderPeerID
        self.responderName = responderName
        self.x25519PublicKey = x25519PublicKey
        self.mlkemPublicKey = mlkemPublicKey
        self.mlkemCiphertext = mlkemCiphertext
        self.timestamp = timestamp
    }

    /// Validate the response payload sizes
    public var isValid: Bool {
        x25519PublicKey.count == 32 &&
        mlkemPublicKey.count == 1184 &&
        mlkemCiphertext.count == 1088
    }
}

// MARK: - Chat Decline

/// Response declining a chat request.
public struct ChatDecline: Codable, Sendable, Equatable {
    /// Session ID being declined
    public let sessionID: UUID

    /// Decliner's peer ID
    public let declinePeerID: String

    /// Reason for declining (optional)
    public let reason: DeclineReason?

    /// Timestamp when declined
    public let timestamp: Date

    public enum DeclineReason: String, Codable, Sendable {
        case busy = "busy"
        case declined = "declined"
        case timeout = "timeout"
    }

    public init(
        sessionID: UUID,
        declinePeerID: String,
        reason: DeclineReason? = nil,
        timestamp: Date = Date()
    ) {
        self.sessionID = sessionID
        self.declinePeerID = declinePeerID
        self.reason = reason
        self.timestamp = timestamp
    }
}

// MARK: - Chat Message

/// Encrypted chat message payload.
///
/// Contains all data needed for the recipient to decrypt and verify
/// the message using the Double Ratchet protocol.
public struct ChatMessagePayload: Codable, Sendable, Equatable {
    /// Session ID this message belongs to
    public let sessionID: UUID

    /// Sender's current DH ratchet public key (32 bytes)
    public let dhPublicKey: Data

    /// Message number in current sending chain
    public let messageNumber: UInt32

    /// Previous chain length (for skipped message detection)
    public let previousChainLength: UInt32

    /// AES-GCM nonce (12 bytes)
    public let nonce: Data

    /// Encrypted message content
    public let ciphertext: Data

    /// AES-GCM authentication tag (16 bytes)
    public let tag: Data

    /// Timestamp when message was sent
    public let timestamp: Date

    public init(
        sessionID: UUID,
        dhPublicKey: Data,
        messageNumber: UInt32,
        previousChainLength: UInt32 = 0,
        nonce: Data,
        ciphertext: Data,
        tag: Data,
        timestamp: Date = Date()
    ) {
        self.sessionID = sessionID
        self.dhPublicKey = dhPublicKey
        self.messageNumber = messageNumber
        self.previousChainLength = previousChainLength
        self.nonce = nonce
        self.ciphertext = ciphertext
        self.tag = tag
        self.timestamp = timestamp
    }

    /// Create from an EncryptedMessage
    public init(sessionID: UUID, encrypted: EncryptedMessage, previousChainLength: UInt32 = 0) {
        self.sessionID = sessionID
        self.dhPublicKey = encrypted.dhPublicKey
        self.messageNumber = encrypted.messageNumber
        self.previousChainLength = previousChainLength
        self.nonce = encrypted.nonce
        self.ciphertext = encrypted.ciphertext
        self.tag = encrypted.tag
        self.timestamp = Date()
    }

    /// Convert to EncryptedMessage for decryption
    public func toEncryptedMessage() -> EncryptedMessage {
        EncryptedMessage(
            dhPublicKey: dhPublicKey,
            messageNumber: messageNumber,
            nonce: nonce,
            ciphertext: ciphertext,
            tag: tag
        )
    }

    /// Validate payload sizes
    public var isValid: Bool {
        dhPublicKey.count == 32 &&
        nonce.count == 12 &&
        tag.count == 16 &&
        !ciphertext.isEmpty
    }

    /// Estimated size in bytes
    public var estimatedSize: Int {
        16 + // UUID
        32 + // dhPublicKey
        4 + // messageNumber
        4 + // previousChainLength
        12 + // nonce
        ciphertext.count +
        16 + // tag
        8 // timestamp
    }
}

// MARK: - Chat End

/// Message to end a chat session.
public struct ChatEnd: Codable, Sendable, Equatable {
    /// Session ID being ended
    public let sessionID: UUID

    /// Peer ID of who is ending the session
    public let peerID: String

    /// Reason for ending (optional)
    public let reason: EndReason?

    /// Timestamp when ended
    public let timestamp: Date

    public enum EndReason: String, Codable, Sendable {
        case userEnded = "user_ended"
        case disconnected = "disconnected"
        case timeout = "timeout"
        case error = "error"
    }

    public init(
        sessionID: UUID,
        peerID: String,
        reason: EndReason? = nil,
        timestamp: Date = Date()
    ) {
        self.sessionID = sessionID
        self.peerID = peerID
        self.reason = reason
        self.timestamp = timestamp
    }
}

// MARK: - Chat Message Display

/// Represents a chat message for display in the UI.
/// This is NOT transmitted over the wire - only for local display.
public struct ChatMessage: Identifiable, Sendable, Equatable {
    /// Unique message ID
    public let id: UUID

    /// Session this message belongs to
    public let sessionID: UUID

    /// Message content (decrypted)
    public let content: String

    /// Whether this message was sent by us
    public let isOutgoing: Bool

    /// Timestamp when the message was sent/received
    public let timestamp: Date

    /// Delivery status
    public var status: DeliveryStatus

    public enum DeliveryStatus: String, Sendable {
        case sending = "sending"
        case sent = "sent"
        case delivered = "delivered"
        case failed = "failed"
    }

    public init(
        id: UUID = UUID(),
        sessionID: UUID,
        content: String,
        isOutgoing: Bool,
        timestamp: Date = Date(),
        status: DeliveryStatus = .sending
    ) {
        self.id = id
        self.sessionID = sessionID
        self.content = content
        self.isOutgoing = isOutgoing
        self.timestamp = timestamp
        self.status = status
    }
}
