import Foundation

// MARK: - Chat Notifications

extension Notification.Name {
    /// Notification sent when a chat message should be transmitted
    static let chatMessageToSend = Notification.Name("chatMessageToSend")

    /// Notification sent when a chat session should end
    static let chatEndToSend = Notification.Name("chatEndToSend")
}
