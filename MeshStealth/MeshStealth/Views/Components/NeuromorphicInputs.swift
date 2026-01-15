import SwiftUI

// MARK: - Neuromorphic Amount Input

/// Inset text field for amount entry with max/confirm/cancel
struct NeuromorphicAmountInput: View {
    @Binding var amount: String
    let maxAmount: Double
    let palette: NeuromorphicPalette
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 16) {
            // Input field with max button
            HStack(spacing: 12) {
                // Inset text field
                HStack {
                    TextField("0.00", text: $amount)
                        .keyboardType(.decimalPad)
                        .font(.system(.title3, design: .monospaced))
                        .fontWeight(.semibold)
                        .foregroundColor(palette.textPrimary)
                        .multilineTextAlignment(.center)
                        .focused($isFocused)

                    Text("SOL")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(palette.textSecondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .neuromorphicInset(palette: palette, cornerRadius: 12)

                // Max button
                Button {
                    amount = String(format: "%.4f", maxAmount)
                } label: {
                    Text("MAX")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(palette.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(palette.accent.opacity(0.15))
                        )
                }
                .buttonStyle(.plain)
            }

            // Action buttons
            HStack(spacing: 12) {
                NeuromorphicTextButton(
                    title: "Cancel",
                    palette: palette,
                    isDestructive: true
                ) {
                    isFocused = false
                    onCancel()
                }

                NeuromorphicPrimaryButton(
                    title: "Confirm",
                    palette: palette
                ) {
                    isFocused = false
                    onConfirm()
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(palette.background.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(palette.darkShadow.opacity(0.1), lineWidth: 1)
                )
        )
        .onAppear {
            isFocused = true
        }
    }
}

// MARK: - Neuromorphic Unshield Confirm

/// Confirmation dialog for unshielding with privacy note
struct NeuromorphicUnshieldConfirm: View {
    let amount: Double
    let palette: NeuromorphicPalette
    let isLoading: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            // Amount display
            VStack(spacing: 4) {
                Text("Unshield Amount")
                    .font(.caption)
                    .foregroundColor(palette.textSecondary)

                Text(String(format: "%.4f SOL", amount))
                    .font(.title2)
                    .fontWeight(.bold)
                    .foregroundColor(palette.textPrimary)
            }

            // Privacy note
            HStack(spacing: 8) {
                Image(systemName: "shield.slash")
                    .font(.system(size: 14))
                    .foregroundColor(.orange)

                Text("Funds will be mixed before returning to main wallet")
                    .font(.caption)
                    .foregroundColor(palette.textSecondary)
                    .multilineTextAlignment(.leading)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.orange.opacity(0.1))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.orange.opacity(0.2), lineWidth: 1)
                    )
            )

            // Action buttons
            HStack(spacing: 12) {
                NeuromorphicTextButton(
                    title: "Cancel",
                    palette: palette,
                    isDestructive: true,
                    action: onCancel
                )

                NeuromorphicPrimaryButton(
                    title: isLoading ? "Unshielding..." : "Unshield",
                    palette: palette,
                    isLoading: isLoading,
                    action: onConfirm
                )
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(palette.background.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(palette.darkShadow.opacity(0.1), lineWidth: 1)
                )
        )
    }
}

// MARK: - Preview

#Preview("Neuromorphic Inputs") {
    ZStack {
        NeuromorphicPalette.pageBackground
            .ignoresSafeArea()

        VStack(spacing: 32) {
            // Amount input
            NeuromorphicAmountInput(
                amount: .constant("0.25"),
                maxAmount: 1.5,
                palette: .blue,
                onConfirm: {},
                onCancel: {}
            )

            // Unshield confirm
            NeuromorphicUnshieldConfirm(
                amount: 0.25,
                palette: .purple,
                isLoading: false,
                onConfirm: {},
                onCancel: {}
            )

            // Loading state
            NeuromorphicUnshieldConfirm(
                amount: 0.25,
                palette: .purple,
                isLoading: true,
                onConfirm: {},
                onCancel: {}
            )
        }
        .padding()
    }
}
