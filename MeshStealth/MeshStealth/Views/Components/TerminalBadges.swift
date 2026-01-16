import SwiftUI
import UIKit

// MARK: - Terminal Network Badge

/// Badge showing network type in terminal style: [DEVNET] / [MAINNET]
struct TerminalNetworkBadge: View {
    let isDevnet: Bool

    var body: some View {
        Text(isDevnet ? "[DEVNET]" : "[MAINNET]")
            .font(TerminalTypography.label())
            .foregroundColor(isDevnet ? TerminalPalette.warning : TerminalPalette.success)
    }
}

// MARK: - Terminal Status Badge

/// Badge showing online status: [ONLINE] + optional [PEERS:N]
struct TerminalStatusBadge: View {
    let isOnline: Bool
    let peerCount: Int

    var body: some View {
        HStack(spacing: 8) {
            Text(isOnline ? "[ONLINE]" : "[OFFLINE]")
                .font(TerminalTypography.label())
                .foregroundColor(isOnline ? TerminalPalette.success : TerminalPalette.error)

            if peerCount > 0 {
                Text("[PEERS:\(peerCount)]")
                    .font(TerminalTypography.label())
                    .foregroundColor(TerminalPalette.cyan)
            }
        }
    }
}

// MARK: - Terminal Quantum Badge

/// Badge indicating post-quantum protection: [PQ:MLKEM768]
struct TerminalQuantumBadge: View {
    let accent: TerminalAccent

    init(accent: TerminalAccent = .stealth) {
        self.accent = accent
    }

    var body: some View {
        Text("[PQ:MLKEM768]")
            .font(TerminalTypography.label())
            .foregroundColor(accent.color)
            .terminalGlow(accent.color, radius: 2)
    }
}

// MARK: - Terminal Address Badge

/// Truncated wallet address with [COPY] button
struct TerminalAddressBadge: View {
    let address: String
    let accent: TerminalAccent

    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Text(truncatedAddress)
                .font(TerminalTypography.label())
                .foregroundColor(TerminalPalette.textDim)

            Button {
                UIPasteboard.general.string = address
                withAnimation(.easeInOut(duration: 0.2)) {
                    copied = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        copied = false
                    }
                }
            } label: {
                Text(copied ? "[OK]" : "[COPY]")
                    .font(TerminalTypography.label())
                    .foregroundColor(copied ? TerminalPalette.success : accent.color)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 2)
                .fill(TerminalPalette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(TerminalPalette.border, lineWidth: 1)
                )
        )
    }

    private var truncatedAddress: String {
        guard address.count > 12 else { return address }
        let prefix = address.prefix(6)
        let suffix = address.suffix(4)
        return "\(prefix)...\(suffix)"
    }
}

// MARK: - Terminal Header Status Row

/// Combined status row for wallet header: [DEVNET] [ONLINE] [PEERS:N]
struct TerminalHeaderStatus: View {
    let isDevnet: Bool
    let isOnline: Bool
    let peerCount: Int

    var body: some View {
        HStack(spacing: 8) {
            TerminalNetworkBadge(isDevnet: isDevnet)
            TerminalStatusBadge(isOnline: isOnline, peerCount: peerCount)
        }
    }
}

// MARK: - Terminal Window Title Bar

/// Terminal-style title bar with decorations: [-][+][x] TITLE [trailing content]
struct TerminalTitleBar<TrailingContent: View>: View {
    let title: String
    let accent: TerminalAccent
    @ViewBuilder let trailingContent: () -> TrailingContent

    init(
        title: String,
        accent: TerminalAccent,
        @ViewBuilder trailingContent: @escaping () -> TrailingContent = { EmptyView() }
    ) {
        self.title = title
        self.accent = accent
        self.trailingContent = trailingContent
    }

    var body: some View {
        HStack(spacing: 8) {
            // Window decorations
            HStack(spacing: 4) {
                Text("[-]")
                Text("[+]")
                Text("[x]")
            }
            .font(TerminalTypography.label(10))
            .foregroundColor(TerminalPalette.textMuted)

            // Title (left-aligned after decorations)
            Text(title)
                .font(TerminalTypography.header(12))
                .foregroundColor(accent.color)

            Spacer()

            // Trailing content (status badges, etc.)
            trailingContent()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(TerminalPalette.surface)
        .overlay(
            Rectangle()
                .fill(accent.dimColor)
                .frame(height: 1),
            alignment: .bottom
        )
    }
}

// MARK: - Preview

#Preview("Terminal Badges") {
    ZStack {
        TerminalPalette.background
            .ignoresSafeArea()

        VStack(spacing: 24) {
            // Network badges
            VStack(spacing: 12) {
                Text("// Network Badges")
                    .font(TerminalTypography.label())
                    .foregroundColor(TerminalPalette.textMuted)

                HStack(spacing: 16) {
                    TerminalNetworkBadge(isDevnet: true)
                    TerminalNetworkBadge(isDevnet: false)
                }
            }

            // Status badges
            VStack(spacing: 12) {
                Text("// Status Badges")
                    .font(TerminalTypography.label())
                    .foregroundColor(TerminalPalette.textMuted)

                TerminalStatusBadge(isOnline: true, peerCount: 3)
                TerminalStatusBadge(isOnline: false, peerCount: 0)
            }

            // Quantum badge
            VStack(spacing: 12) {
                Text("// Quantum Badge")
                    .font(TerminalTypography.label())
                    .foregroundColor(TerminalPalette.textMuted)

                HStack(spacing: 16) {
                    TerminalQuantumBadge(accent: .public)
                    TerminalQuantumBadge(accent: .stealth)
                }
            }

            // Address badges
            VStack(spacing: 12) {
                Text("// Address Badges")
                    .font(TerminalTypography.label())
                    .foregroundColor(TerminalPalette.textMuted)

                TerminalAddressBadge(
                    address: "7vJ9JU1bJJE96FWSJKvHsmmFADCg4gpZQff4P3bkLKi",
                    accent: .public
                )
                TerminalAddressBadge(
                    address: "stealth:4xK8Lm2nP9qR5wT3vY7zB1cD4eF6gH8jK0mN",
                    accent: .stealth
                )
            }

            // Header status
            VStack(spacing: 12) {
                Text("// Header Status")
                    .font(TerminalTypography.label())
                    .foregroundColor(TerminalPalette.textMuted)

                TerminalHeaderStatus(isDevnet: true, isOnline: true, peerCount: 3)
            }

            // Title bars
            VStack(spacing: 12) {
                Text("// Title Bars")
                    .font(TerminalTypography.label())
                    .foregroundColor(TerminalPalette.textMuted)

                TerminalTitleBar(title: "[PUBLIC_WALLET]", accent: .public)
                TerminalTitleBar(title: "[STEALTH_WALLET]", accent: .stealth)
            }
        }
        .padding()
    }
}
