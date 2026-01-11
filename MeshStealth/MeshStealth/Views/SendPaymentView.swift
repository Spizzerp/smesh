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
            Form {
                // Recipient section
                Section {
                    HStack {
                        Image(systemName: "person.circle.fill")
                            .font(.title)
                            .foregroundColor(.blue)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(peer.name ?? "Unknown Device")
                                .font(.headline)
                            Text(truncatedAddress)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        Spacer()

                        if isHybrid {
                            Label("PQ", systemImage: "lock.shield.fill")
                                .font(.caption)
                                .foregroundColor(.purple)
                        }
                    }
                } header: {
                    Text("Recipient")
                }

                // Amount section
                Section {
                    HStack {
                        TextField("0.0", text: $amountString)
                            .keyboardType(.decimalPad)
                            .font(.system(size: 36, weight: .bold, design: .rounded))

                        Text("SOL")
                            .font(.title2)
                            .foregroundColor(.secondary)
                    }

                    // Quick amount buttons
                    HStack(spacing: 12) {
                        QuickAmountButton(amount: "0.01", selected: amountString) {
                            amountString = "0.01"
                        }
                        QuickAmountButton(amount: "0.1", selected: amountString) {
                            amountString = "0.1"
                        }
                        QuickAmountButton(amount: "1.0", selected: amountString) {
                            amountString = "1.0"
                        }
                    }
                } header: {
                    Text("Amount")
                }

                // Memo section
                Section {
                    TextField("Optional message", text: $memo)
                } header: {
                    Text("Memo")
                } footer: {
                    Text("This message will be visible to the recipient")
                }

                // Info section
                Section {
                    HStack {
                        Text("Network")
                        Spacer()
                        Text("Devnet")
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Text("Delivery")
                        Spacer()
                        Text("Via BLE Mesh")
                            .foregroundColor(.secondary)
                    }

                    if isHybrid {
                        HStack {
                            Text("Security")
                            Spacer()
                            Text("Post-Quantum (MLKEM)")
                                .foregroundColor(.purple)
                        }
                    }
                }
            }
            .navigationTitle("Send Payment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        sendPayment()
                    }
                    .disabled(!canSend)
                    .fontWeight(.semibold)
                }
            }
            .overlay {
                if isSending {
                    SendingOverlay()
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
}

struct QuickAmountButton: View {
    let amount: String
    let selected: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(amount)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(amount == selected ? .white : .blue)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(amount == selected ? Color.blue : Color.blue.opacity(0.1))
                )
        }
    }
}

struct SendingOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.5)
                Text("Broadcasting to mesh...")
                    .font(.headline)
                    .foregroundColor(.white)
            }
            .padding(32)
            .background(
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(.systemBackground))
            )
        }
    }
}

#Preview {
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
