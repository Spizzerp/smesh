import SwiftUI
import UIKit

// MARK: - Network Badge

/// Badge showing network type (Devnet/Mainnet)
struct NetworkBadge: View {
    let isDevnet: Bool
    let palette: NeuromorphicPalette

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(isDevnet ? Color.orange : Color.green)
                .frame(width: 6, height: 6)

            Text(isDevnet ? "Devnet" : "Mainnet")
                .font(.caption2)
                .fontWeight(.semibold)
        }
        .foregroundColor(palette.textSecondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(palette.background.opacity(0.8))
                .shadow(
                    color: palette.darkShadow.opacity(0.2),
                    radius: 2,
                    x: 1,
                    y: 1
                )
        )
    }
}

// MARK: - Quantum Badge

/// Badge indicating post-quantum protection
struct QuantumBadge: View {
    let palette: NeuromorphicPalette

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "atom")
                .font(.system(size: 10, weight: .semibold))

            Text("Quantum-Proof")
                .font(.caption2)
                .fontWeight(.semibold)
        }
        .foregroundColor(palette.accent)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(palette.accent.opacity(0.15))
                .overlay(
                    Capsule()
                        .stroke(palette.accent.opacity(0.3), lineWidth: 1)
                )
        )
    }
}

// MARK: - Address Row

/// Truncated wallet address with copy button
struct AddressRow: View {
    let address: String
    let palette: NeuromorphicPalette
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Text(truncatedAddress)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(palette.textSecondary)

            Button {
                UIPasteboard.general.string = address
                withAnimation(.easeInOut(duration: 0.2)) {
                    copied = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        copied = false
                    }
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(copied ? .green : palette.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(palette.background.opacity(0.6))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(palette.darkShadow.opacity(0.15), lineWidth: 1)
                )
        )
    }

    private var truncatedAddress: String {
        guard address.count > 12 else { return address }
        let prefix = address.prefix(6)
        let suffix = address.suffix(4)
        return "\(prefix)...\(suffix)"
    }
}

// MARK: - Wallet Header Status

/// Combined header status for wallet screen (network + online status)
struct WalletHeaderStatus: View {
    let isDevnet: Bool
    let isOnline: Bool
    let peerCount: Int

    var body: some View {
        HStack(spacing: 8) {
            // Network badge (Devnet/Mainnet)
            HStack(spacing: 4) {
                Circle()
                    .fill(isDevnet ? Color.orange : Color.green)
                    .frame(width: 6, height: 6)
                Text(isDevnet ? "Devnet" : "Mainnet")
                    .font(.caption2)
                    .fontWeight(.semibold)
            }
            .foregroundColor(NeuromorphicPalette.blue.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(NeuromorphicPalette.main)
                    .shadow(
                        color: NeuromorphicPalette.blue.lightShadow.opacity(0.07),
                        radius: 4,
                        x: -2,
                        y: -2
                    )
                    .shadow(
                        color: NeuromorphicPalette.blue.darkShadow.opacity(0.5),
                        radius: 4,
                        x: 2,
                        y: 2
                    )
            )

            // Online/Offline status
            HStack(spacing: 4) {
                Circle()
                    .fill(isOnline ? Color.green : Color.red)
                    .frame(width: 6, height: 6)
                Text(isOnline ? "Online" : "Offline")
                    .font(.caption2)
                    .fontWeight(.semibold)
            }
            .foregroundColor(NeuromorphicPalette.blue.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(NeuromorphicPalette.main)
                    .shadow(
                        color: NeuromorphicPalette.blue.lightShadow.opacity(0.07),
                        radius: 4,
                        x: -2,
                        y: -2
                    )
                    .shadow(
                        color: NeuromorphicPalette.blue.darkShadow.opacity(0.5),
                        radius: 4,
                        x: 2,
                        y: 2
                    )
            )

            // Peer count (only shown if there are peers)
            if peerCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 9))
                    Text("\(peerCount)")
                        .font(.caption2)
                        .fontWeight(.semibold)
                }
                .foregroundColor(NeuromorphicPalette.blue.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(NeuromorphicPalette.main)
                        .shadow(
                            color: NeuromorphicPalette.blue.lightShadow.opacity(0.07),
                            radius: 4,
                            x: -2,
                            y: -2
                        )
                        .shadow(
                            color: NeuromorphicPalette.blue.darkShadow.opacity(0.5),
                            radius: 4,
                            x: 2,
                            y: 2
                        )
                )
            }
        }
    }
}

// MARK: - Status Indicator

/// Small status indicator (online/offline, peer count)
struct StatusIndicator: View {
    let isOnline: Bool
    let peerCount: Int

    // Use the unified neumorphic background
    private var pillBackground: Color { NeuromorphicPalette.main }
    private let textColor = Color(hex: "8A8A9A")

    var body: some View {
        HStack(spacing: 12) {
            // Online status
            HStack(spacing: 4) {
                Circle()
                    .fill(isOnline ? Color.green : Color.red)
                    .frame(width: 8, height: 8)
                Text(isOnline ? "Online" : "Offline")
                    .font(.caption2)
                    .fontWeight(.medium)
                    .foregroundColor(textColor)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(pillBackground)
            )

            // Peer count
            if peerCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 10))
                    Text("\(peerCount) nearby")
                        .font(.caption2)
                        .fontWeight(.medium)
                }
                .foregroundColor(textColor)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule()
                        .fill(pillBackground)
                )
            }

            // Post-quantum indicator
            HStack(spacing: 4) {
                Image(systemName: "atom")
                    .font(.system(size: 10))
                Text("PQ")
                    .font(.caption2)
                    .fontWeight(.bold)
            }
            .foregroundColor(NeuromorphicPalette.purple.accent)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule()
                    .fill(NeuromorphicPalette.purple.accent.opacity(0.2))
            )
        }
    }
}

// MARK: - Preview

#Preview("Wallet Badges") {
    ZStack {
        NeuromorphicPalette.pageBackground
            .ignoresSafeArea()

        VStack(spacing: 24) {
            // Blue palette badges
            VStack(spacing: 12) {
                Text("Blue Palette")
                    .font(.caption)
                    .foregroundColor(.secondary)

                NetworkBadge(isDevnet: true, palette: .blue)

                AddressRow(
                    address: "7vJ9JU1bJJE96FWSJKvHsmmFADCg4gpZQff4P3bkLKi",
                    palette: .blue
                )
            }

            Divider()

            // Purple palette badges
            VStack(spacing: 12) {
                Text("Purple Palette")
                    .font(.caption)
                    .foregroundColor(.secondary)

                QuantumBadge(palette: .purple)

                AddressRow(
                    address: "stealth:4xK8Lm2nP9qR5wT3vY7zB1cD4eF6gH8jK0mN",
                    palette: .purple
                )
            }

            Divider()

            // Status indicators
            VStack(spacing: 12) {
                Text("Status Indicators")
                    .font(.caption)
                    .foregroundColor(.secondary)

                StatusIndicator(isOnline: true, peerCount: 3)
                StatusIndicator(isOnline: false, peerCount: 0)
            }
        }
        .padding()
    }
}
