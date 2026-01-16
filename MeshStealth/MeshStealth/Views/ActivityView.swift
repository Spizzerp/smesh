import SwiftUI
import StealthCore

// MARK: - Activity Type Filter

enum ActivityTypeFilter: String, CaseIterable {
    case all = "All"
    case shieldUnshield = "Shield"
    case mesh = "Mesh"
    case wallet = "Wallet"

    var icon: String {
        switch self {
        case .all: return "list.bullet"
        case .shieldUnshield: return "eye.slash.fill"
        case .mesh: return "antenna.radiowaves.left.and.right"
        case .wallet: return "wallet.pass.fill"
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

    @Namespace private var filterNamespace
    @State private var showPendingOnly = false
    @State private var selectedTypeFilter: ActivityTypeFilter = .all
    @State private var expandedActivities: Set<UUID> = []

    var body: some View {
        NavigationStack {
            Group {
                if filteredActivities.isEmpty {
                    VStack(spacing: 16) {
                        // Show filter bar even when empty
                        ActivityTypeFilterBar(
                            selectedFilter: $selectedTypeFilter
                        )

                        Spacer()

                        EmptyActivityView(
                            showPendingOnly: showPendingOnly,
                            selectedFilter: selectedTypeFilter
                        )

                        Spacer()
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 16) {
                            // Type filter bar
                            ActivityTypeFilterBar(
                                selectedFilter: $selectedTypeFilter
                            )

                            LazyVStack(spacing: 12) {
                            ForEach(sortedDateKeys, id: \.self) { dateKey in
                                Section {
                                    ForEach(groupedActivities[dateKey] ?? []) { activity in
                                        ActivityCard(
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
                                        Text(dateKey)
                                            .font(.subheadline)
                                            .fontWeight(.semibold)
                                            .foregroundColor(.secondary)
                                        Spacer()
                                    }
                                    .padding(.horizontal, 4)
                                    .padding(.top, dateKey == sortedDateKeys.first ? 0 : 8)
                                }
                            }
                            }
                            .padding(.horizontal)
                        }
                        .padding(.bottom)
                    }
                }
            }
            .navigationTitle("Activity")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    ActivityFilterToggle(showPendingOnly: $showPendingOnly, namespace: filterNamespace)
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

// MARK: - Activity Card

struct ActivityCard: View {
    let activity: ActivityItem
    let childActivities: [ActivityItem]
    let isExpanded: Bool
    let onToggleExpand: () -> Void

    private var hasChildren: Bool {
        !childActivities.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // Main activity row
            HStack(spacing: 12) {
                // Activity type icon
                ZStack {
                    Circle()
                        .fill(iconColor.opacity(0.15))
                        .frame(width: 40, height: 40)

                    Image(systemName: iconName)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(iconColor)
                }

                // Activity details
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(activityTitle)
                            .font(.subheadline)
                            .fontWeight(.medium)

                        if hasChildren {
                            Text("\(childActivities.count) mix\(childActivities.count == 1 ? "" : "es")")
                                .font(.caption2)
                                .fontWeight(.bold)
                                .foregroundColor(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.gray))
                        }
                    }

                    HStack(spacing: 4) {
                        Text(formattedTime)
                            .font(.caption)
                            .foregroundColor(.secondary)

                        if activity.status == .pending {
                            Text("Pending sync")
                                .font(.caption)
                                .foregroundColor(.orange)
                        } else if activity.status == .inProgress {
                            Text("In progress")
                                .font(.caption)
                                .foregroundColor(.blue)
                        } else if activity.status == .failed {
                            Text("Failed")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                }

                Spacer()

                // Amount
                VStack(alignment: .trailing, spacing: 2) {
                    Text(formattedAmount)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(amountColor)

                    if activity.status == .completed,
                       let sig = activity.transactionSignature {
                        Text("\(sig.prefix(6))...")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                // Expand chevron for activities with children
                if hasChildren {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
            }
            .padding()
            .contentShape(Rectangle())
            .onTapGesture {
                if hasChildren {
                    onToggleExpand()
                }
            }

            // Expanded child activities
            if isExpanded && hasChildren {
                Divider()
                    .padding(.horizontal)

                VStack(spacing: 0) {
                    ForEach(Array(childActivities.enumerated()), id: \.element.id) { index, child in
                        ChildActivityRow(activity: child, index: index + 1)
                        if child.id != childActivities.last?.id {
                            Divider()
                                .padding(.leading, 52)
                        }
                    }
                }
                .padding(.bottom, 8)
            }
        }
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var iconName: String {
        switch activity.type {
        case .shield: return "arrow.down.circle.fill"
        case .unshield: return "arrow.up.circle.fill"
        case .meshSend: return "arrow.right.circle.fill"
        case .meshReceive: return "arrow.left.circle.fill"
        case .hop: return "arrow.triangle.2.circlepath"
        case .airdrop: return "drop.circle.fill"
        }
    }

    private var iconColor: Color {
        switch activity.type {
        case .shield: return .blue
        case .unshield: return .green
        case .meshSend: return .orange
        case .meshReceive: return .purple
        case .hop: return .gray
        case .airdrop: return .cyan
        }
    }

    private var activityTitle: String {
        switch activity.type {
        case .shield: return "Shield"
        case .unshield: return "Unshield"
        case .meshSend:
            if let peer = activity.peerName {
                return "Sent to \(peer)"
            }
            return "Sent"
        case .meshReceive:
            if let peer = activity.peerName {
                return "Received from \(peer)"
            }
            return "Received"
        case .hop: return "Mixed"
        case .airdrop: return "Airdrop"
        }
    }

    private var amountColor: Color {
        switch activity.type {
        case .shield, .hop: return .primary
        case .unshield, .meshReceive, .airdrop: return .green
        case .meshSend: return .orange
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

// MARK: - Child Activity Row (for hops)

struct ChildActivityRow: View {
    let activity: ActivityItem
    let index: Int  // Sequential index for display

    var body: some View {
        HStack(spacing: 12) {
            // Smaller icon for child
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.gray)
                .frame(width: 40, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text("Mix \(index)")
                    .font(.caption)
                    .fontWeight(.medium)

                if let sig = activity.transactionSignature {
                    Text("\(sig.prefix(8))...")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()

            Text(String(format: "%.4f SOL", activity.amountInSol))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 6)
    }
}

// MARK: - Empty State

struct EmptyActivityView: View {
    let showPendingOnly: Bool
    var selectedFilter: ActivityTypeFilter = .all

    private var emptyIcon: String {
        if showPendingOnly {
            return "checkmark.circle"
        }
        switch selectedFilter {
        case .all: return "doc.text"
        case .shieldUnshield: return "eye.slash"
        case .mesh: return "antenna.radiowaves.left.and.right"
        case .wallet: return "wallet.pass"
        }
    }

    private var emptyTitle: String {
        if showPendingOnly {
            return "All Synced!"
        }
        switch selectedFilter {
        case .all: return "No Activity Yet"
        case .shieldUnshield: return "No Shield Activity"
        case .mesh: return "No Mesh Transactions"
        case .wallet: return "No Wallet Activity"
        }
    }

    private var emptyMessage: String {
        if showPendingOnly {
            return "All transactions are synced"
        }
        switch selectedFilter {
        case .all: return "Your transaction history will appear here"
        case .shieldUnshield: return "Shield or unshield funds to see activity here"
        case .mesh: return "Send or receive via mesh to see activity here"
        case .wallet: return "Airdrops and other wallet activity will appear here"
        }
    }

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: emptyIcon)
                .font(.system(size: 60))
                .foregroundColor(showPendingOnly ? .green : .secondary)

            VStack(spacing: 8) {
                Text(emptyTitle)
                    .font(.title2)
                    .fontWeight(.bold)

                Text(emptyMessage)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
    }
}

// MARK: - Activity Type Filter Bar

struct ActivityTypeFilterBar: View {
    @Binding var selectedFilter: ActivityTypeFilter

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ActivityTypeFilter.allCases, id: \.self) { filter in
                    ActivityTypeFilterChip(
                        filter: filter,
                        isSelected: selectedFilter == filter
                    ) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            selectedFilter = filter
                        }
                    }
                }
            }
            .padding(.horizontal)
        }
    }
}

struct ActivityTypeFilterChip: View {
    let filter: ActivityTypeFilter
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: filter.icon)
                    .font(.system(size: 12, weight: .semibold))

                Text(filter.rawValue)
                    .font(.subheadline)
                    .fontWeight(.medium)
            }
            .foregroundColor(isSelected ? .white : .secondary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule()
                    .fill(isSelected ? Color.blue : Color(.systemGray5))
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Pending Filter Toggle

struct ActivityFilterToggle: View {
    @Binding var showPendingOnly: Bool
    var namespace: Namespace.ID

    var body: some View {
        GlassEffectContainer(spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "list.bullet")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(showPendingOnly ? .secondary : .white)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
                    .glassEffect()
                    .glassEffectUnion(id: "filter", namespace: namespace)
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showPendingOnly = false
                        }
                    }

                Image(systemName: "clock.badge.exclamationmark")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(showPendingOnly ? .white : .secondary)
                    .frame(width: 36, height: 36)
                    .contentShape(Rectangle())
                    .glassEffect()
                    .glassEffectUnion(id: "filter", namespace: namespace)
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showPendingOnly = true
                        }
                    }
            }
        }
    }
}

#Preview {
    ActivityView()
}
