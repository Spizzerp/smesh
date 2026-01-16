import SwiftUI
import StealthCore

struct WalletView: View {
    @EnvironmentObject var walletViewModel: WalletViewModel
    @EnvironmentObject var meshViewModel: MeshViewModel

    // Shield/Unshield UI state
    @State private var showShieldInput = false
    @State private var showUnshieldConfirm = false
    @State private var shieldAmount = ""
    @State private var shieldError: String?
    @State private var shieldSuccess = false
    @State private var unshieldSuccess = false

    // Refresh state
    @State private var isRefreshing = false

    var body: some View {
        NavigationStack {
            ZStack {
                // Gradient background
                NeuromorphicPalette.pageBackground
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        // Status badges (scroll away with content)
                        HStack {
                            Spacer()
                            WalletHeaderStatus(
                                isDevnet: walletViewModel.network == .devnet,
                                isOnline: meshViewModel.isOnline,
                                peerCount: meshViewModel.peerCount
                            )
                        }
                        .padding(.horizontal, 16)

                        // Wallet content
                        walletContent
                    }
                    .padding(.top, 8)
                }
                .scrollDismissesKeyboard(.immediately)
                .onTapGesture {
                    dismissKeyboard()
                }
            }
            .navigationTitle("Wallet")
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

    // MARK: - Wallet Content

    private var walletContent: some View {
        VStack(spacing: 20) {
            // Main Wallet Container (Blue)
            MainWalletContainer(
                balance: walletViewModel.mainWalletBalance,
                address: walletViewModel.mainWalletAddress ?? "",
                isRefreshing: isRefreshing,
                showInput: showShieldInput,
                showMixing: walletViewModel.isMixing,
                onRefresh: { performRefresh() }
            ) {
                EmptyView()  // Badge moved to header
            } inputContent: {
                // Amount input with cancel/confirm
                NeuromorphicAmountInput(
                    amount: $shieldAmount,
                    maxAmount: walletViewModel.maxShieldAmount,
                    palette: .blue,
                    onConfirm: performShield,
                    onCancel: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showShieldInput = false
                            shieldAmount = ""
                        }
                    }
                )
            } mixingContent: {
                // Mixing progress indicator
                ShieldMixingProgress(
                    mixProgress: walletViewModel.mixProgress,
                    mixStatus: walletViewModel.mixStatus
                )
            }

            // Shield/Unshield Buttons
            ShieldUnshieldRow(
                onShield: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showUnshieldConfirm = false
                        showShieldInput.toggle()
                    }
                },
                onUnshield: {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showShieldInput = false
                        showUnshieldConfirm.toggle()
                    }
                },
                shieldDisabled: !walletViewModel.canShield || walletViewModel.isShielding || walletViewModel.isUnshielding,
                unshieldDisabled: !walletViewModel.canUnshield || walletViewModel.isShielding || walletViewModel.isUnshielding,
                isShielding: showShieldInput || walletViewModel.isShielding,
                isUnshielding: showUnshieldConfirm || walletViewModel.isUnshielding
            )

            // Stealth Wallet Container (Purple)
            StealthWalletContainer(
                balance: walletViewModel.stealthBalance,
                showConfirm: showUnshieldConfirm
            ) {
                QuantumBadge(palette: .purple)
            } confirmContent: {
                NeuromorphicUnshieldConfirm(
                    amount: walletViewModel.maxUnshieldAmount,
                    palette: .purple,
                    isLoading: walletViewModel.isUnshielding,
                    onConfirm: performUnshield,
                    onCancel: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showUnshieldConfirm = false
                        }
                    }
                )
            }

        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    private func performShield() {
        print("[UI] performShield called with shieldAmount: '\(shieldAmount)'")
        guard let amount = Double(shieldAmount), amount > 0 else {
            print("[UI] performShield: invalid amount, returning early")
            return
        }
        print("[UI] performShield: starting shield of \(amount) SOL")

        // Capture amount before clearing
        let shieldAmountValue = amount

        // Step 1: Collapse input section first
        withAnimation(.easeInOut(duration: 0.25)) {
            showShieldInput = false
            shieldAmount = ""
        }

        // Step 2: Wait for collapse animation, then start shield (which triggers mixing section)
        Task {
            // Wait for input collapse animation to complete
            try? await Task.sleep(nanoseconds: 600_000_000) // 0.6 seconds

            do {
                try await walletViewModel.shield(sol: shieldAmountValue)
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
                withAnimation(.easeInOut(duration: 0.2)) {
                    showUnshieldConfirm = false
                }
                unshieldSuccess = true
            } catch {
                shieldError = error.localizedDescription
            }
        }
    }

    private func performRefresh() {
        guard !isRefreshing else { return }

        isRefreshing = true
        Task {
            // Run refresh and minimum delay in parallel, wait for both
            async let refresh: () = walletViewModel.refreshBalance()
            async let minimumDelay: () = Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds minimum

            // Wait for both to complete (whichever takes longer)
            _ = await (refresh, try? minimumDelay)

            // Return to protruding state after both complete
            await MainActor.run {
                isRefreshing = false
            }
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

// MARK: - Shield Mixing Progress (Blue theme, inside wallet container)

struct ShieldMixingProgress: View {
    let mixProgress: Double
    let mixStatus: String

    var body: some View {
        VStack(spacing: 12) {
            // Header with spinner and status
            HStack(spacing: 12) {
                // Spinning indicator
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: NeuromorphicPalette.blue.accent))
                    .scaleEffect(1.0)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Shielding...")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(NeuromorphicPalette.blue.textPrimary)

                    Text(mixStatus.isEmpty ? "Creating stealth hops for privacy" : mixStatus)
                        .font(.caption)
                        .foregroundColor(NeuromorphicPalette.blue.textSecondary)
                        .lineLimit(2)
                }

                Spacer()
            }

            // Progress bar
            if mixProgress > 0 {
                ProgressView(value: mixProgress)
                    .progressViewStyle(LinearProgressViewStyle(tint: NeuromorphicPalette.blue.accent))
                    .frame(height: 4)
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 8)
    }
}

// MARK: - Mix Progress Indicator (Legacy - Purple theme, standalone)

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
                        .foregroundColor(NeuromorphicPalette.purple.textPrimary)
                    Text(mixStatus.isEmpty ? "Creating stealth hops for privacy" : mixStatus)
                        .font(.caption)
                        .foregroundColor(NeuromorphicPalette.purple.textSecondary)
                }

                Spacer()
            }
            .padding()
            .neuromorphicPurple(cornerRadius: 16)

            // Progress bar
            if mixProgress > 0 {
                ProgressView(value: mixProgress)
                    .progressViewStyle(LinearProgressViewStyle(tint: NeuromorphicPalette.purple.accent))
                    .padding(.horizontal)
            }
        }
    }
}

// MARK: - Legacy Components (kept for compatibility)

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
        case .awaitingFunds: return "hourglass"
        case .received: return "clock.fill"
        case .settling: return "arrow.triangle.2.circlepath"
        case .settled: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .expired: return "xmark.circle.fill"
        }
    }

    private var statusColor: Color {
        switch payment.status {
        case .awaitingFunds: return .purple
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
