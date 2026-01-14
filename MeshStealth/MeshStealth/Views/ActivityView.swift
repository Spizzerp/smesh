import SwiftUI
import StealthCore

struct ActivityView: View {
    @EnvironmentObject var walletViewModel: WalletViewModel
    @EnvironmentObject var meshViewModel: MeshViewModel

    @Namespace private var filterNamespace
    @State private var showPendingOnly = false
    @State private var expandedActivities: Set<UUID> = []

    var body: some View {
        NavigationStack {
            Group {
                if filteredActivities.isEmpty {
                    EmptyActivityView(showPendingOnly: showPendingOnly)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(groupedActivities.keys.sorted().reversed(), id: \.self) { dateKey in
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
                                    .padding(.top, dateKey == groupedActivities.keys.sorted().reversed().first ? 0 : 8)
                                }
                            }
                        }
                        .padding(.horizontal)
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

    /// Activities filtered by pending toggle, excluding child activities (hops with parents)
    private var filteredActivities: [ActivityItem] {
        let baseActivities = walletViewModel.activityItems.filter { !$0.isChildActivity }
        if showPendingOnly {
            return baseActivities.filter { $0.needsSync }
        }
        return baseActivities
    }

    /// Get child activities (hops) for a parent activity
    private func childActivities(for parentId: UUID) -> [ActivityItem] {
        walletViewModel.activityItems.filter { $0.parentActivityId == parentId }
    }

    private var groupedActivities: [String: [ActivityItem]] {
        Dictionary(grouping: filteredActivities) { activity in
            formatDateGroup(activity.timestamp)
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

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: showPendingOnly ? "checkmark.circle" : "doc.text")
                .font(.system(size: 60))
                .foregroundColor(showPendingOnly ? .green : .secondary)

            VStack(spacing: 8) {
                Text(showPendingOnly ? "All Synced!" : "No Activity Yet")
                    .font(.title2)
                    .fontWeight(.bold)

                Text(showPendingOnly
                     ? "All transactions are synced"
                     : "Your transaction history will appear here")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
    }
}

// MARK: - Filter Toggle

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
