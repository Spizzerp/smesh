import SwiftUI
import StealthCore

// MARK: - Terminal Settlement Overlay

/// Terminal-styled overlay showing settlement progress
struct TerminalSettlementOverlay: View {
    let progress: SettlementProgress
    let onCancel: (() -> Void)?

    init(progress: SettlementProgress, onCancel: (() -> Void)? = nil) {
        self.progress = progress
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 12) {
                // Header
                HStack {
                    Text("[~~~]")
                        .foregroundColor(TerminalPalette.cyan)
                    Text("SETTLEMENT_IN_PROGRESS")
                        .foregroundColor(TerminalPalette.textPrimary)
                    Spacer()
                    if let cancel = onCancel {
                        Button(action: cancel) {
                            Text("[X]")
                                .foregroundColor(TerminalPalette.error)
                        }
                    }
                }
                .font(TerminalTypography.header(12))

                // Divider
                Rectangle()
                    .fill(TerminalPalette.border)
                    .frame(height: 1)

                // Progress bar
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("[\(progress.completed)/\(progress.total)]")
                            .foregroundColor(TerminalPalette.cyan)
                        Text(progress.status)
                            .foregroundColor(TerminalPalette.textDim)
                        Spacer()
                    }
                    .font(TerminalTypography.label())

                    // ASCII progress bar
                    GeometryReader { geometry in
                        let width = geometry.size.width
                        let fillWidth = width * CGFloat(progress.progress)

                        ZStack(alignment: .leading) {
                            // Background
                            Text(String(repeating: "░", count: 30))
                                .foregroundColor(TerminalPalette.textMuted)
                                .font(TerminalTypography.body(10))

                            // Fill
                            Text(String(repeating: "█", count: Int(progress.progress * 30)))
                                .foregroundColor(TerminalPalette.cyan)
                                .font(TerminalTypography.body(10))
                        }
                    }
                    .frame(height: 14)
                }

                // Status line
                HStack(spacing: 8) {
                    Text(">")
                        .foregroundColor(TerminalPalette.cyan)
                    Text("status:")
                        .foregroundColor(TerminalPalette.textMuted)
                    Text(statusText)
                        .foregroundColor(statusColor)
                        .lineLimit(1)
                    Spacer()
                }
                .font(TerminalTypography.label())

                // Blinking cursor
                HStack {
                    Text("> _")
                        .foregroundColor(TerminalPalette.cyan)
                        .opacity(blinkOpacity)
                    Spacer()
                }
                .font(TerminalTypography.label())
            }
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 2)
                    .fill(TerminalPalette.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(TerminalPalette.cyan.opacity(0.3), lineWidth: 1)
                    )
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 100) // Above tab bar
        }
        .background(Color.black.opacity(0.7))
        .ignoresSafeArea()
    }

    private var statusText: String {
        switch progress.status.lowercased() {
        case let s where s.contains("confirm"):
            return "CONFIRMING_TX"
        case let s where s.contains("sign"):
            return "SIGNING_TX"
        case let s where s.contains("build"):
            return "BUILDING_TX"
        case let s where s.contains("deriv"):
            return "DERIVING_KEY"
        default:
            return progress.status.uppercased()
        }
    }

    private var statusColor: Color {
        switch progress.status.lowercased() {
        case let s where s.contains("fail") || s.contains("error"):
            return TerminalPalette.error
        case let s where s.contains("success") || s.contains("complete"):
            return TerminalPalette.success
        default:
            return TerminalPalette.warning
        }
    }

    @State private var blinkOpacity: Double = 1.0

    private func startBlinking() {
        withAnimation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true)) {
            blinkOpacity = 0.3
        }
    }
}

// MARK: - Settlement Status Badge

/// Small badge showing settlement status for activity items
struct TerminalSettlementStatusBadge: View {
    let status: PendingPaymentStatus
    let nextRetryAt: Date?

    var body: some View {
        HStack(spacing: 4) {
            Text(badgeIcon)
            Text(badgeText)
        }
        .font(TerminalTypography.label())
        .foregroundColor(badgeColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 2)
                .fill(badgeColor.opacity(0.15))
        )
    }

    private var badgeIcon: String {
        switch status {
        case .settling: return "[~]"
        case .failed: return "[!]"
        case .settled: return "[+]"
        default: return "[?]"
        }
    }

    private var badgeText: String {
        switch status {
        case .settling:
            return "SETTLING"
        case .failed:
            if let nextRetry = nextRetryAt {
                let seconds = max(0, Int(nextRetry.timeIntervalSince(Date())))
                if seconds < 60 {
                    return "RETRY:\(seconds)s"
                } else {
                    return "RETRY:\(seconds / 60)m"
                }
            }
            return "FAILED"
        case .settled:
            return "SETTLED"
        default:
            return status.rawValue.uppercased()
        }
    }

    private var badgeColor: Color {
        switch status {
        case .settling: return TerminalPalette.cyan
        case .failed: return TerminalPalette.error
        case .settled: return TerminalPalette.success
        default: return TerminalPalette.warning
        }
    }
}

// MARK: - Settlement Toast

/// Terminal-styled toast notification for settlement results
struct TerminalSettlementToast: View {
    let result: SettlementResult
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text(result.success ? "[OK]" : "[!]")
                .foregroundColor(result.success ? TerminalPalette.success : TerminalPalette.error)

            VStack(alignment: .leading, spacing: 2) {
                Text(result.success ? "PAYMENT_SETTLED" : "SETTLEMENT_FAILED")
                    .foregroundColor(TerminalPalette.textPrimary)

                if let sig = result.signature {
                    Text("\(sig.prefix(12))...")
                        .foregroundColor(TerminalPalette.textMuted)
                } else if let error = result.error {
                    Text(error.localizedDescription.prefix(30) + "...")
                        .foregroundColor(TerminalPalette.textMuted)
                }
            }

            Spacer()

            Button(action: onDismiss) {
                Text("[X]")
                    .foregroundColor(TerminalPalette.textDim)
            }
        }
        .font(TerminalTypography.label())
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 2)
                .fill(TerminalPalette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(result.success ? TerminalPalette.success.opacity(0.5) : TerminalPalette.error.opacity(0.5), lineWidth: 1)
                )
        )
    }
}

// MARK: - Preview

#Preview("Settlement Overlay") {
    ZStack {
        TerminalPalette.background
            .ignoresSafeArea()

        ScanlineOverlay()
            .ignoresSafeArea()

        TerminalSettlementOverlay(
            progress: SettlementProgress(
                total: 5,
                completed: 2,
                currentPaymentId: UUID(),
                status: "CONFIRMING_TX"
            )
        )
    }
}

#Preview("Settlement Badges") {
    ZStack {
        TerminalPalette.background
            .ignoresSafeArea()

        VStack(spacing: 16) {
            TerminalSettlementStatusBadge(status: .settling, nextRetryAt: nil)
            TerminalSettlementStatusBadge(status: .failed, nextRetryAt: Date().addingTimeInterval(30))
            TerminalSettlementStatusBadge(status: .settled, nextRetryAt: nil)
        }
        .padding()
    }
}
