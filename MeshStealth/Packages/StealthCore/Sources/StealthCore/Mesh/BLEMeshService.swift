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
        bleQueue.async { [weak self] in
            guard let self = self else { return }
            guard self.centralManager.state == .poweredOn else {
                print("Bluetooth not ready, state: \(self.centralManager.state.rawValue)")
                return
            }

            self.startScanning()
            self.startAdvertising()
            self.updateOnMain {
                self.isActive = true
            }
        }
    }

    /// Stop mesh networking
    public func stop() {
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

        // Check size
        guard data.count <= 4096 else {
            throw MeshError.payloadTooLarge(size: data.count, max: 4096)
        }

        // Capture values synchronously before async boundary
        let (peripheralsToSend, characteristic, manager) = getPeripheralsForBroadcast()

        // Send to all connected peripherals (as central)
        for (peripheral, char) in peripheralsToSend {
            peripheral.writeValue(data, for: char, type: .withResponse)
        }

        // Send to all subscribed centrals (as peripheral)
        if let characteristic = characteristic {
            manager?.updateValue(data, for: characteristic, onSubscribedCentrals: nil)
        }

        await meshNode.recordMessageSent(bytes: data.count)
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
    public func sendToPeer(_ message: MeshMessage, peerID: String) async throws {
        let data = try message.serialize()

        // Check size
        guard data.count <= 4096 else {
            throw MeshError.payloadTooLarge(size: data.count, max: 4096)
        }

        // Find the peripheral for this peer
        let targetPeripheral = getPeripheralForPeer(peerID: peerID)

        guard let (peripheral, characteristic) = targetPeripheral else {
            throw MeshError.peerNotFound(peerID)
        }

        // Send to the specific peer
        peripheral.writeValue(data, for: characteristic, type: .withResponse)

        await meshNode.recordMessageSent(bytes: data.count)
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
            print("Scan cycle: pausing for \(scanPause)s")

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
        print("Scan cycle: scanning for \(scanDuration)s")
    }

    private func stopScanning() {
        // Cancel duty cycle timer
        scanCycleTimer?.cancel()
        scanCycleTimer = nil
        isInScanPhase = false

        centralManager.stopScan()
        print("Stopped scanning")
    }

    private func connectToPeripheral(_ peripheral: CBPeripheral) {
        let peripheralID = peripheral.identifier

        lock.lock()
        let alreadyConnected = connectedPeripherals[peripheralID] != nil
        let lastAttempt = lastConnectionAttempt[peripheralID]
        lock.unlock()

        // Skip if already connected
        guard !alreadyConnected else { return }

        // Throttle connection attempts
        if let lastAttempt = lastAttempt {
            let elapsed = Date().timeIntervalSince(lastAttempt)
            if elapsed < connectionThrottleInterval {
                // Store for later connection attempt
                lock.lock()
                pendingConnections[peripheralID] = peripheral
                lock.unlock()
                return
            }
        }

        // Record this connection attempt
        lock.lock()
        lastConnectionAttempt[peripheralID] = Date()
        pendingConnections.removeValue(forKey: peripheralID)
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
            properties: [.read, .write, .notify],
            value: nil,
            permissions: [.readable, .writeable]
        )

        lock.lock()
        self.messageCharacteristic = characteristic
        lock.unlock()

        let service = CBMutableService(type: serviceUUID, primary: true)
        service.characteristics = [characteristic]

        peripheralManager.add(service)

        // Start advertising
        peripheralManager.startAdvertising([
            CBAdvertisementDataServiceUUIDsKey: [serviceUUID],
            CBAdvertisementDataLocalNameKey: "MeshStealth"
        ])

        print("Started advertising mesh service")
    }

    private func stopAdvertising() {
        peripheralManager.stopAdvertising()
        peripheralManager.removeAllServices()

        lock.lock()
        subscribedCentrals.removeAll()
        lock.unlock()

        print("Stopped advertising")
    }

    // MARK: - Message Processing

    private func handleReceivedData(_ data: Data, from peerID: String) {
        let meshNode = self.meshNode
        let selfRef = self

        Task {
            await meshNode.recordBytesReceived(data.count)

            do {
                let message = try MeshMessage.deserialize(from: data)
                let result = await meshNode.processIncomingMessage(message)

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
                print("Failed to process message: \(error)")
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
            let wasActive = self.isActive
            if wasActive {
                startScanning()
            }
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
        connectedPeripherals[peripheralID] = peripheral
        lock.unlock()

        let meshNode = self.meshNode
        Task {
            await meshNode.updatePeer(id: peerID) { peer in
                peer.connectionState = .connected
            }
        }

        // Discover services
        peripheral.discoverServices([serviceUUID])
        print("Connected to peer: \(peerID)")
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        let peerID = peripheral.identifier.uuidString
        let peripheralID = peripheral.identifier

        lock.lock()
        connectedPeripherals.removeValue(forKey: peripheralID)
        peripheralCharacteristics.removeValue(forKey: peripheralID)
        lock.unlock()

        let meshNode = self.meshNode
        Task {
            await meshNode.updatePeer(id: peerID) { peer in
                peer.connectionState = .disconnected
            }
        }

        print("Disconnected from peer: \(peerID)")

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

        let meshNode = self.meshNode
        Task {
            await meshNode.updatePeer(id: peerID) { peer in
                peer.connectionState = .disconnected
            }
        }

        print("Failed to connect to peer: \(peerID), error: \(error?.localizedDescription ?? "unknown")")
    }
}

// MARK: - CBPeripheralDelegate

extension BLEMeshService: CBPeripheralDelegate {
    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverServices error: Error?
    ) {
        guard let services = peripheral.services else { return }

        for service in services where service.uuid == serviceUUID {
            peripheral.discoverCharacteristics([messageCharacteristicUUID], for: service)
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard let characteristics = service.characteristics else { return }

        for characteristic in characteristics where characteristic.uuid == messageCharacteristicUUID {
            lock.lock()
            peripheralCharacteristics[peripheral.identifier] = characteristic
            lock.unlock()

            // Subscribe to notifications
            peripheral.setNotifyValue(true, for: characteristic)
        }
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard let data = characteristic.value else { return }

        let peerID = peripheral.identifier.uuidString
        handleReceivedData(data, from: peerID)
    }

    public func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error = error {
            print("Write failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - CBPeripheralManagerDelegate

extension BLEMeshService: CBPeripheralManagerDelegate {
    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            if isActive {
                startAdvertising()
            }
        case .poweredOff, .unauthorized, .unsupported:
            break
        default:
            break
        }
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        didReceiveWrite requests: [CBATTRequest]
    ) {
        for request in requests {
            if let data = request.value {
                handleReceivedData(data, from: request.central.identifier.uuidString)
            }
            peripheral.respond(to: request, withResult: .success)
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

        print("Central subscribed: \(central.identifier)")
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        lock.lock()
        subscribedCentrals.removeAll { $0.identifier == central.identifier }
        lock.unlock()

        print("Central unsubscribed: \(central.identifier)")
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
