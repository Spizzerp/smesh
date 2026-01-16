import SwiftUI

// MARK: - Terminal ASCII Spinner

/// ASCII character rotation spinner: | / - \
struct TerminalSpinner: View {
    let color: Color

    @State private var currentIndex = 0

    private let frames = ["|", "/", "-", "\\"]

    init(color: Color = TerminalPalette.cyan) {
        self.color = color
    }

    var body: some View {
        Text(frames[currentIndex])
            .font(TerminalTypography.body(14))
            .foregroundColor(color)
            .onAppear {
                startAnimation()
            }
    }

    private func startAnimation() {
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            currentIndex = (currentIndex + 1) % frames.count
        }
    }
}

// MARK: - Blinking Cursor

/// Animated blinking cursor |
struct BlinkingCursor: View {
    let color: Color

    @State private var isVisible = true

    init(color: Color = TerminalPalette.cyan) {
        self.color = color
    }

    var body: some View {
        Text("|")
            .font(TerminalTypography.body(14))
            .foregroundColor(color)
            .opacity(isVisible ? 1 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
                    isVisible.toggle()
                }
            }
    }
}

// MARK: - Typewriter Text (Optional)

/// Text that types out character by character
struct TypewriterText: View {
    let fullText: String
    let color: Color
    let speed: Double

    @State private var displayedText = ""
    @State private var currentIndex = 0

    init(_ text: String, color: Color = TerminalPalette.textPrimary, speed: Double = 0.05) {
        self.fullText = text
        self.color = color
        self.speed = speed
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(displayedText)
                .font(TerminalTypography.body())
                .foregroundColor(color)

            if currentIndex < fullText.count {
                BlinkingCursor(color: color)
            }
        }
        .onAppear {
            typeText()
        }
    }

    private func typeText() {
        guard currentIndex < fullText.count else { return }

        Timer.scheduledTimer(withTimeInterval: speed, repeats: true) { timer in
            if currentIndex < fullText.count {
                let index = fullText.index(fullText.startIndex, offsetBy: currentIndex)
                displayedText += String(fullText[index])
                currentIndex += 1
            } else {
                timer.invalidate()
            }
        }
    }
}

// MARK: - Terminal Progress Bar

/// ASCII-style progress bar [=====>    ]
struct TerminalProgressBar: View {
    let progress: Double // 0.0 to 1.0
    let width: Int
    let accent: TerminalAccent

    init(progress: Double, width: Int = 20, accent: TerminalAccent = .public) {
        self.progress = min(max(progress, 0), 1)
        self.width = width
        self.accent = accent
    }

    var body: some View {
        Text(progressString)
            .font(TerminalTypography.body())
            .foregroundColor(accent.color)
    }

    private var progressString: String {
        let filled = Int(Double(width) * progress)
        let empty = width - filled

        let filledStr = String(repeating: "=", count: max(0, filled - 1))
        let arrow = filled > 0 ? ">" : ""
        let emptyStr = String(repeating: " ", count: empty)

        return "[\(filledStr)\(arrow)\(emptyStr)]"
    }
}

// MARK: - Terminal Loading Dots

/// Loading indicator: ... with animation
struct TerminalLoadingDots: View {
    let color: Color

    @State private var dotCount = 0

    init(color: Color = TerminalPalette.textDim) {
        self.color = color
    }

    var body: some View {
        Text(String(repeating: ".", count: dotCount + 1))
            .font(TerminalTypography.body())
            .foregroundColor(color)
            .frame(width: 30, alignment: .leading)
            .onAppear {
                startAnimation()
            }
    }

    private func startAnimation() {
        Timer.scheduledTimer(withTimeInterval: 0.4, repeats: true) { _ in
            dotCount = (dotCount + 1) % 3
        }
    }
}

// MARK: - Glow Effect Modifier

/// Adds a subtle glow effect around text/elements
struct TerminalGlowModifier: ViewModifier {
    let color: Color
    let radius: CGFloat

    func body(content: Content) -> some View {
        content
            .shadow(color: color.opacity(0.5), radius: radius / 2, x: 0, y: 0)
            .shadow(color: color.opacity(0.3), radius: radius, x: 0, y: 0)
    }
}

extension View {
    /// Apply terminal glow effect
    func terminalGlow(_ color: Color, radius: CGFloat = 4) -> some View {
        modifier(TerminalGlowModifier(color: color, radius: radius))
    }
}

// MARK: - Preview

#Preview("Terminal Animations") {
    ZStack {
        TerminalPalette.background
            .ignoresSafeArea()

        VStack(spacing: 32) {
            // Spinners
            HStack(spacing: 24) {
                HStack(spacing: 8) {
                    TerminalSpinner(color: TerminalPalette.cyan)
                    Text("Loading")
                        .font(TerminalTypography.body())
                        .foregroundColor(TerminalPalette.textDim)
                }

                HStack(spacing: 8) {
                    TerminalSpinner(color: TerminalPalette.purple)
                    Text("Mixing")
                        .font(TerminalTypography.body())
                        .foregroundColor(TerminalPalette.textDim)
                }
            }

            // Blinking cursor
            HStack(spacing: 4) {
                Text("> ")
                    .font(TerminalTypography.body())
                    .foregroundColor(TerminalPalette.cyan)
                BlinkingCursor(color: TerminalPalette.cyan)
            }

            // Progress bars
            VStack(alignment: .leading, spacing: 8) {
                TerminalProgressBar(progress: 0.3, accent: .public)
                TerminalProgressBar(progress: 0.6, accent: .stealth)
                TerminalProgressBar(progress: 1.0, accent: .public)
            }

            // Loading dots
            HStack(spacing: 4) {
                Text("Processing")
                    .font(TerminalTypography.body())
                    .foregroundColor(TerminalPalette.textDim)
                TerminalLoadingDots()
            }

            // Glow effect
            Text("[QUANTUM]")
                .font(TerminalTypography.header())
                .foregroundColor(TerminalPalette.purple)
                .terminalGlow(TerminalPalette.purple)
        }
        .padding()
    }
}
