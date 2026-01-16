import SwiftUI

// MARK: - Terminal Color Palette

/// Terminal/hacker aesthetic color palette
struct TerminalPalette {
    // Core colors
    static let background = Color(hex: "000000")       // Pure black
    static let surface = Color(hex: "0A0A0A")          // Slightly lighter for containers
    static let surfaceLight = Color(hex: "111111")     // For hover/active states

    // Accent colors
    static let cyan = Color(hex: "00FFFF")             // Public wallet accent
    static let purple = Color(hex: "B06EE6")           // Stealth wallet accent (kept from original)

    // Text colors
    static let textPrimary = Color.white
    static let textDim = Color(hex: "666666")          // Secondary text, timestamps
    static let textMuted = Color(hex: "444444")        // Very dim text

    // Status colors
    static let success = Color(hex: "00FF00")          // Confirmations
    static let error = Color(hex: "FF0000")            // Errors
    static let warning = Color(hex: "FFA500")          // Pending states

    // Border color
    static let border = Color(hex: "333333")           // Subtle borders
    static let borderAccent = Color(hex: "444444")     // Slightly brighter borders
}

// MARK: - Terminal Typography

/// Terminal monospace font helpers
struct TerminalTypography {
    /// Balance display (large)
    static func balance(_ size: CGFloat = 32) -> Font {
        .system(size: size, weight: .bold, design: .monospaced)
    }

    /// Header text
    static func header(_ size: CGFloat = 14) -> Font {
        .system(size: size, weight: .bold, design: .monospaced)
    }

    /// Body text
    static func body(_ size: CGFloat = 14) -> Font {
        .system(size: size, weight: .regular, design: .monospaced)
    }

    /// Label/badge text
    static func label(_ size: CGFloat = 11) -> Font {
        .system(size: size, weight: .medium, design: .monospaced)
    }

    /// Timestamp text
    static func timestamp(_ size: CGFloat = 10) -> Font {
        .system(size: size, weight: .regular, design: .monospaced)
    }

    /// Command text (for buttons)
    static func command(_ size: CGFloat = 12) -> Font {
        .system(size: size, weight: .semibold, design: .monospaced)
    }
}

// MARK: - Scanline Overlay

/// Subtle CRT scanline effect overlay
struct ScanlineOverlay: View {
    let lineSpacing: CGFloat
    let opacity: Double

    init(lineSpacing: CGFloat = 2, opacity: Double = 0.08) {
        self.lineSpacing = lineSpacing
        self.opacity = opacity
    }

    var body: some View {
        Canvas { context, size in
            let lineHeight: CGFloat = 1
            var y: CGFloat = 0

            while y < size.height {
                let rect = CGRect(x: 0, y: y, width: size.width, height: lineHeight)
                context.fill(
                    Path(rect),
                    with: .color(Color.black.opacity(opacity))
                )
                y += lineSpacing + lineHeight
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - ASCII Box-Drawing Characters

/// Unicode box-drawing characters for terminal-authentic borders
struct ASCIIBorder {
    static let topLeft = "┌"
    static let topRight = "┐"
    static let bottomLeft = "└"
    static let bottomRight = "┘"
    static let horizontal = "─"
    static let vertical = "│"

    /// Generate a horizontal line of specified width
    static func horizontalLine(width: Int) -> String {
        String(repeating: horizontal, count: width)
    }
}

// MARK: - Terminal Accent Type

/// Defines accent type for terminal styling
enum TerminalAccent {
    case `public`  // Cyan for public wallet
    case stealth   // Purple for stealth wallet

    var color: Color {
        switch self {
        case .public: return TerminalPalette.cyan
        case .stealth: return TerminalPalette.purple
        }
    }

    /// Dim color for secondary elements - uses solid darker shade, no opacity
    var dimColor: Color {
        switch self {
        case .public: return Color(hex: "005555")   // Dark cyan
        case .stealth: return Color(hex: "4A2D5C")  // Dark purple
        }
    }
}

// MARK: - Terminal Container Modifier

/// View modifier for terminal container styling
struct TerminalContainerModifier: ViewModifier {
    let accent: TerminalAccent
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(TerminalPalette.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .stroke(accent.dimColor, lineWidth: 1)
                    )
            )
    }
}

// MARK: - Terminal Border Modifier

/// View modifier for terminal border styling (no fill)
struct TerminalBorderModifier: ViewModifier {
    let accent: TerminalAccent
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .stroke(accent.dimColor, lineWidth: 1)
            )
    }
}

// MARK: - View Extensions

extension View {
    /// Apply terminal public (cyan) container styling
    func terminalPublic(cornerRadius: CGFloat = 2) -> some View {
        modifier(TerminalContainerModifier(
            accent: .public,
            cornerRadius: cornerRadius
        ))
    }

    /// Apply terminal stealth (purple) container styling
    func terminalStealth(cornerRadius: CGFloat = 2) -> some View {
        modifier(TerminalContainerModifier(
            accent: .stealth,
            cornerRadius: cornerRadius
        ))
    }

    /// Apply terminal border only (no fill)
    func terminalBorder(_ accent: TerminalAccent, cornerRadius: CGFloat = 2) -> some View {
        modifier(TerminalBorderModifier(
            accent: accent,
            cornerRadius: cornerRadius
        ))
    }
}

// MARK: - Preview

#Preview("Terminal Styles") {
    ZStack {
        TerminalPalette.background
            .ignoresSafeArea()

        ScanlineOverlay()
            .ignoresSafeArea()

        VStack(spacing: 24) {
            // Cyan card
            VStack(alignment: .leading, spacing: 8) {
                Text("[PUBLIC_WALLET]")
                    .font(TerminalTypography.header())
                    .foregroundColor(TerminalPalette.cyan)

                Text("0.5000")
                    .font(TerminalTypography.balance())
                    .foregroundColor(TerminalPalette.textPrimary)

                Text("SOL")
                    .font(TerminalTypography.label())
                    .foregroundColor(TerminalPalette.textDim)
            }
            .padding(16)
            .terminalPublic()

            // Purple card
            VStack(alignment: .leading, spacing: 8) {
                Text("[STEALTH_WALLET]")
                    .font(TerminalTypography.header())
                    .foregroundColor(TerminalPalette.purple)

                Text("0.2500")
                    .font(TerminalTypography.balance())
                    .foregroundColor(TerminalPalette.textPrimary)

                Text("SOL")
                    .font(TerminalTypography.label())
                    .foregroundColor(TerminalPalette.textDim)
            }
            .padding(16)
            .terminalStealth()

            // Status colors
            HStack(spacing: 16) {
                Text("[SUCCESS]")
                    .font(TerminalTypography.label())
                    .foregroundColor(TerminalPalette.success)

                Text("[ERROR]")
                    .font(TerminalTypography.label())
                    .foregroundColor(TerminalPalette.error)

                Text("[WARNING]")
                    .font(TerminalTypography.label())
                    .foregroundColor(TerminalPalette.warning)
            }
        }
        .padding()
    }
}
