import SwiftUI
import MacAssistantKit

struct CheatsheetView: View {
    @ObservedObject var workspace: WorkspaceStore
    @State private var query = ""
    @State private var selectedCategory: String?
    @State private var selectedRisk: RiskLevel?
    @State private var selectedCommandID: String?
    @FocusState private var searchFocused: Bool

    /// 搜索 + 风险下的全部命中,不受当前分类限制,给侧栏计数用。
    private var scopedMatches: [CommandEntry] {
        CommandLibrary.search(query, risk: selectedRisk)
    }

    private var results: [CommandEntry] {
        CommandLibrary.search(query, risk: selectedRisk, category: selectedCategory)
    }

    private var grouped: [(String, [CommandEntry])] {
        let groups = Dictionary(grouping: results, by: \.category)
        return CommandLibrary.categories.compactMap { category in
            groups[category].map { (category, $0) }
        }
    }

    private var selectedCommand: CommandEntry? {
        results.first { $0.id == selectedCommandID }
    }

    private var hasFilters: Bool {
        !query.isEmpty || selectedCategory != nil || selectedRisk != nil
    }

    private var selectedRiskName: String {
        selectedRisk?.label ?? L("cheatsheet.all")
    }

    private var categoryCounts: [String: Int] {
        Dictionary(grouping: scopedMatches, by: \.category).mapValues(\.count)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                categorySidebar
                    .frame(width: 214)
                Divider()
                if results.isEmpty {
                    emptyState
                } else {
                    commandList
                }
            }
        }
        .featureSurfaceBackground()
        .onSubmit(of: .text) {
            selectedCommandID = results.first?.id
        }
        .background(focusSearchShortcut)
        .task {
            applyPendingSearch()
        }
        .onChange(of: workspace.pendingSearchQuery) { _ in
            applyPendingSearch()
        }
        .onChange(of: query) { _ in
            pruneEmptyCategory()
            dropStaleSelection()
        }
        .onChange(of: selectedRisk) { _ in
            pruneEmptyCategory()
            dropStaleSelection()
        }
        .onChange(of: selectedCategory) { _ in
            dropStaleSelection()
        }
        .toolbar {
            ToolbarItem {
                copySelectedButton
            }
        }
    }

    @ViewBuilder
    private var copySelectedButton: some View {
        let button = Button {
            if let selectedCommand {
                copyToClipboard(selectedCommand.command)
            }
        } label: {
            Label(L("cheatsheet.copySelected"), systemImage: "doc.on.doc")
        }
        .disabled(selectedCommand == nil)
        .help(L("cheatsheet.copySelected.help"))
        .accessibilityIdentifier("cheatsheet.copySelected")

        if searchFocused {
            button
        } else {
            button.keyboardShortcut("c", modifiers: [.command])
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            searchField
            HStack(alignment: .center, spacing: 10) {
                riskChips
                    .layoutPriority(1)
                Spacer(minLength: 8)
                Text(L("cheatsheet.resultCount", results.count))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .accessibilityLabel(L("cheatsheet.resultCount.accessibility", results.count))
                    .accessibilityIdentifier("cheatsheet.resultsCount")
                if hasFilters {
                    Button(L("cheatsheet.clearFilters")) {
                        clearFilters()
                    }
                    .buttonStyle(.borderless)
                    .fixedSize()
                    .accessibilityHint(L("cheatsheet.clearFilters.hint"))
                    .accessibilityIdentifier("cheatsheet.resetFilters")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(L("cheatsheet.searchPrompt"), text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .accessibilityLabel(L("cheatsheet.search.accessibility"))
                .accessibilityIdentifier("cheatsheet.search")
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("cheatsheet.clearSearch"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .insetSurfaceBackground(
            RoundedRectangle(cornerRadius: 9, style: .continuous),
            legacyFill: Color.primary.opacity(0.06)
        )
        .help(L("cheatsheet.search.help"))
    }

    private var riskChips: some View {
        HStack(spacing: 6) {
            riskChip(nil, title: L("cheatsheet.all"))
            ForEach(RiskLevel.allCases, id: \.self) { risk in
                riskChip(risk, title: risk.label)
            }
        }
        .help(L("cheatsheet.risk.help", selectedRiskName))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("cheatsheet.risk.accessibility", selectedRiskName))
        .accessibilityIdentifier("cheatsheet.riskFilter")
    }

    private func riskChip(_ risk: RiskLevel?, title: String) -> some View {
        let selected = selectedRisk == risk
        return Button {
            selectedRisk = risk
        } label: {
            HStack(spacing: 5) {
                if let risk {
                    Circle()
                        .fill(risk.color)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                }
                Text(title)
                    .font(.caption.weight(selected ? .semibold : .regular))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.appAccent : Color.secondary)
        .background {
            Capsule()
                .fill(selected ? Color.appAccent.opacity(0.12) : Color.primary.opacity(0.04))
        }
        .overlay {
            Capsule()
                .strokeBorder(selected ? Color.appAccent.opacity(0.28) : Color.primary.opacity(0.08), lineWidth: 1)
        }
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier(risk.map { "cheatsheet.risk.\($0.rawValue)" } ?? "cheatsheet.risk.all")
    }

    private var categorySidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("cheatsheet.categories"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.top, 10)
                    .padding(.bottom, 4)

                categoryRow(
                    id: nil,
                    title: L("cheatsheet.allCategories"),
                    count: scopedMatches.count,
                    identifier: "all"
                )

                ForEach(CommandLibrary.categories, id: \.self) { category in
                    categoryRow(
                        id: category,
                        title: CommandLibrary.localizedCategory(category),
                        count: categoryCounts[category] ?? 0,
                        identifier: CommandLibrary.categorySlug(category) ?? category
                    )
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 10)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cheatsheet.categoryFilter")
    }

    private func categoryRow(id: String?, title: String, count: Int, identifier: String) -> some View {
        let selected = selectedCategory == id
        let enabled = count > 0 || id == nil
        return Button {
            selectedCategory = id
        } label: {
            HStack(spacing: 8) {
                Text(title)
                    .font(.callout.weight(selected ? .medium : .regular))
                    .foregroundStyle(selected ? Color.appAccent : (enabled ? Color.primary : Color.secondary))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                Text("\(count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(selected ? Color.appAccent : Color.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.appAccent.opacity(0.12) : Color.clear)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(selected ? Color.appAccent.opacity(0.18) : Color.clear)
            }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .help(L("cheatsheet.category.help", title))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityLabel(L("cheatsheet.section.accessibility", title, count))
        .accessibilityIdentifier("cheatsheet.category.\(identifier)")
    }

    private var commandList: some View {
        List(selection: $selectedCommandID) {
            ForEach(grouped, id: \.0) { category, commands in
                Section {
                    ForEach(commands) { command in
                        CommandRow(command: command)
                            .tag(command.id)
                            .sceneListRowFill()
                    }
                } header: {
                    HStack(spacing: 6) {
                        Text(CommandLibrary.localizedCategory(category))
                        Text("\(commands.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(L(
                        "cheatsheet.section.accessibility",
                        CommandLibrary.localizedCategory(category),
                        commands.count
                    ))
                }
            }
        }
        .listStyle(.inset)
        .sceneListChrome()
        .id("\(selectedCategory ?? "all")-\(selectedRisk?.rawValue ?? "all")")
        .accessibilityIdentifier("cheatsheet.results")
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "text.magnifyingglass")
                .font(.title)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(L("cheatsheet.empty.title"))
                .font(.headline)
            Text(L("cheatsheet.empty.detail"))
                .font(.callout)
                .foregroundStyle(.secondary)
            Button(L("cheatsheet.empty.reset")) {
                clearFilters()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cheatsheet.emptyState")
    }

    private var focusSearchShortcut: some View {
        Button(action: { searchFocused = true }) {
            Color.clear
                .frame(width: 1, height: 1)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("f", modifiers: .command)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func clearFilters() {
        query = ""
        selectedCategory = nil
        selectedRisk = nil
        selectedCommandID = nil
    }

    private func pruneEmptyCategory() {
        guard let selectedCategory else { return }
        if (categoryCounts[selectedCategory] ?? 0) == 0 {
            self.selectedCategory = nil
        }
    }

    private func dropStaleSelection() {
        if let selectedCommandID, !results.contains(where: { $0.id == selectedCommandID }) {
            self.selectedCommandID = nil
        }
    }

    private func applyPendingSearch() {
        guard let pending = workspace.consumePendingSearchQuery(), !pending.isEmpty else { return }
        query = pending
        selectedCategory = nil
        selectedRisk = nil
        selectedCommandID = CommandLibrary.search(pending).first?.id
        searchFocused = true
    }
}

private struct CommandRow: View {
    let command: CommandEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(command.title)
                    .font(.callout.weight(.medium))
                CommandRiskLabel(risk: command.risk)
                Spacer(minLength: 8)
                CopyButton(text: command.command, label: L("theme.copy"))
                    .labelStyle(.iconOnly)
                    .accessibilityLabel(L("cheatsheet.copy.accessibility", command.title))
                    .accessibilityHint(L("cheatsheet.copy.hint"))
                    .help(L("cheatsheet.copy.help"))
            }

            Text(command.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(command.command)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .insetSurfaceBackground(
                    RoundedRectangle(cornerRadius: 5),
                    legacyFill: Color(nsColor: .textBackgroundColor).opacity(0.7)
                )
                .accessibilityLabel(L("cheatsheet.command.accessibility", command.command))

            if let note = command.versionNote {
                Label(note, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .accessibilityLabel(L("cheatsheet.versionNote.accessibility", note))
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("cheatsheet.row.\(command.id)")
    }
}

private struct CommandRiskLabel: View {
    let risk: RiskLevel

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(risk.color)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(risk.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("cheatsheet.risk.help", risk.label))
    }
}
