# Mesh Stealth Transfers

> **Hackathon Track:** Private Payments ($15,000 Prize)

Offline, unlinkable SPL token transfers via Bluetooth mesh. Two phones in airplane mode can exchange value that settles on Solana with zero on-chain correlation between sender and receiver.

## The Innovation

**First stealth address implementation for Solana** + **First offline payment system for Solana**

- **Stealth Addresses**: EIP-5564 adapted for ed25519/Solana - one-time addresses derived from receiver's meta-address
- **Post-Quantum Security**: Hybrid X25519 + ML-KEM 768 (NIST FIPS 203) using Apple CryptoKit
- **Offline Mesh Payments**: BLE mesh with store-and-forward and automatic settlement when online
- **E2E Encrypted Chat**: Double Ratchet with post-quantum hybridization over mesh

## Key Features

### 1. Stealth Addresses
Sender derives a one-time stealth address from receiver's public meta-address. The transaction destination has zero on-chain link to the receiver's identity.

```
Receiver generates: M (spending) + V (viewing) → meta-address
Sender derives: P_stealth = M + SHA256(ECDH(r, V))*G
Include ephemeral R in memo → receiver scans and recovers
```

### 2. Post-Quantum Security (Hybrid Mode)
Optional ML-KEM 768 hybridization provides quantum resistance while maintaining classical security:
- Combined secret: `S = SHA256(S_classical || S_kyber)`
- 66% faster scanning than pure ECDH per [arxiv.org/abs/2501.13733](https://arxiv.org/abs/2501.13733)
- Uses Apple CryptoKit MLKEM768 (iOS 26+) - no external dependencies

### 3. Offline BLE Mesh Payments
- CoreBluetooth peer discovery and message relay
- TTL-based flooding with message deduplication
- Store-and-forward queue for offline peers
- Automatic settlement when connectivity restored

### 4. E2E Encrypted Chat
- Double Ratchet protocol (Signal-style)
- Post-quantum hybridization (X3DH + ML-KEM)
- Perfect forward secrecy and post-compromise security
- Works entirely over BLE mesh - no internet required

### 5. Privacy Protocol Integration
- Privacy Cash and ShadowWire protocol support
- WebView bridge for protocol interaction
- Automatic mixing with 1-5 hops before settlement

## Demo

### Peer Discovery Radar
Interactive radar visualization showing nearby mesh peers with RSSI-based positioning and PQ capability indicators.

### Payment Flow
1. Tap nearby peer on radar
2. Request their meta-address (automatic)
3. Enter amount and send
4. Payment queued for mesh delivery
5. Auto-settles when either device comes online

### Stealth Wallet
- Shield: Move SOL from main wallet to stealth addresses
- Unshield: Consolidate stealth payments back to main wallet
- Activity feed with PQ badges for quantum-resistant transactions

## Quick Start

### Requirements
- **iOS 26+** (required for CryptoKit MLKEM768)
- Xcode 16+
- Two iOS devices with Bluetooth for mesh testing
- Solana Devnet (automatic airdrop available)

### Build

```bash
git clone https://github.com/your-org/smesh.git
cd smesh/MeshStealth
open MeshStealth.xcodeproj
```

1. Select your development team in Signing & Capabilities
2. Build and run on two physical iOS devices
3. Tap "Request Airdrop" to get devnet SOL
4. Discover each other on the mesh radar
5. Send a stealth payment!

### Test StealthCore Library

```bash
cd MeshStealth/Packages/StealthCore
swift test
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        iOS App                               │
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────┐  │
│  │  WalletView │  │  RadarView  │  │     ChatView        │  │
│  └──────┬──────┘  └──────┬──────┘  └──────────┬──────────┘  │
│         │                │                     │             │
│  ┌──────┴────────────────┴─────────────────────┴──────────┐ │
│  │                    ViewModels                           │ │
│  │  WalletViewModel │ MeshViewModel │ ChatViewModel        │ │
│  └──────────────────────────┬──────────────────────────────┘ │
└─────────────────────────────┼────────────────────────────────┘
                              │
┌─────────────────────────────┼────────────────────────────────┐
│                     StealthCore Package                       │
│  ┌──────────────────────────┴──────────────────────────────┐ │
│  │              MeshNetworkManager (Coordinator)            │ │
│  └──────────────────────────┬──────────────────────────────┘ │
│         ┌───────────────────┼───────────────────┐            │
│         ▼                   ▼                   ▼            │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────────┐  │
│  │ BLEMeshSvc  │    │ StealthWallet│   │ SettlementSvc   │  │
│  │ (CoreBT)    │    │ Manager      │   │ (Auto-settle)   │  │
│  └──────┬──────┘    └──────┬───────┘   └────────┬────────┘  │
│         │                  │                     │           │
│  ┌──────┴──────────────────┴─────────────────────┴────────┐ │
│  │                      Crypto Layer                       │ │
│  │  SodiumWrapper │ MLKEMWrapper │ DoubleRatchetEngine     │ │
│  └──────────────────────────┬──────────────────────────────┘ │
└─────────────────────────────┼────────────────────────────────┘
                              │
                              ▼
                    ┌─────────────────┐
                    │  Solana Devnet  │
                    │  (Helius RPC)   │
                    └─────────────────┘
```

## API Reference

### Generate Stealth Identity

```swift
import StealthCore

// Generate keypair with post-quantum support
let keyPair = try StealthKeyPair.generate(enablePostQuantum: true)

// Share meta-address via QR code
let metaAddress = keyPair.hybridMetaAddressString
```

### Send to Stealth Address

```swift
// Derive one-time address from meta-address
let result = try StealthAddressGenerator.generateStealthAddressAuto(
    metaAddressString: recipientMetaAddress
)

// result.stealthAddress - transaction destination
// result.ephemeralPublicKey - include in memo
// result.isHybrid - whether PQ was used
```

### Scan for Payments

```swift
let scanner = StealthScanner(keyPair: myKeyPair)

// Scan transaction
if let payment = try scanner.scanTransaction(
    stealthAddress: destination,
    ephemeralPublicKey: memoData,
    mlkemCiphertext: ciphertext  // optional for hybrid
) {
    // payment.spendingPrivateKey can sign from stealth address
}
```

## Security Model

| Threat | Mitigation |
|--------|------------|
| Relay reads payment | Payload encrypted to recipient's viewing key (AES-256-GCM) |
| Relay modifies tx | Transaction pre-signed; tampering invalidates signature |
| Replay attack | Message IDs + deduplication cache (1-hour TTL) |
| Quantum adversary | Hybrid X25519 + ML-KEM 768 (NIST Level 3) |
| Key extraction | iOS Keychain with `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` |
| Device compromise | Biometric auth for spending operations |

## Tech Stack

- **Swift 5.9+** / iOS 26+ deployment target
- **SwiftUI** with MVVM architecture
- **CoreBluetooth** for BLE mesh networking
- **CryptoKit** for X25519, AES-256-GCM, SHA256, MLKEM768
- **swift-sodium-full** for ed25519 point arithmetic
- **Solana.Swift** for blockchain interaction

## References

- [EIP-5564: Stealth Addresses](https://eips.ethereum.org/EIPS/eip-5564)
- [Post-Quantum Stealth Address Protocols](https://arxiv.org/abs/2501.13733)
- [NIST FIPS 203: ML-KEM Standard](https://csrc.nist.gov/pubs/fips/203/final)
- [Apple CryptoKit MLKEM768](https://developer.apple.com/documentation/cryptokit/mlkem768)

## License

MIT License - see [LICENSE](LICENSE) for details.

---

Built for the Solana Private Payments Hackathon
