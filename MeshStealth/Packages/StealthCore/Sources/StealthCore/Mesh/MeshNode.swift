import Foundation
import Combine

/// Represents a discovered peer in the mesh network
public struct MeshPeer: Identifiable, Sendable, Equatable {
    /// Unique peer identifier (BLE peripheral identifier)
    public let id: String

    /// Display name (if available)
    public let name: String?

    /// Peer capabilities
    public let capabilities: PeerCapabilities

    /// Signal strength (RSSI) - lower is weaker (updated on discovery)
    public var rssi: Int

    /// When this peer was first discovered
    public let discoveredAt: Date

    /// When we last heard from this peer
    public var lastSeenAt: Date

    /// Connection state
    public var connectionState: PeerConnectionState

    public init(
        id: String,
        name: String? = nil,
        capabilities: PeerCapabilities = PeerCapabilities(),
        rssi: Int = -50,
        discoveredAt: Date = Date(),
        lastSeenAt: Date = Date(),
        connectionState: PeerConnectionState = .disconnected
    ) {
        self.id = id
        self.name = name
        self.capabilities = capabilities
        self.rssi = rssi
        self.discoveredAt = discoveredAt
        self.lastSeenAt = lastSeenAt
        self.connectionState = connectionState
    }

    /// Whether this peer is currently connected
    public var isConnected: Bool {
        connectionState == .connected
    }

    /// Whether peer is stale (not seen recently)
    public func isStale(timeout: TimeInterval = 30) -> Bool {
        Date().timeIntervalSince(lastSeenAt) > timeout
    }

    /// Update last seen timestamp
    public mutating func markSeen() {
        lastSeenAt = Date()
    }
}

/// Connection state for a peer
public enum PeerConnectionState: String, Codable, Sendable {
    case disconnected
    case connecting
    case connected
    case disconnecting
}

/// Statistics for the mesh node
public struct MeshStatistics: Sendable {
    public var messagesReceived: Int = 0
    public var messagesSent: Int = 0
    public var messagesRelayed: Int = 0
    public var messagesDropped: Int = 0
    public var duplicatesFiltered: Int = 0
    public var peersDiscovered: Int = 0
    public var bytesReceived: Int = 0
    public var bytesSent: Int = 0

    public init() {}
}

/// Actor managing local mesh node state
/// Handles peer tracking, message deduplication, and routing decisions
public actor MeshNode {
    /// Unique identifier for this node
    public nonisolated let peerID: String

    /// This node's capabilities
    public nonisolated let capabilities: PeerCapabilities

    /// Known peers
    private var peers: [String: MeshPeer] = [:]

    /// Recently seen message IDs for deduplication
    private var recentMessageIDs: Set<String> = []

    /// Maximum size of deduplication cache
    private let maxRecentMessages = 1000

    /// Messages pending delivery (for store-and-forward)
    private var pendingMessages: [MeshMessage] = []

    /// Maximum pending messages to store
    private let maxPendingMessages = 100

    /// Statistics
    private var stats = MeshStatistics()

    /// Delegate for mesh events
    public weak var delegate: MeshNodeDelegate?

    /// Publisher for peer updates
    private nonisolated(unsafe) let peerUpdateSubject = PassthroughSubject<[MeshPeer], Never>()
    public nonisolated var peerUpdates: AnyPublisher<[MeshPeer], Never> {
        peerUpdateSubject.eraseToAnyPublisher()
    }

    /// Publisher for received stealth payments
    private nonisolated(unsafe) let paymentReceivedSubject = PassthroughSubject<MeshStealthPayload, Never>()
    public nonisolated var paymentsReceived: AnyPublisher<MeshStealthPayload, Never> {
        paymentReceivedSubject.eraseToAnyPublisher()
    }

    /// Publisher for meta-address requests (when someone wants our address)
    private nonisolated(unsafe) let metaAddressRequestSubject = PassthroughSubject<MetaAddressRequest, Never>()
    public nonisolated var metaAddressRequests: AnyPublisher<MetaAddressRequest, Never> {
        metaAddressRequestSubject.eraseToAnyPublisher()
    }

    /// Publisher for meta-address responses (when we receive someone's address)
    private nonisolated(unsafe) let metaAddressResponseSubject = PassthroughSubject<MetaAddressResponse, Never>()
    public nonisolated var metaAddressResponses: AnyPublisher<MetaAddressResponse, Never> {
        metaAddressResponseSubject.eraseToAnyPublisher()
    }

    // MARK: - Chat Message Publishers

    /// Publisher for incoming chat requests
    private nonisolated(unsafe) let chatRequestSubject = PassthroughSubject<ChatRequest, Never>()
    public nonisolated var chatRequests: AnyPublisher<ChatRequest, Never> {
        chatRequestSubject.eraseToAnyPublisher()
    }

    /// Publisher for chat accept responses
    private nonisolated(unsafe) let chatAcceptSubject = PassthroughSubject<ChatAccept, Never>()
    public nonisolated var chatAccepts: AnyPublisher<ChatAccept, Never> {
        chatAcceptSubject.eraseToAnyPublisher()
    }

    /// Publisher for chat decline responses
    private nonisolated(unsafe) let chatDeclineSubject = PassthroughSubject<ChatDecline, Never>()
    public nonisolated var chatDeclines: AnyPublisher<ChatDecline, Never> {
        chatDeclineSubject.eraseToAnyPublisher()
    }

    /// Publisher for encrypted chat messages
    private nonisolated(unsafe) let chatMessageSubject = PassthroughSubject<ChatMessagePayload, Never>()
    public nonisolated var chatMessages: AnyPublisher<ChatMessagePayload, Never> {
        chatMessageSubject.eraseToAnyPublisher()
    }

    /// Publisher for chat end messages
    private nonisolated(unsafe) let chatEndSubject = PassthroughSubject<ChatEnd, Never>()
    public nonisolated var chatEnds: AnyPublisher<ChatEnd, Never> {
        chatEndSubject.eraseToAnyPublisher()
    }

    public init(
        peerID: String = UUID().uuidString,
        capabilities: PeerCapabilities = PeerCapabilities()
    ) {
        self.peerID = peerID
        self.capabilities = capabilities
    }

    // MARK: - Peer Management

    /// Register a discovered peer
    public func addPeer(_ peer: MeshPeer) {
        peers[peer.id] = peer
        stats.peersDiscovered += 1
        notifyPeerUpdate()
    }

    /// Update an existing peer
    public func updatePeer(id: String, update: (inout MeshPeer) -> Void) {
        guard var peer = peers[id] else { return }
        update(&peer)
        peers[id] = peer
        notifyPeerUpdate()
    }

    /// Remove a peer
    public func removePeer(id: String) {
        peers.removeValue(forKey: id)
        notifyPeerUpdate()
    }

    /// Get a specific peer
    public func getPeer(id: String) -> MeshPeer? {
        peers[id]
    }

    /// Get all known peers
    public func getAllPeers() -> [MeshPeer] {
        Array(peers.values)
    }

    /// Get connected peers
    public func getConnectedPeers() -> [MeshPeer] {
        peers.values.filter { $0.isConnected }
    }

    /// Remove stale peers
    public func pruneStalepeers(timeout: TimeInterval = 60) {
        let staleIDs = peers.values
            .filter { $0.isStale(timeout: timeout) }
            .map { $0.id }

        for id in staleIDs {
            peers.removeValue(forKey: id)
        }

        if !staleIDs.isEmpty {
            notifyPeerUpdate()
        }
    }

    private func notifyPeerUpdate() {
        peerUpdateSubject.send(Array(peers.values))
    }

    // MARK: - Message Handling

    /// Process an incoming message
    /// Returns messages to relay (if any)
    public func processIncomingMessage(_ message: MeshMessage) -> ProcessResult {
        // Check for duplicate
        if recentMessageIDs.contains(message.deduplicationKey) {
            stats.duplicatesFiltered += 1
            return .duplicate
        }

        // Check if expired
        if message.isExpired() {
            stats.messagesDropped += 1
            return .expired
        }

        // Add to deduplication cache
        addToRecentMessages(message.deduplicationKey)
        stats.messagesReceived += 1

        // Handle by type
        switch message.type {
        case .stealthPayment:
            return processStealthPayment(message)

        case .acknowledgment:
            return processAcknowledgment(message)

        case .discovery:
            return processDiscovery(message)

        case .heartbeat:
            return .processed

        case .metaAddressRequest:
            return processMetaAddressRequest(message)

        case .metaAddressResponse:
            return processMetaAddressResponse(message)

        // Chat message types
        case .chatRequest:
            return processChatRequest(message)

        case .chatAccept:
            return processChatAccept(message)

        case .chatDecline:
            return processChatDecline(message)

        case .chatMessage:
            return processChatMessage(message)

        case .chatEnd:
            return processChatEnd(message)
        }
    }

    private func processStealthPayment(_ message: MeshMessage) -> ProcessResult {
        // Try to decode payload
        guard let payload = try? message.decodeStealthPayload() else {
            stats.messagesDropped += 1
            return .invalid
        }

        // Notify delegate/publisher
        paymentReceivedSubject.send(payload)

        // Forward if TTL allows
        if let forwardable = message.forwarded() {
            return .relay(forwardable)
        }

        return .processed
    }

    private func processAcknowledgment(_ message: MeshMessage) -> ProcessResult {
        // For now, just log acknowledgments
        // Could be used to confirm delivery
        return .processed
    }

    private func processDiscovery(_ message: MeshMessage) -> ProcessResult {
        // Discovery messages are not relayed
        guard let capabilities = try? JSONDecoder().decode(
            PeerCapabilities.self,
            from: message.payload
        ) else {
            return .invalid
        }

        // Update peer info
        if var peer = peers[message.originPeerID] {
            peer.markSeen()
            peers[message.originPeerID] = peer
        }
        // Note: New peer creation happens in BLEMeshService when peripheral is discovered

        return .processed
    }

    private func processMetaAddressRequest(_ message: MeshMessage) -> ProcessResult {
        // Meta-address requests are not relayed (direct peer-to-peer only)
        guard let request = try? message.decodeMetaAddressRequest() else {
            return .invalid
        }

        // Notify via publisher so app can respond
        metaAddressRequestSubject.send(request)

        return .processed
    }

    private func processMetaAddressResponse(_ message: MeshMessage) -> ProcessResult {
        // Meta-address responses are not relayed (direct peer-to-peer only)
        guard let response = try? message.decodeMetaAddressResponse() else {
            return .invalid
        }

        // Notify via publisher so app can use the received address
        metaAddressResponseSubject.send(response)

        return .processed
    }

    // MARK: - Chat Message Processing

    private func processChatRequest(_ message: MeshMessage) -> ProcessResult {
        DebugLogger.log("[MeshNode] Processing chat request...")

        guard let request = try? message.decodeChatRequest() else {
            DebugLogger.log("[MeshNode] Failed to decode chat request")
            return .invalid
        }

        DebugLogger.log("[MeshNode] Decoded chat request: sessionID=\(request.sessionID), requester=\(request.requesterPeerID.prefix(8))...")

        // Validate request
        guard request.isValid else {
            DebugLogger.log("[MeshNode] Chat request validation failed")
            return .invalid
        }

        DebugLogger.log("[MeshNode] Chat request valid, sending to subject...")
        chatRequestSubject.send(request)
        return .processed
    }

    private func processChatAccept(_ message: MeshMessage) -> ProcessResult {
        guard let accept = try? message.decodeChatAccept() else {
            return .invalid
        }

        // Validate accept
        guard accept.isValid else {
            return .invalid
        }

        chatAcceptSubject.send(accept)
        return .processed
    }

    private func processChatDecline(_ message: MeshMessage) -> ProcessResult {
        guard let decline = try? message.decodeChatDecline() else {
            return .invalid
        }

        chatDeclineSubject.send(decline)
        return .processed
    }

    private func processChatMessage(_ message: MeshMessage) -> ProcessResult {
        guard let chatPayload = try? message.decodeChatMessage() else {
            return .invalid
        }

        // Validate message
        guard chatPayload.isValid else {
            return .invalid
        }

        chatMessageSubject.send(chatPayload)
        return .processed
    }

    private func processChatEnd(_ message: MeshMessage) -> ProcessResult {
        guard let end = try? message.decodeChatEnd() else {
            return .invalid
        }

        chatEndSubject.send(end)
        return .processed
    }

    private func addToRecentMessages(_ key: String) {
        recentMessageIDs.insert(key)

        // Prune if over limit (simple FIFO-ish approach)
        if recentMessageIDs.count > maxRecentMessages {
            // Remove ~10% oldest (we don't have ordering, so just random removal)
            let toRemove = recentMessageIDs.count - maxRecentMessages + 100
            for _ in 0..<toRemove {
                if let first = recentMessageIDs.first {
                    recentMessageIDs.remove(first)
                }
            }
        }
    }

    // MARK: - Message Queueing

    /// Queue a message for later delivery
    public func queueMessage(_ message: MeshMessage) {
        // Enforce storage limit - drop oldest if at capacity
        if pendingMessages.count >= maxPendingMessages {
            pendingMessages.removeFirst()
            stats.messagesDropped += 1
        }
        pendingMessages.append(message)
    }

    /// Get pending messages for a peer
    public func getPendingMessages(forPeer peerID: String) -> [MeshMessage] {
        // For now, return all pending messages
        // Could filter by destination or capability matching
        pendingMessages
    }

    /// Remove a message from pending queue
    public func removePendingMessage(id: MessageID) {
        pendingMessages.removeAll { $0.id == id }
    }

    /// Clear all pending messages
    public func clearPendingMessages() {
        pendingMessages.removeAll()
    }

    // MARK: - Statistics

    /// Get current statistics
    public func getStatistics() -> MeshStatistics {
        stats
    }

    /// Record a sent message
    public func recordMessageSent(bytes: Int) {
        stats.messagesSent += 1
        stats.bytesSent += bytes
    }

    /// Record a relayed message
    public func recordMessageRelayed() {
        stats.messagesRelayed += 1
    }

    /// Record received bytes
    public func recordBytesReceived(_ bytes: Int) {
        stats.bytesReceived += bytes
    }

    /// Reset statistics
    public func resetStatistics() {
        stats = MeshStatistics()
    }
}

// MARK: - Process Result

/// Result of processing an incoming message
public enum ProcessResult: Sendable, Equatable {
    /// Message was processed successfully
    case processed

    /// Message should be relayed to other peers
    case relay(MeshMessage)

    /// Message was a duplicate
    case duplicate

    /// Message has expired
    case expired

    /// Message was invalid
    case invalid

    public static func == (lhs: ProcessResult, rhs: ProcessResult) -> Bool {
        switch (lhs, rhs) {
        case (.processed, .processed): return true
        case (.duplicate, .duplicate): return true
        case (.expired, .expired): return true
        case (.invalid, .invalid): return true
        case (.relay(let a), .relay(let b)): return a.id == b.id
        default: return false
        }
    }
}

// MARK: - Delegate Protocol

/// Delegate for mesh node events
public protocol MeshNodeDelegate: AnyObject, Sendable {
    /// Called when a stealth payment is received
    func meshNode(_ node: MeshNode, didReceivePayment payload: MeshStealthPayload) async

    /// Called when a peer is discovered
    func meshNode(_ node: MeshNode, didDiscoverPeer peer: MeshPeer) async

    /// Called when a peer disconnects
    func meshNode(_ node: MeshNode, didLosePeer peerID: String) async

    /// Called when a message should be relayed
    func meshNode(_ node: MeshNode, shouldRelay message: MeshMessage) async
}

// MARK: - Default Delegate Implementation

public extension MeshNodeDelegate {
    func meshNode(_ node: MeshNode, didReceivePayment payload: MeshStealthPayload) async {}
    func meshNode(_ node: MeshNode, didDiscoverPeer peer: MeshPeer) async {}
    func meshNode(_ node: MeshNode, didLosePeer peerID: String) async {}
    func meshNode(_ node: MeshNode, shouldRelay message: MeshMessage) async {}
}
