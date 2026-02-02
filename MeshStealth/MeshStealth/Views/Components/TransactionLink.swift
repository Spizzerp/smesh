import SwiftUI
import UIKit

// MARK: - Solana Cluster

enum SolanaCluster: String {
    case devnet = "devnet"
    case mainnet = "mainnet"
    case testnet = "testnet"
}

// MARK: - Transaction Link

/// Tappable transaction signature link that opens Solscan explorer
struct TransactionLink: View {
    let signature: String
    var truncateLength: Int = 6
    var cluster: SolanaCluster = .devnet

    var body: some View {
        Button(action: openExplorer) {
            HStack(spacing: 4) {
                Text("\(signature.prefix(truncateLength))...")
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 10))
            }
            .font(TerminalTypography.label())
            .foregroundColor(TerminalPalette.cyan)
        }
        .buttonStyle(.plain)
    }

    private func openExplorer() {
        let baseURL: String
        switch cluster {
        case .mainnet:
            baseURL = "https://solscan.io/tx/\(signature)"
        case .devnet:
            baseURL = "https://solscan.io/tx/\(signature)?cluster=devnet"
        case .testnet:
            baseURL = "https://solscan.io/tx/\(signature)?cluster=testnet"
        }

        if let url = URL(string: baseURL) {
            UIApplication.shared.open(url)
        }
    }
}

// MARK: - Preview

#Preview("Transaction Links") {
    ZStack {
        TerminalPalette.background
            .ignoresSafeArea()

        VStack(spacing: 16) {
            TransactionLink(
                signature: "5UfDuX7WXpDPqspwK5bvpFT7G4VL9oYnKJTHSJQdYJBq2W4sLfDe7rSNvx9ZL5LkM5vP9qXz3Yz2",
                truncateLength: 6,
                cluster: .devnet
            )

            TransactionLink(
                signature: "5UfDuX7WXpDPqspwK5bvpFT7G4VL9oYnKJTHSJQdYJBq2W4sLfDe7rSNvx9ZL5LkM5vP9qXz3Yz2",
                truncateLength: 8,
                cluster: .devnet
            )

            TransactionLink(
                signature: "5UfDuX7WXpDPqspwK5bvpFT7G4VL9oYnKJTHSJQdYJBq2W4sLfDe7rSNvx9ZL5LkM5vP9qXz3Yz2",
                truncateLength: 12,
                cluster: .mainnet
            )
        }
        .padding()
    }
}
