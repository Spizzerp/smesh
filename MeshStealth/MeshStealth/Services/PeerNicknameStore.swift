import Foundation
import Combine

/// Manages persistent storage of peer nicknames using UserDefaults.
/// Thread-safe observable store for peer-to-nickname mappings.
@MainActor
class PeerNicknameStore: ObservableObject {
    /// Published nicknames dictionary: [peerID: nickname]
    @Published private(set) var nicknames: [String: String] = [:]

    /// UserDefaults key for storing nicknames
    private let storageKey = "com.meshstealth.peerNicknames"

    /// Shared singleton instance
    static let shared = PeerNicknameStore()

    init() {
        loadNicknames()
    }

    // MARK: - Public API

    /// Set a nickname for a peer. Pass empty string to remove.
    /// - Parameters:
    ///   - nickname: The nickname to set (empty string removes it)
    ///   - peerID: The peer's unique identifier
    func setNickname(_ nickname: String, for peerID: String) {
        let trimmed = nickname.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            nicknames.removeValue(forKey: peerID)
        } else {
            nicknames[peerID] = trimmed
        }
        saveNicknames()
    }

    /// Get the nickname for a peer, if one exists.
    /// - Parameter peerID: The peer's unique identifier
    /// - Returns: The nickname, or nil if none set
    func getNickname(for peerID: String) -> String? {
        nicknames[peerID]
    }

    /// Remove the nickname for a peer.
    /// - Parameter peerID: The peer's unique identifier
    func removeNickname(for peerID: String) {
        nicknames.removeValue(forKey: peerID)
        saveNicknames()
    }

    /// Get display name for a peer: nickname if set, otherwise device name or fallback.
    /// - Parameters:
    ///   - peerID: The peer's unique identifier
    ///   - deviceName: The device's advertised name (may be nil)
    /// - Returns: The best available display name
    func displayName(for peerID: String, deviceName: String?) -> String {
        if let nickname = nicknames[peerID], !nickname.isEmpty {
            return nickname
        }
        return deviceName ?? "UNKNOWN_NODE"
    }

    // MARK: - Private

    private func loadNicknames() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
            nicknames = decoded
        }
    }

    private func saveNicknames() {
        if let encoded = try? JSONEncoder().encode(nicknames) {
            UserDefaults.standard.set(encoded, forKey: storageKey)
        }
    }
}
