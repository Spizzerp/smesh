import Foundation
import Combine
import StealthCore

/// Represents a nearby peer with proximity info
struct NearbyPeer: Identifiable, Equatable {
    let id: String
    let name: String?
    let rssi: Int
    let isConnected: Bool
    let lastSeenAt: Date
    let supportsHybrid: Bool

    /// Signal strength as percentage (0-100)
    var signalStrength: Int {
        // RSSI typically ranges from -100 (weak) to -30 (strong)
        let normalized = min(max(rssi, -100), -30)
        return Int((Double(normalized + 100) / 70.0) * 100)
    }

    /// Proximity description
    var proximityDescription: String {
        switch rssi {
        case -50...0:
            return "Very Close"
        case -65...(-51):
            return "Close"
        case -80...(-66):
            return "Nearby"
        default:
            return "Far"
        }
    }

    /// Whether peer is close enough for "tap to pay"
    var isCloseEnough: Bool {
        rssi >= -65
    }
}

/// View model for mesh networking state
@MainActor
class MeshViewModel: ObservableObject {
    // MARK: - Published State

    @Published var isActive = false
    @Published var isOnline = false
    @Published var nearbyPeers: [NearbyPeer] = []
    @Published var closestPeer: NearbyPeer?

    @Published var pendingMetaAddressRequest: MetaAddressRequest?
    @Published var receivedMetaAddress: MetaAddressResponse?
    @Published var isRequestingAddress = false

    @Published var lastError: Error?

    // MARK: - Chat State

    @Published var pendingChatRequest: ChatRequest?
    @Published var activeChatSessionID: UUID?
    @Published var isChatConnecting = false

    /// The chat manager for this view model
    private(set) var chatManager: ChatManager?

    // MARK: - Private

    private let meshService: BLEMeshService
    private let walletManager: StealthWalletManager
    private let networkMonitor: NetworkMonitor
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    init(meshService: BLEMeshService, walletManager: StealthWalletManager, networkMonitor: NetworkMonitor) {
        self.meshService = meshService
        self.walletManager = walletManager
        self.networkMonitor = networkMonitor

        // Initialize chat manager with our peer ID
        self.chatManager = ChatManager(
            localPeerID: meshService.getNode().peerID,
            localPeerName: nil
        )

        setupBindings()
    }

    private func setupBindings() {
        // Bind mesh active state
        meshService.$isActive
            .receive(on: DispatchQueue.main)
            .assign(to: &$isActive)

        // Bind network online state from NetworkMonitor
        networkMonitor.$isConnected
            .receive(on: DispatchQueue.main)
            .assign(to: &$isOnline)

        // Bind ALL peers (discovered + connected)
        Publishers.CombineLatest(
            meshService.$connectedPeers,
            meshService.$discoveredPeers
        )
        .receive(on: DispatchQueue.main)
        .map { connected, discovered in
            // Merge both lists, preferring connected status
            var peerMap: [String: MeshPeer] = [:]

            for peer in discovered {
                peerMap[peer.id] = peer
            }
            for peer in connected {
                peerMap[peer.id] = peer  // Connected peers override discovered
            }

            return peerMap.values.map { peer in
                NearbyPeer(
                    id: peer.id,
                    name: peer.name,
                    rssi: peer.rssi,
                    isConnected: peer.isConnected,
                    lastSeenAt: peer.lastSeenAt,
                    supportsHybrid: peer.capabilities.supportsHybrid
                )
            }
            .sorted { $0.rssi > $1.rssi }  // Sort by signal strength (closest first)
        }
        .assign(to: &$nearbyPeers)

        // Update closest peer
        $nearbyPeers
            .map { peers in
                peers.first { $0.isCloseEnough }
            }
            .assign(to: &$closestPeer)

        // Subscribe to meta-address requests
        let meshNode = meshService.getNode()
        meshNode.metaAddressRequests
            .receive(on: DispatchQueue.main)
            .sink { [weak self] request in
                self?.handleMetaAddressRequest(request)
            }
            .store(in: &cancellables)

        // Subscribe to meta-address responses
        meshNode.metaAddressResponses
            .receive(on: DispatchQueue.main)
            .sink { [weak self] response in
                self?.handleMetaAddressResponse(response)
            }
            .store(in: &cancellables)

        // MARK: - Chat Message Subscriptions

        // Subscribe to chat requests
        meshNode.chatRequests
            .receive(on: DispatchQueue.main)
            .sink { [weak self] request in
                self?.handleChatRequest(request)
            }
            .store(in: &cancellables)

        // Subscribe to chat accepts
        meshNode.chatAccepts
            .receive(on: DispatchQueue.main)
            .sink { [weak self] accept in
                Task { @MainActor in
                    await self?.handleChatAccept(accept)
                }
            }
            .store(in: &cancellables)

        // Subscribe to chat declines
        meshNode.chatDeclines
            .receive(on: DispatchQueue.main)
            .sink { [weak self] decline in
                Task { @MainActor in
                    await self?.handleChatDecline(decline)
                }
            }
            .store(in: &cancellables)

        // Subscribe to chat messages
        meshNode.chatMessages
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                Task { @MainActor in
                    await self?.handleChatMessage(message)
                }
            }
            .store(in: &cancellables)

        // Subscribe to chat end messages
        meshNode.chatEnds
            .receive(on: DispatchQueue.main)
            .sink { [weak self] end in
                Task { @MainActor in
                    await self?.handleChatEnd(end)
                }
            }
            .store(in: &cancellables)

        // Subscribe to outgoing chat messages from ChatViewModel
        NotificationCenter.default.publisher(for: .chatMessageToSend)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                if let payload = notification.userInfo?["payload"] as? ChatMessagePayload {
                    Task { @MainActor in
                        await self?.sendChatMessage(payload)
                    }
                }
            }
            .store(in: &cancellables)

        // Subscribe to chat end from ChatViewModel
        NotificationCenter.default.publisher(for: .chatEndToSend)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                if let payload = notification.userInfo?["payload"] as? ChatEnd {
                    Task { @MainActor in
                        await self?.sendChatEnd(payload)
                    }
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Actions

    /// Start mesh networking
    func startMesh() {
        meshService.start()
    }

    /// Stop mesh networking
    func stopMesh() {
        meshService.stop()
    }

    /// Request meta-address from a peer
    func requestMetaAddress(from peer: NearbyPeer, preferHybrid: Bool = true) async {
        isRequestingAddress = true
        receivedMetaAddress = nil

        let request = MetaAddressRequest(
            requesterPeerID: meshService.getNode().peerID,
            requesterName: nil,  // Could add device name here
            preferHybrid: preferHybrid
        )

        do {
            let message = try MeshMessage.metaAddressRequest(request: request)
            try await meshService.sendToPeer(message, peerID: peer.id)
            print("[MESH] Sent meta-address request to peer: \(peer.id)")
        } catch {
            lastError = error
            isRequestingAddress = false
            print("[MESH] Failed to send meta-address request: \(error)")
        }
    }

    /// Respond to a meta-address request
    func respondToMetaAddressRequest(_ request: MetaAddressRequest) async {
        guard let keyPair = walletManager.keyPair else { return }

        let metaAddress: String
        let isHybrid: Bool

        if request.preferHybrid && keyPair.hasPostQuantum {
            metaAddress = keyPair.hybridMetaAddressString
            isHybrid = true
        } else {
            metaAddress = keyPair.metaAddressString
            isHybrid = false
        }

        let response = MetaAddressResponse(
            responderPeerID: meshService.getNode().peerID,
            responderName: nil,
            metaAddress: metaAddress,
            isHybrid: isHybrid
        )

        do {
            let message = try MeshMessage.metaAddressResponse(response: response)
            // Broadcast to all connected peers - the requester will filter by their request
            // This avoids peer ID mismatch issues between MeshNode IDs and CBPeripheral IDs
            try await meshService.broadcastMessage(message)
            print("[MESH] Broadcast meta-address response")
        } catch {
            lastError = error
            print("[MESH] Failed to send meta-address response: \(error)")
        }

        // Clear the pending request
        pendingMetaAddressRequest = nil
    }

    /// Decline a meta-address request
    func declineMetaAddressRequest() {
        pendingMetaAddressRequest = nil
    }

    // MARK: - Chat Actions

    /// Start a chat session with a peer
    func startChat(with peer: NearbyPeer) async {
        guard let chatManager = chatManager else { return }

        isChatConnecting = true

        do {
            let (sessionID, request) = try await chatManager.startSession(
                with: peer.id,
                remotePeerName: peer.name
            )

            // Send the chat request
            let message = try MeshMessage.chatRequest(
                request: request,
                originPeerID: meshService.getNode().peerID
            )
            try await meshService.sendToPeer(message, peerID: peer.id)

            print("[MESH] Sent chat request to peer: \(peer.id)")
        } catch {
            lastError = error
            isChatConnecting = false
            print("[MESH] Failed to start chat: \(error)")
        }
    }

    /// Accept a pending chat request
    func acceptChatRequest() async {
        guard let chatManager = chatManager,
              let request = pendingChatRequest else { return }

        do {
            let accept = try await chatManager.acceptRequest(sessionID: request.sessionID)

            // Send the accept response
            let message = try MeshMessage.chatAccept(
                accept: accept,
                originPeerID: meshService.getNode().peerID
            )
            try await meshService.broadcastMessage(message)

            // Navigate to chat
            activeChatSessionID = request.sessionID
            pendingChatRequest = nil

            print("[MESH] Accepted chat request, session: \(request.sessionID)")
        } catch {
            lastError = error
            print("[MESH] Failed to accept chat request: \(error)")
        }
    }

    /// Decline a pending chat request
    func declineChatRequest() async {
        guard let chatManager = chatManager,
              let request = pendingChatRequest else { return }

        let decline = await chatManager.declineRequest(sessionID: request.sessionID)

        do {
            let message = try MeshMessage.chatDecline(
                decline: decline,
                originPeerID: meshService.getNode().peerID
            )
            try await meshService.broadcastMessage(message)
        } catch {
            print("[MESH] Failed to send decline: \(error)")
        }

        pendingChatRequest = nil
    }

    /// Send a chat message
    private func sendChatMessage(_ payload: ChatMessagePayload) async {
        do {
            let message = try MeshMessage.chatMessage(
                payload: payload,
                originPeerID: meshService.getNode().peerID
            )
            try await meshService.broadcastMessage(message)
        } catch {
            lastError = error
            print("[MESH] Failed to send chat message: \(error)")
        }
    }

    /// Send chat end message
    private func sendChatEnd(_ end: ChatEnd) async {
        do {
            let message = try MeshMessage.chatEnd(
                end: end,
                originPeerID: meshService.getNode().peerID
            )
            try await meshService.broadcastMessage(message)
        } catch {
            print("[MESH] Failed to send chat end: \(error)")
        }
    }

    // MARK: - Private Handlers

    private func handleMetaAddressRequest(_ request: MetaAddressRequest) {
        pendingMetaAddressRequest = request
    }

    private func handleMetaAddressResponse(_ response: MetaAddressResponse) {
        receivedMetaAddress = response
        isRequestingAddress = false
    }

    // MARK: - Chat Message Handlers

    private func handleChatRequest(_ request: ChatRequest) {
        guard let chatManager = chatManager else { return }

        // Store as pending for UI to display
        Task {
            await chatManager.handleIncomingRequest(request)
        }
        pendingChatRequest = request
    }

    private func handleChatAccept(_ accept: ChatAccept) async {
        guard let chatManager = chatManager else { return }

        do {
            try await chatManager.handleAccept(accept)
            activeChatSessionID = accept.sessionID
            isChatConnecting = false
            print("[MESH] Chat session established: \(accept.sessionID)")
        } catch {
            lastError = error
            isChatConnecting = false
            print("[MESH] Failed to handle chat accept: \(error)")
        }
    }

    private func handleChatDecline(_ decline: ChatDecline) async {
        guard let chatManager = chatManager else { return }

        await chatManager.handleDecline(decline)
        isChatConnecting = false
        print("[MESH] Chat request declined: \(decline.sessionID)")
    }

    private func handleChatMessage(_ message: ChatMessagePayload) async {
        guard let chatManager = chatManager else { return }

        do {
            _ = try await chatManager.handleMessage(message)
        } catch {
            print("[MESH] Failed to handle chat message: \(error)")
        }
    }

    private func handleChatEnd(_ end: ChatEnd) async {
        guard let chatManager = chatManager else { return }

        await chatManager.handleSessionEnd(end)

        // Clear active session if it matches
        if activeChatSessionID == end.sessionID {
            activeChatSessionID = nil
        }

        print("[MESH] Chat session ended: \(end.sessionID)")
    }

    // MARK: - Computed Properties

    var peerCount: Int {
        nearbyPeers.count
    }

    var hasNearbyPeers: Bool {
        !nearbyPeers.isEmpty
    }

    var canTapToPay: Bool {
        closestPeer != nil
    }
}
