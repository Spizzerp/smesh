import SwiftUI
import UIKit

// MARK: - Neuromorphic Action Button

/// Large circular action button with neumorphic styling (Shield/Unshield)
struct NeuromorphicActionButton: View {
    let icon: String
    let label: String
    let palette: NeuromorphicPalette
    let action: () -> Void

    @State private var isPressed = false

    var body: some View {
        Button {
            action()
        } label: {
            VStack(spacing: 10) {
                // Circular button with icon
                ZStack {
                    Circle()
                        .fill(palette.background)
                        .frame(width: 64, height: 64)
                        // Light shadow (top-left highlight)
                        .shadow(
                            color: palette.lightShadow.opacity(isPressed ? 0.02 : 0.07),
                            radius: isPressed ? 4 : 8,
                            x: isPressed ? -2 : -4,
                            y: isPressed ? -2 : -4
                        )
                        // Dark shadow (bottom-right depth)
                        .shadow(
                            color: palette.darkShadow.opacity(isPressed ? 0.25 : 0.5),
                            radius: isPressed ? 4 : 8,
                            x: isPressed ? 2 : 4,
                            y: isPressed ? 2 : 4
                        )

                    Image(systemName: icon)
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundColor(palette.accent)
                }
                .scaleEffect(isPressed ? 0.95 : 1.0)

                // Label
                Text(label)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(palette.textSecondary)
            }
        }
        .buttonStyle(.plain)
        .onLongPressGesture(minimumDuration: .infinity, pressing: { pressing in
            withAnimation(.easeInOut(duration: 0.1)) {
                isPressed = pressing
            }
        }, perform: {})
    }
}

// MARK: - Neuromorphic Icon Button

/// Small circular icon button with neumorphic styling
struct NeuromorphicIconButton: View {
    let icon: String
    let palette: NeuromorphicPalette
    let size: CGFloat
    let action: () -> Void

    @State private var isPressed = false

    init(
        icon: String,
        palette: NeuromorphicPalette,
        size: CGFloat = 44,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.palette = palette
        self.size = size
        self.action = action
    }

    var body: some View {
        Button {
            action()
        } label: {
            ZStack {
                Circle()
                    .fill(palette.background)
                    .frame(width: size, height: size)
                    // Light shadow (top-left highlight)
                    .shadow(
                        color: palette.lightShadow.opacity(isPressed ? 0.02 : 0.06),
                        radius: isPressed ? 3 : 6,
                        x: isPressed ? -1 : -3,
                        y: isPressed ? -1 : -3
                    )
                    // Dark shadow (bottom-right depth)
                    .shadow(
                        color: palette.darkShadow.opacity(isPressed ? 0.2 : 0.4),
                        radius: isPressed ? 3 : 6,
                        x: isPressed ? 1 : 3,
                        y: isPressed ? 1 : 3
                    )

                Image(systemName: icon)
                    .font(.system(size: size * 0.4, weight: .semibold))
                    .foregroundColor(palette.accent)
            }
            .scaleEffect(isPressed ? 0.92 : 1.0)
        }
        .buttonStyle(.plain)
        .onLongPressGesture(minimumDuration: .infinity, pressing: { pressing in
            withAnimation(.easeInOut(duration: 0.08)) {
                isPressed = pressing
            }
        }, perform: {})
    }
}

// MARK: - Neuromorphic Text Button

/// Pill-shaped text button with neumorphic styling
struct NeuromorphicTextButton: View {
    let title: String
    let palette: NeuromorphicPalette
    let isDestructive: Bool
    let action: () -> Void

    @State private var isPressed = false

    init(
        title: String,
        palette: NeuromorphicPalette,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.palette = palette
        self.isDestructive = isDestructive
        self.action = action
    }

    var body: some View {
        Button {
            action()
        } label: {
            Text(title)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(isDestructive ? .red : palette.accent)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(
                    Capsule()
                        .fill(palette.background)
                        // Light shadow (top-left highlight)
                        .shadow(
                            color: palette.lightShadow.opacity(isPressed ? 0.02 : 0.06),
                            radius: isPressed ? 3 : 6,
                            x: isPressed ? -1 : -3,
                            y: isPressed ? -1 : -3
                        )
                        // Dark shadow (bottom-right depth)
                        .shadow(
                            color: palette.darkShadow.opacity(isPressed ? 0.2 : 0.4),
                            radius: isPressed ? 3 : 6,
                            x: isPressed ? 1 : 3,
                            y: isPressed ? 1 : 3
                        )
                )
                .scaleEffect(isPressed ? 0.95 : 1.0)
        }
        .buttonStyle(.plain)
        .onLongPressGesture(minimumDuration: .infinity, pressing: { pressing in
            withAnimation(.easeInOut(duration: 0.08)) {
                isPressed = pressing
            }
        }, perform: {})
    }
}

// MARK: - Neuromorphic Primary Button

/// Full-width primary action button with filled accent
struct NeuromorphicPrimaryButton: View {
    let title: String
    let palette: NeuromorphicPalette
    let isLoading: Bool
    let action: () -> Void

    @State private var isPressed = false

    init(
        title: String,
        palette: NeuromorphicPalette,
        isLoading: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.palette = palette
        self.isLoading = isLoading
        self.action = action
    }

    var body: some View {
        Button {
            if !isLoading {
                action()
            }
        } label: {
            HStack {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(0.8)
                } else {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.bold)
                }
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(
                        LinearGradient(
                            colors: [
                                palette.accent,
                                palette.accent.opacity(0.85)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(
                        color: palette.accent.opacity(isPressed ? 0.15 : 0.35),
                        radius: isPressed ? 4 : 8,
                        x: 0,
                        y: isPressed ? 2 : 4
                    )
            )
            .scaleEffect(isPressed ? 0.98 : 1.0)
            .opacity(isLoading ? 0.8 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(isLoading)
        .onLongPressGesture(minimumDuration: .infinity, pressing: { pressing in
            withAnimation(.easeInOut(duration: 0.08)) {
                isPressed = pressing
            }
        }, perform: {})
    }
}

// MARK: - Preview

#Preview("Neuromorphic Buttons") {
    ZStack {
        NeuromorphicPalette.pageBackground
            .ignoresSafeArea()

        VStack(spacing: 32) {
            // Action buttons
            HStack(spacing: 40) {
                NeuromorphicActionButton(
                    icon: "eye.slash.fill",
                    label: "Shield",
                    palette: .blue
                ) {}

                NeuromorphicActionButton(
                    icon: "eye.fill",
                    label: "Unshield",
                    palette: .purple
                ) {}
            }

            // Icon buttons
            HStack(spacing: 20) {
                NeuromorphicIconButton(
                    icon: "arrow.clockwise",
                    palette: .blue
                ) {}

                NeuromorphicIconButton(
                    icon: "qrcode",
                    palette: .purple
                ) {}

                NeuromorphicIconButton(
                    icon: "gearshape.fill",
                    palette: .blue,
                    size: 36
                ) {}
            }

            // Text buttons
            HStack(spacing: 16) {
                NeuromorphicTextButton(
                    title: "Cancel",
                    palette: .blue,
                    isDestructive: true
                ) {}

                NeuromorphicTextButton(
                    title: "Confirm",
                    palette: .blue
                ) {}
            }

            // Primary buttons
            VStack(spacing: 12) {
                NeuromorphicPrimaryButton(
                    title: "Shield Now",
                    palette: .blue
                ) {}

                NeuromorphicPrimaryButton(
                    title: "Processing...",
                    palette: .purple,
                    isLoading: true
                ) {}
            }
            .padding(.horizontal, 40)
        }
        .padding()
    }
}
