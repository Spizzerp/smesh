import Foundation
import Security

/// Manages secure storage of stealth keypairs in the iOS Keychain.
///
/// Private keys are stored with:
/// - `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` - only accessible when device is unlocked
/// - Non-migratable - keys don't transfer to new devices via backup
public final class KeychainService: @unchecked Sendable {

    /// Shared instance with default service identifier
    public static let shared = KeychainService()

    /// Keychain service identifier
    private let service: String

    /// Access group for shared keychain (nil for app-only)
    private let accessGroup: String?

    /// Keychain account keys
    private enum Account: String {
        case spendingScalar = "stealth.spending.scalar"
        case viewingPrivateKey = "stealth.viewing.private"
        case mlkemPrivateKey = "stealth.mlkem.private"  // ~2400 bytes for hybrid mode
        case metaAddressPublic = "stealth.meta.public"
        case hybridMetaAddressPublic = "stealth.hybridmeta.public"  // 1248 bytes
        case mainWalletPrivateKey = "wallet.main.private"  // 64 bytes (ed25519 secret key)
        case mainWalletMnemonic = "wallet.main.mnemonic"  // BIP-39 mnemonic phrase
    }

    /// Initialize with custom service identifier
    /// - Parameters:
    ///   - service: Keychain service identifier
    ///   - accessGroup: Optional access group for keychain sharing between apps
    public init(service: String = "com.meshstealth.keychain", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    // MARK: - StealthKeyPair Storage

    /// Store a stealth keypair securely in the Keychain
    /// - Parameter keyPair: The keypair to store
    /// - Throws: StealthError.keychainError if storage fails
    public func storeKeyPair(_ keyPair: StealthKeyPair) throws {
        // Store spending scalar (most sensitive)
        try storeData(
            keyPair.rawSpendingScalar,
            account: .spendingScalar
        )

        // Store viewing private key
        try storeData(
            keyPair.rawViewingPrivateKey,
            account: .viewingPrivateKey
        )

        // Store MLKEM private key if present (hybrid mode)
        if let mlkemPriv = keyPair.rawMLKEMPrivateKey {
            try storeData(
                mlkemPriv,
                account: .mlkemPrivateKey
            )
        } else {
            // Remove any existing MLKEM key if switching from hybrid to classical
            try? deleteData(account: .mlkemPrivateKey)
        }

        // Store public meta-address (for quick access without unlocking private keys)
        try storeData(
            keyPair.metaAddress,
            account: .metaAddressPublic,
            accessible: kSecAttrAccessibleAfterFirstUnlock
        )

        // Store hybrid meta-address if applicable
        if keyPair.hasPostQuantum {
            try storeData(
                keyPair.hybridMetaAddress,
                account: .hybridMetaAddressPublic,
                accessible: kSecAttrAccessibleAfterFirstUnlock
            )
        } else {
            try? deleteData(account: .hybridMetaAddressPublic)
        }
    }

    /// Load the stored stealth keypair
    /// - Returns: The keypair or nil if not found
    /// - Throws: StealthError if keypair exists but can't be restored
    public func loadKeyPair() throws -> StealthKeyPair? {
        guard let spendingScalar = try loadData(account: .spendingScalar),
              let viewingPrivateKey = try loadData(account: .viewingPrivateKey) else {
            return nil
        }

        // Try to load MLKEM key (may not exist for classical-only keypairs)
        let mlkemPrivateKey = try loadData(account: .mlkemPrivateKey)

        return try StealthKeyPair.restore(
            spendingScalar: spendingScalar,
            viewingPrivateKey: viewingPrivateKey,
            mlkemPrivateKey: mlkemPrivateKey
        )
    }

    /// Load only the public meta-address (classical 64-byte format)
    /// Doesn't require unlocking private keys - useful for displaying address
    /// - Returns: The meta-address or nil if not stored
    public func loadMetaAddress() throws -> Data? {
        return try loadData(account: .metaAddressPublic)
    }

    /// Load the hybrid meta-address (1248 bytes with MLKEM public key)
    /// Falls back to classical meta-address if hybrid not stored
    /// - Returns: The hybrid meta-address, classical meta-address, or nil
    public func loadHybridMetaAddress() throws -> Data? {
        if let hybrid = try loadData(account: .hybridMetaAddressPublic) {
            return hybrid
        }
        return try loadData(account: .metaAddressPublic)
    }

    /// Load meta-address as base58 string
    public func loadMetaAddressString() throws -> String? {
        guard let data = try loadMetaAddress() else { return nil }
        return data.base58EncodedString
    }

    /// Load hybrid meta-address as base58 string
    /// Falls back to classical meta-address if hybrid not stored
    public func loadHybridMetaAddressString() throws -> String? {
        guard let data = try loadHybridMetaAddress() else { return nil }
        return data.base58EncodedString
    }

    /// Delete all stored keypair data
    /// - Throws: StealthError.keychainError if deletion fails
    public func deleteKeyPair() throws {
        try deleteData(account: .spendingScalar)
        try deleteData(account: .viewingPrivateKey)
        try deleteData(account: .mlkemPrivateKey)
        try deleteData(account: .metaAddressPublic)
        try deleteData(account: .hybridMetaAddressPublic)
    }

    /// Check if a keypair exists in the Keychain
    /// - Returns: true if a keypair is stored
    public func hasKeyPair() -> Bool {
        (try? loadData(account: .spendingScalar)) != nil
    }

    // MARK: - Main Wallet Storage

    /// Store the main wallet private key
    /// - Parameter privateKey: 32-byte ed25519 private key
    /// - Throws: StealthError.keychainError if storage fails
    public func storeMainWalletKey(_ privateKey: Data) throws {
        try storeData(
            privateKey,
            account: .mainWalletPrivateKey
        )
    }

    /// Load the main wallet private key
    /// - Returns: The private key or nil if not found
    /// - Throws: StealthError if keychain access fails
    public func loadMainWalletKey() throws -> Data? {
        return try loadData(account: .mainWalletPrivateKey)
    }

    /// Delete the main wallet key
    /// - Throws: StealthError.keychainError if deletion fails
    public func deleteMainWalletKey() throws {
        try deleteData(account: .mainWalletPrivateKey)
    }

    /// Check if a main wallet exists in the Keychain
    /// - Returns: true if a main wallet is stored
    public func hasMainWallet() -> Bool {
        (try? loadData(account: .mainWalletPrivateKey)) != nil
    }

    // MARK: - Mnemonic Storage

    /// Store the main wallet mnemonic phrase
    /// - Parameter phrase: Array of BIP-39 words
    /// - Throws: StealthError.keychainError if storage fails
    public func storeMnemonic(_ phrase: [String]) throws {
        let data = phrase.joined(separator: " ").data(using: .utf8)!
        try storeData(data, account: .mainWalletMnemonic)
    }

    /// Load the main wallet mnemonic phrase
    /// - Returns: Array of mnemonic words or nil if not stored
    /// - Throws: StealthError if keychain access fails
    public func loadMnemonic() throws -> [String]? {
        guard let data = try loadData(account: .mainWalletMnemonic),
              let phrase = String(data: data, encoding: .utf8) else {
            return nil
        }
        return phrase.split(separator: " ").map(String.init)
    }

    /// Delete the mnemonic phrase
    /// - Throws: StealthError.keychainError if deletion fails
    public func deleteMnemonic() throws {
        try deleteData(account: .mainWalletMnemonic)
    }

    /// Check if a mnemonic exists in the Keychain
    /// - Returns: true if a mnemonic is stored
    public func hasMnemonic() -> Bool {
        (try? loadData(account: .mainWalletMnemonic)) != nil
    }

    // MARK: - Generic Data Storage

    /// Store arbitrary data with a custom key
    /// - Parameters:
    ///   - data: Data to store
    ///   - key: Storage key
    public func store(_ data: Data, forKey key: String) throws {
        try storeData(data, accountString: key)
    }

    /// Load arbitrary data by key
    /// - Parameter key: Storage key
    /// - Returns: Stored data or nil
    public func load(forKey key: String) throws -> Data? {
        return try loadData(accountString: key)
    }

    /// Delete data by key
    /// - Parameter key: Storage key
    public func delete(forKey key: String) throws {
        try deleteData(accountString: key)
    }

    // MARK: - Private Helpers

    private func storeData(
        _ data: Data,
        account: Account,
        accessible: CFString = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    ) throws {
        try storeData(data, accountString: account.rawValue, accessible: accessible)
    }

    private func storeData(
        _ data: Data,
        accountString: String,
        accessible: CFString = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    ) throws {
        // Delete existing item first (update not always reliable)
        try? deleteData(accountString: accountString)

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountString,
            kSecValueData as String: data,
            kSecAttrAccessible as String: accessible
        ]

        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        let status = SecItemAdd(query as CFDictionary, nil)

        guard status == errSecSuccess else {
            throw StealthError.keychainError(status)
        }
    }

    private func loadData(account: Account) throws -> Data? {
        return try loadData(accountString: account.rawValue)
    }

    private func loadData(accountString: String) throws -> Data? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            return result as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw StealthError.keychainError(status)
        }
    }

    private func deleteData(account: Account) throws {
        try deleteData(accountString: account.rawValue)
    }

    private func deleteData(accountString: String) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: accountString
        ]

        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        let status = SecItemDelete(query as CFDictionary)

        // Success or item not found are both acceptable
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StealthError.keychainError(status)
        }
    }

    // MARK: - Utility

    /// Clear all data for this service (use with caution!)
    public func clearAll() throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service
        ]

        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw StealthError.keychainError(status)
        }
    }
}
