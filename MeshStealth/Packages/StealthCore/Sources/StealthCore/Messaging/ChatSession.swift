import Foundation
import Combine

/// Actor managing the lifecycle and state of a single chat session.
///
/// Handles:
/// - Session initialization and key exchange
/// - Message encryption/decryption using Double Ratchet
/// - Session state transitions
/// - Automatic session cleanup
public actor ChatSession {

    // MARK: - Types

    /// Current state of the chat session
    public enum State: String, Sendable {
        case initializing = "initializing"
        case pendingAccept = "pending_accept"      // Waiting for remote to accept
        case pendingLocalAccept = "pending_local"  // Waiting for local user to accept
        case active = "active"
        case ending = "ending"
        case ended = "ended"
    }

    /// Session information
    public struct Info: Sendable {
        public let sessionID: UUID
        public let remotePeerID: String
        public let remotePeerName: String?
        public let isInitiator: Bool
        public let isPostQuantum: Bool
        public let startedAt: Date
        public var state: State
        public var lastActivityAt: Date
        public var messageCount: Int
    }

    // MARK: - Properties

    /// Unique session identifier
    public nonisolated let sessionID: UUID

    /// Remote peer's ID
    public nonisolated let remotePeerID: String

    /// Remote peer's name (if available)
    public nonisolated let remotePeerName: String?

    /// Whether we initiated this session
    public nonisolated let isInitiator: Bool

    /// Current session state
    private var state: State = .initializing

    /// Double ratchet state for encryption
    private var ratchetState: DoubleRatchetState?

    /// Storage for skipped message keys
    private var skippedKeys = SkippedMessageKeys()

    /// Messages in this session (for display)
    private var messages: [ChatMessage] = []

    /// When the session started
    private let startedAt: Date

    /// Last activity timestamp
    private var lastActivityAt: Date

    /// Session timeout interval (30 minutes)
    private static let sessionTimeout: TimeInterval = 1800

    // MARK: - Publishers

    /// Publisher for message updates
    private nonisolated(unsafe) let messageSubject = PassthroughSubject<ChatMessage, Never>()
    public nonisolated var messagePublisher: AnyPublisher<ChatMessage, Never> {
        messageSubject.eraseToAnyPublisher()
    }

    /// Publisher for state changes
    private nonisolated(unsafe) let stateSubject = PassthroughSubject<State, Never>()
    public nonisolated var statePublisher: AnyPublisher<State, Never> {
        stateSubject.eraseToAnyPublisher()
    }

    // MARK: - Initialization

    /// Create a new session as the initiator
    public init(
        sessionID: UUID = UUID(),
        remotePeerID: String,
        remotePeerName: String? = nil
    ) throws {
        self.sessionID = sessionID
        self.remotePeerID = remotePeerID
        self.remotePeerName = remotePeerName
        self.isInitiator = true
        self.startedAt = Date()
        self.lastActivityAt = Date()

        // Create initial ratchet state
        self.ratchetState = try DoubleRatchetState(sessionID: sessionID, isInitiator: true)
        self.state = .pendingAccept
    }

    /// Create a new session from an incoming request
    public init(
        request: ChatRequest
    ) throws {
        self.sessionID = request.sessionID
        self.remotePeerID = request.requesterPeerID
        self.remotePeerName = request.requesterName
        self.isInitiator = false
        self.startedAt = Date()
        self.lastActivityAt = Date()

        // Create ratchet state with remote keys
        self.ratchetState = try DoubleRatchetState(
            sessionID: request.sessionID,
            remoteX25519PublicKey: request.x25519PublicKey,
            remoteMlkemPublicKey: request.mlkemPublicKey
        )
        self.state = .pendingLocalAccept
    }

    // MARK: - Session Lifecycle

    /// Get current session info
    public func getInfo() -> Info {
        Info(
            sessionID: sessionID,
            remotePeerID: remotePeerID,
            remotePeerName: remotePeerName,
            isInitiator: isInitiator,
            isPostQuantum: true, // Always using hybrid mode
            startedAt: startedAt,
            state: state,
            lastActivityAt: lastActivityAt,
            messageCount: messages.count
        )
    }

    /// Get current state
    public func getState() -> State {
        state
    }

    /// Create a chat request to send (as initiator)
    public func createRequest(localPeerID: String, localPeerName: String?) throws -> ChatRequest {
        guard let ratchetState = ratchetState else {
            throw ChatSessionError.notInitialized
        }

        return ChatRequest(
            sessionID: sessionID,
            requesterPeerID: localPeerID,
            requesterName: localPeerName,
            x25519PublicKey: ratchetState.dhPublicKey,
            mlkemPublicKey: ratchetState.mlkemPublicKey
        )
    }

    /// Accept the session and create response (as responder)
    public func accept(localPeerID: String, localPeerName: String?) throws -> ChatAccept {
        guard var ratchetState = ratchetState else {
            throw ChatSessionError.notInitialized
        }

        guard state == .pendingLocalAccept else {
            throw ChatSessionError.invalidState
        }

        // Perform key exchange as responder
        guard let remoteX25519 = ratchetState.remotePublicKey,
              let remoteMlkem = ratchetState.remoteMlkemPublicKey else {
            throw ChatSessionError.missingRemoteKeys
        }

        // Encapsulate ML-KEM to get ciphertext to send back
        let (mlkemCiphertext, mlkemSecret) = try MLKEMWrapper.encapsulate(publicKeyData: remoteMlkem)

        // Compute X25519 shared secret
        let remoteKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: remoteX25519)
        let x25519Secret = try ratchetState.dhPrivateKey.sharedSecretFromKeyAgreement(with: remoteKey)
        let x25519SecretData = x25519Secret.withUnsafeBytes { Data($0) }

        // Derive hybrid secret and set up chains
        let hybridSecret = DoubleRatchetEngine.deriveHybridSecret(
            x25519Secret: x25519SecretData,
            mlkemSecret: mlkemSecret
        )

        // Derive initial keys (responder's chains are swapped)
        let inputKey = SymmetricKey(data: hybridSecret)
        let derived = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            salt: Data("MeshChat_Salt".utf8),
            info: Data("MeshChat_RootKey".utf8),
            outputByteCount: 96
        )
        let derivedData = derived.withUnsafeBytes { Data($0) }

        ratchetState.setRootKey(Data(derivedData[0..<32]))
        // Responder chains are swapped relative to initiator:
        // - Our receiving chain must match initiator's sending chain (chain2)
        // - Our sending chain must match initiator's receiving chain (chain1)
        ratchetState.setupReceivingChain(Data(derivedData[64..<96])) // chain2 - matches initiator's sending
        ratchetState.setupSendingChain(Data(derivedData[32..<64]))   // chain1 - matches initiator's receiving

        self.ratchetState = ratchetState
        self.state = .active
        self.lastActivityAt = Date()
        stateSubject.send(.active)

        return ChatAccept(
            sessionID: sessionID,
            responderPeerID: localPeerID,
            responderName: localPeerName,
            x25519PublicKey: ratchetState.dhPublicKey,
            mlkemPublicKey: ratchetState.mlkemPublicKey,
            mlkemCiphertext: mlkemCiphertext
        )
    }

    /// Handle receiving an accept response (as initiator)
    public func handleAccept(_ accept: ChatAccept) throws {
        guard var ratchetState = ratchetState else {
            throw ChatSessionError.notInitialized
        }

        guard state == .pendingAccept else {
            throw ChatSessionError.invalidState
        }

        // Complete key exchange with the ciphertext
        try DoubleRatchetEngine.responderKeyExchange(
            state: &ratchetState,
            remoteX25519PublicKey: accept.x25519PublicKey,
            mlkemCiphertext: accept.mlkemCiphertext
        )

        self.ratchetState = ratchetState
        self.state = .active
        self.lastActivityAt = Date()
        stateSubject.send(.active)
    }

    /// Decline the session
    public func decline() {
        state = .ended
        ratchetState?.clear()
        stateSubject.send(.ended)
    }

    /// End the session
    public func end() {
        state = .ended
        ratchetState?.clear()
        skippedKeys.clear()
        stateSubject.send(.ended)
    }

    // MARK: - Messaging

    /// Encrypt and prepare a message for sending
    public func encryptMessage(_ text: String) throws -> ChatMessagePayload {
        guard var ratchetState = ratchetState else {
            throw ChatSessionError.notInitialized
        }

        guard state == .active else {
            throw ChatSessionError.notActive
        }

        let plaintext = Data(text.utf8)
        let previousChainLength = ratchetState.previousChainLength

        let encrypted = try DoubleRatchetEngine.encrypt(
            plaintext: plaintext,
            state: &ratchetState
        )

        self.ratchetState = ratchetState
        self.lastActivityAt = Date()

        // Create display message
        let displayMessage = ChatMessage(
            sessionID: sessionID,
            content: text,
            isOutgoing: true,
            status: .sending
        )
        messages.append(displayMessage)
        messageSubject.send(displayMessage)

        return ChatMessagePayload(
            sessionID: sessionID,
            encrypted: encrypted,
            previousChainLength: previousChainLength
        )
    }

    /// Decrypt a received message
    public func decryptMessage(_ payload: ChatMessagePayload) throws -> String {
        guard var ratchetState = ratchetState else {
            throw ChatSessionError.notInitialized
        }

        guard state == .active else {
            throw ChatSessionError.notActive
        }

        let encrypted = payload.toEncryptedMessage()

        let plaintext = try DoubleRatchetEngine.decrypt(
            message: encrypted,
            state: &ratchetState,
            skippedKeys: &skippedKeys
        )

        self.ratchetState = ratchetState
        self.lastActivityAt = Date()

        guard let text = String(data: plaintext, encoding: .utf8) else {
            throw ChatSessionError.invalidMessage
        }

        // Create display message
        let displayMessage = ChatMessage(
            sessionID: sessionID,
            content: text,
            isOutgoing: false,
            status: .delivered
        )
        messages.append(displayMessage)
        messageSubject.send(displayMessage)

        return text
    }

    /// Update message status
    public func updateMessageStatus(id: UUID, status: ChatMessage.DeliveryStatus) {
        if let index = messages.firstIndex(where: { $0.id == id }) {
            messages[index].status = status
            messageSubject.send(messages[index])
        }
    }

    /// Get all messages
    public func getMessages() -> [ChatMessage] {
        messages
    }

    // MARK: - Session Validation

    /// Check if session has expired
    public func isExpired() -> Bool {
        Date().timeIntervalSince(lastActivityAt) > Self.sessionTimeout
    }

    /// Check if session is active
    public func isActive() -> Bool {
        state == .active
    }
}

// MARK: - Errors

public enum ChatSessionError: Error, LocalizedError {
    case notInitialized
    case notActive
    case invalidState
    case missingRemoteKeys
    case encryptionFailed
    case decryptionFailed
    case invalidMessage
    case sessionExpired

    public var errorDescription: String? {
        switch self {
        case .notInitialized: return "Chat session not initialized"
        case .notActive: return "Chat session not active"
        case .invalidState: return "Invalid session state for this operation"
        case .missingRemoteKeys: return "Remote peer's keys not available"
        case .encryptionFailed: return "Failed to encrypt message"
        case .decryptionFailed: return "Failed to decrypt message"
        case .invalidMessage: return "Invalid message format"
        case .sessionExpired: return "Chat session has expired"
        }
    }
}

// MARK: - CryptoKit imports needed

import CryptoKit
