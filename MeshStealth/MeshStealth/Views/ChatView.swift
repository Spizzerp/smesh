import SwiftUI
import StealthCore

/// Main chat conversation view with terminal styling
struct ChatView: View {
    @EnvironmentObject var appState: AppState
    @StateObject private var viewModel = ChatViewModel()
    @Environment(\.dismiss) private var dismiss

    let sessionID: UUID
    let chatManager: ChatManager

    @FocusState private var isInputFocused: Bool

    var body: some View {
        NavigationStack {
            ZStack {
                TerminalPalette.background
                    .ignoresSafeArea()

                ScanlineOverlay()
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    // Messages area
                    messagesArea

                    // Divider
                    Rectangle()
                        .fill(TerminalPalette.border)
                        .frame(height: 1)

                    // Input area
                    inputArea
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(TerminalPalette.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar { toolbarContent }
        }
        .task {
            await viewModel.configure(chatManager: chatManager, sessionID: sessionID)
        }
    }

    // MARK: - Messages Area

    @ViewBuilder
    private var messagesArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if viewModel.messages.isEmpty {
                    TerminalChatEmptyState(isConnecting: viewModel.isConnecting)
                        .frame(minHeight: 300)
                } else {
                    LazyVStack(spacing: 12) {
                        ForEach(viewModel.messages) { message in
                            TerminalChatBubble(message: message)
                                .id(message.id)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                }
            }
            .onChange(of: viewModel.messages.count) { _, _ in
                // Scroll to newest message
                if let lastMessage = viewModel.messages.last {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    // MARK: - Input Area

    @ViewBuilder
    private var inputArea: some View {
        HStack(spacing: 12) {
            // Input field
            HStack(spacing: 8) {
                Text(">")
                    .font(TerminalTypography.body())
                    .foregroundColor(TerminalPalette.purple)

                TextField("", text: $viewModel.inputText, prompt: Text("message...").foregroundColor(TerminalPalette.textMuted))
                    .font(TerminalTypography.body(14))
                    .foregroundColor(TerminalPalette.textPrimary)
                    .focused($isInputFocused)
                    .submitLabel(.send)
                    .onSubmit {
                        if viewModel.canSend {
                            Task {
                                await viewModel.sendMessage()
                            }
                        }
                    }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 2)
                    .fill(TerminalPalette.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(TerminalPalette.border, lineWidth: 1)
                    )
            )

            // Send button
            Button {
                Task {
                    await viewModel.sendMessage()
                }
            } label: {
                Text("[>>]")
                    .font(TerminalTypography.command())
                    .foregroundColor(viewModel.canSend ? TerminalPalette.purple : TerminalPalette.textMuted)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 2)
                            .fill(TerminalPalette.surface)
                            .overlay(
                                RoundedRectangle(cornerRadius: 2)
                                    .stroke(viewModel.canSend ? TerminalPalette.purple.opacity(0.5) : TerminalPalette.border, lineWidth: 1)
                            )
                    )
            }
            .buttonStyle(.plain)
            .disabled(!viewModel.canSend)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(TerminalPalette.surface.opacity(0.5))
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            HStack(spacing: 6) {
                Text("[SECURE_CHAT]")
                    .font(TerminalTypography.header(12))
                    .foregroundColor(TerminalPalette.purple)
            }
        }

        ToolbarItem(placement: .principal) {
            VStack(spacing: 2) {
                Text(viewModel.remotePeerName?.uppercased() ?? "UNKNOWN")
                    .font(TerminalTypography.body(12))
                    .foregroundColor(TerminalPalette.textPrimary)

                if viewModel.isPostQuantum {
                    Text("[PQ:ACTIVE]")
                        .font(TerminalTypography.label())
                        .foregroundColor(TerminalPalette.purple)
                }
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button {
                Task {
                    await viewModel.endChat()
                    dismiss()
                }
            } label: {
                Text("[X]")
                    .font(TerminalTypography.label())
                    .foregroundColor(TerminalPalette.error)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Chat Navigation Destination

extension View {
    /// Navigate to chat view
    func chatDestination(chatManager: ChatManager?) -> some View {
        self.navigationDestination(for: UUID.self) { sessionID in
            if let chatManager = chatManager {
                ChatView(sessionID: sessionID, chatManager: chatManager)
            } else {
                Text("Chat not available")
                    .foregroundColor(TerminalPalette.error)
            }
        }
    }
}

// MARK: - Preview

#Preview {
    let chatManager = ChatManager(localPeerID: "preview-peer")

    return NavigationStack {
        ZStack {
            TerminalPalette.background
                .ignoresSafeArea()

            ChatView(sessionID: UUID(), chatManager: chatManager)
        }
    }
}
