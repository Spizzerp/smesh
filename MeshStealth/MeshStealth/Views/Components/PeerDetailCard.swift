import SwiftUI

// MARK: - Peer Detail Card

/// Popup card showing detailed peer information with nickname editing and action buttons.
/// Slides up from bottom when a peer dot is tapped on the radar.
struct PeerDetailCard: View {
    let peer: NearbyPeer
    @Binding var nickname: String
    let displayName: String
    let onSendMessage: () -> Void
    let onSendPayment: () -> Void
    let onDismiss: () -> Void

    @State private var isEditingNickname = false
    @FocusState private var nicknameFieldFocused: Bool

    var body: some View {
        ZStack {
            // Dimmed background
            Color.black.opacity(0.7)
                .ignoresSafeArea()
                .onTapGesture {
                    dismissCard()
                }

            // Card content
            VStack(spacing: 0) {
                // Title bar
                TerminalTitleBar(title: "[PEER_INFO]", accent: .public) {
                    // Signal strength in title bar
                    signalBadge
                }

                VStack(spacing: 16) {
                    // Peer identity section
                    peerIdentitySection

                    // Divider
                    Rectangle()
                        .fill(TerminalPalette.border)
                        .frame(height: 1)

                    // Stats row
                    statsRow

                    // Divider
                    Rectangle()
                        .fill(TerminalPalette.border)
                        .frame(height: 1)

                    // Nickname section
                    nicknameSection

                    // Action buttons
                    actionButtons

                    // Dismiss button
                    Button(action: dismissCard) {
                        Text("[CLOSE]")
                            .font(TerminalTypography.label())
                            .foregroundColor(TerminalPalette.textDim)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                }
                .padding(16)
            }
            .background(
                RoundedRectangle(cornerRadius: 2)
                    .fill(TerminalPalette.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(TerminalPalette.cyan.opacity(0.3), lineWidth: 1)
                    )
            )
            .padding(.horizontal, 24)
        }
    }

    // MARK: - Signal Badge

    private var signalBadge: some View {
        HStack(spacing: 4) {
            Text("[\(peer.signalStrength)%]")
                .font(TerminalTypography.label())
                .foregroundColor(signalColor)
        }
    }

    private var signalColor: Color {
        switch peer.signalStrength {
        case 75...: return TerminalPalette.success
        case 50..<75: return TerminalPalette.cyan
        case 25..<50: return TerminalPalette.warning
        default: return TerminalPalette.error
        }
    }

    // MARK: - Peer Identity Section

    private var peerIdentitySection: some View {
        VStack(spacing: 8) {
            // Name
            HStack(spacing: 8) {
                Text(">")
                    .foregroundColor(TerminalPalette.cyan)
                Text(displayName.uppercased())
                    .foregroundColor(TerminalPalette.textPrimary)
            }
            .font(TerminalTypography.header(16))

            // Device name (if different from display name)
            if let deviceName = peer.name, !nickname.isEmpty {
                Text("// \(deviceName)")
                    .font(TerminalTypography.label())
                    .foregroundColor(TerminalPalette.textMuted)
            }

            // Peer ID
            Text("ID: \(truncatedID)")
                .font(TerminalTypography.label())
                .foregroundColor(TerminalPalette.textDim)

            // PQ capability badge
            if peer.supportsHybrid {
                TerminalQuantumBadge(accent: .stealth)
            }
        }
    }

    private var truncatedID: String {
        let id = peer.id
        if id.count > 16 {
            return "\(id.prefix(8))...\(id.suffix(4))"
        }
        return id
    }

    // MARK: - Stats Row

    private var statsRow: some View {
        HStack(spacing: 24) {
            // Signal strength
            VStack(spacing: 4) {
                Text("SIGNAL")
                    .font(TerminalTypography.label())
                    .foregroundColor(TerminalPalette.textMuted)

                HStack(spacing: 4) {
                    TerminalSignalBars(strength: peer.signalStrength)
                    Text(peer.proximityDescription.uppercased())
                        .font(TerminalTypography.label())
                        .foregroundColor(signalColor)
                }
            }

            // Connection status
            VStack(spacing: 4) {
                Text("STATUS")
                    .font(TerminalTypography.label())
                    .foregroundColor(TerminalPalette.textMuted)

                Text(peer.isConnected ? "[CONNECTED]" : "[DISCOVERED]")
                    .font(TerminalTypography.label())
                    .foregroundColor(peer.isConnected ? TerminalPalette.success : TerminalPalette.textDim)
            }
        }
    }

    // MARK: - Nickname Section

    private var nicknameSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("// NICKNAME")
                .font(TerminalTypography.label())
                .foregroundColor(TerminalPalette.textMuted)

            HStack(spacing: 8) {
                Text(">")
                    .font(TerminalTypography.body())
                    .foregroundColor(TerminalPalette.cyan)

                TextField("Enter nickname...", text: $nickname)
                    .font(TerminalTypography.body())
                    .foregroundColor(TerminalPalette.textPrimary)
                    .focused($nicknameFieldFocused)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit {
                        nicknameFieldFocused = false
                    }

                if !nickname.isEmpty {
                    Button {
                        nickname = ""
                    } label: {
                        Text("[X]")
                            .font(TerminalTypography.label())
                            .foregroundColor(TerminalPalette.error)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 2)
                    .fill(TerminalPalette.background)
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(
                                nicknameFieldFocused ? TerminalPalette.cyan : TerminalPalette.border,
                                lineWidth: 1
                            )
                    )
            )
        }
    }

    // MARK: - Action Buttons

    private var actionButtons: some View {
        VStack(spacing: 12) {
            // Send Payment
            TerminalActionRow(
                label: "SEND_PAYMENT",
                accent: .public,
                action: onSendPayment
            )

            // Send Message (only if PQ-capable)
            if peer.supportsHybrid {
                TerminalActionRow(
                    label: "SEND_MESSAGE",
                    accent: .stealth,
                    action: onSendMessage
                )
            }
        }
    }

    // MARK: - Actions

    private func dismissCard() {
        nicknameFieldFocused = false
        onDismiss()
    }
}

// MARK: - Terminal Signal Bars

/// Visual signal strength indicator with terminal styling
struct TerminalSignalBars: View {
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
            case 50..<75: return TerminalPalette.cyan
            case 25..<50: return TerminalPalette.warning
            default: return TerminalPalette.error
            }
        }
        return TerminalPalette.border
    }
}

// MARK: - Preview

#Preview("Peer Detail Card") {
    struct PreviewWrapper: View {
        @State private var nickname = ""

        var body: some View {
            ZStack {
                TerminalPalette.background
                    .ignoresSafeArea()

                PeerDetailCard(
                    peer: NearbyPeer(
                        id: "peer-1-abc-def-ghi-jkl",
                        name: "Alice's iPhone",
                        rssi: -50,
                        isConnected: true,
                        lastSeenAt: Date(),
                        supportsHybrid: true
                    ),
                    nickname: $nickname,
                    displayName: nickname.isEmpty ? "Alice's iPhone" : nickname,
                    onSendMessage: { print("Send message") },
                    onSendPayment: { print("Send payment") },
                    onDismiss: { print("Dismiss") }
                )
            }
        }
    }

    return PreviewWrapper()
}

#Preview("Peer Detail Card - No PQ") {
    struct PreviewWrapper: View {
        @State private var nickname = "Bob"

        var body: some View {
            ZStack {
                TerminalPalette.background
                    .ignoresSafeArea()

                PeerDetailCard(
                    peer: NearbyPeer(
                        id: "peer-2-xyz",
                        name: "Bob's Device",
                        rssi: -75,
                        isConnected: false,
                        lastSeenAt: Date(),
                        supportsHybrid: false
                    ),
                    nickname: $nickname,
                    displayName: "Bob",
                    onSendMessage: {},
                    onSendPayment: {},
                    onDismiss: {}
                )
            }
        }
    }

    return PreviewWrapper()
}
