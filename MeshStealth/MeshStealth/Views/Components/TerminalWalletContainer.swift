import SwiftUI
import UIKit

// MARK: - Terminal Balance Display

/// Terminal-style balance display: BALANCE: 0.5000 SOL
struct TerminalBalanceDisplay: View {
    let balance: Double
    let accent: TerminalAccent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("BALANCE:")
                .font(TerminalTypography.label())
                .foregroundColor(TerminalPalette.textMuted)

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(String(format: "%.4f", balance))
                    .font(TerminalTypography.balance())
                    .foregroundColor(TerminalPalette.textPrimary)
                    .terminalGlow(accent.color, radius: 2)

                Text("SOL")
                    .font(TerminalTypography.label())
                    .foregroundColor(TerminalPalette.textDim)
            }
        }
    }
}

// MARK: - Terminal Main Wallet Container

/// Main wallet card with terminal styling (cyan theme)
struct TerminalMainWalletContainer<Badge: View, InputContent: View, MixingContent: View, StatusContent: View>: View {
    let balance: Double
    let address: String
    let isRefreshing: Bool
    let showInput: Bool
    let showMixing: Bool
    let onRefresh: () -> Void
    @ViewBuilder let badge: () -> Badge
    @ViewBuilder let inputContent: () -> InputContent
    @ViewBuilder let mixingContent: () -> MixingContent
    @ViewBuilder let statusContent: () -> StatusContent

    init(
        balance: Double,
        address: String,
        isRefreshing: Bool,
        showInput: Bool,
        showMixing: Bool = false,
        onRefresh: @escaping () -> Void,
        @ViewBuilder badge: @escaping () -> Badge,
        @ViewBuilder inputContent: @escaping () -> InputContent,
        @ViewBuilder mixingContent: @escaping () -> MixingContent,
        @ViewBuilder statusContent: @escaping () -> StatusContent = { EmptyView() }
    ) {
        self.balance = balance
        self.address = address
        self.isRefreshing = isRefreshing
        self.showInput = showInput
        self.showMixing = showMixing
        self.onRefresh = onRefresh
        self.badge = badge
        self.inputContent = inputContent
        self.mixingContent = mixingContent
        self.statusContent = statusContent
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title bar with optional status content
            TerminalTitleBar(title: "[PUBLIC_WALLET]", accent: .public) {
                statusContent()
            }

            // Content
            VStack(spacing: 16) {
                // Header row with refresh and badge
                HStack {
                    // Icon
                    Text("[>]")
                        .font(TerminalTypography.header())
                        .foregroundColor(TerminalPalette.cyan)

                    Text("PUBLIC")
                        .font(TerminalTypography.header())
                        .foregroundColor(TerminalPalette.textPrimary)

                    Spacer()

                    // Refresh button
                    TerminalIconButton(
                        label: "R",
                        accent: .public,
                        isActive: isRefreshing
                    ) {
                        onRefresh()
                    }

                    badge()
                }

                // Balance
                TerminalBalanceDisplay(balance: balance, accent: .public)

                // Address
                TerminalAddressBadge(address: address, accent: .public)

                // Description
                Text("// Your public Solana wallet for everyday transactions")
                    .font(TerminalTypography.label())
                    .foregroundColor(TerminalPalette.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Shield input (when active)
                if showInput {
                    inputContent()
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }

                // Mixing progress (when active)
                if showMixing {
                    mixingContent()
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
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
        .animation(.easeInOut(duration: 0.25), value: showInput)
        .animation(.easeInOut(duration: 0.4), value: showMixing)
    }
}

// MARK: - Terminal Stealth Wallet Container

/// Stealth wallet card with terminal styling (purple theme)
struct TerminalStealthWalletContainer<Badge: View, ConfirmContent: View>: View {
    let balance: Double
    let showConfirm: Bool
    @ViewBuilder let badge: () -> Badge
    @ViewBuilder let confirmContent: () -> ConfirmContent

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            TerminalTitleBar(title: "[STEALTH_WALLET]", accent: .stealth)

            // Content
            VStack(spacing: 16) {
                // Header row
                HStack {
                    // Icon
                    Text("[#]")
                        .font(TerminalTypography.header())
                        .foregroundColor(TerminalPalette.purple)

                    Text("STEALTH")
                        .font(TerminalTypography.header())
                        .foregroundColor(TerminalPalette.textPrimary)

                    Spacer()

                    badge()
                }

                // Balance
                TerminalBalanceDisplay(balance: balance, accent: .stealth)

                // Description
                Text("// Private balance with stealth addresses and mixing")
                    .font(TerminalTypography.label())
                    .foregroundColor(TerminalPalette.textMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Unshield confirm (when active)
                if showConfirm {
                    confirmContent()
                        .transition(.opacity.combined(with: .scale(scale: 0.95)))
                }
            }
            .padding(16)
        }
        .background(
            RoundedRectangle(cornerRadius: 2)
                .fill(TerminalPalette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(TerminalAccent.stealth.dimColor, lineWidth: 1)
                )
        )
        .animation(.easeInOut(duration: 0.25), value: showConfirm)
    }
}

// MARK: - Terminal Mixing Progress

/// Mixing progress indicator with terminal styling
struct TerminalMixingProgress: View {
    let mixProgress: Double
    let mixStatus: String
    let accent: TerminalAccent

    init(mixProgress: Double, mixStatus: String, accent: TerminalAccent = .public) {
        self.mixProgress = mixProgress
        self.mixStatus = mixStatus
        self.accent = accent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header with spinner
            HStack(spacing: 12) {
                TerminalSpinner(color: accent.color)

                VStack(alignment: .leading, spacing: 4) {
                    Text("SHIELDING")
                        .font(TerminalTypography.header())
                        .foregroundColor(accent.color)

                    Text(mixStatus.isEmpty ? "Creating stealth hops for privacy" : mixStatus)
                        .font(TerminalTypography.label())
                        .foregroundColor(TerminalPalette.textDim)
                        .lineLimit(2)
                }

                Spacer()
            }

            // Progress bar
            if mixProgress > 0 {
                VStack(alignment: .leading, spacing: 4) {
                    TerminalProgressBar(progress: mixProgress, width: 30, accent: accent)

                    Text(String(format: "%.0f%%", mixProgress * 100))
                        .font(TerminalTypography.label())
                        .foregroundColor(TerminalPalette.textDim)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 2)
                .fill(TerminalPalette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(accent.dimColor, lineWidth: 1)
                )
        )
    }
}

// MARK: - Preview

#Preview("Terminal Wallet Containers") {
    ZStack {
        TerminalPalette.background
            .ignoresSafeArea()

        ScanlineOverlay()
            .ignoresSafeArea()

        ScrollView {
            VStack(spacing: 20) {
                // Main wallet
                TerminalMainWalletContainer(
                    balance: 0.5000,
                    address: "7vJ9JU1bJJE96FWSJKvHsmmFADCg4gpZQff4P3bkLKi",
                    isRefreshing: false,
                    showInput: false,
                    showMixing: false,
                    onRefresh: {}
                ) {
                    EmptyView()
                } inputContent: {
                    EmptyView()
                } mixingContent: {
                    EmptyView()
                }

                // Shield/Unshield buttons
                TerminalShieldUnshieldRow(
                    onShield: {},
                    onUnshield: {},
                    shieldDisabled: false,
                    unshieldDisabled: false
                )

                // Stealth wallet
                TerminalStealthWalletContainer(
                    balance: 0.2500,
                    showConfirm: false
                ) {
                    TerminalQuantumBadge(accent: .stealth)
                } confirmContent: {
                    EmptyView()
                }

                // Header status
                HStack {
                    Spacer()
                    TerminalHeaderStatus(isDevnet: true, isOnline: true, peerCount: 3)
                }

                // Mixing progress example
                TerminalMixingProgress(
                    mixProgress: 0.6,
                    mixStatus: "Hop 3/5 - Waiting for confirmation",
                    accent: .public
                )
            }
            .padding(16)
        }
    }
}
