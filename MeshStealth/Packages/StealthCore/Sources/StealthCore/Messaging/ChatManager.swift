import Foundation
import Combine

/// High-level coordinator for encrypted mesh chat sessions.
///
/// Manages:
/// - Active chat sessions
/// - Incoming chat requests
/// - Message routing
/// - Session cleanup
public actor ChatManager {

    // MARK: - Types

    /// Incoming chat request for UI to display
    public struct IncomingRequest: Sendable, Identifiable {
        public var id: UUID { request.sessionID }
        public let request: ChatRequest
        public let receivedAt: Date

        init(request: ChatRequest) {
            self.request = request
            self.receivedAt = Date()
        }
    }

    // MARK: - Properties

    /// Active chat sessions by session ID
    private var sessions: [UUID: ChatSession] = [:]

    /// Pending incoming requests by session ID
    private var pendingRequests: [UUID: IncomingRequest] = [:]

    /// Our peer ID
    public nonisolated let localPeerID: String

    /// Our display name (optional)
    public nonisolated let localPeerName: String?

    /// Session timeout for cleanup (30 minutes)
    private static let sessionTimeout: TimeInterval = 1800

    /// Request timeout (2 minutes)
    private static let requestTimeout: TimeInterval = 120

    // MARK: - Publishers

    /// Publisher for new incoming requests
    private nonisolated(unsafe) let incomingRequestSubject = PassthroughSubject<IncomingRequest, Never>()
    public nonisolated var incomingRequests: AnyPublisher<IncomingRequest, Never> {
        incomingRequestSubject.eraseToAnyPublisher()
    }

    /// Publisher for session state changes
    private nonisolated(unsafe) let sessionStateSubject = PassthroughSubject<(UUID, ChatSession.State), Never>()
    public nonisolated var sessionStates: AnyPublisher<(UUID, ChatSession.State), Never> {
        sessionStateSubject.eraseToAnyPublisher()
    }

    /// Publisher for received messages
    private nonisolated(unsafe) let messageReceivedSubject = PassthroughSubject<(UUID, String), Never>()
    public nonisolated var messagesReceived: AnyPublisher<(UUID, String), Never> {
        messageReceivedSubject.eraseToAnyPublisher()
    }

    /// Cancellables for subscriptions
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    public init(localPeerID: String, localPeerName: String? = nil) {
        self.localPeerID = localPeerID
        self.localPeerName = localPeerName
    }

    // MARK: - Session Initiation

    /// Start a new chat session with a peer
    /// - Parameters:
    ///   - remotePeerID: The peer's ID
    ///   - remotePeerName: The peer's name (optional)
    /// - Returns: Tuple of (session ID, chat request to send)
    public func startSession(
        with remotePeerID: String,
        remotePeerName: String? = nil
    ) async throws -> (UUID, ChatRequest) {
        // Create new session as initiator
        let session = try ChatSession(
            remotePeerID: remotePeerID,
            remotePeerName: remotePeerName
        )

        // Subscribe to session events
        subscribeToSession(session)

        // Store session
        sessions[session.sessionID] = session

        // Create request to send
        let request = try await session.createRequest(
            localPeerID: localPeerID,
            localPeerName: localPeerName
        )

        return (session.sessionID, request)
    }

    /// Handle an incoming chat request
    public func handleIncomingRequest(_ request: ChatRequest) {
        // Check if we already have a session or pending request
        guard sessions[request.sessionID] == nil,
              pendingRequests[request.sessionID] == nil else {
            return
        }

        // Validate request
        guard request.isValid else {
            DebugLogger.log("[ChatManager] Invalid request received")
            return
        }

        // Store as pending
        let incoming = IncomingRequest(request: request)
        pendingRequests[request.sessionID] = incoming

        // Notify UI
        incomingRequestSubject.send(incoming)
    }

    /// Accept a pending chat request
    /// - Parameter sessionID: The session ID to accept
    /// - Returns: ChatAccept to send back
    public func acceptRequest(sessionID: UUID) async throws -> ChatAccept {
        guard let incoming = pendingRequests.removeValue(forKey: sessionID) else {
            throw ChatManagerError.requestNotFound
        }

        // Create session from request
        let session = try ChatSession(request: incoming.request)

        // Subscribe to session events
        subscribeToSession(session)

        // Accept and get response
        let accept = try await session.accept(
            localPeerID: localPeerID,
            localPeerName: localPeerName
        )

        // Store active session
        sessions[sessionID] = session
        sessionStateSubject.send((sessionID, .active))

        return accept
    }

    /// Decline a pending chat request
    /// - Parameter sessionID: The session ID to decline
    /// - Returns: ChatDecline to send back
    public func declineRequest(sessionID: UUID) -> ChatDecline {
        pendingRequests.removeValue(forKey: sessionID)

        return ChatDecline(
            sessionID: sessionID,
            declinePeerID: localPeerID,
            reason: .declined
        )
    }

    /// Handle a chat accept response (as initiator)
    public func handleAccept(_ accept: ChatAccept) async throws {
        guard let session = sessions[accept.sessionID] else {
            throw ChatManagerError.sessionNotFound
        }

        try await session.handleAccept(accept)
        sessionStateSubject.send((accept.sessionID, .active))
    }

    /// Handle a chat decline response
    public func handleDecline(_ decline: ChatDecline) async {
        if let session = sessions.removeValue(forKey: decline.sessionID) {
            await session.decline()
        }
        sessionStateSubject.send((decline.sessionID, .ended))
    }

    // MARK: - Messaging

    /// Send a message in a session
    /// - Parameters:
    ///   - text: Message text to send
    ///   - sessionID: Session ID
    /// - Returns: ChatMessagePayload to send
    public func sendMessage(_ text: String, in sessionID: UUID) async throws -> ChatMessagePayload {
        guard let session = sessions[sessionID] else {
            throw ChatManagerError.sessionNotFound
        }

        return try await session.encryptMessage(text)
    }

    /// Handle a received encrypted message
    public func handleMessage(_ payload: ChatMessagePayload) async throws -> String {
        guard let session = sessions[payload.sessionID] else {
            throw ChatManagerError.sessionNotFound
        }

        let text = try await session.decryptMessage(payload)
        messageReceivedSubject.send((payload.sessionID, text))

        return text
    }

    // MARK: - Session Management

    /// End a chat session
    public func endSession(_ sessionID: UUID) async -> ChatEnd? {
        guard let session = sessions.removeValue(forKey: sessionID) else {
            return nil
        }

        await session.end()
        sessionStateSubject.send((sessionID, .ended))

        return ChatEnd(
            sessionID: sessionID,
            peerID: localPeerID,
            reason: .userEnded
        )
    }

    /// Handle a session end message
    public func handleSessionEnd(_ end: ChatEnd) async {
        if let session = sessions.removeValue(forKey: end.sessionID) {
            await session.end()
        }
        sessionStateSubject.send((end.sessionID, .ended))
    }

    /// Get a session by ID
    public func getSession(_ sessionID: UUID) -> ChatSession? {
        sessions[sessionID]
    }

    /// Get all active sessions
    public func getActiveSessions() async -> [ChatSession.Info] {
        var infos: [ChatSession.Info] = []
        for session in sessions.values {
            let info = await session.getInfo()
            if info.state == .active {
                infos.append(info)
            }
        }
        return infos
    }

    /// Get pending requests
    public func getPendingRequests() -> [IncomingRequest] {
        Array(pendingRequests.values)
    }

    /// Clean up expired sessions and requests
    public func cleanup() async {
        let now = Date()

        // Clean expired requests
        for (id, request) in pendingRequests {
            if now.timeIntervalSince(request.receivedAt) > Self.requestTimeout {
                pendingRequests.removeValue(forKey: id)
            }
        }

        // Clean expired sessions
        var expiredIDs: [UUID] = []
        for (id, session) in sessions {
            if await session.isExpired() {
                expiredIDs.append(id)
            }
        }

        for id in expiredIDs {
            if let session = sessions.removeValue(forKey: id) {
                await session.end()
                sessionStateSubject.send((id, .ended))
            }
        }
    }

    // MARK: - Private Helpers

    private func subscribeToSession(_ session: ChatSession) {
        let sessionID = session.sessionID

        // Subscribe to state changes
        // Use a detached task to avoid data race issues
        session.statePublisher
            .sink { [weak self] state in
                guard let self = self else { return }
                let capturedSessionID = sessionID
                let capturedState = state
                Task { [self] in
                    await self.handleSessionStateChange(sessionID: capturedSessionID, state: capturedState)
                }
            }
            .store(in: &cancellables)
    }

    private func handleSessionStateChange(sessionID: UUID, state: ChatSession.State) {
        sessionStateSubject.send((sessionID, state))

        // Remove ended sessions
        if state == .ended {
            sessions.removeValue(forKey: sessionID)
        }
    }
}

// MARK: - Errors

public enum ChatManagerError: Error, LocalizedError {
    case sessionNotFound
    case requestNotFound
    case alreadyHaveSession
    case invalidPayload

    public var errorDescription: String? {
        switch self {
        case .sessionNotFound: return "Chat session not found"
        case .requestNotFound: return "Chat request not found"
        case .alreadyHaveSession: return "Already have a session with this peer"
        case .invalidPayload: return "Invalid message payload"
        }
    }
}
