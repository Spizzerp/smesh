import SwiftUI

// MARK: - Terminal Amount Input

/// Terminal-style amount input: > 0.0000 SOL with blinking cursor
struct TerminalAmountInput: View {
    @Binding var amount: String
    let maxAmount: Double
    let accent: TerminalAccent
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @FocusState private var isFocused: Bool
    @State private var cursorVisible = true

    var body: some View {
        VStack(spacing: 16) {
            // Input row
            HStack(spacing: 8) {
                Text(">")
                    .font(TerminalTypography.body())
                    .foregroundColor(accent.color)

                // Amount field
                HStack(spacing: 4) {
                    TextField("0.0000", text: $amount)
                        .keyboardType(.decimalPad)
                        .font(TerminalTypography.balance(24))
                        .foregroundColor(TerminalPalette.textPrimary)
                        .multilineTextAlignment(.trailing)
                        .focused($isFocused)
                        .frame(minWidth: 100)

                    // Blinking cursor when focused
                    if isFocused {
                        Text("|")
                            .font(TerminalTypography.balance(24))
                            .foregroundColor(accent.color)
                            .opacity(cursorVisible ? 1 : 0)
                    }

                    Text("SOL")
                        .font(TerminalTypography.label())
                        .foregroundColor(TerminalPalette.textDim)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 2)
                        .fill(TerminalPalette.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(accent.dimColor, lineWidth: 1)
                        )
                )

                // MAX button
                Button {
                    amount = String(format: "%.4f", maxAmount)
                } label: {
                    Text("[MAX]")
                        .font(TerminalTypography.label())
                        .foregroundColor(accent.color)
                }
                .buttonStyle(.plain)
            }

            // Action buttons
            HStack(spacing: 12) {
                TerminalTextButton(
                    title: "CANCEL",
                    accent: accent,
                    isDestructive: true
                ) {
                    isFocused = false
                    onCancel()
                }

                TerminalPrimaryButton(
                    title: "CONFIRM",
                    accent: accent
                ) {
                    isFocused = false
                    onConfirm()
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 2)
                .fill(TerminalPalette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(TerminalPalette.border, lineWidth: 1)
                )
        )
        .onAppear {
            isFocused = true
            startCursorBlink()
        }
    }

    private func startCursorBlink() {
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            cursorVisible.toggle()
        }
    }
}

// MARK: - Terminal Unshield Confirm

/// Confirmation dialog for unshielding with terminal styling
struct TerminalUnshieldConfirm: View {
    let amount: Double
    let accent: TerminalAccent
    let isLoading: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            // Amount display
            VStack(spacing: 4) {
                Text("// UNSHIELD AMOUNT")
                    .font(TerminalTypography.label())
                    .foregroundColor(TerminalPalette.textMuted)

                Text(String(format: "%.4f SOL", amount))
                    .font(TerminalTypography.balance(24))
                    .foregroundColor(TerminalPalette.textPrimary)
            }

            // Warning box
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("[!]")
                        .foregroundColor(TerminalPalette.warning)

                    Text("WARNING")
                        .foregroundColor(TerminalPalette.warning)
                }
                .font(TerminalTypography.label())

                Text("Funds will be mixed before returning to main wallet")
                    .font(TerminalTypography.body(12))
                    .foregroundColor(TerminalPalette.textDim)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(hex: "1A1200"))  // Dark warning background
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(Color(hex: "664400"), lineWidth: 1)  // Dark warning border
                    )
            )

            // Action buttons
            HStack(spacing: 12) {
                TerminalTextButton(
                    title: "CANCEL",
                    accent: accent,
                    isDestructive: true,
                    action: onCancel
                )

                TerminalPrimaryButton(
                    title: isLoading ? "PROCESSING" : "UNSHIELD",
                    accent: accent,
                    isLoading: isLoading,
                    action: onConfirm
                )
            }
        }
        .padding(16)
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

// MARK: - Preview

#Preview("Terminal Inputs") {
    ZStack {
        TerminalPalette.background
            .ignoresSafeArea()

        VStack(spacing: 32) {
            // Amount input
            VStack(spacing: 12) {
                Text("// Amount Input")
                    .font(TerminalTypography.label())
                    .foregroundColor(TerminalPalette.textMuted)

                TerminalAmountInput(
                    amount: .constant("0.2500"),
                    maxAmount: 1.5,
                    accent: .public,
                    onConfirm: {},
                    onCancel: {}
                )
            }

            // Unshield confirm
            VStack(spacing: 12) {
                Text("// Unshield Confirm")
                    .font(TerminalTypography.label())
                    .foregroundColor(TerminalPalette.textMuted)

                TerminalUnshieldConfirm(
                    amount: 0.2500,
                    accent: .stealth,
                    isLoading: false,
                    onConfirm: {},
                    onCancel: {}
                )
            }

            // Loading state
            VStack(spacing: 12) {
                Text("// Loading State")
                    .font(TerminalTypography.label())
                    .foregroundColor(TerminalPalette.textMuted)

                TerminalUnshieldConfirm(
                    amount: 0.2500,
                    accent: .stealth,
                    isLoading: true,
                    onConfirm: {},
                    onCancel: {}
                )
            }
        }
        .padding()
    }
}
