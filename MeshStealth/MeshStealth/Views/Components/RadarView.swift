import SwiftUI

// MARK: - Radar View

/// Interactive radar visualization showing nearby mesh peers.
/// Peers are positioned by RSSI (distance from center) and hash-based angle (deterministic position).
struct RadarView: View {
    let peers: [NearbyPeer]
    let onPeerTapped: (NearbyPeer) -> Void

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
            let maxRadius = max(1, (size / 2) - 24)  // Ensure positive radius

            ZStack {
                // Pulsating nebula background
                RadarBackground(maxRadius: maxRadius)

                // Center dot (user)
                RadarCenterDot()

                // Peer dots
                ForEach(peers) { peer in
                    PeerDot(
                        peer: peer,
                        angle: angleForPeer(peer.id),
                        radius: radiusForRSSI(peer.rssi, maxRadius: maxRadius)
                    )
                    .position(
                        positionForPeer(peer, maxRadius: maxRadius, center: center)
                    )
                    .onTapGesture {
                        onPeerTapped(peer)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    // MARK: - Position Calculations

    /// Deterministic angle from peer ID hash
    private func angleForPeer(_ peerID: String) -> Double {
        let hash = peerID.hashValue
        return Double(abs(hash) % 360) * .pi / 180
    }

    /// Map RSSI to radius (stronger signal = closer to center)
    private func radiusForRSSI(_ rssi: Int, maxRadius: CGFloat) -> CGFloat {
        // RSSI range: -100 (far) to -30 (close)
        let normalized = Double(min(max(rssi, -100), -30) + 100) / 70.0
        let minRadius = maxRadius * 0.18  // Keep dots outside center
        return maxRadius - (normalized * (maxRadius - minRadius))
    }

    /// Calculate position for a peer
    private func positionForPeer(_ peer: NearbyPeer, maxRadius: CGFloat, center: CGPoint) -> CGPoint {
        let angle = angleForPeer(peer.id)
        let radius = radiusForRSSI(peer.rssi, maxRadius: maxRadius)

        return CGPoint(
            x: center.x + cos(angle) * radius,
            y: center.y + sin(angle) * radius
        )
    }
}

// MARK: - Radar Background

/// Pulsating nebula background using portal images
struct RadarBackground: View {
    let maxRadius: CGFloat
    @State private var pulseScale: CGFloat = 1.0
    @State private var rotation: Double = 0
    @State private var opacity1: Double = 1.0
    @State private var opacity2: Double = 0.5

    var body: some View {
        ZStack {
            // Base dark background
            Circle()
                .fill(TerminalPalette.background)
                .frame(width: maxRadius * 2 + 48, height: maxRadius * 2 + 48)

            // First nebula layer - slower rotation
            // Content offset to align visual swirl center with rotation center
            NebulaImage(
                imageName: "portal_neb1",
                size: maxRadius * 2.2 * pulseScale,
                rotation: rotation,
                opacity: opacity1,
                blendMode: .screen,
                contentOffset: CGSize(width: 0, height: -15)  // Shift content up
            )

            // Second nebula layer - counter rotation for depth
            NebulaImage(
                imageName: "portal_neb2",
                size: maxRadius * 2.4 * pulseScale,
                rotation: -rotation * 0.7,
                opacity: opacity2,
                blendMode: .plusLighter
            )

            // Center glow overlay
            Circle()
                .fill(
                    RadialGradient(
                        gradient: Gradient(colors: [
                            TerminalPalette.purple.opacity(0.3),
                            TerminalPalette.purple.opacity(0.1),
                            Color.clear
                        ]),
                        center: .center,
                        startRadius: 0,
                        endRadius: maxRadius * 0.6
                    )
                )
                .frame(width: maxRadius * 2, height: maxRadius * 2)
                .blendMode(.plusLighter)
        }
        .onAppear {
            // Slow rotation
            withAnimation(.linear(duration: 60).repeatForever(autoreverses: false)) {
                rotation = 360
            }

            // Pulse scale
            withAnimation(.easeInOut(duration: 3).repeatForever(autoreverses: true)) {
                pulseScale = 1.08
            }

            // Opacity breathing
            withAnimation(.easeInOut(duration: 4).repeatForever(autoreverses: true)) {
                opacity1 = 0.7
                opacity2 = 0.8
            }
        }
    }
}

// MARK: - Nebula Image

/// Helper view to properly center and display nebula images
struct NebulaImage: View {
    let imageName: String
    let size: CGFloat
    let rotation: Double
    let opacity: Double
    let blendMode: BlendMode
    var contentOffset: CGSize = .zero  // Offset image content before clipping

    // Ensure positive dimension
    private var safeSize: CGFloat {
        max(1, size)
    }

    var body: some View {
        Image(imageName)
            .resizable()
            .scaledToFill()
            .offset(contentOffset)  // Shift content to align visual center
            .frame(width: safeSize, height: safeSize)
            .clipShape(Circle())
            .rotationEffect(.degrees(rotation))
            .opacity(opacity)
            .blendMode(blendMode)
    }
}

// MARK: - Radar Center Dot

/// User's position indicator at radar center - bright core with purple glow
struct RadarCenterDot: View {
    @State private var glowPulse = false

    // Bright magenta/white for center
    private let coreColor = Color(red: 1.0, green: 0.6, blue: 0.9)

    var body: some View {
        ZStack {
            // Outer glow (purple)
            Circle()
                .fill(TerminalPalette.purple.opacity(0.4))
                .frame(width: 32, height: 32)
                .blur(radius: 12)
                .scaleEffect(glowPulse ? 1.3 : 1.0)

            // Inner glow (brighter)
            Circle()
                .fill(coreColor.opacity(0.5))
                .frame(width: 20, height: 20)
                .blur(radius: 6)

            // Outer ring
            Circle()
                .stroke(coreColor.opacity(0.8), lineWidth: 2)
                .frame(width: 16, height: 16)

            // Inner dot (brightest)
            Circle()
                .fill(Color.white)
                .frame(width: 6, height: 6)
        }
        .shadow(color: TerminalPalette.purple.opacity(0.6), radius: 12)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.5).repeatForever(autoreverses: true)) {
                glowPulse = true
            }
        }
    }
}

// MARK: - Peer Dot

/// Individual peer indicator on the radar
struct PeerDot: View {
    let peer: NearbyPeer
    let angle: Double
    let radius: Double

    @State private var scale: CGFloat = 0.0
    @State private var pulse: CGFloat = 1.0

    var body: some View {
        ZStack {
            // Glow
            Circle()
                .fill(dotColor.opacity(0.4))
                .frame(width: 20, height: 20)
                .blur(radius: 6)
                .scaleEffect(pulse)

            // PQ ring indicator
            if peer.supportsHybrid {
                Circle()
                    .stroke(TerminalPalette.purple, lineWidth: 2)
                    .frame(width: 18, height: 18)
                    .shadow(color: TerminalPalette.purple.opacity(0.5), radius: 4)
            }

            // Main dot
            Circle()
                .fill(dotColor)
                .frame(width: 12, height: 12)

            // Connection state indicator
            if peer.isConnected {
                Circle()
                    .fill(TerminalPalette.success)
                    .frame(width: 4, height: 4)
                    .offset(x: 6, y: -6)
            }
        }
        .scaleEffect(scale)
        .onAppear {
            // Fade in animation
            withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                scale = 1.0
            }

            // Pulse animation
            withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                pulse = 1.15
            }
        }
    }

    private var dotColor: Color {
        if peer.isConnected {
            return TerminalPalette.success
        }
        switch peer.signalStrength {
        case 75...: return TerminalPalette.success
        case 50..<75: return TerminalPalette.cyan
        case 25..<50: return TerminalPalette.warning
        default: return TerminalPalette.textDim
        }
    }
}

// MARK: - Preview

#Preview("Radar View") {
    ZStack {
        TerminalPalette.background
            .ignoresSafeArea()

        ScanlineOverlay()
            .ignoresSafeArea()

        RadarView(
            peers: [
                NearbyPeer(
                    id: "peer-1-abc",
                    name: "Alice's iPhone",
                    rssi: -45,
                    isConnected: true,
                    lastSeenAt: Date(),
                    supportsHybrid: true
                ),
                NearbyPeer(
                    id: "peer-2-def",
                    name: "Bob's Device",
                    rssi: -65,
                    isConnected: false,
                    lastSeenAt: Date(),
                    supportsHybrid: false
                ),
                NearbyPeer(
                    id: "peer-3-ghi",
                    name: nil,
                    rssi: -80,
                    isConnected: false,
                    lastSeenAt: Date(),
                    supportsHybrid: true
                )
            ],
            onPeerTapped: { peer in
                print("Tapped peer: \(peer.name ?? peer.id)")
            }
        )
        .padding(24)
    }
}

#Preview("Radar Empty") {
    ZStack {
        TerminalPalette.background
            .ignoresSafeArea()

        ScanlineOverlay()
            .ignoresSafeArea()

        VStack(spacing: 32) {
            RadarView(peers: [], onPeerTapped: { _ in })
                .padding(24)

            Text("// SCANNING FOR NODES")
                .font(TerminalTypography.label())
                .foregroundColor(TerminalPalette.textMuted)
        }
    }
}
