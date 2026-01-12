import SwiftUI
import StealthCore

struct WalletView: View {
    @EnvironmentObject var walletViewModel: WalletViewModel
    @EnvironmentObject var meshViewModel: MeshViewModel

    @State private var airdropError: Error?
    @State private var airdropSuccess = false

    // Shield/Unshield UI state
    @State private var showShieldInput = false
    @State private var showUnshieldInput = false
    @State private var shieldAmount = ""
    @State private var shieldError: String?
    @State private var shieldSuccess = false
    @State private var unshieldSuccess = false


    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    // Main Wallet Card (for funding) - with Unshield confirmation
                    MainWalletCard(
                        address: walletViewModel.mainWalletAddress,
                        balance: walletViewModel.formattedMainWalletBalance,
                        network: walletViewModel.network,
                        isAirdropping: walletViewModel.isAirdropping,
                        isUnshielding: walletViewModel.isUnshielding,
                        showUnshieldInput: $showUnshieldInput,
                        maxUnshieldAmount: walletViewModel.maxUnshieldAmount,
                        onAirdrop: requestAirdrop,
                        onRefresh: { Task { await walletViewModel.refreshBalance() } },
                        onUnshieldConfirm: performUnshield
                    )

                    // Shield/Unshield Buttons
                    ShieldUnshieldButtons(
                        showShieldInput: $showShieldInput,
                        showUnshieldInput: $showUnshieldInput,
                        canShield: walletViewModel.canShield,
                        canUnshield: walletViewModel.canUnshield,
                        isLoading: walletViewModel.isShielding || walletViewModel.isUnshielding
                    )

                    // Stealth Balance Card - with Shield input
                    StealthBalanceCard(
                        balance: walletViewModel.formattedBalance,
                        hasPostQuantum: walletViewModel.hasPostQuantum,
                        showShieldInput: $showShieldInput,
                        shieldAmount: $shieldAmount,
                        maxShieldAmount: walletViewModel.maxShieldAmount,
                        isShielding: walletViewModel.isShielding,
                        onShieldConfirm: performShield
                    )

                    // Status indicators
                    StatusBar(
                        isOnline: meshViewModel.isOnline,
                        peerCount: meshViewModel.peerCount,
                        hasPostQuantum: walletViewModel.hasPostQuantum
                    )

                    // Auto-mix progress indicator (shown during shield/unshield)
                    if walletViewModel.isMixing {
                        MixProgressIndicator(
                            mixProgress: walletViewModel.mixProgress,
                            mixStatus: walletViewModel.mixStatus
                        )
                    }

                    // Recent Activity
                    RecentActivitySection(
                        pendingPayments: walletViewModel.pendingPayments,
                        settledPayments: walletViewModel.settledPayments
                    )
                }
                .padding(.vertical)
            }
            .navigationTitle("Wallet")
            .background(Color(.systemGroupedBackground))
            .alert("Airdrop Received!", isPresented: $airdropSuccess) {
                Button("OK") { }
            } message: {
                Text("1 SOL has been added to your wallet")
            }
            .alert("Airdrop Failed", isPresented: .constant(airdropError != nil)) {
                Button("OK") { airdropError = nil }
            } message: {
                if let error = airdropError {
                    Text(error.localizedDescription)
                }
            }
            .alert("Shield Successful!", isPresented: $shieldSuccess) {
                Button("OK") { }
            } message: {
                Text("Funds have been moved to your stealth balance")
            }
            .alert("Shield Failed", isPresented: .constant(shieldError != nil)) {
                Button("OK") { shieldError = nil }
            } message: {
                if let error = shieldError {
                    Text(error)
                }
            }
            .alert("Unshield Successful!", isPresented: $unshieldSuccess) {
                Button("OK") { }
            } message: {
                Text("Funds have been moved to your main wallet")
            }
        }
    }

    private func requestAirdrop() {
        Task {
            do {
                _ = try await walletViewModel.requestAirdrop()
                airdropSuccess = true
            } catch {
                airdropError = error
            }
        }
    }

    private func performShield() {
        guard let amount = Double(shieldAmount), amount > 0 else { return }

        Task {
            do {
                try await walletViewModel.shield(sol: amount)
                shieldAmount = ""
                showShieldInput = false
                shieldSuccess = true
            } catch {
                shieldError = error.localizedDescription
            }
        }
    }

    private func performUnshield() {
        Task {
            do {
                // Use unshield with automatic pre-mix for privacy
                try await walletViewModel.unshieldWithMix()
                showUnshieldInput = false
                unshieldSuccess = true
            } catch {
                shieldError = error.localizedDescription
            }
        }
    }
}

// MARK: - Components

struct MainWalletCard: View {
    let address: String?
    let balance: String
    let network: SolanaNetwork
    let isAirdropping: Bool
    let isUnshielding: Bool
    @Binding var showUnshieldInput: Bool
    let maxUnshieldAmount: Double
    let onAirdrop: () -> Void
    let onRefresh: () -> Void
    let onUnshieldConfirm: () -> Void

    @State private var showCopied = false

    var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Main Wallet")
                        .font(.headline)
                    Text("Funding Address")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                Text(network.rawValue)
                    .font(.caption)
                    .foregroundColor(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.15))
                    .cornerRadius(6)

                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                        .foregroundColor(.secondary)
                }
            }

            // Balance
            Text(balance)
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundColor(.primary)

            // Address
            if let address = address {
                Button {
                    UIPasteboard.general.string = address
                    showCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        showCopied = false
                    }
                } label: {
                    HStack {
                        Text(truncateAddress(address))
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                        Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                            .font(.caption)
                            .foregroundColor(showCopied ? .green : .secondary)
                    }
                }
            }

            // Info text
            Text("Send SOL from exchanges or other wallets here")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            // Unshield confirmation (shown when Unshield button tapped)
            if showUnshieldInput {
                UnshieldConfirmSection(
                    availableAmount: maxUnshieldAmount,
                    isLoading: isUnshielding,
                    onConfirm: onUnshieldConfirm,
                    onCancel: { showUnshieldInput = false }
                )
            }

            // Airdrop Button (devnet only)
            if network == .devnet && !showUnshieldInput {
                Button(action: onAirdrop) {
                    HStack {
                        if isAirdropping {
                            ProgressView()
                                .scaleEffect(0.8)
                        } else {
                            Image(systemName: "drop.fill")
                        }
                        Text(isAirdropping ? "Requesting..." : "Request Airdrop")
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(isAirdropping ? Color.gray : Color.blue)
                    )
                }
                .disabled(isAirdropping)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.05), radius: 10, y: 5)
        )
        .padding(.horizontal)
    }

    private func truncateAddress(_ address: String) -> String {
        guard address.count > 12 else { return address }
        return "\(address.prefix(6))...\(address.suffix(4))"
    }
}

struct StealthBalanceCard: View {
    let balance: String
    let hasPostQuantum: Bool
    @Binding var showShieldInput: Bool
    @Binding var shieldAmount: String
    let maxShieldAmount: Double
    let isShielding: Bool
    let onShieldConfirm: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Stealth Balance")
                        .font(.headline)
                    Text("Private Funds")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                if hasPostQuantum {
                    Label("Post-Quantum", systemImage: "lock.shield.fill")
                        .font(.caption)
                        .foregroundColor(.purple)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.purple.opacity(0.15))
                        .cornerRadius(6)
                }
            }

            Text(balance)
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(.primary)

            Text("Received via mesh payments or shielded from main wallet")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            // Shield amount input (shown when Shield button tapped)
            if showShieldInput {
                AmountInputSection(
                    label: "Shield",
                    amount: $shieldAmount,
                    placeholder: "0.0",
                    maxLabel: String(format: "Max: %.4f SOL", maxShieldAmount),
                    isLoading: isShielding,
                    onConfirm: onShieldConfirm,
                    onCancel: { showShieldInput = false; shieldAmount = "" },
                    onMax: { shieldAmount = String(format: "%.4f", maxShieldAmount) }
                )
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.purple.opacity(0.3), lineWidth: 1)
                )
        )
        .padding(.horizontal)
    }
}

// MARK: - Shield/Unshield Buttons

struct ShieldUnshieldButtons: View {
    @Binding var showShieldInput: Bool
    @Binding var showUnshieldInput: Bool
    let canShield: Bool
    let canUnshield: Bool
    let isLoading: Bool

    var body: some View {
        HStack(spacing: 32) {
            // Shield button (down arrow)
            Button {
                showUnshieldInput = false
                showShieldInput.toggle()
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(canShield && !isLoading ? .blue : .gray)
                    Text("Shield")
                        .font(.caption)
                        .foregroundColor(canShield && !isLoading ? .blue : .gray)
                }
            }
            .disabled(!canShield || isLoading)

            // Unshield button (up arrow)
            Button {
                showShieldInput = false
                showUnshieldInput.toggle()
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 40))
                        .foregroundColor(canUnshield && !isLoading ? .green : .gray)
                    Text("Unshield")
                        .font(.caption)
                        .foregroundColor(canUnshield && !isLoading ? .green : .gray)
                }
            }
            .disabled(!canUnshield || isLoading)
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Amount Input Section

struct AmountInputSection: View {
    let label: String
    @Binding var amount: String
    let placeholder: String
    var maxLabel: String? = nil
    var isLoading: Bool = false
    let onConfirm: () -> Void
    let onCancel: () -> Void
    var onMax: (() -> Void)? = nil

    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        VStack(spacing: 12) {
            // Amount input
            HStack {
                Text(label + ":")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                TextField(placeholder, text: $amount)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                    .focused($isTextFieldFocused)

                Text("SOL")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                if let onMax = onMax {
                    Button("Max") {
                        onMax()
                    }
                    .font(.caption)
                    .foregroundColor(.blue)
                }
            }

            if let maxLabel = maxLabel {
                Text(maxLabel)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Confirm/Cancel buttons
            HStack(spacing: 12) {
                Button("Cancel") {
                    isTextFieldFocused = false
                    onCancel()
                }
                .font(.subheadline.weight(.medium))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color(.systemGray5))
                .cornerRadius(8)
                .disabled(isLoading)

                Button {
                    isTextFieldFocused = false
                    onConfirm()
                } label: {
                    HStack {
                        if isLoading {
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                        Text(isLoading ? "Processing..." : "Confirm")
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(isLoading ? Color.gray : Color.blue)
                .cornerRadius(8)
                .disabled(isLoading || amount.isEmpty)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
        .onAppear {
            // Auto-focus the text field when section appears
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                isTextFieldFocused = true
            }
        }
    }
}

// MARK: - Unshield Confirmation Section

struct UnshieldConfirmSection: View {
    let availableAmount: Double
    var isLoading: Bool = false
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            // Info message
            VStack(spacing: 4) {
                Text("Unshield All Funds")
                    .font(.subheadline.weight(.semibold))
                Text(String(format: "%.4f SOL will be moved to your main wallet", availableAmount))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Privacy note
            HStack(spacing: 6) {
                Image(systemName: "shuffle")
                    .font(.caption)
                    .foregroundColor(.purple)
                Text("Auto-mixing 1-5 hops for privacy")
                    .font(.caption)
                    .foregroundColor(.purple)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.purple.opacity(0.1))
            .cornerRadius(8)

            // Confirm/Cancel buttons
            HStack(spacing: 12) {
                Button("Cancel") {
                    onCancel()
                }
                .font(.subheadline.weight(.medium))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color(.systemGray5))
                .cornerRadius(8)
                .disabled(isLoading)

                Button {
                    onConfirm()
                } label: {
                    HStack {
                        if isLoading {
                            ProgressView()
                                .scaleEffect(0.8)
                        }
                        Text(isLoading ? "Unshielding..." : "Confirm")
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(isLoading ? Color.gray : Color.green)
                .cornerRadius(8)
                .disabled(isLoading)
            }
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

struct BalanceCard: View {
    let balance: String

    var body: some View {
        VStack(spacing: 8) {
            Text("Pending Balance")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Text(balance)
                .font(.system(size: 42, weight: .bold, design: .rounded))
                .foregroundColor(.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.05), radius: 10, y: 5)
        )
        .padding(.horizontal)
    }
}

struct StatusBar: View {
    let isOnline: Bool
    let peerCount: Int
    let hasPostQuantum: Bool

    var body: some View {
        HStack(spacing: 16) {
            StatusPill(
                icon: isOnline ? "wifi" : "wifi.slash",
                text: isOnline ? "Online" : "Offline",
                color: isOnline ? .green : .orange
            )

            StatusPill(
                icon: "antenna.radiowaves.left.and.right",
                text: "\(peerCount) nearby",
                color: peerCount > 0 ? .blue : .gray
            )

            if hasPostQuantum {
                StatusPill(
                    icon: "lock.shield.fill",
                    text: "PQ",
                    color: .purple
                )
            }
        }
        .padding(.horizontal)
    }
}

struct StatusPill: View {
    let icon: String
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
            Text(text)
                .font(.caption)
                .fontWeight(.medium)
        }
        .foregroundColor(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule()
                .fill(color.opacity(0.15))
        )
    }
}

struct QuickActionButton: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 28))
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
            .foregroundColor(color)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 20)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(.systemBackground))
                    .shadow(color: .black.opacity(0.05), radius: 5, y: 2)
            )
        }
    }
}

// MARK: - Mix Progress Indicator

struct MixProgressIndicator: View {
    let mixProgress: Double
    let mixStatus: String

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
                    .scaleEffect(0.8)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Auto-Mixing...")
                        .font(.headline)
                    Text(mixStatus.isEmpty ? "Creating stealth hops for privacy" : mixStatus)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()
            }
            .padding()
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.purple.opacity(0.1))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.purple.opacity(0.3), lineWidth: 1)
                    )
            )

            // Progress bar
            if mixProgress > 0 {
                ProgressView(value: mixProgress)
                    .progressViewStyle(LinearProgressViewStyle(tint: .purple))
                    .padding(.horizontal)
            }
        }
        .padding(.horizontal)
    }
}

// MARK: - Recent Activity

struct RecentActivitySection: View {
    let pendingPayments: [PendingPayment]
    let settledPayments: [PendingPayment]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent Activity")
                .font(.headline)
                .padding(.horizontal)

            if pendingPayments.isEmpty && settledPayments.isEmpty {
                EmptyActivityView()
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(pendingPayments.prefix(5)) { payment in
                        PaymentRow(payment: payment)
                    }
                    ForEach(settledPayments.prefix(5)) { payment in
                        PaymentRow(payment: payment)
                    }
                }
                .padding(.horizontal)
            }
        }
    }
}

struct EmptyActivityView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("No recent activity")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }
}

struct PaymentRow: View {
    let payment: PendingPayment

    var body: some View {
        HStack {
            // Status icon
            Image(systemName: statusIcon)
                .foregroundColor(statusColor)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(formattedAddress)
                        .font(.subheadline)
                        .fontWeight(.medium)

                    // Hop count badge (shows how many times this payment has been mixed)
                    if payment.hopCount > 0 {
                        Text("Mixed \(payment.hopCount)x")
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.purple))
                    }
                }
                Text(formattedDate)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(formattedAmount)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundColor(.green)
                Text(payment.status.rawValue)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(.systemBackground))
        )
    }

    private var statusIcon: String {
        switch payment.status {
        case .received: return "clock.fill"
        case .settling: return "arrow.triangle.2.circlepath"
        case .settled: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .expired: return "xmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch payment.status {
        case .received: return .orange
        case .settling: return .blue
        case .settled: return .green
        case .failed: return .red
        case .expired: return .gray
        }
    }

    private var formattedAddress: String {
        let addr = payment.stealthAddress
        return "\(addr.prefix(6))...\(addr.suffix(4))"
    }

    private var formattedAmount: String {
        String(format: "+%.4f SOL", payment.amountInSol)
    }

    private var formattedDate: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: payment.receivedAt, relativeTo: Date())
    }
}

#Preview {
    WalletView()
}
