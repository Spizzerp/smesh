import SwiftUI
import StealthCore

struct NearbyPeersView: View {
    @EnvironmentObject var meshViewModel: MeshViewModel
    @StateObject private var nicknameStore = PeerNicknameStore()
    @State private var showingSendSheet = false
    @State private var selectedPeer: NearbyPeer?
    @State private var showingAddressRequest = false

    // Peer detail card state
    @State private var showingPeerDetailCard = false
    @State private var selectedPeerNickname = ""

    // Chat-related state
    @State private var showingChatRequest = false
    @State private var activeChatSessionID: UUID?
    @State private var navigateToChat = false

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
                .onChange(of: meshViewModel.pendingChatRequest) { _, request in
                    showingChatRequest = request != nil
                }
                .onChange(of: meshViewModel.activeChatSessionID) { _, sessionID in
                    if sessionID != nil {
                        activeChatSessionID = sessionID
                        navigateToChat = true
                    }
                }
                .navigationDestination(isPresented: $navigateToChat) {
                    if let sessionID = activeChatSessionID,
                       let chatManager = meshViewModel.chatManager {
                        ChatView(sessionID: sessionID, chatManager: chatManager)
                    }
                }
                .overlay {
                    // Peer detail card (radar view)
                    if showingPeerDetailCard, let peer = selectedPeer {
                        PeerDetailCard(
                            peer: peer,
                            nickname: $selectedPeerNickname,
                            displayName: nicknameStore.displayName(for: peer.id, deviceName: peer.name),
                            onSendMessage: {
                                showingPeerDetailCard = false
                                saveNicknameIfNeeded(for: peer)
                                startChatWithPeer(peer)
                            },
                            onSendPayment: {
                                showingPeerDetailCard = false
                                saveNicknameIfNeeded(for: peer)
                                requestAddressFromPeer(peer)
                            },
                            onDismiss: {
                                saveNicknameIfNeeded(for: peer)
                                showingPeerDetailCard = false
                                selectedPeer = nil
                            }
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    }

                    // Chat request popup
                    if showingChatRequest, let request = meshViewModel.pendingChatRequest {
                        TerminalChatRequestPopup(
                            requesterName: request.requesterName,
                            onAccept: {
                                Task {
                                    await meshViewModel.acceptChatRequest()
                                }
                            },
                            onDecline: {
                                Task {
                                    await meshViewModel.declineChatRequest()
                                }
                            }
                        )
                        .transition(.opacity)
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

            radarContent
        }
    }

    // MARK: - Radar Content

    @ViewBuilder
    private var radarContent: some View {
        VStack(spacing: 0) {
            // Status header
            HStack {
                Text("//")
                    .foregroundColor(TerminalPalette.textMuted)
                if meshViewModel.hasNearbyPeers {
                    Text("\(meshViewModel.peerCount) NODE\(meshViewModel.peerCount == 1 ? "" : "S") DETECTED")
                        .foregroundColor(TerminalPalette.cyan)
                } else {
                    Text("SCANNING")
                        .foregroundColor(TerminalPalette.textDim)
                }
                Spacer()
            }
            .font(TerminalTypography.label())
            .padding(.horizontal, 16)
            .padding(.top, 16)

            // Radar visualization
            RadarView(peers: meshViewModel.nearbyPeers) { peer in
                selectPeerForDetail(peer)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 16)

            // Closest peer quick info or searching indicator
            if let closest = meshViewModel.closestPeer {
                closestPeerQuickInfo(closest)
                    .padding(.horizontal, 16)
            } else if meshViewModel.isActive {
                searchingIndicator
                    .padding(.horizontal, 16)
            }

            Spacer()
        }
    }

    @ViewBuilder
    private var searchingIndicator: some View {
        HStack(spacing: 12) {
            Text(">")
                .foregroundColor(TerminalPalette.cyan)
            Text("SEARCHING FOR NODES")
                .foregroundColor(TerminalPalette.textDim)
            TerminalLoadingDots(color: TerminalPalette.textDim)
            Spacer()
        }
        .font(TerminalTypography.body(12))
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 2)
                .fill(TerminalPalette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(TerminalPalette.border, lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private func closestPeerQuickInfo(_ peer: NearbyPeer) -> some View {
        Button {
            selectPeerForDetail(peer)
        } label: {
            HStack(spacing: 12) {
                // Signal indicator
                TerminalSignalIndicator(strength: peer.signalStrength)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(">")
                            .foregroundColor(TerminalPalette.cyan)
                        Text(nicknameStore.displayName(for: peer.id, deviceName: peer.name).uppercased())
                            .foregroundColor(TerminalPalette.textPrimary)
                    }
                    .font(TerminalTypography.body(12))

                    Text(peer.proximityDescription.uppercased())
                        .font(TerminalTypography.label())
                        .foregroundColor(TerminalPalette.textMuted)
                }

                Spacer()

                if peer.supportsHybrid {
                    Text("[PQ]")
                        .font(TerminalTypography.label())
                        .foregroundColor(TerminalPalette.purple)
                        .terminalGlow(TerminalPalette.purple, radius: 2)
                }

                Text("[TAP]")
                    .font(TerminalTypography.label())
                    .foregroundColor(TerminalPalette.cyan)
            }
            .padding(12)
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
    }

    // MARK: - Peer Selection

    private func selectPeerForDetail(_ peer: NearbyPeer) {
        selectedPeer = peer
        selectedPeerNickname = nicknameStore.getNickname(for: peer.id) ?? ""
        withAnimation(.easeInOut(duration: 0.2)) {
            showingPeerDetailCard = true
        }
    }

    private func saveNicknameIfNeeded(for peer: NearbyPeer) {
        let trimmed = selectedPeerNickname.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != (nicknameStore.getNickname(for: peer.id) ?? "") {
            nicknameStore.setNickname(trimmed, for: peer.id)
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

    private func startChatWithPeer(_ peer: NearbyPeer) {
        Task {
            await meshViewModel.startChat(with: peer)
        }
    }
}

// MARK: - Terminal Scale Button Style

struct TerminalScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: configuration.isPressed)
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

