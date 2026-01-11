import SwiftUI
import StealthCore

struct SettingsView: View {
    @EnvironmentObject var walletViewModel: WalletViewModel
    @EnvironmentObject var meshViewModel: MeshViewModel

    @State private var showingResetConfirmation = false
    @State private var showingMetaAddress = false

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
                            Label("My Address", systemImage: "qrcode")
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
                        showingResetConfirmation = true
                    } label: {
                        Label("Reset Wallet", systemImage: "trash")
                    }
                } header: {
                    Text("Danger Zone")
                } footer: {
                    Text("This will delete all wallet data including your private keys. Make sure you have a backup!")
                }
            }
            .navigationTitle("Settings")
            .sheet(isPresented: $showingMetaAddress) {
                MetaAddressSheet(
                    metaAddress: walletViewModel.displayMetaAddress ?? "",
                    isHybrid: walletViewModel.hasPostQuantum
                )
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
                    Image(systemName: isHybrid ? "lock.shield.fill" : "key.fill")
                        .font(.system(size: 50))
                        .foregroundColor(isHybrid ? .purple : .blue)

                    Text("Your Payment Address")
                        .font(.title2)
                        .fontWeight(.bold)

                    if isHybrid {
                        Label("Post-Quantum Secure", systemImage: "checkmark.shield")
                            .font(.caption)
                            .foregroundColor(.purple)
                    }
                }
                .padding(.top)

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
                        Label(copied ? "Copied!" : "Copy Address", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.horizontal)
                }

                // Info
                VStack(alignment: .leading, spacing: 8) {
                    InfoRow(
                        icon: "antenna.radiowaves.left.and.right",
                        text: "Share this address with nearby peers"
                    )
                    InfoRow(
                        icon: "eye.slash",
                        text: "Each payment creates a unique stealth address"
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
            .navigationTitle("Address")
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
