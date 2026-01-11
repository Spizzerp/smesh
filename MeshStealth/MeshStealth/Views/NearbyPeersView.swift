import SwiftUI
import StealthCore

struct NearbyPeersView: View {
    @EnvironmentObject var meshViewModel: MeshViewModel
    @State private var showingSendSheet = false
    @State private var selectedPeer: NearbyPeer?
    @State private var showingAddressRequest = false

    var body: some View {
        NavigationStack {
            ZStack {
                // Background
                Color(.systemGroupedBackground)
                    .ignoresSafeArea()

                if meshViewModel.hasNearbyPeers {
                    ScrollView {
                        VStack(spacing: 20) {
                            // Closest peer highlight (tap to pay zone)
                            if let closest = meshViewModel.closestPeer {
                                TapToPayCard(peer: closest) {
                                    selectedPeer = closest
                                    requestAddressFromPeer(closest)
                                }
                            }

                            // Other nearby peers
                            if meshViewModel.nearbyPeers.count > 1 {
                                OtherPeersSection(
                                    peers: meshViewModel.nearbyPeers.filter { $0.id != meshViewModel.closestPeer?.id },
                                    onSelect: { peer in
                                        selectedPeer = peer
                                        requestAddressFromPeer(peer)
                                    }
                                )
                            }
                        }
                        .padding()
                    }
                } else {
                    ScanningView(isActive: meshViewModel.isActive)
                }
            }
            .navigationTitle("Nearby")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        if meshViewModel.isActive {
                            meshViewModel.stopMesh()
                        } else {
                            meshViewModel.startMesh()
                        }
                    } label: {
                        Image(systemName: meshViewModel.isActive ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                    }
                }
            }
            .sheet(isPresented: $showingSendSheet) {
                if let peer = selectedPeer, let response = meshViewModel.receivedMetaAddress {
                    SendPaymentSheet(
                        peer: peer,
                        metaAddress: response.metaAddress,
                        isHybrid: response.isHybrid
                    )
                }
            }
            .alert("Address Request", isPresented: $showingAddressRequest) {
                Button("Share Address") {
                    if let request = meshViewModel.pendingMetaAddressRequest {
                        Task {
                            await meshViewModel.respondToMetaAddressRequest(request)
                        }
                    }
                }
                Button("Decline", role: .cancel) {
                    meshViewModel.declineMetaAddressRequest()
                }
            } message: {
                if let request = meshViewModel.pendingMetaAddressRequest {
                    Text("A nearby device wants to send you a payment. Share your address?")
                }
            }
            .onChange(of: meshViewModel.pendingMetaAddressRequest) { _, request in
                showingAddressRequest = request != nil
            }
            .onChange(of: meshViewModel.receivedMetaAddress) { _, response in
                if response != nil {
                    showingSendSheet = true
                }
            }
        }
    }

    private func requestAddressFromPeer(_ peer: NearbyPeer) {
        Task {
            await meshViewModel.requestMetaAddress(from: peer)
        }
    }
}

// MARK: - Tap to Pay Card

struct TapToPayCard: View {
    let peer: NearbyPeer
    let onTap: () -> Void

    @State private var isPulsing = false

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 16) {
                // Pulsing indicator
                ZStack {
                    Circle()
                        .fill(Color.blue.opacity(0.1))
                        .frame(width: 120, height: 120)
                        .scaleEffect(isPulsing ? 1.2 : 1.0)
                        .opacity(isPulsing ? 0 : 1)

                    Circle()
                        .fill(Color.blue.opacity(0.2))
                        .frame(width: 100, height: 100)

                    Image(systemName: "hand.tap.fill")
                        .font(.system(size: 40))
                        .foregroundColor(.blue)
                }

                VStack(spacing: 4) {
                    Text("Tap to Send")
                        .font(.title2)
                        .fontWeight(.bold)

                    Text(peer.name ?? "Unknown Device")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    HStack(spacing: 4) {
                        SignalStrengthIndicator(strength: peer.signalStrength)
                        Text(peer.proximityDescription)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                if peer.supportsHybrid {
                    Label("Post-Quantum Secure", systemImage: "lock.shield.fill")
                        .font(.caption)
                        .foregroundColor(.purple)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .fill(Color(.systemBackground))
                    .shadow(color: .blue.opacity(0.2), radius: 20, y: 10)
            )
        }
        .buttonStyle(ScaleButtonStyle())
        .onAppear {
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: false)) {
                isPulsing = true
            }
        }
    }
}

struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Other Peers Section

struct OtherPeersSection: View {
    let peers: [NearbyPeer]
    let onSelect: (NearbyPeer) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Other Nearby Devices")
                .font(.headline)
                .foregroundColor(.secondary)

            ForEach(peers) { peer in
                PeerRow(peer: peer) {
                    onSelect(peer)
                }
            }
        }
    }
}

struct PeerRow: View {
    let peer: NearbyPeer
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Signal indicator
                SignalStrengthIndicator(strength: peer.signalStrength)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(peer.name ?? "Unknown Device")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)

                    Text(peer.proximityDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                if peer.supportsHybrid {
                    Image(systemName: "lock.shield.fill")
                        .font(.caption)
                        .foregroundColor(.purple)
                }

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(.systemBackground))
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Signal Strength Indicator

struct SignalStrengthIndicator: View {
    let strength: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<4) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(barColor(for: index))
                    .frame(width: 4, height: CGFloat(6 + index * 3))
            }
        }
    }

    private func barColor(for index: Int) -> Color {
        let threshold = index * 25
        if strength >= threshold {
            switch strength {
            case 75...: return .green
            case 50..<75: return .yellow
            default: return .orange
            }
        }
        return .gray.opacity(0.3)
    }
}

// MARK: - Scanning View

struct ScanningView: View {
    let isActive: Bool

    @State private var rotation = 0.0

    var body: some View {
        VStack(spacing: 24) {
            ZStack {
                Circle()
                    .stroke(Color.blue.opacity(0.2), lineWidth: 2)
                    .frame(width: 150, height: 150)

                Circle()
                    .trim(from: 0, to: 0.3)
                    .stroke(Color.blue, lineWidth: 2)
                    .frame(width: 150, height: 150)
                    .rotationEffect(.degrees(rotation))

                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 50))
                    .foregroundColor(.blue)
            }

            VStack(spacing: 8) {
                Text(isActive ? "Scanning for nearby devices..." : "Mesh Inactive")
                    .font(.headline)

                Text(isActive ? "Move closer to another device to connect" : "Tap the antenna icon to start scanning")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 40)
        }
        .onAppear {
            if isActive {
                withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
        }
        .onChange(of: isActive) { _, active in
            if active {
                withAnimation(.linear(duration: 2).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
        }
    }
}

#Preview {
    NearbyPeersView()
}
