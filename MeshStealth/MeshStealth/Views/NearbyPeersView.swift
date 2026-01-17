import SwiftUI
import StealthCore

struct NearbyPeersView: View {
    @EnvironmentObject var meshViewModel: MeshViewModel
    @State private var showingSendSheet = false
    @State private var selectedPeer: NearbyPeer?
    @State private var showingAddressRequest = false

    var body: some View {
        NavigationStack {
            mainContent
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(TerminalPalette.background, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
                .toolbar { toolbarContent }
                .sheet(isPresented: $showingSendSheet) { sendSheetContent }
                .alert("Address Request", isPresented: $showingAddressRequest) {
                    alertButtons
                } message: {
                    alertMessage
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

    // MARK: - Main Content

    @ViewBuilder
    private var mainContent: some View {
        ZStack {
            TerminalPalette.background
                .ignoresSafeArea()

            ScanlineOverlay()
                .ignoresSafeArea()

            if meshViewModel.hasNearbyPeers {
                peersScrollView
            } else {
                TerminalScanningView(isActive: meshViewModel.isActive)
            }
        }
    }

    @ViewBuilder
    private var peersScrollView: some View {
        ScrollView {
            VStack(spacing: 16) {
                closestPeerCard
                otherPeersSection
            }
            .padding(.horizontal, 16)
            .padding(.top, 40)
            .padding(.bottom, 16)
        }
    }

    @ViewBuilder
    private var closestPeerCard: some View {
        if let closest = meshViewModel.closestPeer {
            TerminalTapToPayCard(peer: closest) {
                selectedPeer = closest
                requestAddressFromPeer(closest)
            }
        }
    }

    @ViewBuilder
    private var otherPeersSection: some View {
        if meshViewModel.nearbyPeers.count > 1 {
            let otherPeers = meshViewModel.nearbyPeers.filter { $0.id != meshViewModel.closestPeer?.id }
            TerminalOtherPeersSection(
                peers: otherPeers,
                onSelect: { peer in
                    selectedPeer = peer
                    requestAddressFromPeer(peer)
                }
            )
        }
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            HStack(spacing: 6) {
                Text("//")
                    .foregroundColor(TerminalPalette.textMuted)
                Text("MESH")
                    .foregroundColor(TerminalPalette.cyan)
                Text("v1.0")
                    .foregroundColor(TerminalPalette.textMuted)
            }
            .font(TerminalTypography.header(14))
        }
        ToolbarItem(placement: .topBarTrailing) {
            meshToggleButton
        }
    }

    private var meshToggleButton: some View {
        Button {
            if meshViewModel.isActive {
                meshViewModel.stopMesh()
            } else {
                meshViewModel.startMesh()
            }
        } label: {
            Text(meshViewModel.isActive ? "[ACTIVE]" : "[START]")
                .font(TerminalTypography.label())
                .foregroundColor(meshViewModel.isActive ? TerminalPalette.success : TerminalPalette.cyan)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sheet

    @ViewBuilder
    private var sendSheetContent: some View {
        if let peer = selectedPeer, let response = meshViewModel.receivedMetaAddress {
            SendPaymentSheet(
                peer: peer,
                metaAddress: response.metaAddress,
                isHybrid: response.isHybrid
            )
        }
    }

    // MARK: - Alert

    @ViewBuilder
    private var alertButtons: some View {
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
    }

    @ViewBuilder
    private var alertMessage: some View {
        Text("A nearby device wants to send you a payment. Share your address?")
    }

    // MARK: - Actions

    private func requestAddressFromPeer(_ peer: NearbyPeer) {
        Task {
            await meshViewModel.requestMetaAddress(from: peer)
        }
    }
}

// MARK: - Terminal Tap to Pay Card

struct TerminalTapToPayCard: View {
    let peer: NearbyPeer
    let onTap: () -> Void

    @State private var cursorVisible = true

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 0) {
                // Title bar
                TerminalTitleBar(title: "[TARGET_NODE]", accent: .public)

                VStack(spacing: 16) {
                    // ASCII art tap indicator
                    VStack(spacing: 4) {
                        Text("┌─────────────┐")
                        Text("│  [>_SEND]   │")
                        Text("│             │")
                        Text("│    ◉◉◉◉     │")
                        Text("│             │")
                        Text("└─────────────┘")
                    }
                    .font(TerminalTypography.body(14))
                    .foregroundColor(TerminalPalette.cyan)
                    .terminalGlow(TerminalPalette.cyan, radius: 4)

                    // Device info
                    VStack(spacing: 8) {
                        HStack(spacing: 8) {
                            Text(">")
                                .foregroundColor(TerminalPalette.cyan)
                            Text("TAP TO SEND")
                                .foregroundColor(TerminalPalette.textPrimary)
                            if cursorVisible {
                                Text("_")
                                    .foregroundColor(TerminalPalette.cyan)
                            }
                        }
                        .font(TerminalTypography.header())

                        Text("// \(peer.name ?? "UNKNOWN_NODE")")
                            .font(TerminalTypography.label())
                            .foregroundColor(TerminalPalette.textMuted)

                        HStack(spacing: 12) {
                            TerminalSignalIndicator(strength: peer.signalStrength)
                            Text(peer.proximityDescription.uppercased())
                                .font(TerminalTypography.label())
                                .foregroundColor(TerminalPalette.textDim)
                        }
                    }

                    // Post-quantum badge
                    if peer.supportsHybrid {
                        TerminalQuantumBadge(accent: .stealth)
                    }
                }
                .padding(16)
            }
            .background(
                RoundedRectangle(cornerRadius: 2)
                    .fill(TerminalPalette.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(TerminalAccent.public.dimColor, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(TerminalScaleButtonStyle())
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                cursorVisible.toggle()
            }
        }
    }
}

struct TerminalScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Terminal Other Peers Section

struct TerminalOtherPeersSection: View {
    let peers: [NearbyPeer]
    let onSelect: (NearbyPeer) -> Void

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            TerminalTitleBar(title: "[OTHER_NODES]", accent: .public)

            VStack(spacing: 0) {
                ForEach(Array(peers.enumerated()), id: \.element.id) { index, peer in
                    TerminalPeerRow(peer: peer, index: index) {
                        onSelect(peer)
                    }

                    if index < peers.count - 1 {
                        Rectangle()
                            .fill(TerminalPalette.border)
                            .frame(height: 1)
                    }
                }
            }
            .padding(12)
        }
        .background(
            RoundedRectangle(cornerRadius: 2)
                .fill(TerminalPalette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(TerminalAccent.public.dimColor, lineWidth: 1)
                )
        )
    }
}

struct TerminalPeerRow: View {
    let peer: NearbyPeer
    let index: Int
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Index number
                Text(String(format: "%02d", index + 1))
                    .font(TerminalTypography.label())
                    .foregroundColor(TerminalPalette.textMuted)

                // Signal indicator
                TerminalSignalIndicator(strength: peer.signalStrength)

                VStack(alignment: .leading, spacing: 2) {
                    Text(peer.name ?? "UNKNOWN_NODE")
                        .font(TerminalTypography.body(12))
                        .foregroundColor(TerminalPalette.textPrimary)

                    Text(peer.proximityDescription.uppercased())
                        .font(TerminalTypography.label())
                        .foregroundColor(TerminalPalette.textMuted)
                }

                Spacer()

                if peer.supportsHybrid {
                    Text("[PQ]")
                        .font(TerminalTypography.label())
                        .foregroundColor(TerminalPalette.purple)
                }

                Text("[>]")
                    .font(TerminalTypography.label())
                    .foregroundColor(TerminalPalette.cyan)
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Terminal Signal Indicator

struct TerminalSignalIndicator: View {
    let strength: Int

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<4, id: \.self) { index in
                Rectangle()
                    .fill(barColor(for: index))
                    .frame(width: 3, height: CGFloat(4 + index * 3))
            }
        }
    }

    private func barColor(for index: Int) -> Color {
        let threshold = index * 25
        if strength >= threshold {
            switch strength {
            case 75...: return TerminalPalette.success
            case 50..<75: return TerminalPalette.warning
            default: return TerminalPalette.error
            }
        }
        return TerminalPalette.border
    }
}

// MARK: - Terminal Scanning View

struct TerminalScanningView: View {
    let isActive: Bool

    @State private var pulseScale: CGFloat = 1.0
    @State private var pulseOpacity: Double = 0.8
    @State private var spinnerIndex = 0
    private let spinnerFrames = ["|", "/", "-", "\\"]

    var body: some View {
        VStack(spacing: 32) {
            // Pulsating circle radar
            ZStack {
                // Outer pulse rings (when active)
                if isActive {
                    ForEach(0..<3, id: \.self) { index in
                        Circle()
                            .stroke(TerminalPalette.cyan, lineWidth: 1)
                            .frame(width: 120, height: 120)
                            .scaleEffect(pulseScale + CGFloat(index) * 0.3)
                            .opacity(pulseOpacity - Double(index) * 0.25)
                    }
                }

                // Static outer ring
                Circle()
                    .stroke(isActive ? TerminalPalette.cyan : TerminalPalette.textMuted, lineWidth: 2)
                    .frame(width: 120, height: 120)

                // Middle ring
                Circle()
                    .stroke(isActive ? TerminalPalette.cyan.opacity(0.5) : TerminalPalette.textMuted.opacity(0.3), lineWidth: 1)
                    .frame(width: 80, height: 80)

                // Inner ring
                Circle()
                    .stroke(isActive ? TerminalPalette.cyan.opacity(0.3) : TerminalPalette.textMuted.opacity(0.2), lineWidth: 1)
                    .frame(width: 40, height: 40)

                // Center dot
                Circle()
                    .fill(isActive ? TerminalPalette.cyan : TerminalPalette.textMuted)
                    .frame(width: 8, height: 8)
                    .shadow(color: isActive ? TerminalPalette.cyan : .clear, radius: 8)
            }
            .frame(width: 160, height: 160)

            // Status text
            VStack(spacing: 12) {
                HStack(spacing: 8) {
                    if isActive {
                        Text(spinnerFrames[spinnerIndex])
                            .font(TerminalTypography.body(16))
                            .foregroundColor(TerminalPalette.cyan)
                    }

                    Text(isActive ? "SCANNING" : "MESH_INACTIVE")
                        .font(TerminalTypography.header())
                        .foregroundColor(isActive ? TerminalPalette.cyan : TerminalPalette.textMuted)

                    if isActive {
                        TerminalLoadingDots(color: TerminalPalette.cyan)
                    }
                }

                Text(isActive ? "// Searching for nearby mesh nodes" : "// Tap [START] to begin scanning")
                    .font(TerminalTypography.label())
                    .foregroundColor(TerminalPalette.textMuted)
                    .multilineTextAlignment(.center)

                if !isActive {
                    Text("> AWAITING_INPUT")
                        .font(TerminalTypography.label())
                        .foregroundColor(TerminalPalette.textDim)
                }
            }
        }
        .onAppear {
            if isActive {
                startAnimations()
            }
        }
        .onChange(of: isActive) { _, active in
            if active {
                startAnimations()
            }
        }
    }

    private func startAnimations() {
        // Pulse animation
        withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
            pulseScale = 1.4
            pulseOpacity = 0.0
        }

        // Spinner animation
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            spinnerIndex = (spinnerIndex + 1) % spinnerFrames.count
        }
    }
}

#Preview {
    ZStack {
        TerminalPalette.background
            .ignoresSafeArea()
        ScanlineOverlay()
            .ignoresSafeArea()
        TerminalScanningView(isActive: true)
    }
}
