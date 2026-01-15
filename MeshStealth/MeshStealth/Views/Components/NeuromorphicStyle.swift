import SwiftUI

// MARK: - Neuromorphic Color Palettes

/// Color palette for neumorphic styling
struct NeuromorphicPalette {
    let background: Color
    let lightShadow: Color
    let darkShadow: Color
    let textPrimary: Color
    let textSecondary: Color
    let accent: Color

    /// Single unified background for neumorphic effect
    /// Cards and page MUST share same background for the illusion to work
    static let main = Color(hex: "2D2D3A")

    /// Blue accent palette for Main Wallet
    static let blue = NeuromorphicPalette(
        background: main,
        lightShadow: Color.white,
        darkShadow: Color.black,
        textPrimary: Color.white,
        textSecondary: Color(hex: "8A8A9A"),
        accent: Color(hex: "5C9CE6")
    )

    /// Purple accent palette for Stealth Wallet
    static let purple = NeuromorphicPalette(
        background: main,
        lightShadow: Color.white,
        darkShadow: Color.black,
        textPrimary: Color.white,
        textSecondary: Color(hex: "8A8A9A"),
        accent: Color(hex: "B06EE6")
    )

    /// Page background - SAME as card background for neumorphic effect
    static let pageBackground = main
}

// MARK: - Shadow Configuration

/// Configuration for neumorphic shadows (dark mode optimized)
struct NeuromorphicShadowConfig {
    let lightOffset: CGSize
    let darkOffset: CGSize
    let radius: CGFloat
    let lightOpacity: Double
    let darkOpacity: Double

    /// Standard shadows for cards (based on Hacking with Swift reference)
    static let card = NeuromorphicShadowConfig(
        lightOffset: CGSize(width: -5, height: -5),
        darkOffset: CGSize(width: 5, height: 5),
        radius: 10,
        lightOpacity: 0.07,  // Very subtle for dark mode
        darkOpacity: 0.5     // More pronounced dark shadow
    )

    /// Shadows for buttons
    static let button = NeuromorphicShadowConfig(
        lightOffset: CGSize(width: -4, height: -4),
        darkOffset: CGSize(width: 4, height: 4),
        radius: 8,
        lightOpacity: 0.07,
        darkOpacity: 0.45
    )

    /// Small shadows for icon buttons
    static let iconButton = NeuromorphicShadowConfig(
        lightOffset: CGSize(width: -3, height: -3),
        darkOffset: CGSize(width: 3, height: 3),
        radius: 6,
        lightOpacity: 0.06,
        darkOpacity: 0.4
    )
}

// MARK: - Neumorphic View Modifier

/// ViewModifier for raised neumorphic effect (softOuterShadow style)
struct NeuromorphicRaisedModifier: ViewModifier {
    let palette: NeuromorphicPalette
    let shadowConfig: NeuromorphicShadowConfig
    let cornerRadius: CGFloat
    let isPressed: Bool

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(palette.background)
                    // Light shadow (top-left highlight)
                    .shadow(
                        color: palette.lightShadow.opacity(isPressed ? shadowConfig.lightOpacity * 0.3 : shadowConfig.lightOpacity),
                        radius: isPressed ? shadowConfig.radius * 0.5 : shadowConfig.radius,
                        x: isPressed ? shadowConfig.lightOffset.width * 0.3 : shadowConfig.lightOffset.width,
                        y: isPressed ? shadowConfig.lightOffset.height * 0.3 : shadowConfig.lightOffset.height
                    )
                    // Dark shadow (bottom-right depth)
                    .shadow(
                        color: palette.darkShadow.opacity(isPressed ? shadowConfig.darkOpacity * 0.5 : shadowConfig.darkOpacity),
                        radius: isPressed ? shadowConfig.radius * 0.5 : shadowConfig.radius,
                        x: isPressed ? shadowConfig.darkOffset.width * 0.3 : shadowConfig.darkOffset.width,
                        y: isPressed ? shadowConfig.darkOffset.height * 0.3 : shadowConfig.darkOffset.height
                    )
            )
            .scaleEffect(isPressed ? 0.98 : 1.0)
            .animation(.easeInOut(duration: 0.1), value: isPressed)
    }
}

/// ViewModifier for inset/pressed neumorphic effect (softInnerShadow style)
struct NeuromorphicInsetModifier: ViewModifier {
    let palette: NeuromorphicPalette
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                ZStack {
                    // Base fill
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(palette.background)

                    // Inner shadow effect using overlays
                    RoundedRectangle(cornerRadius: cornerRadius)
                        .fill(palette.background)
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius)
                                .stroke(palette.darkShadow.opacity(0.3), lineWidth: 4)
                                .blur(radius: 4)
                                .offset(x: 2, y: 2)
                                .mask(RoundedRectangle(cornerRadius: cornerRadius).fill(LinearGradient(
                                    colors: [Color.black, Color.clear],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: cornerRadius)
                                .stroke(palette.lightShadow.opacity(0.05), lineWidth: 4)
                                .blur(radius: 4)
                                .offset(x: -2, y: -2)
                                .mask(RoundedRectangle(cornerRadius: cornerRadius).fill(LinearGradient(
                                    colors: [Color.clear, Color.black],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )))
                        )
                }
            )
    }
}

// MARK: - View Extensions

extension View {
    /// Apply blue neuromorphic raised styling
    func neuromorphicBlue(
        cornerRadius: CGFloat = 24,
        shadowConfig: NeuromorphicShadowConfig = .card,
        isPressed: Bool = false
    ) -> some View {
        modifier(NeuromorphicRaisedModifier(
            palette: .blue,
            shadowConfig: shadowConfig,
            cornerRadius: cornerRadius,
            isPressed: isPressed
        ))
    }

    /// Apply purple neuromorphic raised styling
    func neuromorphicPurple(
        cornerRadius: CGFloat = 24,
        shadowConfig: NeuromorphicShadowConfig = .card,
        isPressed: Bool = false
    ) -> some View {
        modifier(NeuromorphicRaisedModifier(
            palette: .purple,
            shadowConfig: shadowConfig,
            cornerRadius: cornerRadius,
            isPressed: isPressed
        ))
    }

    /// Apply neuromorphic raised styling with custom palette
    func neuromorphicRaised(
        palette: NeuromorphicPalette,
        cornerRadius: CGFloat = 24,
        shadowConfig: NeuromorphicShadowConfig = .card,
        isPressed: Bool = false
    ) -> some View {
        modifier(NeuromorphicRaisedModifier(
            palette: palette,
            shadowConfig: shadowConfig,
            cornerRadius: cornerRadius,
            isPressed: isPressed
        ))
    }

    /// Apply neuromorphic inset styling (for text fields)
    func neuromorphicInset(
        palette: NeuromorphicPalette,
        cornerRadius: CGFloat = 12
    ) -> some View {
        modifier(NeuromorphicInsetModifier(
            palette: palette,
            cornerRadius: cornerRadius
        ))
    }
}

// MARK: - Color Extension for Hex

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

// MARK: - Preview

#Preview("Neuromorphic Styles") {
    ZStack {
        NeuromorphicPalette.pageBackground
            .ignoresSafeArea()

        VStack(spacing: 30) {
            // Blue card
            VStack {
                Text("Main Wallet")
                    .font(.headline)
                    .foregroundColor(NeuromorphicPalette.blue.textPrimary)
                Text("0.5000 SOL")
                    .font(.title)
                    .fontWeight(.bold)
                    .foregroundColor(NeuromorphicPalette.blue.textPrimary)
            }
            .padding(24)
            .neuromorphicBlue()

            // Purple card
            VStack {
                Text("Stealth Wallet")
                    .font(.headline)
                    .foregroundColor(NeuromorphicPalette.purple.textPrimary)
                Text("0.2500 SOL")
                    .font(.title)
                    .fontWeight(.bold)
                    .foregroundColor(NeuromorphicPalette.purple.textPrimary)
            }
            .padding(24)
            .neuromorphicPurple()
        }
        .padding()
    }
}
