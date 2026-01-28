import Foundation
import Combine
import StealthCore

/// View model for managing chat session UI state
@MainActor
class ChatViewModel: ObservableObject {

    // MARK: - Published State

    @Published var messages: [ChatMessage] = []
    @Published var inputText: String = ""
    @Published var isActive: Bool = false
    @Published var isConnecting: Bool = false
    @Published var isPostQuantum: Bool = true
    @Published var error: Error?

    @Published var remotePeerName: String?
    @Published var sessionID: UUID?

    // MARK: - Private

    private var chatManager: ChatManager?
    private var session: ChatSession?
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Initialization

    init() {}

    /// Configure the view model with a chat manager and session
    func configure(chatManager: ChatManager, sessionID: UUID) async {
        self.chatManager = chatManager
        self.sessionID = sessionID

        guard let session = await chatManager.getSession(sessionID) else {
            error = ChatViewModelError.sessionNotFound
            return
        }

        self.session = session

        // Get initial info
        let info = await session.getInfo()
        self.remotePeerName = info.remotePeerName ?? "Unknown"
        self.isActive = info.state == .active
        self.isPostQuantum = info.isPostQuantum
        self.messages = await session.getMessages()

        // Subscribe to session updates
        subscribeToSession(session)
    }

    private func subscribeToSession(_ session: ChatSession) {
        // Subscribe to new messages
        session.messagePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                self?.handleNewMessage(message)
            }
            .store(in: &cancellables)

        // Subscribe to state changes
        session.statePublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.handleStateChange(state)
            }
            .store(in: &cancellables)
    }

    // MARK: - Actions

    /// Send a message
    func sendMessage() async {
        guard let chatManager = chatManager,
              let sessionID = sessionID,
              !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }

        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        inputText = ""

        do {
            let payload = try await chatManager.sendMessage(text, in: sessionID)

            // The message is already added to the local list via the session
            // Now we need to transmit it - this would be done by MeshViewModel
            NotificationCenter.default.post(
                name: .chatMessageToSend,
                object: nil,
                userInfo: ["payload": payload, "sessionID": sessionID]
            )
        } catch {
            self.error = error
            inputText = text  // Restore input on failure
        }
    }

    /// End the chat session
    func endChat() async {
        guard let chatManager = chatManager,
              let sessionID = sessionID else {
            return
        }

        if let endPayload = await chatManager.endSession(sessionID) {
            // Transmit end message
            NotificationCenter.default.post(
                name: .chatEndToSend,
                object: nil,
                userInfo: ["payload": endPayload, "sessionID": sessionID]
            )
        }

        isActive = false
    }

    // MARK: - Private Handlers

    private func handleNewMessage(_ message: ChatMessage) {
        // Check if message already exists (update) or is new
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index] = message
        } else {
            messages.append(message)
        }
    }

    private func handleStateChange(_ state: ChatSession.State) {
        isActive = (state == .active)
        isConnecting = (state == .pendingAccept || state == .pendingLocalAccept)

        if state == .ended {
            // Session ended - could dismiss the view
        }
    }

    // MARK: - Computed Properties

    var canSend: Bool {
        isActive && !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var statusText: String {
        if isConnecting {
            return "Connecting..."
        } else if isActive {
            return "Secure Chat"
        } else {
            return "Disconnected"
        }
    }
}

// MARK: - Errors

enum ChatViewModelError: Error, LocalizedError {
    case sessionNotFound
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .sessionNotFound: return "Chat session not found"
        case .notConfigured: return "Chat view model not configured"
        }
    }
}

// Note: Notification.Name extensions are defined in Extensions/Notification+Chat.swift
