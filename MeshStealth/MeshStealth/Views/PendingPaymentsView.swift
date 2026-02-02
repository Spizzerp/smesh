import SwiftUI
import StealthCore

struct PendingPaymentsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var walletViewModel: WalletViewModel
    @EnvironmentObject var meshViewModel: MeshViewModel

    var body: some View {
        NavigationStack {
            Group {
                if walletViewModel.pendingPayments.isEmpty {
                    EmptyPendingView()
                } else {
                    List {
                        Section {
                            ForEach(walletViewModel.pendingPayments) { payment in
                                PendingPaymentDetailRow(payment: payment)
                            }
                        } header: {
                            HStack {
                                Text("Awaiting Settlement")
                                Spacer()
                                Text("\(walletViewModel.pendingPayments.count)")
                                    .foregroundColor(.secondary)
                            }
                        } footer: {
                            Text("Payments will automatically settle when you're connected to the internet")
                        }

                        if !walletViewModel.settledPayments.isEmpty {
                            Section {
                                ForEach(walletViewModel.settledPayments.prefix(10)) { payment in
                                    SettledPaymentRow(payment: payment)
                                }
                            } header: {
                                Text("Recently Settled")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Pending")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    if !walletViewModel.pendingPayments.isEmpty {
                        Button {
                            Task {
                                await appState.meshNetworkManager.settlePendingPayments()
                            }
                        } label: {
                            Label("Settle Now", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(!meshViewModel.isOnline)
                    }
                }
            }
        }
    }
}

struct EmptyPendingView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 60))
                .foregroundColor(.green)

            VStack(spacing: 8) {
                Text("All Caught Up!")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("No pending payments awaiting settlement")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
    }
}

struct PendingPaymentDetailRow: View {
    let payment: PendingPayment

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header
            HStack {
                StatusBadge(status: payment.status)
                Spacer()
                Text(formattedAmount)
                    .font(.headline)
                    .foregroundColor(.green)
            }

            // Details
            VStack(alignment: .leading, spacing: 6) {
                DetailRow(label: "Stealth Address", value: truncatedAddress)
                DetailRow(label: "Received", value: formattedDate)

                if payment.isHybrid {
                    HStack {
                        Text("Security")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Spacer()
                        Label("Post-Quantum", systemImage: "lock.shield.fill")
                            .font(.caption)
                            .foregroundColor(.purple)
                    }
                }

                if payment.settlementAttempts > 0 {
                    DetailRow(label: "Settlement Attempts", value: "\(payment.settlementAttempts)")
                }

                if let error = payment.errorMessage {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.orange)
                    }
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var truncatedAddress: String {
        let addr = payment.stealthAddress
        return "\(addr.prefix(8))...\(addr.suffix(6))"
    }

    private var formattedAmount: String {
        String(format: "+%.4f SOL", payment.amountInSol)
    }

    private var formattedDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: payment.receivedAt)
    }
}

struct StatusBadge: View {
    let status: PendingPaymentStatus

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(status.rawValue.capitalized)
        }
        .font(.caption)
        .fontWeight(.medium)
        .foregroundColor(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule()
                .fill(color.opacity(0.15))
        )
    }

    private var icon: String {
        switch status {
        case .awaitingFunds: return "hourglass"
        case .received: return "clock.fill"
        case .settling: return "arrow.triangle.2.circlepath"
        case .settled: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        case .expired: return "xmark.circle.fill"
        }
    }

    private var color: Color {
        switch status {
        case .awaitingFunds: return .purple
        case .received: return .orange
        case .settling: return .blue
        case .settled: return .green
        case .failed: return .red
        case .expired: return .gray
        }
    }
}

struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
        }
    }
}

struct SettledPaymentRow: View {
    let payment: PendingPayment

    var body: some View {
        HStack {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)

            VStack(alignment: .leading, spacing: 2) {
                Text(truncatedAddress)
                    .font(.subheadline)
                if let sig = payment.settlementSignature {
                    HStack(spacing: 2) {
                        Text("Tx:")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        TransactionLink(signature: sig, truncateLength: 8, cluster: .devnet)
                    }
                }
            }

            Spacer()

            Text(formattedAmount)
                .font(.subheadline)
                .foregroundColor(.green)
        }
    }

    private var truncatedAddress: String {
        let addr = payment.stealthAddress
        return "\(addr.prefix(6))...\(addr.suffix(4))"
    }

    private var formattedAmount: String {
        String(format: "+%.4f", payment.amountInSol)
    }
}

#Preview {
    PendingPaymentsView()
}
