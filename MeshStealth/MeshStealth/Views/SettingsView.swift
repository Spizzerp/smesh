import SwiftUI
import StealthCore

struct SettingsView: View {
    @EnvironmentObject var walletViewModel: WalletViewModel
    @EnvironmentObject var meshViewModel: MeshViewModel

    @State private var showingResetConfirmation = false
    @State private var showingClearActivityConfirmation = false
    @State private var showingMetaAddress = false
    @State private var showingBackupWallet = false

    var body: some View {
        NavigationStack {
            List {
                // Wallet Section
                Section {
                    // Meta-address display
                    Button {
                        showingMetaAddress = true
                    } label: {
                        HStack {
                            Label("Stealth Address", systemImage: "eye.slash")
                            Spacer()
                            Text(truncatedAddress)
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .foregroundColor(.primary)

                    // Security info
                    HStack {
                        Label("Security", systemImage: "lock.shield")
                        Spacer()
                        if walletViewModel.hasPostQuantum {
                            Text("Post-Quantum")
                                .font(.caption)
                                .foregroundColor(.purple)
                        } else {
                            Text("Classical")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    // Backup wallet
                    Button {
                        showingBackupWallet = true
                    } label: {
                        HStack {
                            Label("Backup Wallet", systemImage: "key.horizontal")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .foregroundColor(.primary)
                } header: {
                    Text("Wallet")
                }

                // Network Section
                Section {
                    HStack {
                        Label("Cluster", systemImage: "globe")
                        Spacer()
                        Text("Devnet")
                            .foregroundColor(.secondary)
                    }

                    HStack {
                        Label("Status", systemImage: meshViewModel.isOnline ? "wifi" : "wifi.slash")
                        Spacer()
                        Text(meshViewModel.isOnline ? "Online" : "Offline")
                            .foregroundColor(meshViewModel.isOnline ? .green : .orange)
                    }
                } header: {
                    Text("Network")
                }

                // Mesh Section
                Section {
                    HStack {
                        Label("Mesh Status", systemImage: "antenna.radiowaves.left.and.right")
                        Spacer()
                        Text(meshViewModel.isActive ? "Active" : "Inactive")
                            .foregroundColor(meshViewModel.isActive ? .green : .secondary)
                    }

                    HStack {
                        Label("Nearby Peers", systemImage: "person.2")
                        Spacer()
                        Text("\(meshViewModel.peerCount)")
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("Mesh Network")
                }

                // About Section
                Section {
                    HStack {
                        Label("Version", systemImage: "info.circle")
                        Spacer()
                        Text("1.0.0")
                            .foregroundColor(.secondary)
                    }

                    Link(destination: URL(string: "https://github.com")!) {
                        HStack {
                            Label("GitHub", systemImage: "link")
                            Spacer()
                            Image(systemName: "arrow.up.right")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    .foregroundColor(.primary)
                } header: {
                    Text("About")
                }

                // Danger Zone
                Section {
                    Button(role: .destructive) {
                        showingClearActivityConfirmation = true
                    } label: {
                        Label("Clear Activity History", systemImage: "clock.arrow.circlepath")
                    }

                    Button(role: .destructive) {
                        showingResetConfirmation = true
                    } label: {
                        Label("Reset Wallet", systemImage: "trash")
                    }
                } header: {
                    Text("Danger Zone")
                } footer: {
                    Text("Clear Activity removes transaction history but keeps your wallet. Reset Wallet deletes everything including private keys.")
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showingMetaAddress) {
                MetaAddressSheet(
                    metaAddress: walletViewModel.displayMetaAddress ?? "",
                    isHybrid: walletViewModel.hasPostQuantum
                )
            }
            .sheet(isPresented: $showingBackupWallet) {
                WalletBackupView()
            }
            .confirmationDialog(
                "Clear Activity History",
                isPresented: $showingClearActivityConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear History", role: .destructive) {
                    walletViewModel.clearActivityHistory()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will remove all transaction history. Your wallet and pending payments will not be affected.")
            }
            .confirmationDialog(
                "Reset Wallet",
                isPresented: $showingResetConfirmation,
                titleVisibility: .visible
            ) {
                Button("Reset", role: .destructive) {
                    try? walletViewModel.resetWallet()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This action cannot be undone. All your wallet data will be permanently deleted.")
            }
        }
    }

    private var truncatedAddress: String {
        guard let addr = walletViewModel.displayMetaAddress else { return "Not set" }
        return "\(addr.prefix(6))...\(addr.suffix(4))"
    }
}

struct MetaAddressSheet: View {
    @Environment(\.dismiss) private var dismiss

    let metaAddress: String
    let isHybrid: Bool

    @State private var copied = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                // Header
                VStack(spacing: 8) {
                    Image(systemName: isHybrid ? "lock.shield.fill" : "eye.slash.fill")
                        .font(.system(size: 50))
                        .foregroundColor(isHybrid ? .purple : .blue)

                    Text("Your Stealth Address")
                        .font(.title2)
                        .fontWeight(.bold)

                    Text("For private mesh payments")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    if isHybrid {
                        Label("Post-Quantum Secure", systemImage: "checkmark.shield")
                            .font(.caption)
                            .foregroundColor(.purple)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                            .background(Color.purple.opacity(0.15))
                            .cornerRadius(8)
                    }
                }
                .padding(.top)

                // Important distinction
                VStack(spacing: 8) {
                    HStack {
                        Image(systemName: "info.circle.fill")
                            .foregroundColor(.blue)
                        Text("This is different from your Main Wallet address")
                            .font(.subheadline.weight(.medium))
                    }

                    Text("Share this stealth address with nearby peers to receive private payments via Bluetooth mesh. Each payment creates a unique one-time address that only you can detect.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                .background(Color.blue.opacity(0.1))
                .cornerRadius(12)
                .padding(.horizontal)

                // Address display
                VStack(spacing: 12) {
                    Text(metaAddress)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color(.systemGray6))
                        )
                        .padding(.horizontal)

                    Button {
                        UIPasteboard.general.string = metaAddress
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            copied = false
                        }
                    } label: {
                        Label(copied ? "Copied!" : "Copy Stealth Address", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.purple)
                    .padding(.horizontal)
                }

                // Info
                VStack(alignment: .leading, spacing: 8) {
                    InfoRow(
                        icon: "antenna.radiowaves.left.and.right",
                        text: "Share with nearby peers via Bluetooth mesh"
                    )
                    InfoRow(
                        icon: "eye.slash",
                        text: "Payments are unlinkable - each uses a unique address"
                    )
                    InfoRow(
                        icon: "wallet.pass",
                        text: "Different from Main Wallet (funding address)"
                    )
                    if isHybrid {
                        InfoRow(
                            icon: "lock.shield",
                            text: "Protected against quantum computer attacks"
                        )
                    }
                }
                .padding()
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(.systemGray6))
                )
                .padding(.horizontal)

                Spacer()
            }
            .navigationTitle("Stealth Address")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct InfoRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundColor(.secondary)
                .frame(width: 20)
            Text(text)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

#Preview {
    SettingsView()
}
