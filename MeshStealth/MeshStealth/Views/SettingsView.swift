import SwiftUI
import StealthCore

struct SettingsView: View {
    @EnvironmentObject var walletViewModel: WalletViewModel
    @EnvironmentObject var meshViewModel: MeshViewModel

    @State private var showingResetConfirmation = false
    @State private var showingClearActivityConfirmation = false
    @State private var showingMetaAddress = false
    @State private var showingBackupWallet = false

    var body: some View {
        NavigationStack {
            ZStack {
                TerminalPalette.background
                    .ignoresSafeArea()

                ScanlineOverlay()
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        // Wallet Section
                        TerminalSettingsSection(title: "[WALLET_CONFIG]") {
                            // Main wallet address
                            TerminalSettingsRow(
                                label: "MAIN_ADDR",
                                value: truncatedMainAddress,
                                valueColor: TerminalPalette.cyan
                            )

                            // Backup main wallet
                            TerminalSettingsRow(
                                label: "MAIN_ADDR_BACKUP",
                                value: "[EXPORT]",
                                showChevron: true
                            ) {
                                showingBackupWallet = true
                            }

                            // Stealth meta-address display
                            TerminalSettingsRow(
                                label: "STEALTH_ADDR",
                                value: truncatedStealthAddress,
                                showChevron: true
                            ) {
                                showingMetaAddress = true
                            }

                            // Security info
                            TerminalSettingsRow(
                                label: "SECURITY",
                                value: walletViewModel.hasPostQuantum ? "[PQ:MLKEM768]" : "[CLASSICAL]",
                                valueColor: walletViewModel.hasPostQuantum ? TerminalPalette.purple : TerminalPalette.textDim
                            )
                        }

                        // Network Section
                        TerminalSettingsSection(title: "[NETWORK_CONFIG]") {
                            TerminalSettingsRow(
                                label: "CLUSTER",
                                value: "[DEVNET]",
                                valueColor: TerminalPalette.warning
                            )

                            TerminalSettingsRow(
                                label: "STATUS",
                                value: meshViewModel.isOnline ? "[ONLINE]" : "[OFFLINE]",
                                valueColor: meshViewModel.isOnline ? TerminalPalette.success : TerminalPalette.error
                            )
                        }

                        // Mesh Section
                        TerminalSettingsSection(title: "[MESH_CONFIG]") {
                            TerminalSettingsRow(
                                label: "MESH_STATUS",
                                value: meshViewModel.isActive ? "[ACTIVE]" : "[INACTIVE]",
                                valueColor: meshViewModel.isActive ? TerminalPalette.success : TerminalPalette.textMuted
                            )

                            TerminalSettingsRow(
                                label: "PEER_COUNT",
                                value: "[\(meshViewModel.peerCount)]",
                                valueColor: TerminalPalette.cyan
                            )
                        }

                        // About Section
                        TerminalSettingsSection(title: "[SYSTEM_INFO]") {
                            TerminalSettingsRow(
                                label: "VERSION",
                                value: "v1.0.0"
                            )

                            TerminalSettingsRow(
                                label: "SOURCE",
                                value: "[GITHUB]",
                                showChevron: true
                            ) {
                                if let url = URL(string: "https://github.com") {
                                    UIApplication.shared.open(url)
                                }
                            }
                        }

                        // Danger Zone
                        TerminalSettingsSection(title: "[DANGER_ZONE]", accent: TerminalPalette.error) {
                            TerminalSettingsRow(
                                label: "CLEAR_HISTORY",
                                value: "[EXEC]",
                                valueColor: TerminalPalette.error
                            ) {
                                showingClearActivityConfirmation = true
                            }

                            TerminalSettingsRow(
                                label: "RESET_WALLET",
                                value: "[EXEC]",
                                valueColor: TerminalPalette.error
                            ) {
                                showingResetConfirmation = true
                            }

                            Text("// CLEAR_HISTORY removes transaction logs")
                                .font(TerminalTypography.label())
                                .foregroundColor(TerminalPalette.textMuted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 4)

                            Text("// RESET_WALLET deletes all data including keys")
                                .font(TerminalTypography.label())
                                .foregroundColor(TerminalPalette.textMuted)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 40)
                    .padding(.bottom, 16)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(TerminalPalette.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 6) {
                        Text("//")
                            .foregroundColor(TerminalPalette.textMuted)
                        Text("CONFIG")
                            .foregroundColor(TerminalPalette.cyan)
                        Text("v1.0")
                            .foregroundColor(TerminalPalette.textMuted)
                    }
                    .font(TerminalTypography.header(14))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    TerminalStatusBadge(
                        isOnline: meshViewModel.isOnline,
                        peerCount: meshViewModel.peerCount
                    )
                }
            }
            .sheet(isPresented: $showingMetaAddress) {
                TerminalMetaAddressSheet(
                    metaAddress: walletViewModel.displayMetaAddress ?? "",
                    isHybrid: walletViewModel.hasPostQuantum
                )
            }
            .sheet(isPresented: $showingBackupWallet) {
                WalletBackupView()
            }
            .confirmationDialog(
                "Clear Activity History",
                isPresented: $showingClearActivityConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear History", role: .destructive) {
                    walletViewModel.clearActivityHistory()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will remove all transaction history. Your wallet and pending payments will not be affected.")
            }
            .confirmationDialog(
                "Reset Wallet",
                isPresented: $showingResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Reset", role: .destructive) {
                    try? walletViewModel.resetWallet()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This action cannot be undone. All your wallet data will be permanently deleted.")
            }
        }
    }

    private var truncatedMainAddress: String {
        guard let addr = walletViewModel.mainWalletAddress else { return "NOT_SET" }
        return "\(addr.prefix(6))...\(addr.suffix(4))"
    }

    private var truncatedStealthAddress: String {
        guard let addr = walletViewModel.displayMetaAddress else { return "NOT_SET" }
        return "\(addr.prefix(6))...\(addr.suffix(4))"
    }
}

// MARK: - Terminal Settings Components

struct TerminalSettingsSection<Content: View>: View {
    let title: String
    var accent: Color = TerminalPalette.cyan
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Text("[-]")
                    Text("[+]")
                    Text("[x]")
                }
                .font(TerminalTypography.label(10))
                .foregroundColor(TerminalPalette.textMuted)

                Text(title)
                    .font(TerminalTypography.header(12))
                    .foregroundColor(accent)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(TerminalPalette.surface)
            .overlay(
                Rectangle()
                    .fill(accent == TerminalPalette.error ? Color(hex: "550000") : TerminalAccent.public.dimColor)
                    .frame(height: 1),
                alignment: .bottom
            )

            // Content
            VStack(spacing: 0) {
                content()
            }
            .padding(12)
        }
        .background(
            RoundedRectangle(cornerRadius: 2)
                .fill(TerminalPalette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(accent == TerminalPalette.error ? Color(hex: "550000") : TerminalAccent.public.dimColor, lineWidth: 1)
                )
        )
    }
}

struct TerminalSettingsRow: View {
    let label: String
    let value: String
    var valueColor: Color = TerminalPalette.textDim
    var showChevron: Bool = false
    var action: (() -> Void)? = nil

    var body: some View {
        Button {
            action?()
        } label: {
            HStack(spacing: 12) {
                Text("> \(label)")
                    .font(TerminalTypography.body(12))
                    .foregroundColor(TerminalPalette.textPrimary)

                Spacer()

                Text(value)
                    .font(TerminalTypography.label())
                    .foregroundColor(valueColor)

                if showChevron {
                    Text("[>]")
                        .font(TerminalTypography.label())
                        .foregroundColor(TerminalPalette.cyan)
                }
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .disabled(action == nil)
    }
}

struct TerminalMetaAddressSheet: View {
    @Environment(\.dismiss) private var dismiss

    let metaAddress: String
    let isHybrid: Bool

    @State private var copied = false

    var body: some View {
        NavigationStack {
            ZStack {
                TerminalPalette.background
                    .ignoresSafeArea()

                ScanlineOverlay()
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        // Header
                        VStack(spacing: 12) {
                            // ASCII art icon
                            VStack(spacing: 2) {
                                Text("┌─────────┐")
                                Text("│  [#]    │")
                                Text("│  ADDR   │")
                                Text("└─────────┘")
                            }
                            .font(TerminalTypography.body(14))
                            .foregroundColor(isHybrid ? TerminalPalette.purple : TerminalPalette.cyan)
                            .terminalGlow(isHybrid ? TerminalPalette.purple : TerminalPalette.cyan, radius: 4)

                            Text("STEALTH_ADDRESS")
                                .font(TerminalTypography.header())
                                .foregroundColor(TerminalPalette.textPrimary)

                            Text("// For private mesh payments")
                                .font(TerminalTypography.label())
                                .foregroundColor(TerminalPalette.textMuted)

                            if isHybrid {
                                TerminalQuantumBadge(accent: .stealth)
                            }
                        }
                        .padding(.top, 20)

                        // Info box
                        VStack(alignment: .leading, spacing: 8) {
                            Text("> INFO:")
                                .font(TerminalTypography.body(12))
                                .foregroundColor(TerminalPalette.cyan)

                            Text("This is different from your MAIN_WALLET address")
                                .font(TerminalTypography.body(12))
                                .foregroundColor(TerminalPalette.textPrimary)

                            Text("// Share with nearby peers for private payments via BLE mesh. Each payment generates a unique one-time address only you can detect.")
                                .font(TerminalTypography.label())
                                .foregroundColor(TerminalPalette.textMuted)
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
                        .padding(.horizontal, 16)

                        // Address display
                        VStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("> ADDRESS:")
                                    .font(TerminalTypography.label())
                                    .foregroundColor(TerminalPalette.textMuted)

                                Text(metaAddress)
                                    .font(TerminalTypography.label())
                                    .foregroundColor(TerminalPalette.textDim)
                                    .lineLimit(nil)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(TerminalPalette.surface)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 2)
                                            .stroke(TerminalPalette.border, lineWidth: 1)
                                    )
                            )

                            Button {
                                UIPasteboard.general.string = metaAddress
                                copied = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    copied = false
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Text(copied ? "[OK]" : "[>]")
                                    Text(copied ? "COPIED" : "COPY_ADDRESS")
                                }
                                .font(TerminalTypography.header(14))
                                .foregroundColor(copied ? TerminalPalette.success : TerminalPalette.purple)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(TerminalPalette.surface)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 2)
                                                .stroke(copied ? TerminalPalette.success : TerminalAccent.stealth.dimColor, lineWidth: 1)
                                        )
                                )
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 16)

                        // Info list
                        VStack(alignment: .leading, spacing: 8) {
                            TerminalInfoRow(label: "01", text: "Share with nearby peers via BLE mesh")
                            TerminalInfoRow(label: "02", text: "Payments are unlinkable - unique addresses")
                            TerminalInfoRow(label: "03", text: "Different from MAIN_WALLET (funding)")
                            if isHybrid {
                                TerminalInfoRow(label: "04", text: "Protected against quantum attacks")
                            }
                        }
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: 2)
                                .fill(TerminalPalette.surface)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 2)
                                        .stroke(TerminalPalette.border, lineWidth: 1)
                                )
                        )
                        .padding(.horizontal, 16)

                        Spacer(minLength: 40)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(TerminalPalette.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text("[STEALTH_ADDR]")
                        .font(TerminalTypography.header(12))
                        .foregroundColor(TerminalPalette.purple)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Text("[CLOSE]")
                            .font(TerminalTypography.label())
                            .foregroundColor(TerminalPalette.cyan)
                    }
                }
            }
        }
    }
}

struct TerminalInfoRow: View {
    let label: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Text("[\(label)]")
                .font(TerminalTypography.label())
                .foregroundColor(TerminalPalette.textMuted)
            Text(text)
                .font(TerminalTypography.label())
                .foregroundColor(TerminalPalette.textDim)
        }
    }
}

#Preview {
    ZStack {
        TerminalPalette.background
            .ignoresSafeArea()
        ScanlineOverlay()
            .ignoresSafeArea()
        SettingsView()
    }
}
