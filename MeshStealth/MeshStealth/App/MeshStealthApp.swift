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
        Group {
            if appState.isInitialized {
                TabView(selection: $selectedTab) {
                    WalletView()
                        .tabItem {
                            Label("WALLET", systemImage: "square.fill")
                        }
                        .tag(0)

                    NearbyPeersView()
                        .tabItem {
                            Label("MESH", systemImage: "circle.grid.3x3")
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
                    // Spacer to add padding above tab bar
                    Color.clear.frame(height: 8)
                }
                .tint(TerminalPalette.cyan)
            } else if let error = appState.initializationError {
                ErrorView(error: error)
            } else {
                LoadingView()
            }
        }
    }
}

struct LoadingView: View {
    @State private var spinnerIndex = 0
    private let spinnerFrames = ["|", "/", "-", "\\"]

    var body: some View {
        ZStack {
            TerminalPalette.background
                .ignoresSafeArea()

            ScanlineOverlay()
                .ignoresSafeArea()

            VStack(spacing: 24) {
                // ASCII art logo placeholder
                Text("[MESH_STEALTH]")
                    .font(TerminalTypography.balance(24))
                    .foregroundColor(TerminalPalette.cyan)
                    .terminalGlow(TerminalPalette.cyan, radius: 4)

                HStack(spacing: 8) {
                    Text(spinnerFrames[spinnerIndex])
                        .font(TerminalTypography.body(16))
                        .foregroundColor(TerminalPalette.cyan)

                    Text("INITIALIZING WALLET")
                        .font(TerminalTypography.body(14))
                        .foregroundColor(TerminalPalette.textDim)

                    TerminalLoadingDots(color: TerminalPalette.textDim)
                }

                Text("// Connecting to Solana network")
                    .font(TerminalTypography.label())
                    .foregroundColor(TerminalPalette.textMuted)
            }
        }
        .onAppear {
            Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                spinnerIndex = (spinnerIndex + 1) % spinnerFrames.count
            }
        }
    }
}

struct ErrorView: View {
    let error: Error

    var body: some View {
        ZStack {
            TerminalPalette.background
                .ignoresSafeArea()

            ScanlineOverlay()
                .ignoresSafeArea()

            VStack(spacing: 24) {
                Text("[ERROR]")
                    .font(TerminalTypography.balance(24))
                    .foregroundColor(TerminalPalette.error)
                    .terminalGlow(TerminalPalette.error, radius: 4)

                VStack(spacing: 12) {
                    Text("INITIALIZATION FAILED")
                        .font(TerminalTypography.header())
                        .foregroundColor(TerminalPalette.error)

                    Text(error.localizedDescription)
                        .font(TerminalTypography.body(12))
                        .foregroundColor(TerminalPalette.textDim)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                // Error box
                VStack(alignment: .leading, spacing: 8) {
                    Text("> Stack trace:")
                        .font(TerminalTypography.label())
                        .foregroundColor(TerminalPalette.textMuted)
                    Text(String(describing: type(of: error)))
                        .font(TerminalTypography.label())
                        .foregroundColor(TerminalPalette.textDim)
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 2)
                        .fill(TerminalPalette.surface)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(Color(hex: "550000"), lineWidth: 1)  // Dark red border
                        )
                )
            }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppState())
}
