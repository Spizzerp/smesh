import SwiftUI

// MARK: - Terminal Command Button

/// Command-style button: > SHIELD, > UNSHIELD
struct TerminalCommandButton: View {
    let command: String
    let accent: TerminalAccent
    let isActive: Bool
    let isDisabled: Bool
    let action: () -> Void

    @State private var isPressed = false

    init(
        command: String,
        accent: TerminalAccent,
        isActive: Bool = false,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.command = command
        self.accent = accent
        self.isActive = isActive
        self.isDisabled = isDisabled
        self.action = action
    }

    var body: some View {
        Button {
            guard !isDisabled && !isActive else { return }
            action()
        } label: {
            HStack(spacing: 4) {
                Text(">")
                    .foregroundColor(isActive ? accent.color : TerminalPalette.textDim)

                if isActive {
                    TerminalSpinner(color: accent.color)
                }

                Text(command)
                    .foregroundColor(effectiveColor)
            }
            .font(TerminalTypography.command())
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 2)
                    .fill(isPressed ? TerminalPalette.surfaceLight : TerminalPalette.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(effectiveBorderColor, lineWidth: 1)
                    )
            )
            .scaleEffect(isPressed ? 0.98 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled || isActive)
        .opacity(isDisabled && !isActive ? 0.5 : 1.0)
        .onLongPressGesture(minimumDuration: .infinity, pressing: { pressing in
            withAnimation(.easeInOut(duration: 0.08)) {
                isPressed = pressing
            }
        }, perform: {})
    }

    private var effectiveColor: Color {
        if isActive { return accent.color }
        if isDisabled { return TerminalPalette.textMuted }
        return accent.color
    }

    private var effectiveBorderColor: Color {
        if isActive { return accent.color }
        if isPressed { return accent.color }
        return accent.dimColor
    }
}

// MARK: - Terminal Icon Button

/// Small icon button: [R] refresh, [X] close
struct TerminalIconButton: View {
    let label: String
    let accent: TerminalAccent
    let isActive: Bool
    let action: () -> Void

    @State private var isPressed = false

    init(
        label: String,
        accent: TerminalAccent,
        isActive: Bool = false,
        action: @escaping () -> Void
    ) {
        self.label = label
        self.accent = accent
        self.isActive = isActive
        self.action = action
    }

    var body: some View {
        Button {
            guard !isActive else { return }
            action()
        } label: {
            Group {
                if isActive {
                    TerminalSpinner(color: accent.color)
                } else {
                    Text("[\(label)]")
                }
            }
            .font(TerminalTypography.label())
            .foregroundColor(accent.color)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 2)
                    .fill(isPressed ? TerminalPalette.surfaceLight : Color.clear)
            )
            .scaleEffect(isPressed ? 0.95 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(isActive)
        .onLongPressGesture(minimumDuration: .infinity, pressing: { pressing in
            withAnimation(.easeInOut(duration: 0.08)) {
                isPressed = pressing
            }
        }, perform: {})
    }
}

// MARK: - Terminal Text Button

/// Simple text button with terminal styling
struct TerminalTextButton: View {
    let title: String
    let accent: TerminalAccent
    let isDestructive: Bool
    let action: () -> Void

    @State private var isPressed = false

    init(
        title: String,
        accent: TerminalAccent,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.accent = accent
        self.isDestructive = isDestructive
        self.action = action
    }

    var body: some View {
        Button {
            action()
        } label: {
            Text(title)
                .font(TerminalTypography.command())
                .foregroundColor(isDestructive ? TerminalPalette.error : accent.color)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 2)
                        .fill(isPressed ? TerminalPalette.surfaceLight : Color.clear)
                        .overlay(
                            RoundedRectangle(cornerRadius: 2)
                                .stroke(
                                    isPressed ? (isDestructive ? TerminalPalette.error : accent.color) : (isDestructive ? Color(hex: "550000") : accent.dimColor),
                                    lineWidth: 1
                                )
                        )
                )
                .scaleEffect(isPressed ? 0.98 : 1.0)
        }
        .buttonStyle(.plain)
        .onLongPressGesture(minimumDuration: .infinity, pressing: { pressing in
            withAnimation(.easeInOut(duration: 0.08)) {
                isPressed = pressing
            }
        }, perform: {})
    }
}

// MARK: - Terminal Primary Button

/// Full-width primary action button with accent fill
struct TerminalPrimaryButton: View {
    let title: String
    let accent: TerminalAccent
    let isLoading: Bool
    let action: () -> Void

    @State private var isPressed = false

    init(
        title: String,
        accent: TerminalAccent,
        isLoading: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.accent = accent
        self.isLoading = isLoading
        self.action = action
    }

    var body: some View {
        Button {
            if !isLoading {
                action()
            }
        } label: {
            HStack(spacing: 8) {
                if isLoading {
                    TerminalSpinner(color: TerminalPalette.background)
                }

                Text(isLoading ? "PROCESSING" : title)
                    .font(TerminalTypography.command())
            }
            .foregroundColor(TerminalPalette.background)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 2)
                    .fill(accent.color)
                    .opacity(isPressed ? 0.8 : 1.0)
            )
            .scaleEffect(isPressed ? 0.98 : 1.0)
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

// MARK: - Terminal Shield/Unshield Row

/// Horizontal row with Shield and Unshield command buttons
struct TerminalShieldUnshieldRow: View {
    let onShield: () -> Void
    let onUnshield: () -> Void
    let shieldDisabled: Bool
    let unshieldDisabled: Bool
    var isShielding: Bool = false
    var isUnshielding: Bool = false

    var body: some View {
        HStack(spacing: 20) {
            TerminalCommandButton(
                command: "SHIELD",
                accent: .public,
                isActive: isShielding,
                isDisabled: shieldDisabled
            ) {
                onShield()
            }

            TerminalCommandButton(
                command: "UNSHIELD",
                accent: .stealth,
                isActive: isUnshielding,
                isDisabled: unshieldDisabled
            ) {
                onUnshield()
            }
        }
    }
}

// MARK: - Preview

#Preview("Terminal Buttons") {
    ZStack {
        TerminalPalette.background
            .ignoresSafeArea()

        VStack(spacing: 24) {
            // Command buttons
            VStack(spacing: 12) {
                Text("// Command Buttons")
                    .font(TerminalTypography.label())
                    .foregroundColor(TerminalPalette.textMuted)

                HStack(spacing: 16) {
                    TerminalCommandButton(command: "SHIELD", accent: .public) {}
                    TerminalCommandButton(command: "UNSHIELD", accent: .stealth) {}
                }

                HStack(spacing: 16) {
                    TerminalCommandButton(command: "LOADING", accent: .public, isActive: true) {}
                    TerminalCommandButton(command: "DISABLED", accent: .stealth, isDisabled: true) {}
                }
            }

            // Icon buttons
            VStack(spacing: 12) {
                Text("// Icon Buttons")
                    .font(TerminalTypography.label())
                    .foregroundColor(TerminalPalette.textMuted)

                HStack(spacing: 16) {
                    TerminalIconButton(label: "R", accent: .public) {}
                    TerminalIconButton(label: "X", accent: .stealth) {}
                    TerminalIconButton(label: "R", accent: .public, isActive: true) {}
                }
            }

            // Text buttons
            VStack(spacing: 12) {
                Text("// Text Buttons")
                    .font(TerminalTypography.label())
                    .foregroundColor(TerminalPalette.textMuted)

                HStack(spacing: 16) {
                    TerminalTextButton(title: "CANCEL", accent: .public, isDestructive: true) {}
                    TerminalTextButton(title: "CONFIRM", accent: .public) {}
                }
            }

            // Primary buttons
            VStack(spacing: 12) {
                Text("// Primary Buttons")
                    .font(TerminalTypography.label())
                    .foregroundColor(TerminalPalette.textMuted)

                TerminalPrimaryButton(title: "EXECUTE", accent: .public) {}
                TerminalPrimaryButton(title: "PROCESS", accent: .stealth, isLoading: true) {}
            }
            .padding(.horizontal, 40)

            // Shield/Unshield row
            VStack(spacing: 12) {
                Text("// Shield/Unshield Row")
                    .font(TerminalTypography.label())
                    .foregroundColor(TerminalPalette.textMuted)

                TerminalShieldUnshieldRow(
                    onShield: {},
                    onUnshield: {},
                    shieldDisabled: false,
                    unshieldDisabled: false
                )
            }
        }
        .padding()
    }
}
