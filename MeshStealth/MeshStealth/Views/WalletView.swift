import SwiftUI
import StealthCore

struct WalletView: View {
    @EnvironmentObject var walletViewModel: WalletViewModel
    @EnvironmentObject var meshViewModel: MeshViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Balance Card
                    BalanceCard(balance: walletViewModel.formattedBalance)

                    // Status indicators
                    StatusBar(
                        isOnline: meshViewModel.isOnline,
                        peerCount: meshViewModel.peerCount,
                        hasPostQuantum: walletViewModel.hasPostQuantum
                    )

                    // Quick Actions
                    HStack(spacing: 16) {
                        QuickActionButton(
                            title: "Request",
                            icon: "arrow.down.circle.fill",
                            color: .green
                        ) {
                            // Show receive sheet
                        }

                        QuickActionButton(
                            title: "Send",
                            icon: "arrow.up.circle.fill",
                            color: .blue
                        ) {
                            // Navigate to nearby peers
                        }
                    }
                    .padding(.horizontal)

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
        }
    }
}

// MARK: - Components

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
                Text(formattedAddress)
                    .font(.subheadline)
                    .fontWeight(.medium)
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
