import SwiftUI
import StealthCore

/// Chat message bubble with terminal styling
struct TerminalChatBubble: View {
    let message: ChatMessage
    let maxWidth: CGFloat

    init(message: ChatMessage, maxWidth: CGFloat = 280) {
        self.message = message
        self.maxWidth = maxWidth
    }

    private var accent: TerminalAccent {
        message.isOutgoing ? .stealth : .public
    }

    private var alignment: HorizontalAlignment {
        message.isOutgoing ? .trailing : .leading
    }

    var body: some View {
        HStack {
            if message.isOutgoing {
                Spacer(minLength: 40)
            }

            VStack(alignment: alignment, spacing: 4) {
                // Message content
                HStack(alignment: .bottom, spacing: 8) {
                    if !message.isOutgoing {
                        Text(">")
                            .font(TerminalTypography.body(12))
                            .foregroundColor(accent.color)
                    }

                    Text(message.content)
                        .font(TerminalTypography.body(14))
                        .foregroundColor(TerminalPalette.textPrimary)

                    if message.isOutgoing {
                        Text("<")
                            .font(TerminalTypography.body(12))
                            .foregroundColor(accent.color)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 2)
                        .fill(TerminalPalette.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(accent.dimColor, lineWidth: 1)
                        )
                )

                // Timestamp and status
                HStack(spacing: 4) {
                    Text(formattedTime)
                        .font(TerminalTypography.timestamp())
                        .foregroundColor(TerminalPalette.textMuted)

                    if message.isOutgoing {
                        statusIndicator
                    }
                }
            }
            .frame(maxWidth: maxWidth, alignment: message.isOutgoing ? .trailing : .leading)

            if !message.isOutgoing {
                Spacer(minLength: 40)
            }
        }
    }

    private var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: message.timestamp)
    }

    @ViewBuilder
    private var statusIndicator: some View {
        switch message.status {
        case .sending:
            TerminalSpinner(color: accent.dimColor)
        case .sent:
            Text("[>]")
                .font(TerminalTypography.timestamp())
                .foregroundColor(TerminalPalette.textMuted)
        case .delivered:
            Text("[>>]")
                .font(TerminalTypography.timestamp())
                .foregroundColor(accent.color)
        case .failed:
            Text("[!]")
                .font(TerminalTypography.timestamp())
                .foregroundColor(TerminalPalette.error)
        }
    }
}

/// Empty state for chat - when no messages yet
struct TerminalChatEmptyState: View {
    let isConnecting: Bool

    var body: some View {
        VStack(spacing: 16) {
            if isConnecting {
                HStack(spacing: 8) {
                    TerminalSpinner(color: TerminalPalette.purple)
                    Text("ESTABLISHING_CONNECTION")
                        .font(TerminalTypography.body(12))
                        .foregroundColor(TerminalPalette.textDim)
                    TerminalLoadingDots(color: TerminalPalette.textDim)
                }
            } else {
                VStack(spacing: 8) {
                    Text("[SECURE_CHAT]")
                        .font(TerminalTypography.header())
                        .foregroundColor(TerminalPalette.purple)
                        .terminalGlow(TerminalPalette.purple, radius: 4)

                    Text("// Post-quantum encrypted")
                        .font(TerminalTypography.label())
                        .foregroundColor(TerminalPalette.textMuted)

                    Text("Messages are ephemeral")
                        .font(TerminalTypography.label())
                        .foregroundColor(TerminalPalette.textDim)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Preview

#Preview("Chat Bubbles") {
    ZStack {
        TerminalPalette.background
            .ignoresSafeArea()

        ScanlineOverlay()
            .ignoresSafeArea()

        VStack(spacing: 12) {
            TerminalChatBubble(
                message: ChatMessage(
                    sessionID: UUID(),
                    content: "Hello!",
                    isOutgoing: true,
                    status: .delivered
                )
            )

            TerminalChatBubble(
                message: ChatMessage(
                    sessionID: UUID(),
                    content: "Hi there! How are you?",
                    isOutgoing: false,
                    status: .delivered
                )
            )

            TerminalChatBubble(
                message: ChatMessage(
                    sessionID: UUID(),
                    content: "Sending...",
                    isOutgoing: true,
                    status: .sending
                )
            )
        }
        .padding()
    }
}

#Preview("Empty State") {
    ZStack {
        TerminalPalette.background
            .ignoresSafeArea()

        TerminalChatEmptyState(isConnecting: false)
    }
}
