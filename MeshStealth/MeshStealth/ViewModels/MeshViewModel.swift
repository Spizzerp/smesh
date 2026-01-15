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

    // MARK: - Private Handlers

    private func handleMetaAddressRequest(_ request: MetaAddressRequest) {
        pendingMetaAddressRequest = request
    }

    private func handleMetaAddressResponse(_ response: MetaAddressResponse) {
        receivedMetaAddress = response
        isRequestingAddress = false
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
