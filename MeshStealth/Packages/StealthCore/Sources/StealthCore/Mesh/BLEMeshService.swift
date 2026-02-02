import Foundation
@preconcurrency import CoreBluetooth
import Combine

/// BLE Mesh Service - Manages both Central and Peripheral roles for mesh networking
/// Enables device-to-device stealth payment relay without internet connectivity
///
/// Note: This class manages its own thread safety for CoreBluetooth operations.
/// BLE callbacks happen on bleQueue, UI updates are dispatched to main.
public class BLEMeshService: NSObject, ObservableObject, @unchecked Sendable {

    // MARK: - Published State

    /// Current Bluetooth state
    @Published public private(set) var bluetoothState: CBManagerState = .unknown

    /// Whether the service is actively scanning/advertising
    @Published public private(set) var isActive: Bool = false

    /// Connected peers
    @Published public private(set) var connectedPeers: [MeshPeer] = []

    /// Discovered (but not connected) peers
    @Published public private(set) var discoveredPeers: [MeshPeer] = []

    // MARK: - Private Properties

    /// Central manager (for scanning and connecting to peripherals)
    private var centralManager: CBCentralManager!

    /// Peripheral manager (for advertising and accepting connections)
    private var peripheralManager: CBPeripheralManager!

    /// The mesh node managing state
    private let meshNode: MeshNode

    /// Message relay service
    private let messageRelay: MessageRelay

    /// Service UUID
    private let serviceUUID = CBUUID(string: MESH_SERVICE_UUID)

    /// Characteristic UUIDs
    private let messageCharacteristicUUID = CBUUID(string: MESH_MESSAGE_CHARACTERISTIC_UUID)
    private let discoveryCharacteristicUUID = CBUUID(string: MESH_DISCOVERY_CHARACTERISTIC_UUID)

    /// Connected peripherals (as central)
    private var connectedPeripherals: [UUID: CBPeripheral] = [:]

    /// Discovered characteristics for each peripheral
    private var peripheralCharacteristics: [UUID: CBCharacteristic] = [:]

    /// Central subscribers (as peripheral)
    private var subscribedCentrals: [CBCentral] = []

    /// Our advertised characteristic
    private var messageCharacteristic: CBMutableCharacteristic?

    /// Cancellables for Combine subscriptions
    private var cancellables = Set<AnyCancellable>()

    /// Delegate for service events
    public weak var delegate: BLEMeshServiceDelegate?

    /// Queue for BLE operations
    private let bleQueue = DispatchQueue(label: "com.meshstealth.ble", qos: .userInitiated)

    /// Lock for thread-safe property access
    private let lock = NSLock()

    // MARK: - Throttling Configuration

    /// Minimum interval between discovery updates for the same peer (seconds)
    private let discoveryThrottleInterval: TimeInterval = 1.0

    /// Minimum interval between connection attempts to the same peer (seconds)
    private let connectionThrottleInterval: TimeInterval = 5.0

    /// Scan duty cycle - how long to scan before pausing (seconds)
    private let scanDuration: TimeInterval = 10.0

    /// Scan pause - how long to pause between scan cycles (seconds)
    private let scanPause: TimeInterval = 2.0

    /// Last discovery timestamp for each peer (for throttling)
    private var lastDiscoveryTime: [UUID: Date] = [:]

    /// Last connection attempt timestamp for each peer (for throttling)
    private var lastConnectionAttempt: [UUID: Date] = [:]

    /// Pending connection peripherals (discovered but not yet connected)
    private var pendingConnections: [UUID: CBPeripheral] = [:]

    /// Scan cycle timer
    private var scanCycleTimer: DispatchSourceTimer?

    /// Whether scan is in active phase of duty cycle
    private var isInScanPhase = false

    /// Whether the GATT service has been successfully added
    private var isServiceAdded = false

    /// Whether we want the mesh to be active (used for auto-start when BLE ready)
    private var wantsActive = false

    /// Pending write continuation for chunked writes
    private var pendingWriteContinuation: CheckedContinuation<Void, Error>?

    /// Buffer for reassembling chunked messages from each peer
    /// Key is peer ID, value is (totalLength, assembledData)
    private var reassemblyBuffers: [String: (totalLength: Int, data: Data)] = [:]

    // MARK: - Initialization

    public init(meshNode: MeshNode, messageRelay: MessageRelay) {
        self.meshNode = meshNode
        self.messageRelay = messageRelay
        super.init()

        // Initialize managers on BLE queue
        centralManager = CBCentralManager(delegate: self, queue: bleQueue)
        peripheralManager = CBPeripheralManager(delegate: self, queue: bleQueue)

        // Subscribe to mesh node updates
        setupSubscriptions()
    }

    /// Convenience initializer with default node and relay
    public convenience override init() {
        let node = MeshNode()
        let relay = MessageRelay(meshNode: node)
        self.init(meshNode: node, messageRelay: relay)
    }

    private func setupSubscriptions() {
        // Note: In production, use proper async stream subscription
        // For now, we'll update peers manually when events occur
    }

    // MARK: - Thread-Safe Helpers

    private func updateOnMain(_ update: @escaping @Sendable () -> Void) {
        if Thread.isMainThread {
            update()
        } else {
            DispatchQueue.main.async(execute: update)
        }
    }

    // MARK: - Public API

    /// Start mesh networking (scanning and advertising)
    public func start() {
        wantsActive = true
        tryStart()
    }

    /// Try to start mesh if both BLE managers are ready
    private func tryStart() {
        bleQueue.async { [weak self] in
            guard let self = self, self.wantsActive else { return }

            // Check BOTH managers are ready
            guard self.centralManager.state == .poweredOn,
                  self.peripheralManager.state == .poweredOn else {
                DebugLogger.log("Bluetooth not ready - Central: \(self.centralManager.state.rawValue), Peripheral: \(self.peripheralManager.state.rawValue)")
                return
            }

            // Avoid starting twice
            guard !self.isActive else { return }

            self.startScanning()
            self.startAdvertising()
            self.updateOnMain {
                self.isActive = true
            }
        }
    }

    /// Stop mesh networking
    public func stop() {
        wantsActive = false
        bleQueue.async { [weak self] in
            guard let self = self else { return }
            self.stopScanning()
            self.stopAdvertising()
            self.disconnectAll()
            self.updateOnMain {
                self.isActive = false
            }
        }
    }

    /// Send a stealth payment to the mesh
    public func sendPayment(_ payload: MeshStealthPayload) async throws {
        let message = try MeshMessage.stealthPayment(
            payload: payload,
            originPeerID: meshNode.peerID
        )

        try await broadcastMessage(message)
    }

    /// Broadcast a message to all connected peers
    public func broadcastMessage(_ message: MeshMessage) async throws {
        let data = try message.serialize()

        // Check size - allow larger messages since we use chunking
        guard data.count <= 16384 else {
            throw MeshError.payloadTooLarge(size: data.count, max: 16384)
        }

        // Capture values synchronously before async boundary
        let (peripheralsToSend, characteristic, manager) = getPeripheralsForBroadcast()
        let subscriberCount = getSubscribedCentralCount()

        DebugLogger.log("[BLE] Broadcasting message type: \(message.type), size: \(data.count) bytes")
        DebugLogger.log("[BLE]   -> To \(peripheralsToSend.count) connected peripherals")
        DebugLogger.log("[BLE]   -> To \(subscriberCount) subscribed centrals")

        // Send to all connected peripherals (as central)
        for (peripheral, char) in peripheralsToSend {
            let maxWriteLength = peripheral.maximumWriteValueLength(for: .withoutResponse)
            if data.count <= maxWriteLength {
                // Small message - use fast .withoutResponse
                peripheral.writeValue(data, for: char, type: .withoutResponse)
            } else {
                // Large message - use chunked .withResponse
                DebugLogger.log("[BLE] Broadcast to \(peripheral.identifier.uuidString.prefix(8))... needs chunking")
                try await sendChunkedData(data, to: peripheral, characteristic: char)
            }
        }

        // Send to all subscribed centrals (as peripheral) via notifications
        // For large messages, we need to chunk notifications too
        if let characteristic = characteristic, let mgr = manager {
            if data.count <= 512 {  // Notifications typically limited to ~512 bytes
                mgr.updateValue(data, for: characteristic, onSubscribedCentrals: nil)
            } else {
                // Chunk the notification data
                try await sendChunkedNotifications(data, characteristic: characteristic, manager: mgr)
            }
        }

        await meshNode.recordMessageSent(bytes: data.count)
    }

    /// Send chunked notifications to all subscribed centrals
    private func sendChunkedNotifications(_ data: Data, characteristic: CBMutableCharacteristic, manager: CBPeripheralManager) async throws {
        let payloadSize = Self.chunkPayloadSize
        let totalLength = data.count

        var offset = 0
        var chunkIndex = 0
        let totalChunks = (data.count + payloadSize - 1) / payloadSize

        DebugLogger.log("[BLE] sendChunkedNotifications: Sending \(totalChunks) chunks to subscribers")

        while offset < data.count {
            let end = min(offset + payloadSize, data.count)
            let payload = data[offset..<end]

            // Build chunk with header
            var chunk = Data(capacity: Self.chunkHeaderSize + payload.count)
            chunk.append(Self.chunkMagicByte)
            chunk.append(UInt8((totalLength >> 8) & 0xFF))
            chunk.append(UInt8(totalLength & 0xFF))
            chunk.append(UInt8((offset >> 8) & 0xFF))
            chunk.append(UInt8(offset & 0xFF))
            chunk.append(contentsOf: payload)

            // Send notification chunk
            let success = manager.updateValue(chunk, for: characteristic, onSubscribedCentrals: nil)
            if !success {
                DebugLogger.log("[BLE] sendChunkedNotifications: Transmit queue full, waiting...")
                try await Task.sleep(nanoseconds: 50_000_000) // 50ms
                _ = manager.updateValue(chunk, for: characteristic, onSubscribedCentrals: nil)
            }

            offset = end
            chunkIndex += 1

            // Small delay between chunks
            if offset < data.count {
                try await Task.sleep(nanoseconds: 10_000_000) // 10ms
            }
        }

        DebugLogger.log("[BLE] sendChunkedNotifications: All \(totalChunks) chunks sent")
    }

    /// Thread-safe helper to get subscriber count
    private func getSubscribedCentralCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return subscribedCentrals.count
    }

    /// Thread-safe helper to get peripherals for broadcast
    private func getPeripheralsForBroadcast() -> ([(CBPeripheral, CBCharacteristic)], CBMutableCharacteristic?, CBPeripheralManager?) {
        lock.lock()
        defer { lock.unlock() }

        let peripheralsToSend = peripheralCharacteristics.keys.compactMap { uuid -> (CBPeripheral, CBCharacteristic)? in
            guard let peripheral = connectedPeripherals[uuid],
                  let characteristic = peripheralCharacteristics[uuid] else { return nil }
            return (peripheral, characteristic)
        }

        return (peripheralsToSend, messageCharacteristic, peripheralManager)
    }

    /// Send a message to a specific peer
    /// Uses .withResponse writes with chunking to ensure reliable delivery of large messages
    public func sendToPeer(_ message: MeshMessage, peerID: String) async throws {
        let data = try message.serialize()

        DebugLogger.log("[BLE] sendToPeer: type=\(message.type), peerID=\(peerID.prefix(8))..., size=\(data.count) bytes")

        // Check size - chunking protocol uses 2 bytes for length, so max is 65535
        // But keep a reasonable limit for BLE transfers
        guard data.count <= 16384 else {
            throw MeshError.payloadTooLarge(size: data.count, max: 16384)
        }

        // Find the peripheral for this peer (we write to their characteristic as central)
        guard let (peripheral, characteristic) = getPeripheralForPeer(peerID: peerID) else {
            DebugLogger.log("[BLE] sendToPeer: Peer not found! Checking state...")
            printPeerDebugInfo()
            throw MeshError.peerNotFound(peerID)
        }

        // Get maximum write length for this peripheral
        // For .withResponse, CoreBluetooth handles fragmentation but we need to avoid queue overflow
        // For .withoutResponse, we need to stay within the limit
        let maxWriteLength = peripheral.maximumWriteValueLength(for: .withoutResponse)
        DebugLogger.log("[BLE] sendToPeer: maxWriteLength=\(maxWriteLength), dataSize=\(data.count)")

        if data.count <= maxWriteLength {
            // Data fits in a single write - use .withoutResponse for speed
            DebugLogger.log("[BLE] sendToPeer: Single write with .withoutResponse")
            peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
        } else {
            // Data needs chunking - use .withResponse for reliability and let CoreBluetooth handle it
            // But send in smaller chunks to avoid prepare queue overflow
            DebugLogger.log("[BLE] sendToPeer: Chunked write with .withResponse (data too large for single write)")
            try await sendChunkedData(data, to: peripheral, characteristic: characteristic)
        }

        DebugLogger.log("[BLE] sendToPeer: Write dispatched")
        await meshNode.recordMessageSent(bytes: data.count)
    }

    // MARK: - Chunked Message Protocol
    // Header format: [0xFF (magic)] [totalLen high] [totalLen low] [offset high] [offset low] [data...]
    // Total header size: 5 bytes

    private static let chunkMagicByte: UInt8 = 0xFF
    private static let chunkHeaderSize = 5
    private static let chunkPayloadSize = 507  // 512 - 5 header bytes

    /// Send large data in chunks using .withResponse writes
    /// Each chunk is sent sequentially to avoid prepare queue overflow
    private func sendChunkedData(_ data: Data, to peripheral: CBPeripheral, characteristic: CBCharacteristic) async throws {
        let payloadSize = Self.chunkPayloadSize
        let totalLength = data.count

        var offset = 0
        var chunkIndex = 0
        let totalChunks = (data.count + payloadSize - 1) / payloadSize

        DebugLogger.log("[BLE] sendChunkedData: Sending \(totalChunks) chunks, totalLength=\(totalLength)")

        while offset < data.count {
            let end = min(offset + payloadSize, data.count)
            let payload = data[offset..<end]

            // Build chunk with header
            var chunk = Data(capacity: Self.chunkHeaderSize + payload.count)
            chunk.append(Self.chunkMagicByte)
            chunk.append(UInt8((totalLength >> 8) & 0xFF))  // Total length high byte
            chunk.append(UInt8(totalLength & 0xFF))          // Total length low byte
            chunk.append(UInt8((offset >> 8) & 0xFF))        // Offset high byte
            chunk.append(UInt8(offset & 0xFF))               // Offset low byte
            chunk.append(contentsOf: payload)

            DebugLogger.log("[BLE] sendChunkedData: Chunk \(chunkIndex + 1)/\(totalChunks), offset=\(offset), payloadSize=\(payload.count)")

            // Send chunk with .withResponse and wait for completion
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                bleQueue.async { [weak self] in
                    guard let self = self else {
                        continuation.resume(throwing: MeshError.serviceNotReady)
                        return
                    }

                    self.lock.lock()
                    self.pendingWriteContinuation = continuation
                    self.lock.unlock()

                    peripheral.writeValue(chunk, for: characteristic, type: .withResponse)

                    // Timeout after 5 seconds
                    self.bleQueue.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                        guard let self = self else { return }
                        self.lock.lock()
                        let pending = self.pendingWriteContinuation
                        self.pendingWriteContinuation = nil
                        self.lock.unlock()

                        if let pending = pending {
                            DebugLogger.log("[BLE] sendChunkedData: Chunk \(chunkIndex + 1) timed out")
                            pending.resume(throwing: MeshError.writeTimeout)
                        }
                    }
                }
            }

            offset = end
            chunkIndex += 1

            // Small delay between chunks to let the queue clear
            if offset < data.count {
                try await Task.sleep(nanoseconds: 10_000_000) // 10ms
            }
        }

        DebugLogger.log("[BLE] sendChunkedData: All \(totalChunks) chunks sent successfully")
    }


    /// Thread-safe helper to get a specific peer's peripheral
    private func getPeripheralForPeer(peerID: String) -> (CBPeripheral, CBCharacteristic)? {
        lock.lock()
        defer { lock.unlock() }

        // Find the peripheral UUID that matches this peer ID
        for (uuid, peripheral) in connectedPeripherals {
            if uuid.uuidString == peerID || peripheral.identifier.uuidString == peerID {
                if let characteristic = peripheralCharacteristics[uuid] {
                    return (peripheral, characteristic)
                }
            }
        }

        return nil
    }


    /// Thread-safe helper to print debug info about connected peers
    private func printPeerDebugInfo() {
        lock.lock()
        let connectedKeys = connectedPeripherals.keys.map { $0.uuidString.prefix(8) }
        let charKeys = peripheralCharacteristics.keys.map { $0.uuidString.prefix(8) }
        let subscribedKeys = subscribedCentrals.map { $0.identifier.uuidString.prefix(8) }
        lock.unlock()

        DebugLogger.log("[BLE]   connectedPeripherals: \(connectedKeys)")
        DebugLogger.log("[BLE]   peripheralCharacteristics: \(charKeys)")
        DebugLogger.log("[BLE]   subscribedCentrals: \(subscribedKeys)")
    }

    /// Get the current mesh node
    public func getNode() -> MeshNode {
        meshNode
    }

    /// Get the message relay
    public func getRelay() -> MessageRelay {
        messageRelay
    }

    // MARK: - Central Role (Scanning)

    private func startScanning() {
        guard centralManager.state == .poweredOn else { return }

        // Start duty cycle scanning
        startScanDutyCycle()
    }

    /// Start duty cycle scanning to reduce battery and CPU usage
    private func startScanDutyCycle() {
        // Cancel any existing timer
        scanCycleTimer?.cancel()
        scanCycleTimer = nil

        // Create new timer on BLE queue
        let timer = DispatchSource.makeTimerSource(queue: bleQueue)
        scanCycleTimer = timer

        // Start with scan phase
        isInScanPhase = true
        performScan()

        // Set up repeating timer for duty cycle
        let totalCycle = scanDuration + scanPause
        timer.schedule(deadline: .now() + scanDuration, repeating: totalCycle)
        timer.setEventHandler { [weak self] in
            self?.toggleScanPhase()
        }
        timer.resume()
    }

    /// Toggle between scan and pause phases
    private func toggleScanPhase() {
        if isInScanPhase {
            // End scan phase, start pause
            centralManager.stopScan()
            isInScanPhase = false
            DebugLogger.log("Scan cycle: pausing for \(scanPause)s")

            // Process any pending connections during the pause
            processPendingConnections()

            // Schedule resumption of scanning
            bleQueue.asyncAfter(deadline: .now() + scanPause) { [weak self] in
                guard let self = self, self.isActive else { return }
                self.isInScanPhase = true
                self.performScan()
            }
        }
    }

    /// Actually perform the scan
    private func performScan() {
        guard centralManager.state == .poweredOn, isActive else { return }

        centralManager.scanForPeripherals(
            withServices: [serviceUUID],
            options: [
                CBCentralManagerScanOptionAllowDuplicatesKey: false
            ]
        )
        DebugLogger.log("Scan cycle: scanning for \(scanDuration)s")
    }

    private func stopScanning() {
        // Cancel duty cycle timer
        scanCycleTimer?.cancel()
        scanCycleTimer = nil
        isInScanPhase = false

        centralManager.stopScan()
        DebugLogger.log("Stopped scanning", category: "BLE")
    }

    private func connectToPeripheral(_ peripheral: CBPeripheral) {
        let peripheralID = peripheral.identifier

        lock.lock()
        let alreadyConnected = connectedPeripherals[peripheralID] != nil
        let alreadyPending = pendingConnections[peripheralID] != nil
        let lastAttempt = lastConnectionAttempt[peripheralID]
        lock.unlock()

        // Skip if already connected or pending connection
        guard !alreadyConnected && !alreadyPending else { return }

        // Throttle connection attempts
        if let lastAttempt = lastAttempt {
            let elapsed = Date().timeIntervalSince(lastAttempt)
            if elapsed < connectionThrottleInterval {
                // Store for later connection attempt (this also retains the peripheral)
                lock.lock()
                pendingConnections[peripheralID] = peripheral
                lock.unlock()
                return
            }
        }

        // IMPORTANT: Store the peripheral reference BEFORE calling connect
        // CoreBluetooth requires us to retain the peripheral during connection
        lock.lock()
        lastConnectionAttempt[peripheralID] = Date()
        pendingConnections[peripheralID] = peripheral  // Keep reference during connection
        lock.unlock()

        peripheral.delegate = self
        centralManager.connect(peripheral, options: nil)

        let peerID = peripheral.identifier.uuidString
        Task {
            await meshNode.updatePeer(id: peerID) { peer in
                peer.connectionState = .connecting
            }
        }
    }

    /// Process pending connections that were throttled
    private func processPendingConnections() {
        lock.lock()
        let pending = pendingConnections
        lock.unlock()

        for (_, peripheral) in pending {
            connectToPeripheral(peripheral)
        }
    }

    private func disconnectAll() {
        lock.lock()
        let peripherals = Array(connectedPeripherals.values)
        connectedPeripherals.removeAll()
        peripheralCharacteristics.removeAll()
        pendingConnections.removeAll()
        lastConnectionAttempt.removeAll()
        lastDiscoveryTime.removeAll()
        lock.unlock()

        for peripheral in peripherals {
            centralManager.cancelPeripheralConnection(peripheral)
        }
    }

    // MARK: - Peripheral Role (Advertising)

    private func startAdvertising() {
        guard peripheralManager.state == .poweredOn else { return }

        // Create service and characteristic
        let characteristic = CBMutableCharacteristic(
            type: messageCharacteristicUUID,
            properties: [.read, .write, .writeWithoutResponse, .notify],
            value: nil,
            permissions: [.readable, .writeable]
        )

        lock.lock()
        self.messageCharacteristic = characteristic
        self.isServiceAdded = false
        lock.unlock()

        let service = CBMutableService(type: serviceUUID, primary: true)
        service.characteristics = [characteristic]

        // Add service - advertising will start in didAdd callback
        peripheralManager.add(service)
        DebugLogger.log("Adding mesh service...", category: "BLE")
    }

    private func stopAdvertising() {
        peripheralManager.stopAdvertising()
        peripheralManager.removeAllServices()

        lock.lock()
        subscribedCentrals.removeAll()
        isServiceAdded = false
        lock.unlock()

        DebugLogger.log("Stopped advertising", category: "BLE")
    }

    // MARK: - Message Processing

    private func handleReceivedData(_ data: Data, from peerID: String) {
        let meshNode = self.meshNode
        let selfRef = self

        Task {
            await meshNode.recordBytesReceived(data.count)

            do {
                let message = try MeshMessage.deserialize(from: data)
                DebugLogger.log("[BLE] Received message type: \(message.type) from peer: \(peerID.prefix(8))...")
                let result = await meshNode.processIncomingMessage(message)
                DebugLogger.log("[BLE] Process result: \(result)")

                switch result {
                case .relay(let forwardMessage):
                    // Relay to other peers
                    await meshNode.recordMessageRelayed()
                    try? await selfRef.broadcastMessage(forwardMessage)

                case .processed:
                    // Message handled - notify delegate on main actor
                    await selfRef.notifyMessageProcessed(message)

                case .duplicate, .expired, .invalid:
                    // Ignored
                    break
                }
            } catch {
                DebugLogger.log("[BLE] Failed to process message: \(error)")
            }
        }
    }

    @MainActor
    private func notifyMessageProcessed(_ message: MeshMessage) {
        delegate?.bleService(self, didProcessMessage: message)
    }

    @MainActor
    private func notifyPeerDiscovered(_ peer: MeshPeer) {
        delegate?.bleService(self, didDiscoverPeer: peer)
    }

    /// Refresh the published peer lists from mesh node state
    private func refreshPeerLists() async {
        let allPeers = await meshNode.getAllPeers()
        let discovered = allPeers.filter { $0.connectionState == .disconnected }
        let connected = allPeers.filter { $0.connectionState == .connected }

        await MainActor.run {
            self.discoveredPeers = discovered
            self.connectedPeers = connected
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEMeshService: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = central.state

        updateOnMain { [weak self] in
            self?.bluetoothState = state
        }

        switch state {
        case .poweredOn:
            // Try to start if we want to be active
            tryStart()
        case .poweredOff, .unauthorized, .unsupported:
            updateOnMain { [weak self] in
                self?.isActive = false
            }
        default:
            break
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let peripheralID = peripheral.identifier

        // Throttle discovery updates for the same peer
        lock.lock()
        let lastDiscovery = lastDiscoveryTime[peripheralID]
        let shouldProcess: Bool
        if let lastDiscovery = lastDiscovery {
            shouldProcess = Date().timeIntervalSince(lastDiscovery) >= discoveryThrottleInterval
        } else {
            shouldProcess = true
        }

        if shouldProcess {
            lastDiscoveryTime[peripheralID] = Date()
        }
        lock.unlock()

        // Skip processing if throttled (but still attempt connection)
        guard shouldProcess else {
            // Still try to connect even if we throttle the discovery update
            connectToPeripheral(peripheral)
            return
        }

        let peerID = peripheral.identifier.uuidString
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        let rssiValue = RSSI.intValue
        let meshNode = self.meshNode
        let selfRef = self

        Task {
            let existingPeer = await meshNode.getPeer(id: peerID)

            if existingPeer == nil {
                let peer = MeshPeer(
                    id: peerID,
                    name: name,
                    rssi: rssiValue,
                    connectionState: .disconnected
                )
                await meshNode.addPeer(peer)
                await selfRef.notifyPeerDiscovered(peer)
            } else {
                await meshNode.updatePeer(id: peerID) { peer in
                    peer.rssi = rssiValue
                    peer.markSeen()
                }
            }

            // Update the published discoveredPeers list
            await selfRef.refreshPeerLists()
        }

        // Auto-connect to discovered peers
        connectToPeripheral(peripheral)
    }

    public func centralManager(
        _ central: CBCentralManager,
        didConnect peripheral: CBPeripheral
    ) {
        let peerID = peripheral.identifier.uuidString
        let peripheralID = peripheral.identifier

        lock.lock()
        // Move from pending to connected
        pendingConnections.removeValue(forKey: peripheralID)
        connectedPeripherals[peripheralID] = peripheral
        lock.unlock()

        let meshNode = self.meshNode
        let selfRef = self
        Task {
            await meshNode.updatePeer(id: peerID) { peer in
                peer.connectionState = .connected
            }
            // Update published peer lists
            await selfRef.refreshPeerLists()
        }

        // Discover services
        peripheral.discoverServices([serviceUUID])
        DebugLogger.log("Connected to peer: \(peerID)")
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        let peerID = peripheral.identifier.uuidString
        let peripheralID = peripheral.identifier

        lock.lock()
        pendingConnections.removeValue(forKey: peripheralID)
        connectedPeripherals.removeValue(forKey: peripheralID)
        peripheralCharacteristics.removeValue(forKey: peripheralID)
        lock.unlock()

        let meshNode = self.meshNode
        let selfRef = self
        Task {
            await meshNode.updatePeer(id: peerID) { peer in
                peer.connectionState = .disconnected
            }
            // Update published peer lists
            await selfRef.refreshPeerLists()
        }

        DebugLogger.log("Disconnected from peer: \(peerID)")

        // Attempt reconnection if still active
        if isActive {
            bleQueue.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.connectToPeripheral(peripheral)
            }
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        let peerID = peripheral.identifier.uuidString
        let peripheralID = peripheral.identifier

        // Clean up pending connection
        lock.lock()
        pendingConnections.removeValue(forKey: peripheralID)
        lock.unlock()

        let meshNode = self.meshNode
        let selfRef = self
        Task {
            await meshNode.updatePeer(id: peerID) { peer in
                peer.connectionState = .disconnected
            }
            await selfRef.refreshPeerLists()
        }

        DebugLogger.log("Failed to connect to peer: \(peerID), error: \(error?.localizedDescription ?? "unknown")")
    }
}

// MARK: - CBPeripheralDelegate

extension BLEMeshService: CBPeripheralDelegate {
    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverServices error: Error?
    ) {
        if let error = error {
            DebugLogger.log("[BLE] Failed to discover services: \(error.localizedDescription)")
            return
        }

        guard let services = peripheral.services else {
            DebugLogger.log("[BLE] No services found for peer: \(peripheral.identifier.uuidString.prefix(8))...")
            return
        }

        DebugLogger.log("[BLE] Discovered \(services.count) services for peer: \(peripheral.identifier.uuidString.prefix(8))...")

        for service in services where service.uuid == serviceUUID {
            DebugLogger.log("[BLE] Found mesh service, discovering characteristics...")
            peripheral.discoverCharacteristics([messageCharacteristicUUID], for: service)
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        if let error = error {
            DebugLogger.log("[BLE] Failed to discover characteristics: \(error.localizedDescription)")
            return
        }

        guard let characteristics = service.characteristics else {
            DebugLogger.log("[BLE] No characteristics found for service")
            return
        }

        DebugLogger.log("[BLE] Discovered \(characteristics.count) characteristics for peer: \(peripheral.identifier.uuidString.prefix(8))...")

        for characteristic in characteristics where characteristic.uuid == messageCharacteristicUUID {
            DebugLogger.log("[BLE] Found message characteristic, storing for peer: \(peripheral.identifier.uuidString.prefix(8))...")

            lock.lock()
            peripheralCharacteristics[peripheral.identifier] = characteristic
            lock.unlock()

            // Subscribe to notifications
            peripheral.setNotifyValue(true, for: characteristic)
            DebugLogger.log("[BLE] Subscribed to notifications for peer: \(peripheral.identifier.uuidString.prefix(8))...")
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard let data = characteristic.value, !data.isEmpty else { return }

        let peerID = peripheral.identifier.uuidString

        // Check if this is a chunked notification (starts with magic byte)
        if data[0] == Self.chunkMagicByte && data.count >= Self.chunkHeaderSize {
            DebugLogger.log("[BLE] Received chunked notification from \(peerID.prefix(8))...")
            handleChunkedWrite(data: data, from: peerID)
        } else {
            // Regular (non-chunked) notification
            handleReceivedData(data, from: peerID)
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        // Resume pending continuation for chunked writes
        lock.lock()
        let continuation = pendingWriteContinuation
        pendingWriteContinuation = nil
        lock.unlock()

        if let error = error {
            DebugLogger.log("[BLE] Write callback - failed: \(error.localizedDescription)")
            continuation?.resume(throwing: error)
        } else {
            DebugLogger.log("[BLE] Write callback - succeeded for peer: \(peripheral.identifier.uuidString.prefix(8))...")
            continuation?.resume()
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error = error {
            DebugLogger.log("[BLE] Notification subscription failed: \(error.localizedDescription)")
            return
        }

        DebugLogger.log("[BLE] Notification state updated for peer: \(peripheral.identifier.uuidString.prefix(8))..., isNotifying: \(characteristic.isNotifying)")
    }
}

// MARK: - CBPeripheralManagerDelegate

extension BLEMeshService: CBPeripheralManagerDelegate {
    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            // Try to start if we want to be active
            tryStart()
        case .poweredOff, .unauthorized, .unsupported:
            break
        default:
            break
        }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error = error {
            DebugLogger.log("Failed to add service: \(error.localizedDescription)")
            return
        }

        lock.lock()
        isServiceAdded = true
        lock.unlock()

        DebugLogger.log("Service added successfully, now advertising...", category: "BLE")

        // NOW start advertising
        peripheral.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [serviceUUID],
            CBAdvertisementDataLocalNameKey: "MeshStealth"
        ])

        DebugLogger.log("Started advertising mesh service", category: "BLE")
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didReceiveWrite requests: [CBATTRequest]
    ) {
        DebugLogger.log("[BLE] didReceiveWrite: \(requests.count) requests")

        for request in requests {
            guard let data = request.value, !data.isEmpty else { continue }

            let peerID = request.central.identifier.uuidString
            DebugLogger.log("[BLE] Request from \(peerID.prefix(8))..., offset: \(request.offset), size: \(data.count)")

            // Check if this is a chunked message (starts with magic byte)
            if data[0] == Self.chunkMagicByte && data.count >= Self.chunkHeaderSize {
                handleChunkedWrite(data: data, from: peerID)
            } else {
                // Regular (non-chunked) message - process directly
                DebugLogger.log("[BLE] Received regular write: \(data.count) bytes from central: \(peerID.prefix(8))...")
                handleReceivedData(data, from: peerID)
            }
        }

        // Respond to all requests (required for .withResponse writes)
        for request in requests {
            peripheral.respond(to: request, withResult: .success)
        }
    }

    /// Handle a chunk of a chunked message - buffer and reassemble
    private func handleChunkedWrite(data: Data, from peerID: String) {
        // Parse header: [magic] [totalLen high] [totalLen low] [offset high] [offset low] [payload...]
        let totalLength = (Int(data[1]) << 8) | Int(data[2])
        let chunkOffset = (Int(data[3]) << 8) | Int(data[4])
        let payload = data.dropFirst(Self.chunkHeaderSize)

        DebugLogger.log("[BLE] Chunk received: totalLen=\(totalLength), offset=\(chunkOffset), payloadSize=\(payload.count)")

        lock.lock()

        // Get or create buffer for this peer
        var buffer = reassemblyBuffers[peerID]

        if buffer == nil || buffer!.totalLength != totalLength {
            // Start new reassembly
            buffer = (totalLength: totalLength, data: Data(count: totalLength))
            DebugLogger.log("[BLE] Started new reassembly buffer for \(peerID.prefix(8))..., totalLength=\(totalLength)")
        }

        // Copy payload into buffer at the correct offset
        let endOffset = min(chunkOffset + payload.count, totalLength)
        buffer!.data.replaceSubrange(chunkOffset..<endOffset, with: payload.prefix(endOffset - chunkOffset))

        reassemblyBuffers[peerID] = buffer

        // Check if reassembly is complete (we've received up to totalLength)
        // Note: This simple check assumes chunks arrive in order; for robustness, track received ranges
        let receivedUpTo = chunkOffset + payload.count

        lock.unlock()

        DebugLogger.log("[BLE] Buffer progress: received up to \(receivedUpTo)/\(totalLength)")

        if receivedUpTo >= totalLength {
            // Reassembly complete
            lock.lock()
            let completeData = reassemblyBuffers[peerID]?.data
            reassemblyBuffers.removeValue(forKey: peerID)
            lock.unlock()

            if let data = completeData {
                DebugLogger.log("[BLE] Reassembly complete: \(data.count) bytes from \(peerID.prefix(8))...")
                handleReceivedData(data, from: peerID)
            }
        }
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        lock.lock()
        if !subscribedCentrals.contains(where: { $0.identifier == central.identifier }) {
            subscribedCentrals.append(central)
        }
        lock.unlock()

        DebugLogger.log("Central subscribed: \(central.identifier)")
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        lock.lock()
        subscribedCentrals.removeAll { $0.identifier == central.identifier }
        lock.unlock()

        DebugLogger.log("Central unsubscribed: \(central.identifier)")
    }
}

// MARK: - Delegate Protocol

/// Delegate for BLE mesh service events
public protocol BLEMeshServiceDelegate: AnyObject {
    /// Called when a peer is discovered
    @MainActor func bleService(_ service: BLEMeshService, didDiscoverPeer peer: MeshPeer)

    /// Called when a message is processed
    @MainActor func bleService(_ service: BLEMeshService, didProcessMessage message: MeshMessage)

    /// Called when an error occurs
    @MainActor func bleService(_ service: BLEMeshService, didEncounterError error: Error)
}

// MARK: - Default Delegate Implementation

public extension BLEMeshServiceDelegate {
    func bleService(_ service: BLEMeshService, didDiscoverPeer peer: MeshPeer) {}
    func bleService(_ service: BLEMeshService, didProcessMessage message: MeshMessage) {}
    func bleService(_ service: BLEMeshService, didEncounterError error: Error) {}
}
