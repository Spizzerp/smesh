import SwiftUI
import StealthCore

struct SettingsView: View {
    @EnvironmentObject var walletViewModel: WalletViewModel
    @EnvironmentObject var meshViewModel: MeshViewModel

    @State private var showingResetConfirmation = false
    @State private var showingClearActivityConfirmation = false
    @State private var showingMetaAddress = false
    @State private var showingBackupWallet = false
    @State private var showingPrivacyInfo = false

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

                        // Privacy Protocol Section
                        TerminalSettingsSection(title: "[PRIVACY_CONFIG]", accent: TerminalPalette.purple) {
                            // Privacy toggle
                            HStack {
                                Text("> PRIVACY_ROUTING")
                                    .font(TerminalTypography.body(12))
                                    .foregroundColor(TerminalPalette.textPrimary)

                                Spacer()

                                Toggle("", isOn: Binding(
                                    get: { walletViewModel.privacyEnabled },
                                    set: { walletViewModel.setPrivacyEnabled($0) }
                                ))
                                    .toggleStyle(TerminalToggleStyle())
                            }
                            .padding(.vertical, 8)

                            // Protocol selector
                            TerminalSettingsRow(
                                label: "PROTOCOL",
                                value: "[\(walletViewModel.selectedPrivacyProtocol.displayName.uppercased())]",
                                valueColor: protocolColor,
                                showChevron: true
                            ) {
                                cycleProtocol()
                            }

                            // Status indicator
                            TerminalSettingsRow(
                                label: "STATUS",
                                value: privacyStatusValue,
                                valueColor: privacyStatusColor
                            )

                            // Mode indicator (simulation vs live)
                            if walletViewModel.privacyEnabled && walletViewModel.selectedPrivacyProtocol != .direct {
                                TerminalSettingsRow(
                                    label: "MODE",
                                    value: walletViewModel.privacySimulationMode ? "[SIMULATION]" : "[LIVE]",
                                    valueColor: walletViewModel.privacySimulationMode ? TerminalPalette.warning : TerminalPalette.success
                                )
                            }

                            // Pool balance (if any)
                            if walletViewModel.privacyPoolBalance > 0 {
                                TerminalSettingsRow(
                                    label: "POOL_BAL",
                                    value: String(format: "[%.4f SOL]", walletViewModel.privacyPoolBalance),
                                    valueColor: TerminalPalette.cyan
                                )
                            }

                            // Error display
                            if let error = walletViewModel.privacyError {
                                Text("// ERROR: \(error)")
                                    .font(TerminalTypography.label())
                                    .foregroundColor(TerminalPalette.error)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, 4)
                            }

                            // Info button
                            TerminalSettingsRow(
                                label: "INFO",
                                value: "[VIEW]",
                                showChevron: true
                            ) {
                                showingPrivacyInfo = true
                            }

                            // Prize value display
                            if walletViewModel.selectedPrivacyProtocol != .direct {
                                Text("// Hackathon bounty: $\(walletViewModel.privacyPrizeValue)")
                                    .font(TerminalTypography.label())
                                    .foregroundColor(TerminalPalette.warning)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.top, 4)
                            }
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
            .sheet(isPresented: $showingPrivacyInfo) {
                PrivacyInfoSheet()
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

    // MARK: - Privacy Protocol Helpers

    private var protocolColor: Color {
        switch walletViewModel.selectedPrivacyProtocol {
        case .shadowWire:
            return TerminalPalette.purple
        case .privacyCash:
            return TerminalPalette.cyan
        case .direct:
            return TerminalPalette.textMuted
        }
    }

    private var privacyStatusValue: String {
        if !walletViewModel.privacyEnabled {
            return "[DISABLED]"
        }
        if !walletViewModel.privacyReady && walletViewModel.selectedPrivacyProtocol != .direct {
            return "[LOADING]"
        }
        switch walletViewModel.selectedPrivacyProtocol {
        case .direct:
            return "[DIRECT]"
        case .shadowWire, .privacyCash:
            return walletViewModel.privacyReady ? "[ACTIVE]" : "[LOADING]"
        }
    }

    private var privacyStatusColor: Color {
        if !walletViewModel.privacyEnabled {
            return TerminalPalette.textMuted
        }
        if !walletViewModel.privacyReady && walletViewModel.selectedPrivacyProtocol != .direct {
            return TerminalPalette.warning
        }
        return TerminalPalette.success
    }

    private func cycleProtocol() {
        let protocols: [PrivacyProtocolId] = [.direct, .shadowWire, .privacyCash]
        if let currentIndex = protocols.firstIndex(of: walletViewModel.selectedPrivacyProtocol) {
            let nextIndex = (currentIndex + 1) % protocols.count
            let newProtocol = protocols[nextIndex]

            // Set protocol asynchronously
            Task {
                await walletViewModel.setPrivacyProtocol(newProtocol)
            }
        }
    }
}

// MARK: - Terminal Toggle Style

struct TerminalToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label

            Button {
                configuration.isOn.toggle()
            } label: {
                HStack(spacing: 4) {
                    Text(configuration.isOn ? "[ON]" : "[OFF]")
                        .font(TerminalTypography.label())
                        .foregroundColor(configuration.isOn ? TerminalPalette.success : TerminalPalette.textMuted)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 2)
                        .fill(TerminalPalette.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(configuration.isOn ? TerminalPalette.success.opacity(0.5) : TerminalPalette.border, lineWidth: 1)
                        )
                )
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Privacy Info Sheet

struct PrivacyInfoSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                TerminalPalette.background
                    .ignoresSafeArea()

                ScanlineOverlay()
                    .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        // Header
                        VStack(alignment: .leading, spacing: 8) {
                            Text("[PRIVACY_PROTOCOLS]")
                                .font(TerminalTypography.header())
                                .foregroundColor(TerminalPalette.purple)

                            Text("// Enhanced on-chain privacy for settlements")
                                .font(TerminalTypography.label())
                                .foregroundColor(TerminalPalette.textMuted)
                        }

                        // Direct mode
                        TerminalProtocolCard(
                            name: "DIRECT",
                            description: "Standard on-chain transfer. No privacy enhancement.",
                            prize: 0,
                            color: TerminalPalette.textMuted
                        )

                        // ShadowWire
                        TerminalProtocolCard(
                            name: "SHADOWWIRE",
                            description: "Radr Labs privacy layer using ZK proofs. Hides transfer amounts and breaks sender-receiver link. Runs in SIMULATION mode without merchant key.",
                            prize: 15_000,
                            color: TerminalPalette.purple
                        )

                        // Privacy Cash
                        TerminalProtocolCard(
                            name: "PRIVACY_CASH",
                            description: "Zero-knowledge privacy pool. Lighter weight alternative for amount hiding.",
                            prize: 6_000,
                            color: TerminalPalette.cyan
                        )

                        // Combined value
                        VStack(alignment: .leading, spacing: 8) {
                            Text("> COMBINED_BOUNTY:")
                                .font(TerminalTypography.body(12))
                                .foregroundColor(TerminalPalette.textPrimary)

                            Text("$21,000")
                                .font(TerminalTypography.header(24))
                                .foregroundColor(TerminalPalette.warning)
                                .terminalGlow(TerminalPalette.warning, radius: 4)

                            Text("// Plus main track eligibility")
                                .font(TerminalTypography.label())
                                .foregroundColor(TerminalPalette.textMuted)
                        }
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 2)
                                .fill(TerminalPalette.surface)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 2)
                                        .stroke(TerminalPalette.warning.opacity(0.5), lineWidth: 1)
                                )
                        )

                        // How it works
                        VStack(alignment: .leading, spacing: 12) {
                            Text("> HOW_IT_WORKS:")
                                .font(TerminalTypography.body(12))
                                .foregroundColor(TerminalPalette.cyan)

                            TerminalInfoRow(label: "01", text: "Payment received via BLE mesh (offline)")
                            TerminalInfoRow(label: "02", text: "Device comes online")
                            TerminalInfoRow(label: "03", text: "Settlement routes through privacy pool")
                            TerminalInfoRow(label: "04", text: "Amount hidden + link broken")
                            TerminalInfoRow(label: "05", text: "Funds arrive at new stealth address")
                        }
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 2)
                                .fill(TerminalPalette.surface)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 2)
                                        .stroke(TerminalPalette.border, lineWidth: 1)
                                )
                        )

                        Spacer(minLength: 40)
                    }
                    .padding(16)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(TerminalPalette.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text("[PRIVACY_INFO]")
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

struct TerminalProtocolCard: View {
    let name: String
    let description: String
    let prize: UInt
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("[\(name)]")
                    .font(TerminalTypography.header(14))
                    .foregroundColor(color)

                Spacer()

                if prize > 0 {
                    Text("$\(prize)")
                        .font(TerminalTypography.label())
                        .foregroundColor(TerminalPalette.warning)
                }
            }

            Text(description)
                .font(TerminalTypography.label())
                .foregroundColor(TerminalPalette.textDim)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 2)
                .fill(TerminalPalette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(color.opacity(0.3), lineWidth: 1)
                )
        )
    }
}

// MARK: - Privacy Status Bar (for WalletView)

struct TerminalPrivacyStatusBar: View {
    let `protocol`: PrivacyProtocolId
    let isReady: Bool
    let poolBalance: Double

    private var protocolColor: Color {
        switch `protocol` {
        case .shadowWire: return TerminalPalette.purple
        case .privacyCash: return TerminalPalette.cyan
        case .direct: return TerminalPalette.textMuted
        }
    }

    private var statusIcon: String {
        if !isReady && `protocol` != .direct {
            return "..."
        }
        return isReady ? "[OK]" : "[-]"
    }

    var body: some View {
        HStack(spacing: 8) {
            // Protocol indicator
            HStack(spacing: 4) {
                Circle()
                    .fill(protocolColor)
                    .frame(width: 6, height: 6)

                Text("PRIVACY:")
                    .font(TerminalTypography.label())
                    .foregroundColor(TerminalPalette.textMuted)

                Text(`protocol`.displayName.uppercased())
                    .font(TerminalTypography.label())
                    .foregroundColor(protocolColor)
            }

            Spacer()

            // Status
            Text(statusIcon)
                .font(TerminalTypography.label())
                .foregroundColor(isReady ? TerminalPalette.success : TerminalPalette.warning)

            // Pool balance (if any)
            if poolBalance > 0 {
                Text(String(format: "%.4f", poolBalance))
                    .font(TerminalTypography.label())
                    .foregroundColor(TerminalPalette.cyan)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 2)
                .fill(TerminalPalette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(protocolColor.opacity(0.3), lineWidth: 1)
                )
        )
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
