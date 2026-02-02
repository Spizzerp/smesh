import SwiftUI

/// Popup for selecting action when tapping a peer
/// Shows [SEND_PAYMENT] and [START_CHAT] options
struct TerminalPeerActionPopup: View {
    let peerName: String?
    let supportsChat: Bool
    let onSendPayment: () -> Void
    let onStartChat: () -> Void
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            // Dimmed background
            Color.black.opacity(0.7)
                .ignoresSafeArea()
                .onTapGesture {
                    onCancel()
                }

            // Popup content
            VStack(spacing: 0) {
                // Title bar
                TerminalTitleBar(title: "[SELECT_ACTION]", accent: .public)

                VStack(spacing: 16) {
                    // Device name
                    HStack {
                        Text("//")
                            .foregroundColor(TerminalPalette.textMuted)
                        Text(peerName?.uppercased() ?? "UNKNOWN_DEVICE")
                            .foregroundColor(TerminalPalette.textPrimary)
                    }
                    .font(TerminalTypography.body(12))

                    // Action buttons
                    VStack(spacing: 12) {
                        // Send Payment button
                        TerminalActionRow(
                            label: "SEND_PAYMENT",
                            accent: .public,
                            action: onSendPayment
                        )

                        // Start Chat button
                        if supportsChat {
                            TerminalActionRow(
                                label: "START_CHAT",
                                accent: .stealth,
                                action: onStartChat
                            )
                        }
                    }

                    // Cancel button
                    Button(action: onCancel) {
                        Text("[CANCEL]")
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
            .padding(.horizontal, 40)
        }
    }
}

/// Action row with arrow indicator
struct TerminalActionRow: View {
    let label: String
    let accent: TerminalAccent
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(">")
                    .foregroundColor(accent.color)

                Text(label)
                    .foregroundColor(accent.color)

                Spacer()

                Text("[>]")
                    .foregroundColor(accent.dimColor)
            }
            .font(TerminalTypography.command())
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 2)
                    .fill(isPressed ? TerminalPalette.surfaceLight : TerminalPalette.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(accent.dimColor, lineWidth: 1)
                    )
            )
            .scaleEffect(isPressed ? 0.98 : 1.0)
        }
        .buttonStyle(.plain)
        .onLongPressGesture(minimumDuration: .infinity, pressing: { pressing in
            withAnimation(.easeInOut(duration: 0.08)) {
                isPressed = pressing
            }
        }, perform: {})
    }
}

/// Chat request popup - shown when receiving a chat request
struct TerminalChatRequestPopup: View {
    let requesterName: String?
    let onAccept: () -> Void
    let onDecline: () -> Void

    var body: some View {
        ZStack {
            // Dimmed background
            Color.black.opacity(0.7)
                .ignoresSafeArea()

            // Popup content
            VStack(spacing: 0) {
                // Title bar
                TerminalTitleBar(title: "[CHAT_REQUEST]", accent: .stealth)

                VStack(spacing: 16) {
                    // Message
                    VStack(spacing: 8) {
                        Text("//")
                            .foregroundColor(TerminalPalette.textMuted)
                        Text(requesterName?.uppercased() ?? "UNKNOWN")
                            .foregroundColor(TerminalPalette.purple)
                            .terminalGlow(TerminalPalette.purple, radius: 2)
                        Text("wants to start encrypted chat")
                            .foregroundColor(TerminalPalette.textPrimary)
                    }
                    .font(TerminalTypography.body(12))
                    .multilineTextAlignment(.center)

                    // PQ indicator
                    HStack(spacing: 4) {
                        Text("[PQ:ACTIVE]")
                            .font(TerminalTypography.label())
                            .foregroundColor(TerminalPalette.purple)
                            .terminalGlow(TerminalPalette.purple, radius: 2)
                    }

                    // Action buttons
                    HStack(spacing: 16) {
                        TerminalTextButton(
                            title: "[DECLINE]",
                            accent: .public,
                            isDestructive: true
                        ) {
                            onDecline()
                        }

                        TerminalTextButton(
                            title: "[ACCEPT]",
                            accent: .stealth
                        ) {
                            onAccept()
                        }
                    }
                }
                .padding(16)
            }
            .background(
                RoundedRectangle(cornerRadius: 2)
                    .fill(TerminalPalette.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(TerminalPalette.purple.opacity(0.3), lineWidth: 1)
                    )
            )
            .padding(.horizontal, 40)
        }
    }
}

// MARK: - Preview

#Preview("Peer Action Popup") {
    ZStack {
        TerminalPalette.background
            .ignoresSafeArea()

        TerminalPeerActionPopup(
            peerName: "Alice's iPhone",
            supportsChat: true,
            onSendPayment: {},
            onStartChat: {},
            onCancel: {}
        )
    }
}

#Preview("Chat Request Popup") {
    ZStack {
        TerminalPalette.background
            .ignoresSafeArea()

        TerminalChatRequestPopup(
            requesterName: "Bob's Device",
            onAccept: {},
            onDecline: {}
        )
    }
}
