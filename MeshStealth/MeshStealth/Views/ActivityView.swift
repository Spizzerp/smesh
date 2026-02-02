import SwiftUI
import StealthCore

// MARK: - Activity Type Filter

enum ActivityTypeFilter: String, CaseIterable {
    case all = "ALL"
    case shieldUnshield = "SHIELD"
    case mesh = "MESH"
    case wallet = "WALLET"

    var terminalLabel: String {
        switch self {
        case .all: return "[*]"
        case .shieldUnshield: return "[S]"
        case .mesh: return "[M]"
        case .wallet: return "[W]"
        }
    }

    /// Filter activity items by this filter type
    func matches(_ activity: ActivityItem) -> Bool {
        switch self {
        case .all:
            return true
        case .shieldUnshield:
            return activity.type == .shield || activity.type == .unshield
        case .mesh:
            return activity.type == .meshSend || activity.type == .meshReceive
        case .wallet:
            return activity.type == .airdrop || activity.type == .hop
        }
    }
}

struct ActivityView: View {
    @EnvironmentObject var walletViewModel: WalletViewModel
    @EnvironmentObject var meshViewModel: MeshViewModel

    @State private var showPendingOnly = false
    @State private var selectedTypeFilter: ActivityTypeFilter = .all
    @State private var expandedActivities: Set<UUID> = []

    var body: some View {
        NavigationStack {
            ZStack {
                TerminalPalette.background
                    .ignoresSafeArea()

                ScanlineOverlay()
                    .ignoresSafeArea()

                Group {
                    if filteredActivities.isEmpty {
                        VStack(spacing: 16) {
                            // Show filter bar even when empty
                            TerminalActivityFilterBar(
                                selectedFilter: $selectedTypeFilter,
                                showPendingOnly: $showPendingOnly
                            )

                            Spacer()

                            TerminalEmptyActivityView(
                                showPendingOnly: showPendingOnly,
                                selectedFilter: selectedTypeFilter
                            )

                            Spacer()
                        }
                        .padding(.top, 40)
                    } else {
                        ScrollView {
                            VStack(spacing: 16) {
                                // Type filter bar
                                TerminalActivityFilterBar(
                                    selectedFilter: $selectedTypeFilter,
                                    showPendingOnly: $showPendingOnly
                                )

                                // Queued outgoing payments section
                                if !walletViewModel.outgoingPaymentIntents.isEmpty {
                                    OutgoingIntentsSection(intents: walletViewModel.outgoingPaymentIntents)
                                        .padding(.horizontal, 16)
                                }

                                LazyVStack(spacing: 8) {
                                    ForEach(sortedDateKeys, id: \.self) { dateKey in
                                        Section {
                                            ForEach(groupedActivities[dateKey] ?? []) { activity in
                                                TerminalActivityCard(
                                                    activity: activity,
                                                    childActivities: childActivities(for: activity.id),
                                                    isExpanded: expandedActivities.contains(activity.id),
                                                    onToggleExpand: {
                                                        withAnimation(.easeInOut(duration: 0.25)) {
                                                            if expandedActivities.contains(activity.id) {
                                                                expandedActivities.remove(activity.id)
                                                            } else {
                                                                expandedActivities.insert(activity.id)
                                                            }
                                                        }
                                                    }
                                                )
                                            }
                                        } header: {
                                            HStack {
                                                Text("// \(dateKey.uppercased())")
                                                    .font(TerminalTypography.label())
                                                    .foregroundColor(TerminalPalette.textMuted)
                                                Spacer()
                                            }
                                            .padding(.horizontal, 4)
                                            .padding(.top, dateKey == sortedDateKeys.first ? 0 : 8)
                                        }
                                    }
                                }
                                .padding(.horizontal, 16)
                            }
                            .padding(.top, 40)
                            .padding(.bottom, 16)
                        }
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(TerminalPalette.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 6) {
                        Text("//")
                            .foregroundColor(TerminalPalette.textMuted)
                        Text("ACTIVITY")
                            .foregroundColor(TerminalPalette.cyan)
                        Text("v1.0")
                            .foregroundColor(TerminalPalette.textMuted)
                    }
                    .font(TerminalTypography.header(14))
                }
                ToolbarItem(placement: .topBarTrailing) {
                    TerminalStatusBadge(
                        isOnline: meshViewModel.isOnline,
                        peerCount: meshViewModel.peerCount
                    )
                }
            }
        }
    }

    /// Activities filtered by pending toggle and type filter, excluding child activities (hops with parents)
    private var filteredActivities: [ActivityItem] {
        var activities = walletViewModel.activityItems.filter { !$0.isChildActivity }

        // Apply type filter
        if selectedTypeFilter != .all {
            activities = activities.filter { selectedTypeFilter.matches($0) }
        }

        // Apply pending filter
        if showPendingOnly {
            activities = activities.filter { $0.needsSync }
        }

        return activities
    }

    /// Get child activities (hops) for a parent activity
    private func childActivities(for parentId: UUID) -> [ActivityItem] {
        walletViewModel.activityItems.filter { $0.parentActivityId == parentId }
    }

    /// Group activities by date, with activities sorted newest first within each group
    private var groupedActivities: [String: [ActivityItem]] {
        var groups = Dictionary(grouping: filteredActivities) { activity in
            formatDateGroup(activity.timestamp)
        }
        // Sort activities within each group by timestamp (newest first)
        for (key, items) in groups {
            groups[key] = items.sorted { $0.timestamp > $1.timestamp }
        }
        return groups
    }

    /// Get sorted date group keys (newest first)
    private var sortedDateKeys: [String] {
        let keys = groupedActivities.keys
        return keys.sorted { key1, key2 in
            // Get representative date for each group
            let date1 = groupedActivities[key1]?.first?.timestamp ?? Date.distantPast
            let date2 = groupedActivities[key2]?.first?.timestamp ?? Date.distantPast
            return date1 > date2  // Newest first
        }
    }

    private func formatDateGroup(_ date: Date) -> String {
        let calendar = Calendar.current

        if calendar.isDateInToday(date) {
            return "Today"
        } else if calendar.isDateInYesterday(date) {
            return "Yesterday"
        } else if let weekAgo = calendar.date(byAdding: .day, value: -7, to: Date()),
                  date > weekAgo {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE"
            return formatter.string(from: date)
        } else {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return formatter.string(from: date)
        }
    }
}

// MARK: - Terminal Activity Card

struct TerminalActivityCard: View {
    let activity: ActivityItem
    let childActivities: [ActivityItem]
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    var onRetrySettlement: (() -> Void)? = nil

    private var hasChildren: Bool {
        !childActivities.isEmpty
    }

    /// Check if this is a mesh receive activity that can be retried
    private var canRetry: Bool {
        activity.type == .meshReceive && activity.status == .failed
    }

    var body: some View {
        VStack(spacing: 0) {
            // Main activity row
            HStack(spacing: 12) {
                // Activity type indicator
                Text(terminalIcon)
                    .font(TerminalTypography.body(14))
                    .foregroundColor(iconColor)

                // Activity details
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(activityTitle)
                            .font(TerminalTypography.body(12))
                            .foregroundColor(TerminalPalette.textPrimary)

                        if hasChildren {
                            Text("[\(childActivities.count)x]")
                                .font(TerminalTypography.label())
                                .foregroundColor(TerminalPalette.textMuted)
                        }
                    }

                    HStack(spacing: 8) {
                        Text(formattedTime)
                            .font(TerminalTypography.label())
                            .foregroundColor(TerminalPalette.textMuted)

                        // Status badges
                        statusBadge
                    }
                }

                Spacer()

                // Amount and retry button
                VStack(alignment: .trailing, spacing: 2) {
                    Text(formattedAmount)
                        .font(TerminalTypography.body(12))
                        .foregroundColor(amountColor)

                    if activity.status == .completed,
                       let sig = activity.transactionSignature {
                        Text("\(sig.prefix(6))...")
                            .font(TerminalTypography.label())
                            .foregroundColor(TerminalPalette.textMuted)
                    }

                    // Retry button for failed mesh receives
                    if canRetry, let onRetry = onRetrySettlement {
                        Button(action: onRetry) {
                            Text("[RETRY]")
                                .font(TerminalTypography.label())
                                .foregroundColor(TerminalPalette.cyan)
                        }
                        .buttonStyle(.plain)
                    }
                }

                // Expand indicator for activities with children
                if hasChildren {
                    Text(isExpanded ? "[v]" : "[>]")
                        .font(TerminalTypography.label())
                        .foregroundColor(TerminalPalette.cyan)
                }
            }
            .padding(12)
            .contentShape(Rectangle())
            .onTapGesture {
                if hasChildren {
                    onToggleExpand()
                }
            }

            // Expanded child activities
            if isExpanded && hasChildren {
                Rectangle()
                    .fill(TerminalPalette.border)
                    .frame(height: 1)
                    .padding(.horizontal, 12)

                VStack(spacing: 0) {
                    ForEach(Array(childActivities.enumerated()), id: \.element.id) { index, child in
                        TerminalChildActivityRow(activity: child, index: index + 1)
                        if child.id != childActivities.last?.id {
                            Rectangle()
                                .fill(TerminalPalette.border)
                                .frame(height: 1)
                                .padding(.leading, 36)
                        }
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 2)
                .fill(TerminalPalette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(TerminalPalette.border, lineWidth: 1)
                )
        )
    }

    private var terminalIcon: String {
        switch activity.type {
        case .shield: return "[↓]"
        case .unshield: return "[↑]"
        case .meshSend: return "[→]"
        case .meshReceive: return "[←]"
        case .hop: return "[~]"
        case .airdrop: return "[+]"
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch activity.status {
        case .pending:
            Text("[PENDING]")
                .font(TerminalTypography.label())
                .foregroundColor(TerminalPalette.warning)
        case .inProgress:
            // Show settling status for mesh receives
            if activity.type == .meshReceive {
                Text("[SETTLING]")
                    .font(TerminalTypography.label())
                    .foregroundColor(TerminalPalette.cyan)
            } else {
                Text("[IN_PROGRESS]")
                    .font(TerminalTypography.label())
                    .foregroundColor(TerminalPalette.cyan)
            }
        case .failed:
            // Show retry time if available
            if let nextRetry = activity.nextRetryAt {
                let remaining = Int(max(0, nextRetry.timeIntervalSince(Date())))
                if remaining < 60 {
                    Text("[RETRY:\(remaining)s]")
                        .font(TerminalTypography.label())
                        .foregroundColor(TerminalPalette.error)
                } else {
                    Text("[RETRY:\(remaining / 60)m]")
                        .font(TerminalTypography.label())
                        .foregroundColor(TerminalPalette.error)
                }
            } else {
                Text("[FAILED]")
                    .font(TerminalTypography.label())
                    .foregroundColor(TerminalPalette.error)
            }
        case .completed:
            EmptyView()
        }
    }

    private var iconColor: Color {
        switch activity.type {
        case .shield: return TerminalPalette.cyan
        case .unshield: return TerminalPalette.success
        case .meshSend: return TerminalPalette.warning
        case .meshReceive: return TerminalPalette.purple
        case .hop: return TerminalPalette.textMuted
        case .airdrop: return TerminalPalette.cyan
        }
    }

    private var activityTitle: String {
        switch activity.type {
        case .shield: return "SHIELD"
        case .unshield: return "UNSHIELD"
        case .meshSend:
            if let peer = activity.peerName {
                return "SEND -> \(peer.uppercased())"
            }
            return "SEND"
        case .meshReceive:
            if let peer = activity.peerName {
                return "RECV <- \(peer.uppercased())"
            }
            return "RECEIVE"
        case .hop: return "MIX"
        case .airdrop: return "AIRDROP"
        }
    }

    private var amountColor: Color {
        switch activity.type {
        case .shield, .hop: return TerminalPalette.textPrimary
        case .unshield, .meshReceive, .airdrop: return TerminalPalette.success
        case .meshSend: return TerminalPalette.warning
        }
    }

    private var formattedAmount: String {
        let sol = activity.amountInSol
        let prefix: String
        switch activity.type {
        case .meshSend: prefix = "-"
        case .meshReceive, .airdrop, .unshield: prefix = "+"
        case .shield, .hop: prefix = ""
        }
        return String(format: "%@%.4f SOL", prefix, sol)
    }

    private var formattedTime: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: activity.timestamp, relativeTo: Date())
    }
}

// MARK: - Terminal Child Activity Row (for hops)

struct TerminalChildActivityRow: View {
    let activity: ActivityItem
    let index: Int  // Sequential index for display

    var body: some View {
        HStack(spacing: 12) {
            // Index and icon
            Text(String(format: "%02d [~]", index))
                .font(TerminalTypography.label())
                .foregroundColor(TerminalPalette.textMuted)
                .frame(width: 50, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text("HOP_\(index)")
                    .font(TerminalTypography.label())
                    .foregroundColor(TerminalPalette.textDim)

                if let sig = activity.transactionSignature {
                    Text("\(sig.prefix(8))...")
                        .font(TerminalTypography.label())
                        .foregroundColor(TerminalPalette.textMuted)
                }
            }

            Spacer()

            Text(String(format: "%.4f SOL", activity.amountInSol))
                .font(TerminalTypography.label())
                .foregroundColor(TerminalPalette.textDim)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - Terminal Empty State

struct TerminalEmptyActivityView: View {
    let showPendingOnly: Bool
    var selectedFilter: ActivityTypeFilter = .all

    private var emptyIcon: String {
        if showPendingOnly {
            return "[✓]"
        }
        switch selectedFilter {
        case .all: return "[_]"
        case .shieldUnshield: return "[#]"
        case .mesh: return "[◉]"
        case .wallet: return "[W]"
        }
    }

    private var emptyTitle: String {
        if showPendingOnly {
            return "ALL_SYNCED"
        }
        switch selectedFilter {
        case .all: return "NO_ACTIVITY"
        case .shieldUnshield: return "NO_SHIELD_ACTIVITY"
        case .mesh: return "NO_MESH_TRANSACTIONS"
        case .wallet: return "NO_WALLET_ACTIVITY"
        }
    }

    private var emptyMessage: String {
        if showPendingOnly {
            return "// All transactions have been synced"
        }
        switch selectedFilter {
        case .all: return "// Transaction history will appear here"
        case .shieldUnshield: return "// Shield or unshield funds to see activity"
        case .mesh: return "// Send or receive via mesh to see activity"
        case .wallet: return "// Airdrops and wallet activity will appear here"
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            // ASCII art empty state
            VStack(spacing: 4) {
                Text("┌───────────────────┐")
                Text("│                   │")
                Text("│    \(emptyIcon)           │")
                Text("│                   │")
                Text("└───────────────────┘")
            }
            .font(TerminalTypography.body(14))
            .foregroundColor(showPendingOnly ? TerminalPalette.success : TerminalPalette.textMuted)

            VStack(spacing: 8) {
                Text(emptyTitle)
                    .font(TerminalTypography.header())
                    .foregroundColor(showPendingOnly ? TerminalPalette.success : TerminalPalette.textDim)

                Text(emptyMessage)
                    .font(TerminalTypography.label())
                    .foregroundColor(TerminalPalette.textMuted)
                    .multilineTextAlignment(.center)
            }

            if !showPendingOnly {
                Text("> AWAITING_DATA")
                    .font(TerminalTypography.label())
                    .foregroundColor(TerminalPalette.textMuted)
            }
        }
        .padding()
    }
}

// MARK: - Terminal Activity Filter Bar

struct TerminalActivityFilterBar: View {
    @Binding var selectedFilter: ActivityTypeFilter
    @Binding var showPendingOnly: Bool

    var body: some View {
        VStack(spacing: 12) {
            // Pending toggle (top row, right aligned)
            HStack {
                Spacer()

                TerminalFilterChip(
                    label: "[!]",
                    title: showPendingOnly ? "PENDING" : "SHOW_PENDING",
                    isSelected: showPendingOnly,
                    accent: TerminalPalette.warning
                ) {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showPendingOnly.toggle()
                    }
                }
            }

            // Type filters (bottom row)
            HStack(spacing: 8) {
                ForEach(ActivityTypeFilter.allCases, id: \.self) { filter in
                    TerminalFilterChip(
                        label: filter.terminalLabel,
                        title: filter.rawValue,
                        isSelected: selectedFilter == filter
                    ) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedFilter = filter
                        }
                    }
                }

                Spacer()
            }
        }
        .padding(.horizontal, 16)
    }
}

struct TerminalFilterChip: View {
    let label: String
    let title: String
    let isSelected: Bool
    var accent: Color = TerminalPalette.cyan
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 4) {
                Text(label)
                    .font(TerminalTypography.label())

                Text(title)
                    .font(TerminalTypography.label())
            }
            .foregroundColor(isSelected ? accent : TerminalPalette.textMuted)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 2)
                    .fill(isSelected ? accent.opacity(0.15) : TerminalPalette.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 2)
                            .stroke(isSelected ? accent : TerminalPalette.border, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Outgoing Intents Section

struct OutgoingIntentsSection: View {
    let intents: [OutgoingPaymentIntent]

    var body: some View {
        VStack(spacing: 8) {
            // Section header
            HStack {
                Text("// QUEUED_OUTGOING")
                    .font(TerminalTypography.label())
                    .foregroundColor(TerminalPalette.warning)
                Spacer()
                Text("[\(intents.count)]")
                    .font(TerminalTypography.label())
                    .foregroundColor(TerminalPalette.textMuted)
            }

            // Intent cards
            ForEach(intents, id: \.id) { intent in
                OutgoingIntentCard(intent: intent)
            }
        }
    }
}

struct OutgoingIntentCard: View {
    let intent: OutgoingPaymentIntent

    var body: some View {
        HStack(spacing: 12) {
            // Icon
            Text("[→]")
                .font(TerminalTypography.body(14))
                .foregroundColor(statusColor)

            // Details
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("SEND")
                        .font(TerminalTypography.body(12))
                        .foregroundColor(TerminalPalette.textPrimary)

                    statusBadge
                }

                Text("to: \(intent.recipientMetaAddress.prefix(12))...")
                    .font(TerminalTypography.label())
                    .foregroundColor(TerminalPalette.textMuted)
            }

            Spacer()

            // Amount
            Text(String(format: "-%.4f SOL", Double(intent.amount) / 1_000_000_000))
                .font(TerminalTypography.body(12))
                .foregroundColor(statusColor)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 2)
                .fill(TerminalPalette.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(statusColor.opacity(0.5), lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch intent.status {
        case .queued:
            Text("[QUEUED]")
                .font(TerminalTypography.label())
                .foregroundColor(TerminalPalette.warning)
        case .sending:
            Text("[SENDING]")
                .font(TerminalTypography.label())
                .foregroundColor(TerminalPalette.cyan)
        case .confirmed:
            Text("[CONFIRMED]")
                .font(TerminalTypography.label())
                .foregroundColor(TerminalPalette.success)
        case .failed:
            Text("[FAILED]")
                .font(TerminalTypography.label())
                .foregroundColor(TerminalPalette.error)
        }
    }

    private var statusColor: Color {
        switch intent.status {
        case .queued: return TerminalPalette.warning
        case .sending: return TerminalPalette.cyan
        case .confirmed: return TerminalPalette.success
        case .failed: return TerminalPalette.error
        }
    }
}

#Preview {
    ZStack {
        TerminalPalette.background
            .ignoresSafeArea()
        ScanlineOverlay()
            .ignoresSafeArea()
        ActivityView()
    }
}
