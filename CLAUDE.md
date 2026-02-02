# Mesh Stealth Transfers - Project Context for Claude Code

## Project Summary

Mesh Stealth Transfers enables offline, unlinkable SPL token transfers between mobile devices via Bluetooth mesh. Two phones in airplane mode can exchange value that settles on Solana with zero on-chain correlation between sender and receiver.

**Hackathon Track:** Private Payments ($15,000 prize)
**Core Innovation:** First stealth address implementation for Solana + first offline payment system for Solana

## Architecture

### Core Components

1. **Stealth Address Protocol** - One-time addresses derived from receiver's meta-address (EIP-5564 adapted for Solana)
2. **BLE Mesh Layer** - CoreBluetooth peer discovery and message relay with TTL-based flooding
3. **Payload Encryption** - X25519 + AES-256-GCM (classical) or Kyber + AES-256-GCM (post-quantum)
4. **Settlement Service** - Broadcasts transactions when connectivity restored

### System Flow

```
Sender (offline) --> BLE Mesh --> Relay Nodes --> Solana Network
                                      ^
Receiver (offline) <-- scans chain ---+
```

## Cryptographic Protocol

### Classical (EIP-5564 Adapted for ed25519/Solana)

**Receiver generates identity:**
```
Spending keypair: (m, M) where M = m*G  [ed25519 - Solana compatible]
Viewing keypair:  (v, V) where V = v*G  [X25519 - for ECDH]
Meta-address: Base58(M || V) = 64 bytes encoded
```

**Sender derives stealth address:**
```
1. Parse meta-address -> (M, V)
2. Generate ephemeral keypair: (r, R) where R = r*G  [X25519]
3. Compute shared secret: S = X25519(r, V)
4. Hash secret: s_h = SHA256(S)
5. Derive stealth pubkey: P_stealth = M + s_h*G  [ed25519 point addition]
6. Stealth address = Base58(P_stealth)
7. Include R in transaction memo
```

**Receiver scans and recovers:**
```
1. Extract ephemeral pubkey R from transaction memo
2. Compute shared secret: S = X25519(v, R)
3. Hash secret: s_h = SHA256(S)
4. Derive expected pubkey: P' = M + s_h*G
5. If P' == transaction destination:
   - Derive spending key: p_stealth = m + s_h (mod L)
   - This key can sign transactions from stealth address
```

### Post-Quantum Option (Hybrid Classical + ML-KEM)

For quantum resistance, we implement a **hybrid** approach combining X25519 + ML-KEM:
- Uses Apple CryptoKit `MLKEM768` (iOS 26+) - no external dependencies
- NIST FIPS 203 standardized (Kyber-768, NIST Level 3 security)
- 66% faster scanning than classical ECDH per arxiv.org/abs/2501.13733
- Secure Enclave support with formally verified implementation

**Key Sizes (MLKEM768):**
| Component | Size |
|-----------|------|
| Public Key | 1,184 bytes |
| Private Key | 2,400 bytes |
| Ciphertext | 1,088 bytes |
| Shared Secret | 32 bytes |

**Hybrid Meta-Address Format:**
```
Classical:  M (32 bytes) || V (32 bytes) = 64 bytes
Hybrid:     M (32 bytes) || V (32 bytes) || K_pub (1184 bytes) = 1280 bytes
```

**Hybrid Stealth Address Derivation:**
```
Sender:
1. Generate ephemeral X25519 keypair (r, R)
2. S_classical = X25519(r, V)
3. (ciphertext, S_kyber) = MLKEM768.encapsulate(K_pub)
4. Combined: S = SHA256(S_classical || S_kyber)
5. P_stealth = M + SHA256(S)*G
6. Memo: R (32 bytes) || ciphertext (1088 bytes)

Receiver:
1. S_classical = X25519(v, R)
2. S_kyber = MLKEM768.decapsulate(ciphertext, K_priv)
3. Combined: S = SHA256(S_classical || S_kyber)
4. Check: P' = M + SHA256(S)*G matches destination
5. Derive: p_stealth = m + SHA256(S)
```

## Tech Stack

### iOS (Hackathon - Primary)
- Swift 5.9+ / **iOS 26+ deployment target** (for CryptoKit MLKEM768)
- SwiftUI for UI with MVVM architecture
- CoreBluetooth for BLE mesh networking
- CryptoKit for X25519, AES-256-GCM, SHA256, **MLKEM768** (post-quantum)
- swift-sodium-full for ed25519 point arithmetic (libsodium)
- Solana.Swift for blockchain interaction
- Base58Swift for Solana address encoding

### Android (Post-Hackathon - Seeker Support)
- Kotlin / Android 12+ (SDK 31+)
- Jetpack Compose for UI
- Android BLE APIs
- libsodium-jni for crypto
- liboqs-java for Kyber
- Solana-KMP (Kotlin Multiplatform) for blockchain
- Solana Mobile Stack for Seeker integration

## Project Structure

```
smesh/
├── CLAUDE.md                    # This file - project context
├── .gitignore                   # Excludes .claude/, build artifacts, secrets
├── README.md                    # Public-facing documentation
│
├── MeshStealth/                 # iOS App
│   ├── MeshStealth.xcodeproj    # Xcode project
│   ├── MeshStealth/
│   │   ├── App/
│   │   │   └── MeshStealthApp.swift    # App entry point, AppState coordinator
│   │   ├── Views/
│   │   │   ├── Components/
│   │   │   │   ├── TerminalStyle.swift         # Color palette, typography
│   │   │   │   ├── TerminalButtons.swift       # Button components
│   │   │   │   ├── TerminalInputs.swift        # Input components
│   │   │   │   ├── TerminalWalletContainer.swift
│   │   │   │   ├── TerminalBadges.swift        # Status badges
│   │   │   │   ├── TerminalAnimations.swift    # Scanline, glow effects
│   │   │   │   ├── TerminalChatBubble.swift    # Chat message bubbles
│   │   │   │   └── RadarView.swift             # Mesh peer radar
│   │   │   ├── WalletView.swift
│   │   │   ├── ActivityView.swift
│   │   │   ├── NearbyPeersView.swift
│   │   │   ├── SendPaymentView.swift
│   │   │   ├── PendingPaymentsView.swift
│   │   │   ├── SettingsView.swift
│   │   │   ├── ChatView.swift                  # E2E encrypted chat
│   │   │   └── WalletBackupView.swift
│   │   ├── ViewModels/
│   │   │   ├── WalletViewModel.swift
│   │   │   ├── MeshViewModel.swift
│   │   │   └── ChatViewModel.swift             # Chat session state
│   │   ├── Resources/
│   │   │   └── Assets.xcassets
│   │   └── Info.plist
│   │
│   └── Packages/
│       └── StealthCore/         # Core crypto library (Swift Package)
│           ├── Package.swift
│           ├── Sources/StealthCore/
│           │   ├── Crypto/
│           │   │   ├── SodiumWrapper.swift      # libsodium C bindings
│           │   │   ├── MLKEMWrapper.swift       # CryptoKit MLKEM768 (iOS 26+)
│           │   │   └── StealthCrypto.swift      # Protocol abstraction
│           │   ├── Stealth/
│           │   │   ├── StealthKeyPair.swift     # Identity management
│           │   │   ├── StealthAddress.swift     # Sender-side derivation
│           │   │   └── StealthScanner.swift     # Receiver-side scanning
│           │   ├── Storage/
│           │   │   └── KeychainService.swift    # Secure key storage
│           │   ├── Mesh/
│           │   │   ├── BLEMeshService.swift     # CoreBluetooth mesh
│           │   │   ├── MeshNode.swift           # Peer state (actor)
│           │   │   ├── MeshPayload.swift        # Message format
│           │   │   └── MessageRelay.swift       # Store-and-forward
│           │   ├── Messaging/
│           │   │   ├── DoubleRatchetEngine.swift # Signal-style ratchet
│           │   │   ├── ChatSession.swift        # Single chat session
│           │   │   └── ChatManager.swift        # Multi-session manager
│           │   ├── Solana/
│           │   │   ├── SolanaRPCClient.swift    # Helius RPC
│           │   │   ├── SolanaTransaction.swift  # Transaction construction
│           │   │   ├── DevnetFaucet.swift       # Devnet airdrop
│           │   │   ├── BlockchainScanner.swift  # Batch stealth scanning
│           │   │   └── StealthPQClient.swift    # PQ stealth operations
│           │   ├── Privacy/
│           │   │   ├── PrivacyRoutingService.swift  # Protocol coordinator
│           │   │   ├── PrivacyCashProvider.swift    # Privacy Cash integration
│           │   │   ├── ShadowWireProvider.swift     # ShadowWire integration
│           │   │   └── WebViewBridge.swift          # JS bridge for protocols
│           │   ├── Integration/
│           │   │   ├── MeshNetworkManager.swift # High-level coordinator
│           │   │   ├── StealthWalletManager.swift
│           │   │   ├── ShieldService.swift      # Shield/unshield
│           │   │   ├── MixingService.swift      # Auto-mixing
│           │   │   ├── SettlementService.swift  # Auto-settle
│           │   │   ├── NetworkMonitor.swift     # Connectivity
│           │   │   └── PayloadEncryption.swift  # Mesh encryption
│           │   └── Extensions/
│           │       ├── Data+Extensions.swift
│           │       ├── String+Base58.swift
│           │       └── DebugLogger.swift        # #if DEBUG logging
│           └── Tests/StealthCoreTests/
│               ├── StealthKeyPairTests.swift
│               ├── StealthAddressTests.swift
│               ├── StealthScannerTests.swift
│               └── CryptoRoundtripTests.swift
│
├── MeshStealthAndroid/          # Android App (post-hackathon)
│   └── ...
│
└── docs/
    ├── mesh-stealth-transfers-spec.md
    └── mesh-stealth-hackathon-strategy.md
```

## Key Files Reference

### Crypto Layer
| File | Purpose |
|------|---------|
| `SodiumWrapper.swift` | libsodium C bindings for ed25519 point arithmetic (`pointAdd`, `scalarMultBase`, `scalarAdd`) |
| `MLKEMWrapper.swift` | CryptoKit MLKEM768 wrapper for post-quantum key encapsulation (iOS 26+) |
| `StealthCrypto.swift` | Protocol abstraction allowing switch between classical/hybrid crypto |

### Stealth Protocol
| File | Purpose |
|------|---------|
| `StealthKeyPair.swift` | Keypair generation, meta-address encoding, shared secret computation |
| `StealthAddress.swift` | Sender-side stealth address derivation from meta-address |
| `StealthScanner.swift` | Receiver-side transaction scanning and spending key recovery |

### Mesh Network
| File | Purpose |
|------|---------|
| `BLEMeshService.swift` | CoreBluetooth central + peripheral, GATT service |
| `MeshNode.swift` | Actor managing peer connections, message deduplication |
| `MeshPayload.swift` | Message format with version, type, TTL, encrypted data |
| `MessageRelay.swift` | Store-and-forward queue, settlement queue |

### Encrypted Mesh Messaging
| File | Purpose |
|------|---------|
| `DoubleRatchetEngine.swift` | Signal-style Double Ratchet with PQ hybridization |
| `ChatSession.swift` | Single chat session state (ratchet keys, message chain) |
| `ChatManager.swift` | Manages multiple chat sessions, key exchange coordination |
| `ChatViewModel.swift` | UI state for chat interface |

**Key Exchange Flow:**
1. Initiator sends `ChatRequest` with X3DH prekey bundle + ML-KEM public key
2. Responder derives shared secret via hybrid X3DH + ML-KEM encapsulation
3. Both initialize Double Ratchet with combined secret
4. Messages encrypted with ratcheting keys (forward secrecy + PCS)

**Security Properties:**
- Perfect Forward Secrecy: Compromised keys don't reveal past messages
- Post-Compromise Security: New keys generated after each exchange
- Quantum Resistance: Hybrid X25519 + ML-KEM for all key exchanges

### Solana Integration
| File | Purpose |
|------|---------|
| `SolanaRPCClient.swift` | Helius RPC interaction, transaction submission |
| `SolanaTransaction.swift` | Transaction construction and signing |
| `DevnetFaucet.swift` | Devnet airdrop requests and transaction helpers |
| `BlockchainScanner.swift` | Batch scanning for stealth payments, hybrid decryption |
| `StealthPQClient.swift` | Post-quantum stealth address client operations |

### Integration Services
| File | Purpose |
|------|---------|
| `MeshNetworkManager.swift` | High-level coordinator for mesh, wallet, and settlement |
| `StealthWalletManager.swift` | Wallet state, activity tracking, payment management |
| `ShieldService.swift` | Shield (main→stealth) and unshield (stealth→main) operations |
| `MixingService.swift` | Automatic mixing with random 1-5 hops for privacy |
| `SettlementService.swift` | Auto-settlement of pending payments when online |
| `NetworkMonitor.swift` | NWPathMonitor wrapper for connectivity detection |
| `PayloadEncryption.swift` | X25519/AES-256-GCM encryption for mesh payloads |

### Privacy Protocol Integration
| File | Purpose |
|------|---------|
| `PrivacyRoutingService.swift` | Protocol selection and routing coordination |
| `PrivacyCashProvider.swift` | Privacy Cash integration (deposit/withdraw pools) |
| `ShadowWireProvider.swift` | ShadowWire protocol integration |
| `WebViewBridge.swift` | JavaScript bridge for WebView-based protocols |
| `PrivacyProtocol.swift` | Protocol interface definition |

**Supported Protocols:**
- `direct` - No privacy routing (default)
- `privacyCash` - Privacy Cash pool-based mixing
- `shadowWire` - ShadowWire protocol routing

**Usage:**
```swift
// Set privacy protocol
await walletViewModel.setPrivacyProtocol(.privacyCash)
walletViewModel.setPrivacyEnabled(true)

// Payments automatically route through selected protocol
```

**SDK Implementation Notes:**

| Protocol | Bridge | Bundle Size | Notes |
|----------|--------|-------------|-------|
| Privacy Cash | JSContext | 8.4 MB | Pure JS, no WASM needed |
| ShadowWire | WKWebView | 4.8 MB | Requires WASM for ZK proofs |

**ShadowWire SDK Requirements:**
- WKWebView required (not JSContext) because the SDK uses WASM for Bulletproof ZK proofs
- **Buffer polyfill required**: The SDK uses Node.js `Buffer` class (via `blake-hash` dependency). WebViewBridge includes an inline Buffer polyfill that must be defined before bundle execution
- Bundles are injected via base64-encoded chunks (500KB each) to handle large file sizes
- Console.log from WebView is captured and forwarded to DebugLogger for debugging
- Runs in **simulation mode** without merchant credentials (get from https://radrlabs.io for live mode)

**Privacy Cash SDK Requirements:**
- JSContext sufficient (lighter weight than WKWebView)
- Web API polyfills included: TextEncoder, TextDecoder, atob/btoa, crypto.getRandomValues, Buffer, process
- No API key required for devnet

### UI Components (Terminal-Style Design)
| File | Purpose |
|------|---------|
| `TerminalStyle.swift` | Color palette (TerminalPalette), typography, view modifiers |
| `TerminalButtons.swift` | Primary, secondary, icon, and text button components |
| `TerminalInputs.swift` | Amount input with MAX button, text fields |
| `TerminalWalletContainer.swift` | Public and Stealth wallet card containers |
| `TerminalBadges.swift` | Network, quantum, address, and status indicator badges |
| `TerminalAnimations.swift` | Pulsing glows, scanline overlays, typing effects |
| `TerminalChatBubble.swift` | Chat message bubbles with PQ status indicators |

### Radar Visualization
| File | Purpose |
|------|---------|
| `RadarView.swift` | Interactive radar showing nearby mesh peers |
| `RadarBackground.swift` | Pulsating nebula background with portal images |
| `PeerDot.swift` | Individual peer indicator with signal strength colors |
| `PeerDetailCard.swift` | Detailed peer info card on selection |

**Radar Features:**
- RSSI-based positioning (stronger signal = closer to center)
- Deterministic angle from peer ID hash
- PQ-capable peers show purple ring indicator
- Connected peers show green status dot

## Coding Conventions

### Swift Style
```swift
// Use async/await over callbacks
func generateStealthAddress() async throws -> StealthAddressResult

// Use actors for thread-safe state
actor MeshNode {
    private var peers: [UUID: PeerConnection] = [:]
}

// Use structured concurrency
await withTaskGroup(of: Void.self) { group in
    for peer in peers {
        group.addTask { await peer.sendMessage(payload) }
    }
}

// SwiftUI with MVVM
@Observable  // iOS 17+
class WalletViewModel {
    var balance: UInt64 = 0
    var pendingPayments: [PendingPayment] = []
}

// Or for iOS 15+ compatibility
class WalletViewModel: ObservableObject {
    @Published var balance: UInt64 = 0
}
```

### Naming Conventions
| Element | Convention | Example |
|---------|------------|---------|
| Types | PascalCase | `StealthKeyPair`, `MeshPayload` |
| Functions/Variables | camelCase | `generateStealthAddress`, `viewingPublicKey` |
| Constants | camelCase | `maxHops = 7`, `bleServiceUUID` |
| Files | Match primary type | `StealthKeyPair.swift` |
| Test files | TypeTests | `StealthKeyPairTests.swift` |

### Error Handling
```swift
// Define domain-specific errors
enum StealthError: Error, LocalizedError {
    case invalidMetaAddress
    case pointAdditionFailed
    case keyDerivationFailed
    case keychainError(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidMetaAddress: return "Invalid stealth meta-address format"
        // ...
        }
    }
}

// Never force unwrap - use guard/if-let
guard let result = SodiumWrapper.pointAdd(a, b) else {
    throw StealthError.pointAdditionFailed
}
```

### Testing
```swift
// Unit tests for all crypto operations
final class StealthKeyPairTests: XCTestCase {

    override func setUpWithError() throws {
        XCTAssertTrue(SodiumWrapper.initialize())
    }

    func testKeyPairGeneration() async throws {
        let keyPair = try StealthKeyPair.generate()
        XCTAssertEqual(keyPair.spendingPublicKey.count, 32)
    }
}
```

## Dependencies

### Swift Package Manager
```swift
// Package.swift
platforms: [.iOS(.v26), .macOS(.v26)],  // iOS 26+ for CryptoKit MLKEM768
dependencies: [
    // Ed25519 point arithmetic (libsodium with full build)
    .package(url: "https://github.com/algorandfoundation/swift-sodium-full.git", from: "1.0.0"),

    // Base58 encoding for Solana addresses
    .package(url: "https://github.com/keefertaylor/Base58Swift.git", from: "2.1.0"),

    // Solana blockchain interaction
    .package(url: "https://github.com/ajamaica/Solana.Swift", from: "5.0.0"),

    // QR code generation
    .package(url: "https://github.com/dagronf/QRCode", from: "18.0.0"),

    // Post-quantum: NO DEPENDENCY NEEDED
    // CryptoKit MLKEM768 is built into iOS 26+
]
```

### Native Frameworks (No Installation Required)
| Framework | Purpose |
|-----------|---------|
| CryptoKit | X25519 ECDH, AES-256-GCM, SHA256, HMAC, **MLKEM768** (iOS 26+) |
| CoreBluetooth | BLE central/peripheral, GATT services |
| Network | NWPathMonitor for connectivity detection |
| Security | Keychain Services for key storage |
| AVFoundation | Camera access for QR code scanning |
| SwiftUI | User interface |

## Environment Configuration

### RPC Endpoints (Helius)
```swift
enum SolanaNetwork {
    case devnet
    case mainnet

    var rpcURL: URL {
        switch self {
        case .devnet:
            return URL(string: "https://devnet.helius-rpc.com/?api-key=\(apiKey)")!
        case .mainnet:
            return URL(string: "https://mainnet.helius-rpc.com/?api-key=\(apiKey)")!
        }
    }
}
```

### Test Tokens
| Token | Network | Mint Address |
|-------|---------|--------------|
| USDC | Devnet | `4zMMC9srt5Ri5X14GAgXhaHii3GnPAEERYPJgZJDncDU` |
| SOL | Devnet | Native (no mint) |

### BLE Configuration
```swift
// Service and Characteristic UUIDs
static let meshServiceUUID = CBUUID(string: "12345678-1234-1234-1234-123456789ABC")
static let meshCharacteristicUUID = CBUUID(string: "12345678-1234-1234-1234-123456789ABD")

// Mesh parameters
static let maxHops = 7              // TTL limit
static let advertisingInterval = 100 // milliseconds
static let maxPayloadSize = 244     // BLE 5.0 extended advertising
```

## Common Tasks

### Generate New Stealth Keypair
```swift
// Create new identity
let keyPair = try StealthKeyPair.generate()

// Get shareable meta-address (for QR code)
let metaAddress = keyPair.metaAddressString
// => "stealth:sol:4vJ9JU1bJJE96FWSJKvHsmmFADCg4gpZQff4P3bkLKi..."

// Store securely
try KeychainService.shared.storeKeyPair(keyPair)
```

### Send to Stealth Address
```swift
// Derive one-time stealth address from recipient's meta-address
let result = try StealthAddressGenerator.generateStealthAddress(
    metaAddressString: recipientMetaAddress
)

// result.stealthAddress -> use as transaction destination
// result.ephemeralPublicKey -> include in transaction memo
// result.viewTag -> optional: first byte for fast filtering

// Create and sign transaction
let tx = try await TransactionBuilder.createSPLTransfer(
    from: myWallet,
    to: result.stealthAddress,
    amount: 1_000_000, // 1 USDC (6 decimals)
    tokenMint: usdcMint,
    memo: result.ephemeralPublicKey.base58EncodedString
)
```

### Scan for Received Payments
```swift
// Initialize scanner with your keypair
let scanner = StealthScanner(keyPair: myKeyPair)

// Scan a transaction
if let payment = try scanner.scanTransaction(
    stealthAddress: txDestination,
    ephemeralPublicKey: memoData
) {
    // This payment is ours!
    // payment.stealthAddress - the one-time address
    // payment.spendingPrivateKey - can sign transactions from this address
    // payment.viewTag - for verification
}

// Batch scan (for syncing)
let detected = try scanner.scanTransactions(transactions)
```

### Spend from Stealth Address
```swift
// Use the derived spending key to sign
let stealthKeyPair = try SolanaKeyPair(privateKey: payment.spendingPrivateKey)

let tx = try await TransactionBuilder.createSPLTransfer(
    from: stealthKeyPair,
    to: myMainWallet,
    amount: payment.amount,
    tokenMint: payment.tokenMint
)

let signature = try await SolanaRPCClient.shared.sendTransaction(tx)
```

## Security Considerations

### Threat Model
| Threat | Mitigation |
|--------|------------|
| Relay reads payment | Payload encrypted to recipient's viewing key (AES-256-GCM) |
| Relay modifies tx | Transaction pre-signed; tampering invalidates signature |
| Replay attack | Message IDs + deduplication cache (1-hour TTL) |
| Double spend | Trust model for MVP; escrow/e-cash for production |
| Key extraction | Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` |
| Device compromise | Biometric auth (Face ID/Touch ID) for spending operations |

### Keychain Configuration
```swift
let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "com.meshstealth.keychain",
    kSecAttrAccount as String: "spending_private_key",
    kSecValueData as String: privateKeyData,
    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
]
```

## References

### Specifications
- [EIP-5564: Stealth Addresses](https://eips.ethereum.org/EIPS/eip-5564)
- [Post-Quantum Stealth Address Protocols](https://arxiv.org/abs/2501.13733)
- [NIST FIPS 203: ML-KEM Standard](https://csrc.nist.gov/pubs/fips/203/final)

### Libraries
- [libsodium Point Arithmetic](https://libsodium.gitbook.io/doc/advanced/point-arithmetic)
- [Solana.Swift](https://github.com/ajamaica/Solana.Swift)

### Platform Documentation
- [WWDC25: Get ahead with quantum-secure cryptography](https://developer.apple.com/videos/play/wwdc2025/314/)
- [Apple CryptoKit MLKEM768](https://developer.apple.com/documentation/cryptokit/mlkem768)
- [Solana Mobile Stack](https://solanamobile.com/developers)
- [Helius RPC Docs](https://docs.helius.dev/)
- [CoreBluetooth Programming Guide](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/)

### Related Projects
- [Umbra Protocol (Ethereum stealth addresses)](https://umbra.cash)
- [Bitchat (Bitcoin offline payments)](https://github.com/nicholasrq/bitchat)
