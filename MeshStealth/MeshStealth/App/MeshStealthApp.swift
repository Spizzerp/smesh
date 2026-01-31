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
            walletManager: meshNetworkManager.walletManager,
            networkMonitor: meshNetworkManager.networkMonitor
        )

        // Wire up privacy routing service to all components (mesh, settlement, shield service, wallet manager)
        meshNetworkManager.setPrivacyRoutingService(walletViewModel.privacyRoutingService)

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

    init() {
        // Configure tab bar appearance for terminal style
        let appearance = UITabBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.backgroundColor = UIColor(TerminalPalette.background)

        // Top border line above tab bar
        appearance.shadowColor = UIColor(TerminalPalette.textMuted)


        // Normal state
        appearance.stackedLayoutAppearance.normal.iconColor = UIColor(TerminalPalette.textMuted)
        appearance.stackedLayoutAppearance.normal.titleTextAttributes = [
            .foregroundColor: UIColor(TerminalPalette.textMuted),
            .font: UIFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        ]

        // Selected state
        appearance.stackedLayoutAppearance.selected.iconColor = UIColor(TerminalPalette.cyan)
        appearance.stackedLayoutAppearance.selected.titleTextAttributes = [
            .foregroundColor: UIColor(TerminalPalette.cyan),
            .font: UIFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        ]

        UITabBar.appearance().standardAppearance = appearance
        UITabBar.appearance().scrollEdgeAppearance = appearance
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NearbyPeersView()
                .tabItem {
                    Label("MESH", systemImage: "circle.grid.3x3")
                }
                .tag(0)

            WalletView()
                .tabItem {
                    Label("WALLET", systemImage: "square.fill")
                }
                .tag(1)

            ActivityView()
                .tabItem {
                    Label("ACTIVITY", systemImage: "list.bullet")
                }
                .tag(2)

            SettingsView()
                .tabItem {
                    Label("CONFIG", systemImage: "slider.horizontal.3")
                }
                .tag(3)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Color.clear.frame(height: 8)
        }
        .tint(TerminalPalette.cyan)
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
