import Foundation
import Combine

/// Configuration for message relay behavior
public struct RelayConfiguration: Sendable {
    /// Maximum number of messages to store
    public let maxStoredMessages: Int

    /// Maximum age of messages before expiry (seconds)
    public let messageExpiry: TimeInterval

    /// How often to prune expired messages (seconds)
    public let pruneInterval: TimeInterval

    /// Whether to relay messages to other peers
    public let enableRelay: Bool

    /// Minimum RSSI to consider a peer for relay
    public let minRelayRSSI: Int

    /// Maximum messages to send per relay cycle
    public let maxMessagesPerCycle: Int

    public init(
        maxStoredMessages: Int = 100,
        messageExpiry: TimeInterval = 3600,  // 1 hour
        pruneInterval: TimeInterval = 60,     // 1 minute
        enableRelay: Bool = true,
        minRelayRSSI: Int = -80,
        maxMessagesPerCycle: Int = 10
    ) {
        self.maxStoredMessages = maxStoredMessages
        self.messageExpiry = messageExpiry
        self.pruneInterval = pruneInterval
        self.enableRelay = enableRelay
        self.minRelayRSSI = minRelayRSSI
        self.maxMessagesPerCycle = maxMessagesPerCycle
    }

    /// Default configuration
    public static let `default` = RelayConfiguration()

    /// Configuration optimized for low battery usage
    public static let lowPower = RelayConfiguration(
        maxStoredMessages: 50,
        messageExpiry: 1800,  // 30 minutes
        pruneInterval: 120,
        enableRelay: true,
        minRelayRSSI: -70,
        maxMessagesPerCycle: 5
    )

    /// Configuration for aggressive relay (hackathon demo)
    public static let aggressive = RelayConfiguration(
        maxStoredMessages: 200,
        messageExpiry: 7200,  // 2 hours
        pruneInterval: 30,
        enableRelay: true,
        minRelayRSSI: -90,
        maxMessagesPerCycle: 20
    )
}

/// Stored message with metadata
public struct StoredMessage: Sendable, Identifiable {
    public let id: MessageID
    public let message: MeshMessage
    public let receivedAt: Date
    public var relayCount: Int
    public var lastRelayAttempt: Date?

    public init(message: MeshMessage) {
        self.id = message.id
        self.message = message
        self.receivedAt = Date()
        self.relayCount = 0
        self.lastRelayAttempt = nil
    }

    /// Whether this message has expired
    public func isExpired(maxAge: TimeInterval) -> Bool {
        Date().timeIntervalSince(receivedAt) > maxAge
    }
}

/// Message relay service - handles store-and-forward for mesh messages
/// Stores messages for offline peers and relays them when connectivity is available
public actor MessageRelay {

    // MARK: - Properties

    /// Configuration
    private let config: RelayConfiguration

    /// Reference to mesh node
    private let meshNode: MeshNode

    /// Stored messages awaiting delivery
    private var storedMessages: [MessageID: StoredMessage] = [:]

    /// Messages that have been acknowledged
    private var acknowledgedMessages: Set<MessageID> = []

    /// Timer for periodic tasks
    private var pruneTask: Task<Void, Never>?

    /// Publisher for relay events
    private let relayEventSubject = PassthroughSubject<RelayEvent, Never>()
    public var relayEvents: AnyPublisher<RelayEvent, Never> {
        relayEventSubject.eraseToAnyPublisher()
    }

    // MARK: - Initialization

    public init(meshNode: MeshNode, config: RelayConfiguration = .default) {
        self.meshNode = meshNode
        self.config = config
    }

    /// Start the relay service
    public func start() {
        // Start periodic pruning
        pruneTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(config.pruneInterval * 1_000_000_000))
                await pruneExpiredMessages()
            }
        }
    }

    /// Stop the relay service
    public func stop() {
        pruneTask?.cancel()
        pruneTask = nil
    }

    // MARK: - Message Storage

    /// Store a message for later relay
    public func storeMessage(_ message: MeshMessage) {
        // Check if already stored or acknowledged
        guard storedMessages[message.id] == nil,
              !acknowledgedMessages.contains(message.id) else {
            return
        }

        // Enforce storage limit
        if storedMessages.count >= config.maxStoredMessages {
            evictOldestMessage()
        }

        let stored = StoredMessage(message: message)
        storedMessages[message.id] = stored

        relayEventSubject.send(.messageStored(message.id))
    }

    /// Retrieve a stored message
    public func getMessage(id: MessageID) -> MeshMessage? {
        storedMessages[id]?.message
    }

    /// Get all stored messages
    public func getAllStoredMessages() -> [StoredMessage] {
        Array(storedMessages.values)
    }

    /// Get messages that need relaying
    public func getMessagesForRelay() -> [MeshMessage] {
        storedMessages.values
            .filter { !$0.isExpired(maxAge: config.messageExpiry) }
            .filter { $0.message.ttl > 0 }
            .prefix(config.maxMessagesPerCycle)
            .map { $0.message }
    }

    /// Mark a message as relayed
    public func markRelayed(id: MessageID) {
        if var stored = storedMessages[id] {
            stored.relayCount += 1
            stored.lastRelayAttempt = Date()
            storedMessages[id] = stored

            relayEventSubject.send(.messageRelayed(id))
        }
    }

    /// Mark a message as acknowledged (delivered)
    public func markAcknowledged(id: MessageID) {
        storedMessages.removeValue(forKey: id)
        acknowledgedMessages.insert(id)

        // Limit ack cache size
        if acknowledgedMessages.count > 1000 {
            // Remove oldest (we don't track order, so just remove some)
            while acknowledgedMessages.count > 800 {
                if let first = acknowledgedMessages.first {
                    acknowledgedMessages.remove(first)
                }
            }
        }

        relayEventSubject.send(.messageAcknowledged(id))
    }

    /// Remove a message from storage
    public func removeMessage(id: MessageID) {
        storedMessages.removeValue(forKey: id)
    }

    /// Clear all stored messages
    public func clearAll() {
        storedMessages.removeAll()
    }

    // MARK: - Relay Logic

    /// Perform relay to connected peers
    /// Returns messages that should be sent
    public func prepareRelay() async -> [MeshMessage] {
        guard config.enableRelay else { return [] }

        let connectedPeers = await meshNode.getConnectedPeers()
        guard !connectedPeers.isEmpty else { return [] }

        // Filter peers by RSSI
        let eligiblePeers = connectedPeers.filter { $0.rssi >= config.minRelayRSSI }
        guard !eligiblePeers.isEmpty else { return [] }

        // Get messages to relay
        let messages = getMessagesForRelay()

        // Prepare forwarded versions
        return messages.compactMap { message in
            message.forwarded()
        }
    }

    /// Record successful relay
    public func recordRelaySuccess(messageIDs: [MessageID]) {
        for id in messageIDs {
            markRelayed(id: id)
        }
    }

    /// Record relay failure
    public func recordRelayFailure(messageIDs: [MessageID], error: Error) {
        relayEventSubject.send(.relayFailed(messageIDs, error))
    }

    // MARK: - Maintenance

    /// Remove expired messages
    private func pruneExpiredMessages() {
        let expiredIDs = storedMessages.values
            .filter { $0.isExpired(maxAge: config.messageExpiry) }
            .map { $0.id }

        for id in expiredIDs {
            storedMessages.removeValue(forKey: id)
            relayEventSubject.send(.messageExpired(id))
        }
    }

    /// Evict oldest message to make room
    private func evictOldestMessage() {
        guard let oldest = storedMessages.values.min(by: { $0.receivedAt < $1.receivedAt }) else {
            return
        }
        storedMessages.removeValue(forKey: oldest.id)
        relayEventSubject.send(.messageEvicted(oldest.id))
    }

    // MARK: - Statistics

    /// Get relay statistics
    public func getStatistics() -> RelayStatistics {
        RelayStatistics(
            storedMessageCount: storedMessages.count,
            acknowledgedCount: acknowledgedMessages.count,
            totalRelayAttempts: storedMessages.values.reduce(0) { $0 + $1.relayCount },
            oldestMessageAge: storedMessages.values.map { Date().timeIntervalSince($0.receivedAt) }.max() ?? 0
        )
    }
}

// MARK: - Relay Events

/// Events emitted by the relay service
public enum RelayEvent: Sendable {
    case messageStored(MessageID)
    case messageRelayed(MessageID)
    case messageAcknowledged(MessageID)
    case messageExpired(MessageID)
    case messageEvicted(MessageID)
    case relayFailed([MessageID], Error)
}

// MARK: - Relay Statistics

/// Statistics about relay operations
public struct RelayStatistics: Sendable {
    public let storedMessageCount: Int
    public let acknowledgedCount: Int
    public let totalRelayAttempts: Int
    public let oldestMessageAge: TimeInterval

    public init(
        storedMessageCount: Int,
        acknowledgedCount: Int,
        totalRelayAttempts: Int,
        oldestMessageAge: TimeInterval
    ) {
        self.storedMessageCount = storedMessageCount
        self.acknowledgedCount = acknowledgedCount
        self.totalRelayAttempts = totalRelayAttempts
        self.oldestMessageAge = oldestMessageAge
    }
}

// MARK: - Relay Event Sendable Conformance

extension RelayEvent: Equatable {
    public static func == (lhs: RelayEvent, rhs: RelayEvent) -> Bool {
        switch (lhs, rhs) {
        case (.messageStored(let a), .messageStored(let b)):
            return a == b
        case (.messageRelayed(let a), .messageRelayed(let b)):
            return a == b
        case (.messageAcknowledged(let a), .messageAcknowledged(let b)):
            return a == b
        case (.messageExpired(let a), .messageExpired(let b)):
            return a == b
        case (.messageEvicted(let a), .messageEvicted(let b)):
            return a == b
        case (.relayFailed(let a, _), .relayFailed(let b, _)):
            return a == b
        default:
            return false
        }
    }
}
