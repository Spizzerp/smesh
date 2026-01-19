import SwiftUI
import StealthCore

struct SendPaymentSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState

    let peer: NearbyPeer
    let metaAddress: String
    let isHybrid: Bool

    @State private var amountString = ""
    @State private var memo = ""
    @State private var isSending = false
    @State private var sendError: Error?
    @State private var sendSuccess = false

    var body: some View {
        NavigationStack {
            ZStack {
                TerminalPalette.background
                    .ignoresSafeArea()

                ScanlineOverlay()
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 16) {
                        // Recipient section
                        TerminalPaymentSection(title: "[RECIPIENT]", accent: TerminalPalette.cyan) {
                            HStack(spacing: 12) {
                                Text("[>]")
                                    .font(TerminalTypography.body())
                                    .foregroundColor(TerminalPalette.cyan)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(peer.name?.uppercased() ?? "UNKNOWN_DEVICE")
                                        .font(TerminalTypography.body(12))
                                        .foregroundColor(TerminalPalette.textPrimary)
                                    Text(truncatedAddress)
                                        .font(TerminalTypography.label())
                                        .foregroundColor(TerminalPalette.textDim)
                                }

                                Spacer()

                                if isHybrid {
                                    Text("[PQ]")
                                        .font(TerminalTypography.label())
                                        .foregroundColor(TerminalPalette.purple)
                                        .terminalGlow(TerminalPalette.purple, radius: 2)
                                }
                            }
                        }

                        // Amount section
                        TerminalPaymentSection(title: "[AMOUNT]", accent: TerminalPalette.cyan) {
                            VStack(spacing: 12) {
                                // Amount input
                                HStack(spacing: 8) {
                                    Text(">")
                                        .font(TerminalTypography.body())
                                        .foregroundColor(TerminalPalette.cyan)

                                    TextField("0.0", text: $amountString)
                                        .keyboardType(.decimalPad)
                                        .font(TerminalTypography.balance(28))
                                        .foregroundColor(TerminalPalette.textPrimary)
                                        .multilineTextAlignment(.trailing)

                                    Text("SOL")
                                        .font(TerminalTypography.label())
                                        .foregroundColor(TerminalPalette.textDim)
                                }
                                .padding(12)
                                .background(
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(TerminalPalette.surfaceLight)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 2)
                                                .stroke(TerminalPalette.border, lineWidth: 1)
                                        )
                                )

                                // Quick amount buttons
                                HStack(spacing: 12) {
                                    TerminalQuickAmountButton(amount: "0.01", selected: amountString) {
                                        amountString = "0.01"
                                        dismissKeyboard()
                                    }
                                    TerminalQuickAmountButton(amount: "0.1", selected: amountString) {
                                        amountString = "0.1"
                                        dismissKeyboard()
                                    }
                                    TerminalQuickAmountButton(amount: "1.0", selected: amountString) {
                                        amountString = "1.0"
                                        dismissKeyboard()
                                    }
                                }
                            }
                        }

                        // Memo section
                        TerminalPaymentSection(title: "[MEMO]", accent: TerminalPalette.textDim) {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 8) {
                                    Text(">")
                                        .font(TerminalTypography.body())
                                        .foregroundColor(TerminalPalette.textMuted)

                                    TextField("optional_message", text: $memo)
                                        .font(TerminalTypography.body(12))
                                        .foregroundColor(TerminalPalette.textPrimary)
                                }

                                Text("// visible to recipient")
                                    .font(TerminalTypography.label())
                                    .foregroundColor(TerminalPalette.textMuted)
                            }
                        }

                        // Info section
                        TerminalPaymentSection(title: "[TX_INFO]", accent: TerminalPalette.textDim) {
                            VStack(spacing: 6) {
                                terminalInfoRow("NETWORK", "[DEVNET]", TerminalPalette.warning)
                                terminalInfoRow("DELIVERY", "BLE_MESH", TerminalPalette.textDim)
                                if isHybrid {
                                    terminalInfoRow("SECURITY", "[PQ:MLKEM768]", TerminalPalette.purple)
                                }
                            }
                        }

                        // Send button
                        TerminalPrimaryButton(
                            title: "SEND_PAYMENT",
                            accent: .public,
                            isLoading: isSending
                        ) {
                            sendPayment()
                        }
                        .disabled(!canSend)
                        .opacity(canSend ? 1.0 : 0.5)
                        .padding(.top, 8)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .padding(.bottom, 16)
                }
                .scrollDismissesKeyboard(.immediately)
                .onTapGesture {
                    dismissKeyboard()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(TerminalPalette.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Text("[CANCEL]")
                            .font(TerminalTypography.label())
                            .foregroundColor(TerminalPalette.textDim)
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text("// SEND_PAYMENT")
                        .font(TerminalTypography.header(12))
                        .foregroundColor(TerminalPalette.cyan)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        sendPayment()
                    } label: {
                        Text("[EXEC]")
                            .font(TerminalTypography.label())
                            .foregroundColor(canSend ? TerminalPalette.cyan : TerminalPalette.textMuted)
                    }
                    .disabled(!canSend)
                }
            }
            .overlay {
                if isSending {
                    TerminalSendingOverlay()
                }
            }
            .alert("Payment Sent!", isPresented: $sendSuccess) {
                Button("Done") {
                    dismiss()
                }
            } message: {
                Text("Your payment has been broadcast to the mesh network. It will settle when the recipient comes online.")
            }
            .alert("Send Failed", isPresented: .constant(sendError != nil)) {
                Button("OK") {
                    sendError = nil
                }
            } message: {
                if let error = sendError {
                    Text(error.localizedDescription)
                }
            }
        }
    }

    private var truncatedAddress: String {
        "\(metaAddress.prefix(8))...\(metaAddress.suffix(6))"
    }

    private var canSend: Bool {
        guard let amount = Double(amountString), amount > 0 else { return false }
        return !isSending
    }

    private var amountInLamports: UInt64 {
        guard let amount = Double(amountString) else { return 0 }
        return UInt64(amount * 1_000_000_000)
    }

    private func sendPayment() {
        guard canSend else { return }

        // Dismiss keyboard before sending
        dismissKeyboard()

        isSending = true

        Task {
            do {
                try await appState.meshNetworkManager.sendPayment(
                    to: metaAddress,
                    amount: amountInLamports,
                    memo: memo.isEmpty ? nil : memo
                )
                sendSuccess = true
            } catch {
                sendError = error
            }
            isSending = false
        }
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    private func terminalInfoRow(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack {
            Text("> \(label)")
                .font(TerminalTypography.body(12))
                .foregroundColor(TerminalPalette.textPrimary)
            Spacer()
            Text(value)
                .font(TerminalTypography.label())
                .foregroundColor(color)
        }
    }
}

// MARK: - Terminal Payment Section

struct TerminalPaymentSection<Content: View>: View {
    let title: String
    let accent: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(TerminalTypography.header(12))
                .foregroundColor(accent)
                .padding(.bottom, 8)

            content()
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 2)
                        .fill(TerminalPalette.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(TerminalPalette.border, lineWidth: 1)
                        )
                )
        }
    }
}

// MARK: - Terminal Quick Amount Button

struct TerminalQuickAmountButton: View {
    let amount: String
    let selected: String
    let action: () -> Void

    var isSelected: Bool { amount == selected }

    var body: some View {
        Button(action: action) {
            Text("[\(amount)]")
                .font(TerminalTypography.label())
                .foregroundColor(isSelected ? TerminalPalette.cyan : TerminalPalette.textDim)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 2)
                        .fill(isSelected ? TerminalPalette.surfaceLight : Color.clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(isSelected ? TerminalPalette.cyan : TerminalPalette.border, lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Terminal Sending Overlay

struct TerminalSendingOverlay: View {
    var body: some View {
        ZStack {
            TerminalPalette.background.opacity(0.95)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                Text("[~~~]")
                    .font(TerminalTypography.balance(24))
                    .foregroundColor(TerminalPalette.cyan)
                    .terminalGlow(TerminalPalette.cyan, radius: 4)

                HStack(spacing: 8) {
                    TerminalSpinner(color: TerminalPalette.cyan)
                    Text("BROADCASTING_TO_MESH...")
                        .font(TerminalTypography.body(12))
                        .foregroundColor(TerminalPalette.textPrimary)
                }
            }
            .padding(32)
            .background(
                RoundedRectangle(cornerRadius: 2)
                    .fill(TerminalPalette.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(TerminalPalette.cyan, lineWidth: 1)
                    )
            )
        }
    }
}

#Preview {
    ZStack {
        TerminalPalette.background
            .ignoresSafeArea()
        ScanlineOverlay()
            .ignoresSafeArea()
        SendPaymentSheet(
            peer: NearbyPeer(
                id: "test",
                name: "Alice's iPhone",
                rssi: -45,
                isConnected: true,
                lastSeenAt: Date(),
                supportsHybrid: true
            ),
            metaAddress: "abc123def456abc123def456abc123def456",
            isHybrid: true
        )
    }
}
