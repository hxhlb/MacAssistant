import SwiftUI
import MacAssistantKit

struct RecipesView: View {
    @ObservedObject var workspace: WorkspaceStore
    @State private var query = ""
    @State private var runningID: String?
    @State private var resultText = ""
    @State private var resultOK: Bool?

    private var filtered: [ShellRecipe] {
        RecipeLibrary.search(query)
    }

    private var grouped: [(String, [ShellRecipe])] {
        let dict = Dictionary(grouping: filtered, by: \.categoryID)
        return RecipeLibrary.categoryIDs.compactMap { categoryID in
            guard let items = dict[categoryID], let first = items.first else { return nil }
            return (first.category, items)
        }
    }

    var body: some View {
        FeatureScaffold(title: L("recipesview.title"), subtitle: L("recipesview.subtitle")) {
            if !resultText.isEmpty {
                Card {
                    HStack(alignment: .top) {
                        StatusBadge(ok: resultOK)
                        Text(resultText.isEmpty ? "—" : resultText)
                            .font(.footnote.monospaced()).textSelection(.enabled)
                        Spacer()
                        Button { resultText = ""; resultOK = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                    }
                }
            }

            if grouped.isEmpty {
                Card {
                    Text(L("recipesview.empty"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(grouped, id: \.0) { category, items in
                VStack(alignment: .leading, spacing: 8) {
                    Text(category).font(.headline).foregroundStyle(.tint)
                    ForEach(items) { recipe in
                        RecipeRow(recipe: recipe,
                                  running: runningID == recipe.id,
                                  onRun: { run(recipe) })
                    }
                }
            }
        }
        .searchable(text: $query, placement: .toolbar, prompt: L("recipesview.searchPrompt"))
        .task {
            applyPendingSearch()
        }
        .onChange(of: workspace.pendingSearchQuery) { _ in
            applyPendingSearch()
        }
    }

    private func applyPendingSearch() {
        guard let pending = workspace.consumePendingSearchQuery(), !pending.isEmpty else { return }
        query = pending
    }

    private func run(_ recipe: ShellRecipe) {
        runningID = recipe.id
        resultText = ""
        resultOK = nil
        let r = recipe
        DispatchQueue.global(qos: .userInitiated).async {
            let result = try? RecipeLibrary.run(r)
            DispatchQueue.main.async {
                resultOK = result?.succeeded ?? false
                resultText = (result?.combinedOutput.isEmpty ?? true)
                    ? L("recipesview.executed", r.name)
                    : (result?.combinedOutput ?? "")
                runningID = nil
            }
        }
    }
}

private struct RecipeRow: View {
    let recipe: ShellRecipe
    let running: Bool
    let onRun: () -> Void

    var body: some View {
        Card(padding: 12) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(recipe.name).font(.callout.weight(.semibold))
                        if recipe.needsSudo {
                            tag(L("recipesview.tag.password"), color: .orange)
                        }
                        if recipe.dangerous {
                            tag(L("recipesview.tag.careful"), color: .red)
                        }
                    }
                    Text(recipe.detail).font(.caption).foregroundStyle(.secondary)
                    Text(recipe.command).font(.caption2.monospaced()).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                CopyButton(text: recipe.command)
                if recipe.needsSudo {
                    Text(L("recipesview.copyToRun")).font(.caption).foregroundStyle(.secondary)
                } else {
                    Button(action: onRun) {
                        Label(running ? L("recipesview.running") : L("recipesview.run"), systemImage: "play.fill")
                    }
                    .disabled(running)
                }
            }
        }
    }

    private func tag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }
}
