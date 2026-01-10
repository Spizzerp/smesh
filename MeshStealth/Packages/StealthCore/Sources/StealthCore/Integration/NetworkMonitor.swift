import Foundation
import Network
import Combine

/// Network connectivity status
public enum NetworkStatus: String, Sendable {
    case connected
    case disconnected
    case unknown
}

/// Network connection type
public enum ConnectionType: String, Sendable {
    case wifi
    case cellular
    case wiredEthernet
    case other
    case none
}

/// Monitors network connectivity for settlement triggering
@MainActor
public class NetworkMonitor: ObservableObject {

    /// Current network status
    @Published public private(set) var status: NetworkStatus = .unknown

    /// Current connection type
    @Published public private(set) var connectionType: ConnectionType = .none

    /// Whether the device is currently online
    @Published public private(set) var isConnected: Bool = false

    /// Whether expensive network (cellular) is being used
    @Published public private(set) var isExpensive: Bool = false

    /// Whether constrained network (low data mode) is active
    @Published public private(set) var isConstrained: Bool = false

    /// The underlying NWPathMonitor
    private let monitor: NWPathMonitor

    /// Queue for path updates
    private let queue = DispatchQueue(label: "com.meshstealth.networkmonitor", qos: .utility)

    /// Publisher for connectivity changes
    private let connectivitySubject = PassthroughSubject<Bool, Never>()
    public var connectivityChanges: AnyPublisher<Bool, Never> {
        connectivitySubject.eraseToAnyPublisher()
    }

    /// Callback for when device comes online
    public var onConnected: (() -> Void)?

    /// Callback for when device goes offline
    public var onDisconnected: (() -> Void)?

    /// Whether monitoring is active
    private var isMonitoring = false

    public init() {
        self.monitor = NWPathMonitor()
    }

    /// Initialize with a specific interface type requirement
    public init(requiredInterfaceType: NWInterface.InterfaceType) {
        self.monitor = NWPathMonitor(requiredInterfaceType: requiredInterfaceType)
    }

    deinit {
        // Cancel monitor directly since we can't call @MainActor method from deinit
        monitor.cancel()
    }

    // MARK: - Control

    /// Start monitoring network connectivity
    public func start() {
        guard !isMonitoring else { return }

        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                self?.handlePathUpdate(path)
            }
        }

        monitor.start(queue: queue)
        isMonitoring = true
    }

    /// Stop monitoring network connectivity
    public func stop() {
        guard isMonitoring else { return }
        monitor.cancel()
        isMonitoring = false
    }

    // MARK: - Path Handling

    private func handlePathUpdate(_ path: NWPath) {
        let wasConnected = isConnected
        let newStatus: NetworkStatus
        let newConnectionType: ConnectionType

        switch path.status {
        case .satisfied:
            newStatus = .connected
        case .unsatisfied:
            newStatus = .disconnected
        case .requiresConnection:
            newStatus = .disconnected
        @unknown default:
            newStatus = .unknown
        }

        // Determine connection type
        if path.usesInterfaceType(.wifi) {
            newConnectionType = .wifi
        } else if path.usesInterfaceType(.cellular) {
            newConnectionType = .cellular
        } else if path.usesInterfaceType(.wiredEthernet) {
            newConnectionType = .wiredEthernet
        } else if path.status == .satisfied {
            newConnectionType = .other
        } else {
            newConnectionType = .none
        }

        // Update published properties
        status = newStatus
        connectionType = newConnectionType
        isConnected = (newStatus == .connected)
        isExpensive = path.isExpensive
        isConstrained = path.isConstrained

        // Notify of connectivity changes
        if isConnected != wasConnected {
            connectivitySubject.send(isConnected)

            if isConnected {
                onConnected?()
            } else {
                onDisconnected?()
            }
        }
    }

    // MARK: - Convenience

    /// Check if we should attempt settlement (has good connectivity)
    public var shouldAttemptSettlement: Bool {
        // Connected and preferably not on constrained network
        isConnected && !isConstrained
    }

    /// Check if we have WiFi (preferred for larger transactions)
    public var hasWiFi: Bool {
        connectionType == .wifi && isConnected
    }

    /// Wait for connectivity (with timeout)
    public func waitForConnectivity(timeout: TimeInterval = 30) async -> Bool {
        if isConnected { return true }

        return await withCheckedContinuation { continuation in
            var cancellable: AnyCancellable?
            var timeoutTask: Task<Void, Never>?

            cancellable = connectivityChanges
                .first(where: { $0 })
                .sink { connected in
                    timeoutTask?.cancel()
                    cancellable?.cancel()
                    continuation.resume(returning: connected)
                }

            timeoutTask = Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if !Task.isCancelled {
                    cancellable?.cancel()
                    continuation.resume(returning: false)
                }
            }
        }
    }
}

// MARK: - Network Reachability Helper

/// Simple reachability check without continuous monitoring
public struct NetworkReachability: Sendable {

    public init() {}

    /// Quick one-time check if network is reachable
    public func isReachable() async -> Bool {
        await withCheckedContinuation { continuation in
            let monitor = NWPathMonitor()
            let queue = DispatchQueue(label: "com.meshstealth.reachability")

            monitor.pathUpdateHandler = { path in
                monitor.cancel()
                continuation.resume(returning: path.status == .satisfied)
            }

            monitor.start(queue: queue)

            // Timeout after 5 seconds
            queue.asyncAfter(deadline: .now() + 5) {
                monitor.cancel()
                continuation.resume(returning: false)
            }
        }
    }

    /// Check if a specific host is reachable
    public func isHostReachable(_ host: String, port: UInt16 = 443) async -> Bool {
        await withCheckedContinuation { continuation in
            let endpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host(host),
                port: NWEndpoint.Port(integerLiteral: port)
            )

            let connection = NWConnection(to: endpoint, using: .tcp)

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    connection.cancel()
                    continuation.resume(returning: true)
                case .failed, .cancelled:
                    continuation.resume(returning: false)
                default:
                    break
                }
            }

            connection.start(queue: DispatchQueue(label: "com.meshstealth.hostcheck"))

            // Timeout
            DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
                connection.cancel()
            }
        }
    }

    /// Check if Solana RPC is reachable
    public func isSolanaReachable(cluster: SolanaCluster = .devnet) async -> Bool {
        let host: String
        switch cluster {
        case .mainnetBeta:
            host = "api.mainnet-beta.solana.com"
        case .devnet:
            host = "api.devnet.solana.com"
        case .testnet:
            host = "api.testnet.solana.com"
        case .custom(let url):
            // Extract host from custom URL
            if let urlHost = URL(string: url.absoluteString)?.host {
                host = urlHost
            } else {
                return false
            }
        }
        return await isHostReachable(host)
    }
}
