import SwiftUI

// MARK: - Wallet Container Configuration

struct WalletContainerConfig {
    let title: String
    let icon: String
    let palette: NeuromorphicPalette
}

// MARK: - Main Wallet Container

/// Main wallet card with neumorphic styling for the blue theme
struct MainWalletContainer<Badge: View, InputContent: View, MixingContent: View>: View {
    let balance: Double
    let address: String
    let isRefreshing: Bool
    let showInput: Bool
    let showMixing: Bool
    let onRefresh: () -> Void
    @ViewBuilder let badge: () -> Badge
    @ViewBuilder let inputContent: () -> InputContent
    @ViewBuilder let mixingContent: () -> MixingContent

    init(
        balance: Double,
        address: String,
        isRefreshing: Bool,
        showInput: Bool,
        showMixing: Bool = false,
        onRefresh: @escaping () -> Void,
        @ViewBuilder badge: @escaping () -> Badge,
        @ViewBuilder inputContent: @escaping () -> InputContent,
        @ViewBuilder mixingContent: @escaping () -> MixingContent
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
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header row
            HStack {
                // Icon and title
                HStack(spacing: 10) {
                    Image(systemName: "eye")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(NeuromorphicPalette.blue.accent)

                    Text("Public")
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundColor(NeuromorphicPalette.blue.textPrimary)
                }

                Spacer()

                // Refresh button (top right, smaller)
                NeuromorphicIconButton(
                    icon: "arrow.clockwise",
                    palette: .blue,
                    size: 32,
                    isActive: isRefreshing
                ) {
                    onRefresh()
                }

                badge()
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 8)

            // Balance with SOL inline
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(String(format: "%.4f", balance))
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundColor(NeuromorphicPalette.blue.textPrimary)

                Text("SOL")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundColor(NeuromorphicPalette.blue.textSecondary)
            }
            .padding(.vertical, 8)

            // Address row
            AddressRow(address: address, palette: .blue)
                .padding(.vertical, 8)

            // Description
            Text("Your public Solana wallet for everyday transactions")
                .font(.caption)
                .foregroundColor(NeuromorphicPalette.blue.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.vertical, 4)

            // Shield input (when active)
            Group {
                if showInput {
                    inputContent()
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: showInput)

            // Mixing progress (when active)
            Group {
                if showMixing {
                    mixingContent()
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                }
            }
            .animation(.easeInOut(duration: 0.4), value: showMixing)

            Spacer()
                .frame(height: 20)
        }
        .neuromorphicBlue(cornerRadius: 28)
    }
}

// MARK: - Stealth Wallet Container

/// Stealth wallet card with neumorphic styling for the purple theme
struct StealthWalletContainer<Badge: View, ConfirmContent: View>: View {
    let balance: Double
    let showConfirm: Bool
    @ViewBuilder let badge: () -> Badge
    @ViewBuilder let confirmContent: () -> ConfirmContent

    var body: some View {
        VStack(spacing: 0) {
            // Header row
            HStack {
                // Icon and title
                HStack(spacing: 10) {
                    Image(systemName: "eye.slash")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(NeuromorphicPalette.purple.accent)

                    Text("Stealth")
                        .font(.headline)
                        .fontWeight(.bold)
                        .foregroundColor(NeuromorphicPalette.purple.textPrimary)
                }

                Spacer()

                badge()
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 8)

            // Balance with SOL inline
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(String(format: "%.4f", balance))
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundColor(NeuromorphicPalette.purple.textPrimary)

                Text("SOL")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundColor(NeuromorphicPalette.purple.textSecondary)
            }
            .padding(.vertical, 8)

            // Description
            Text("Private balance with stealth addresses and mixing")
                .font(.caption)
                .foregroundColor(NeuromorphicPalette.purple.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .padding(.vertical, 4)

            // Unshield confirm (when active)
            if showConfirm {
                confirmContent()
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }

            Spacer()
                .frame(height: 20)
        }
        .neuromorphicPurple(cornerRadius: 28)
    }
}

// MARK: - Shield/Unshield Buttons Row

/// Horizontal row with Shield and Unshield action buttons
struct ShieldUnshieldRow: View {
    let onShield: () -> Void
    let onUnshield: () -> Void
    let shieldDisabled: Bool
    let unshieldDisabled: Bool
    var isShielding: Bool = false
    var isUnshielding: Bool = false

    var body: some View {
        HStack(spacing: 60) {
            NeuromorphicActionButton(
                icon: "eye.slash.fill",
                label: "Shield",
                palette: .blue,
                isActive: isShielding
            ) {
                onShield()
            }
            .opacity(shieldDisabled && !isShielding ? 0.5 : 1.0)

            NeuromorphicActionButton(
                icon: "eye.fill",
                label: "Unshield",
                palette: .purple,
                isActive: isUnshielding
            ) {
                onUnshield()
            }
            .opacity(unshieldDisabled && !isUnshielding ? 0.5 : 1.0)
        }
    }
}

// MARK: - Preview

#Preview("Wallet Containers") {
    ZStack {
        NeuromorphicPalette.pageBackground
            .ignoresSafeArea()

        ScrollView {
            VStack(spacing: 24) {
                // Main wallet
                MainWalletContainer(
                    balance: 0.5000,
                    address: "7vJ9JU1bJJE96FWSJKvHsmmFADCg4gpZQff4P3bkLKi",
                    isRefreshing: false,
                    showInput: false,
                    showMixing: false,
                    onRefresh: {}
                ) {
                    NetworkBadge(isDevnet: true, palette: .blue)
                } inputContent: {
                    EmptyView()
                } mixingContent: {
                    EmptyView()
                }

                // Shield/Unshield buttons
                ShieldUnshieldRow(
                    onShield: {},
                    onUnshield: {},
                    shieldDisabled: false,
                    unshieldDisabled: false,
                    isShielding: false,
                    isUnshielding: false
                )

                // Stealth wallet
                StealthWalletContainer(
                    balance: 0.2500,
                    showConfirm: false
                ) {
                    QuantumBadge(palette: .purple)
                } confirmContent: {
                    EmptyView()
                }

                // Status
                StatusIndicator(isOnline: true, peerCount: 3)
            }
            .padding()
        }
    }
}
