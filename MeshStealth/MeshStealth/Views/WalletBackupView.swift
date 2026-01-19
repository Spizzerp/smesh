import SwiftUI
import StealthCore

struct WalletBackupView: View {
    @EnvironmentObject var walletViewModel: WalletViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var showPhrase = false
    @State private var copiedConfirmation = false
    @State private var mnemonic: [String]?
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            ZStack {
                TerminalPalette.background
                    .ignoresSafeArea()

                ScanlineOverlay()
                    .ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 20) {
                        // Warning header
                        TerminalWarningHeader()

                        if isLoading {
                            VStack(spacing: 12) {
                                TerminalSpinner(color: TerminalPalette.cyan)
                                Text("LOADING...")
                                    .font(TerminalTypography.body(12))
                                    .foregroundColor(TerminalPalette.textDim)
                            }
                            .padding(.vertical, 40)
                        } else if showPhrase, let phrase = mnemonic {
                            // Seed phrase grid
                            TerminalSeedPhraseGrid(words: phrase)

                            // Copy button
                            Button {
                                UIPasteboard.general.string = phrase.joined(separator: " ")
                                copiedConfirmation = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    copiedConfirmation = false
                                }
                            } label: {
                                HStack(spacing: 8) {
                                    Text(copiedConfirmation ? "[OK]" : "[>]")
                                    Text(copiedConfirmation ? "COPIED" : "COPY_TO_CLIPBOARD")
                                }
                                .font(TerminalTypography.header(14))
                                .foregroundColor(copiedConfirmation ? TerminalPalette.success : TerminalPalette.cyan)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                                .background(
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(TerminalPalette.surface)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 2)
                                                .stroke(copiedConfirmation ? TerminalPalette.success : TerminalAccent.public.dimColor, lineWidth: 1)
                                        )
                                )
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 16)

                            // Security reminder
                            TerminalSecurityReminder()
                        } else if mnemonic != nil {
                            // Reveal button
                            Button {
                                withAnimation { showPhrase = true }
                            } label: {
                                HStack(spacing: 8) {
                                    Text("[!]")
                                    Text("REVEAL_RECOVERY_PHRASE")
                                }
                                .font(TerminalTypography.header(14))
                                .foregroundColor(TerminalPalette.warning)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(TerminalPalette.warning.opacity(0.15))
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 2)
                                                .stroke(TerminalPalette.warning, lineWidth: 1)
                                        )
                                )
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 16)
                        } else {
                            // No mnemonic available
                            TerminalNoMnemonicView()
                        }

                        Spacer(minLength: 40)
                    }
                    .padding(.top, 20)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(TerminalPalette.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Text("[MAIN_ADDR_BACKUP]")
                        .font(TerminalTypography.header(12))
                        .foregroundColor(TerminalPalette.cyan)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        dismiss()
                    } label: {
                        Text("[CLOSE]")
                            .font(TerminalTypography.label())
                            .foregroundColor(TerminalPalette.textDim)
                    }
                }
            }
            .task {
                await loadMnemonic()
            }
        }
    }

    private func loadMnemonic() async {
        mnemonic = await walletViewModel.getMnemonic()
        isLoading = false
    }
}

// MARK: - Terminal Warning Header

struct TerminalWarningHeader: View {
    var body: some View {
        VStack(spacing: 16) {
            // ASCII art warning
            VStack(spacing: 2) {
                Text("┌─────────────────────┐")
                Text("│      [!] [!] [!]    │")
                Text("│       WARNING       │")
                Text("└─────────────────────┘")
            }
            .font(TerminalTypography.body(14))
            .foregroundColor(TerminalPalette.warning)
            .terminalGlow(TerminalPalette.warning, radius: 4)

            VStack(spacing: 8) {
                Text("BACKUP_RECOVERY_PHRASE")
                    .font(TerminalTypography.header())
                    .foregroundColor(TerminalPalette.textPrimary)

                Text("// Write these words down and store safely")
                    .font(TerminalTypography.label())
                    .foregroundColor(TerminalPalette.textMuted)

                Text("// Anyone with this phrase can access funds")
                    .font(TerminalTypography.label())
                    .foregroundColor(TerminalPalette.error)
            }
        }
        .padding(16)
    }
}

// MARK: - Terminal Seed Phrase Grid

struct TerminalSeedPhraseGrid: View {
    let words: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Title bar
            HStack(spacing: 8) {
                HStack(spacing: 4) {
                    Text("[-]")
                    Text("[+]")
                    Text("[x]")
                }
                .font(TerminalTypography.label(10))
                .foregroundColor(TerminalPalette.textMuted)

                Text("[SEED_PHRASE]")
                    .font(TerminalTypography.header(12))
                    .foregroundColor(TerminalPalette.warning)

                Spacer()

                Text("[\(words.count)_WORDS]")
                    .font(TerminalTypography.label())
                    .foregroundColor(TerminalPalette.textDim)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(TerminalPalette.surface)
            .overlay(
                Rectangle()
                    .fill(Color(hex: "553300"))
                    .frame(height: 1),
                alignment: .bottom
            )

            // Word grid
            LazyVGrid(columns: [
                GridItem(.flexible()),
                GridItem(.flexible()),
                GridItem(.flexible())
            ], spacing: 8) {
                ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                    HStack(spacing: 6) {
                        Text(String(format: "%02d", index + 1))
                            .font(TerminalTypography.label())
                            .foregroundColor(TerminalPalette.textMuted)
                            .frame(width: 20, alignment: .trailing)

                        Text(word.uppercased())
                            .font(TerminalTypography.body(11))
                            .foregroundColor(TerminalPalette.textPrimary)

                        Spacer()
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 2)
                            .fill(TerminalPalette.surfaceLight)
                            .overlay(
                                RoundedRectangle(cornerRadius: 2)
                                    .stroke(TerminalPalette.border, lineWidth: 1)
                            )
                    )
                }
            }
            .padding(12)
        }
        .background(
            RoundedRectangle(cornerRadius: 2)
                .fill(TerminalPalette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Color(hex: "553300"), lineWidth: 1)
                )
        )
        .padding(.horizontal, 16)
    }
}

// MARK: - Terminal Security Reminder

struct TerminalSecurityReminder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("> SECURITY_NOTES:")
                .font(TerminalTypography.body(12))
                .foregroundColor(TerminalPalette.warning)

            VStack(alignment: .leading, spacing: 6) {
                securityRow("01", "Never share your recovery phrase")
                securityRow("02", "Write on paper, avoid digital storage")
                securityRow("03", "If lost, funds cannot be recovered")
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 2)
                .fill(TerminalPalette.warning.opacity(0.1))
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Color(hex: "553300"), lineWidth: 1)
                )
        )
        .padding(.horizontal, 16)
    }

    private func securityRow(_ number: String, _ text: String) -> some View {
        HStack(spacing: 8) {
            Text("[\(number)]")
                .font(TerminalTypography.label())
                .foregroundColor(TerminalPalette.textMuted)
            Text(text)
                .font(TerminalTypography.label())
                .foregroundColor(TerminalPalette.textDim)
        }
    }
}

// MARK: - Terminal No Mnemonic View

struct TerminalNoMnemonicView: View {
    var body: some View {
        VStack(spacing: 20) {
            // ASCII art
            VStack(spacing: 2) {
                Text("┌─────────────────────┐")
                Text("│       [X]           │")
                Text("│    NO_PHRASE        │")
                Text("└─────────────────────┘")
            }
            .font(TerminalTypography.body(14))
            .foregroundColor(TerminalPalette.textMuted)

            VStack(spacing: 8) {
                Text("NO_RECOVERY_PHRASE")
                    .font(TerminalTypography.header())
                    .foregroundColor(TerminalPalette.textDim)

                Text("// Wallet imported from private key")
                    .font(TerminalTypography.label())
                    .foregroundColor(TerminalPalette.textMuted)

                Text("// Cannot backup via seed phrase")
                    .font(TerminalTypography.label())
                    .foregroundColor(TerminalPalette.textMuted)
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 2)
                .fill(TerminalPalette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(TerminalPalette.border, lineWidth: 1)
                )
        )
        .padding(.horizontal, 16)
    }
}

#Preview {
    ZStack {
        TerminalPalette.background
            .ignoresSafeArea()
        ScanlineOverlay()
            .ignoresSafeArea()
        WalletBackupView()
    }
}
