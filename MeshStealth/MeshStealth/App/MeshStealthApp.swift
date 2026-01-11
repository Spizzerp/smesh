import SwiftUI
import StealthCore

@main
struct MeshStealthApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .environmentObject(appState.walletViewModel)
                .environmentObject(appState.meshViewModel)
        }
    }
}

/// Central app state coordinator
@MainActor
class AppState: ObservableObject {
    let meshNetworkManager: MeshNetworkManager
    let walletViewModel: WalletViewModel
    let meshViewModel: MeshViewModel

    @Published var isInitialized = false
    @Published var initializationError: Error?

    init() {
        // Initialize the mesh network manager
        self.meshNetworkManager = MeshNetworkManager(cluster: .devnet)

        // Create view models
        self.walletViewModel = WalletViewModel(walletManager: meshNetworkManager.walletManager)
        self.meshViewModel = MeshViewModel(
            meshService: meshNetworkManager.meshService,
            walletManager: meshNetworkManager.walletManager
        )

        // Start initialization
        Task {
            await initialize()
        }
    }

    private func initialize() async {
        do {
            try await meshNetworkManager.initialize()
            meshNetworkManager.startMesh()
            isInitialized = true
        } catch {
            initializationError = error
        }
    }
}

/// Main content view with tab navigation
struct ContentView: View {
    @EnvironmentObject var appState: AppState
    @State private var selectedTab = 0

    var body: some View {
        Group {
            if appState.isInitialized {
                TabView(selection: $selectedTab) {
                    WalletView()
                        .tabItem {
                            Label("Wallet", systemImage: "wallet.pass")
                        }
                        .tag(0)

                    NearbyPeersView()
                        .tabItem {
                            Label("Nearby", systemImage: "antenna.radiowaves.left.and.right")
                        }
                        .tag(1)

                    PendingPaymentsView()
                        .tabItem {
                            Label("Pending", systemImage: "clock.arrow.circlepath")
                        }
                        .tag(2)

                    SettingsView()
                        .tabItem {
                            Label("Settings", systemImage: "gear")
                        }
                        .tag(3)
                }
            } else if let error = appState.initializationError {
                ErrorView(error: error)
            } else {
                LoadingView()
            }
        }
    }
}

struct LoadingView: View {
    var body: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
            Text("Initializing Wallet...")
                .font(.headline)
                .foregroundColor(.secondary)
        }
    }
}

struct ErrorView: View {
    let error: Error

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 60))
                .foregroundColor(.red)
            Text("Initialization Failed")
                .font(.headline)
            Text(error.localizedDescription)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
