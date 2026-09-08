import SwiftUI
import AppKit
import MacAssistantKit

struct DashboardView: View {
    @ObservedObject var workspace: WorkspaceStore
    @State private var snapshot: SystemSnapshot?
    @State private var cpuFraction: Double?
    @State private var networkRate = NetworkRateSnapshot.empty
    @State private var history: [UsageHistorySample] = []
    @State private var sampler = SystemLiveSampler()
    @State private var live = true

    private let columns = [GridItem(.adaptive(minimum: 230), spacing: 14)]

    var body: some View {
        FeatureScaffold(title: L("dashboard.title"), subtitle: L("dashboard.subtitle")) {
            if let snapshot {
                dashboardBody(snapshot)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 160)
            }
        } trailing: {
            Toggle(isOn: $live) {
                Label(L("dashboard.live"), systemImage: "dot.radiowaves.left.and.right")
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .help(L("dashboard.live.help"))
            Button {
                apply(tick())
            } label: {
                Label(L("dashboard.refresh"), systemImage: "arrow.clockwise")
            }
        }
        .task(id: live) {
            apply(tick())
            if live {
                try? await Task.sleep(nanoseconds: 200_000_000)
                if !Task.isCancelled {
                    apply(tick())
                }
            }
            while live, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { break }
                apply(tick())
            }
        }
    }

    @ViewBuilder
    private func dashboardBody(_ snapshot: SystemSnapshot) -> some View {
        LazyVGrid(columns: columns, spacing: 14) {
            ForEach(snapshot.items) { item in
                infoCard(item)
            }
        }

        Card {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(L("dashboard.usage")).font(.headline)
                    Spacer()
                    Text(live ? L("dashboard.live.on") : L("dashboard.live.off"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                usageBar(
                    title: L("dashboard.cpu"),
                    fraction: cpuFraction ?? 0,
                    text: cpuFraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—",
                    tint: .orange,
                    sparkline: history.compactMap(\.cpuFraction)
                )
                DashboardJumpButton(
                    workspace: workspace,
                    destination: .memory,
                    identifier: "dashboard.link.memory.usage",
                    accessibilityTitle: L("dashboard.memory"),
                    accessibilityValueText: "\(snapshot.memoryUsedText), \(snapshot.memoryPressure.label)"
                ) {
                    usageBar(
                        title: L("dashboard.memory"),
                        fraction: snapshot.memoryUsedFraction,
                        text: snapshot.memoryUsedText,
                        tint: .blue,
                        sparkline: history.map(\.memoryFraction),
                        pressure: snapshot.memoryPressure
                    )
                }
                usageBar(
                    title: L("dashboard.disk"),
                    fraction: snapshot.diskUsedFraction,
                    text: snapshot.diskUsedText,
                    tint: .purple,
                    sparkline: history.map(\.diskFraction),
                    footnote: snapshot.diskPurgeableBytes > 0
                        ? L("dashboard.disk.purgeable", snapshot.diskPurgeableText)
                        : nil
                )

                if snapshot.battery.level != nil || snapshot.battery.state != nil {
                    usageBar(
                        title: L("dashboard.battery"),
                        fraction: snapshot.battery.level ?? 0,
                        text: snapshot.battery.shortText,
                        tint: (snapshot.battery.level ?? 1) < 0.2 ? .red : .green,
                        footnote: snapshot.battery.detailText.isEmpty ? nil : snapshot.battery.detailText
                    )
                }

                HStack {
                    Label(L("dashboard.network"), systemImage: "arrow.up.arrow.down")
                    Spacer()
                    Text(
                        L(
                            "dashboard.network.rates",
                            NetworkService.formatBytesPerSecond(networkRate.bytesInPerSecond),
                            NetworkService.formatBytesPerSecond(networkRate.bytesOutPerSecond)
                        )
                    )
                    .font(.caption.monospacedDigit())
                    .textSelection(.enabled)
                }
                .font(.subheadline.weight(.medium))
                Text(
                    L(
                        "dashboard.network.session",
                        FileSystemHelper.humanReadableSize(Int64(clamping: networkRate.sessionBytesIn)),
                        FileSystemHelper.humanReadableSize(Int64(clamping: networkRate.sessionBytesOut))
                    )
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func infoCard(_ item: InfoItem) -> some View {
        let card = Card {
            HStack(spacing: 12) {
                Image(systemName: item.systemImage)
                    .font(.title2)
                    .frame(width: 34, height: 34)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.label).font(.caption).foregroundStyle(.secondary)
                    Text(item.value).font(.callout.weight(.semibold))
                        .textSelection(.enabled)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
        }
        if let destination = item.destination {
            DashboardJumpButton(
                workspace: workspace,
                destination: destination,
                identifier: "dashboard.link.\(item.id)",
                accessibilityTitle: "\(item.label), \(item.value)"
            ) {
                card
            }
        } else {
            card
        }
    }

    private func usageBar(
        title: String,
        fraction: Double,
        text: String,
        tint: Color,
        sparkline: [Double] = [],
        footnote: String? = nil,
        pressure: MemoryPressureLevel? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(title).font(.subheadline.weight(.medium))
                if let pressure, pressure != .unknown {
                    PressureBadge(level: pressure, color: pressureColor(pressure))
                }
                Spacer(minLength: 8)
                if sparkline.count > 1 {
                    UsageSparkline(values: sparkline, tint: tint)
                }
                Text(text).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Gauge(value: min(1, max(0, fraction))) { EmptyView() }
                .gaugeStyle(.accessoryLinearCapacity)
                .tint(tint)
            if let footnote, !footnote.isEmpty {
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private func pressureColor(_ level: MemoryPressureLevel) -> Color {
        switch level {
        case .healthy: return .green
        case .warning: return .orange
        case .critical: return .red
        case .unknown: return .secondary
        }
    }

    private func tick() -> SystemLiveSample {
        var next = sampler
        let sample = next.tick()
        sampler = next
        return sample
    }

    private func apply(_ sample: SystemLiveSample) {
        snapshot = sample.snapshot
        cpuFraction = sample.cpuFraction
        networkRate = sample.network
        history = sample.history
    }
}

private struct PressureBadge: View {
    let level: MemoryPressureLevel
    let color: Color

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(level.label)
                .font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .foregroundStyle(color)
        .insetSurfaceBackground(
            Capsule(),
            legacyFill: color.opacity(0.12),
            glassFill: AnyShapeStyle(color.opacity(0.22)),
            stroke: color.opacity(0.35)
        )
        .help(L("dashboard.pressure.help"))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L("dashboard.pressure"))
        .accessibilityValue(level.label)
        .accessibilityIdentifier("dashboard.pressure")
    }
}

private struct DashboardJumpButton<Content: View>: View {
    @ObservedObject var workspace: WorkspaceStore
    let destination: AppDestination
    let identifier: String
    var accessibilityTitle: String? = nil
    var accessibilityValueText: String? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        Button {
            workspace.request(destination)
        } label: {
            content()
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                NSCursor.pointingHand.push()
            } else {
                NSCursor.pop()
            }
        }
        .help(L("root.accessibility.open", destination.sidebarItem.title))
        .accessibilityLabel(accessibilityTitle ?? destination.sidebarItem.title)
        .accessibilityValue(accessibilityValueText ?? "")
        .accessibilityHint(L("root.accessibility.open", destination.sidebarItem.title))
        .accessibilityIdentifier(identifier)
    }
}
