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
            ScrollView {
                VStack(spacing: 24) {
                    // Warning header
                    WarningHeader()

                    if isLoading {
                        ProgressView()
                            .padding(.vertical, 40)
                    } else if showPhrase, let phrase = mnemonic {
                        // Seed phrase grid
                        SeedPhraseGrid(words: phrase)

                        // Copy button
                        Button {
                            UIPasteboard.general.string = phrase.joined(separator: " ")
                            copiedConfirmation = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                copiedConfirmation = false
                            }
                        } label: {
                            Label(
                                copiedConfirmation ? "Copied!" : "Copy to Clipboard",
                                systemImage: copiedConfirmation ? "checkmark" : "doc.on.doc"
                            )
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .padding(.horizontal)

                        // Security reminder
                        SecurityReminder()
                    } else if mnemonic != nil {
                        // Reveal button
                        Button {
                            withAnimation { showPhrase = true }
                        } label: {
                            Label("Reveal Recovery Phrase", systemImage: "eye")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.horizontal)
                    } else {
                        // No mnemonic available
                        NoMnemonicView()
                    }

                    Spacer(minLength: 40)
                }
                .padding(.vertical)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Backup Wallet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
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

// MARK: - Components

struct WarningHeader: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(.orange)

            Text("Backup Your Recovery Phrase")
                .font(.title2.bold())

            Text("Write these words down and store them safely. Anyone with this phrase can access your funds.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
    }
}

struct SeedPhraseGrid: View {
    let words: [String]

    var body: some View {
        LazyVGrid(columns: [
            GridItem(.flexible()),
            GridItem(.flexible()),
            GridItem(.flexible())
        ], spacing: 12) {
            ForEach(Array(words.enumerated()), id: \.offset) { index, word in
                HStack {
                    Text("\(index + 1).")
                        .foregroundColor(.secondary)
                        .font(.caption)
                        .frame(width: 20, alignment: .trailing)
                    Text(word)
                        .fontWeight(.medium)
                        .font(.subheadline)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 10)
                .background(Color(.systemBackground))
                .cornerRadius(8)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemBackground))
                .shadow(color: .black.opacity(0.05), radius: 5, y: 2)
        )
        .padding(.horizontal)
    }
}

struct SecurityReminder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "lock.shield")
                    .foregroundColor(.orange)
                    .frame(width: 24)
                Text("Never share your recovery phrase")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            HStack(spacing: 12) {
                Image(systemName: "doc.text")
                    .foregroundColor(.orange)
                    .frame(width: 24)
                Text("Write it on paper, don't store digitally")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundColor(.orange)
                    .frame(width: 24)
                Text("If lost, your funds cannot be recovered")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.orange.opacity(0.1))
        )
        .padding(.horizontal)
    }
}

struct NoMnemonicView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "key.slash")
                .font(.system(size: 48))
                .foregroundColor(.secondary)

            Text("No Recovery Phrase Available")
                .font(.headline)

            Text("This wallet was imported from a private key without a recovery phrase. You cannot back it up using a seed phrase.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(.systemGray6))
        )
        .padding(.horizontal)
    }
}

#Preview {
    WalletBackupView()
}
