import AppKit
import SwiftUI
import MacAssistantKit

struct AppCloneView: View {
    @ObservedObject var workspace: WorkspaceStore
    @ObservedObject private var library = MacAppLibraryMonitor.shared
    @State private var source: URL?
    @State private var probe: AppCloneProbe?
    @State private var probeError = ""
    @State private var cloneName = ""
    @State private var displayName = ""
    @State private var bundleID = ""
    @State private var strategy: AppCloneStrategy = .hard
    @State private var injection: AppCloneInjection = .auto
    @State private var placeInUserApplications = true
    @State private var useProxy = false
    @State private var proxy = AppCloneProxy()
    @State private var clones: [AppCloneRecord] = []
    @State private var dropTargeted = false
    @State private var busy = false
    @State private var statusText = ""
    @State private var statusOK: Bool?
    @State private var pendingRemoval: AppCloneRecord?
    @State private var launchError = ""

    private var canCreate: Bool {
        !busy
            && source != nil
            && probe != nil
            && AppCloneService.isValidCloneName(cloneName)
            && AppCloneService.isValidBundleID(bundleID)
            && (!useProxy || AppCloneService.isValidProxy(proxy))
    }

    var body: some View {
        FeatureScaffold(title: L("appcloneview.title"), subtitle: L("appcloneview.subtitle")) {
            PermissionGuideCard(needs: PermissionGuide.appClone)
            HStack(alignment: .top, spacing: 16) {
                MacAppLibraryPane(library: library, selection: $source)
                    .frame(width: 270)

                VStack(alignment: .leading, spacing: 16) {
                    if source != nil {
                        createCard
                        if let probe {
                            recipeCard(probe)
                        }
                    } else {
                        emptyCard
                    }
                    clonesCard
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear { library.ensureLoaded() }
        .onChange(of: library.apps) { _ in
            let known = Set(library.apps + library.extras)
            if let source, known.contains(source) == false {
                self.source = nil
            }
            if source == nil {
                source = library.visibleApps.first
            }
        }
        .onChange(of: source) { newValue in
            statusText = ""
            statusOK = nil
            if let newValue {
                applyProbe(for: newValue)
            } else {
                probe = nil
                probeError = ""
            }
        }
        .task {
            clones = AppCloneService.list()
            applyPendingSource()
        }
        .onChange(of: workspace.pendingAppCloneURL) { _ in
            applyPendingSource()
        }
        .confirmationDialog(
            L("appcloneview.remove.title"),
            isPresented: Binding(
                get: { pendingRemoval != nil },
                set: { if !$0 { pendingRemoval = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(L("appcloneview.remove.appOnly"), role: .destructive) {
                if let pendingRemoval { remove(pendingRemoval, deleteData: false) }
            }
            Button(L("appcloneview.remove.withData"), role: .destructive) {
                if let pendingRemoval { remove(pendingRemoval, deleteData: true) }
            }
            Button(L("appcloneview.cancel"), role: .cancel) {
                pendingRemoval = nil
            }
        } message: {
            if let pendingRemoval {
                Text(L("appcloneview.remove.message", pendingRemoval.displayName, pendingRemoval.dataPath))
            }
        }
        .alert(L("appcloneview.launchFailed"), isPresented: Binding(
            get: { !launchError.isEmpty },
            set: { if !$0 { launchError = "" } }
        )) {
            Button(L("appcloneview.cancel"), role: .cancel) { launchError = "" }
        } message: {
            Text(launchError)
        }
    }

    private var emptyCard: some View {
        Card {
            VStack(spacing: 8) {
                Image(systemName: "app.dashed").font(.title)
                Text(L("appcloneview.noSelection")).font(.headline)
                Text(L("appcloneview.noSelectionDetail"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 220)
            .fileURLDropTarget(isTargeted: $dropTargeted, onDrop: selectDropped)
        }
    }

    private var createCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                if let source {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 12) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: source.path))
                                .resizable()
                                .frame(width: 48, height: 48)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(MacAppLibrary.displayName(of: source))
                                    .font(.title3.weight(.semibold))
                                Text(source.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                            }
                            Spacer(minLength: 0)
                        }
                        HStack(spacing: 8) {
                            Button(L("appcloneview.open")) { open(source, newInstance: false) }
                            Button(L("appcloneview.newInstance")) { open(source, newInstance: true) }
                                .help(L("appcloneview.newInstance.help"))
                            Button(L("appcloneview.reveal")) { revealInFinder(source) }
                            Spacer(minLength: 0)
                        }
                        Text(L("appcloneview.newInstance.hint"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .fileURLDropTarget(isTargeted: $dropTargeted, onDrop: selectDropped)
                }

                if !probeError.isEmpty {
                    Text(probeError).font(.caption).foregroundStyle(.red)
                }

                if probe != nil {
                    Text(L("appcloneview.create.title")).font(.headline)
                    formFields
                    HStack {
                        Button {
                            create()
                        } label: {
                            Label(
                                busy ? L("appcloneview.creating") : L("appcloneview.create"),
                                systemImage: "rectangle.badge.plus"
                            )
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!canCreate)
                        if let statusOK {
                            StatusBadge(ok: statusOK)
                        }
                    }
                    if !statusText.isEmpty {
                        Text(statusText)
                            .font(.caption)
                            .foregroundStyle(statusOK == false ? Color.red : Color.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    private var formFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(L("appcloneview.name"), text: $cloneName)
                .textFieldStyle(.soft)
            TextField(L("appcloneview.displayName"), text: $displayName)
                .textFieldStyle(.soft)
            TextField(L("appcloneview.bundleID"), text: $bundleID)
                .textFieldStyle(.soft)
            Picker(L("appcloneview.strategy"), selection: $strategy) {
                ForEach(AppCloneStrategy.allCases, id: \.self) { item in
                    Text(item.label).tag(item)
                }
            }
            .pickerStyle(.segmented)
            Picker(L("appcloneview.injection"), selection: $injection) {
                ForEach(AppCloneInjection.allCases, id: \.self) { item in
                    Text(item.label).tag(item)
                }
            }
            Toggle(L("appcloneview.placeInApplications"), isOn: $placeInUserApplications)
            Toggle(L("appcloneview.proxy.enable"), isOn: $useProxy)
            if useProxy {
                HStack {
                    Picker(L("appcloneview.proxy.kind"), selection: $proxy.kind) {
                        ForEach(AppCloneProxyKind.allCases, id: \.self) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .frame(width: 140)
                    TextField(L("appcloneview.proxy.host"), text: $proxy.host)
                        .textFieldStyle(.soft)
                    TextField(L("appcloneview.proxy.port"), value: $proxy.port, format: .number)
                        .textFieldStyle(.soft)
                        .frame(width: 80)
                }
            }
        }
    }

    private func recipeCard(_ probe: AppCloneProbe) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text(L("appcloneview.probe.title")).font(.headline)
                labeled(L("appcloneview.probe.app"), probe.info.name)
                labeled(L("appcloneview.probe.bundle"), probe.info.bundleID)
                labeled(L("appcloneview.probe.kind"), probe.kind.label)
                labeled(L("appcloneview.probe.strategy"), probe.recipe.strategy.label)
                labeled(
                    L("appcloneview.probe.recipe"),
                    probe.matchedBuiltin ? probe.recipe.appName : L("appclone.recipe.auto")
                )
                labeled(
                    L("appcloneview.probe.sandbox"),
                    probe.info.hasSandbox ? L("appcloneview.yes") : L("appcloneview.no")
                )
                Text(probe.reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L("appcloneview.footnote"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var clonesCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(L("appcloneview.list.title")).font(.headline)
                    Spacer()
                    Button {
                        clones = AppCloneService.list()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.borderless)
                    .help(L("appcloneview.refresh"))
                }
                if clones.isEmpty {
                    Text(L("appcloneview.list.empty"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(clones) { record in
                        cloneRow(record)
                        if record.id != clones.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
    }

    private func cloneRow(_ record: AppCloneRecord) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: record.cloneExists ? record.clonePath : record.sourcePath))
                .resizable()
                .frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.displayName).font(.callout.weight(.semibold))
                Text("\(record.strategy.label) · \(record.recipeName) · \(record.bundleID)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(record.clonePath)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                if !record.cloneExists {
                    Text(L("appcloneview.missing"))
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
            Spacer(minLength: 8)
            Button(L("appcloneview.open")) { open(record.cloneURL, newInstance: false) }
                .disabled(!record.cloneExists)
            Button(L("appcloneview.reveal")) { revealInFinder(record.cloneURL) }
                .disabled(!record.cloneExists)
            Button(L("appcloneview.update")) { update(record) }
                .disabled(busy || !record.sourceExists)
            Button(L("appcloneview.remove"), role: .destructive) {
                pendingRemoval = record
            }
            .disabled(busy)
        }
        .padding(.vertical, 4)
    }

    private func labeled(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value).font(.callout).textSelection(.enabled)
        }
    }

    private func open(_ app: URL, newInstance: Bool) {
        Task {
            do {
                try await MacAppLaunchService.open(app, newInstance: newInstance)
            } catch {
                launchError = error.localizedDescription
            }
        }
    }

    private func applyPendingSource() {
        guard let pending = workspace.consumePendingAppCloneURL() else { return }
        library.addExtra(pending)
        source = pending
    }

    private func selectDropped(_ url: URL) {
        guard url.pathExtension.lowercased() == "app" else {
            probeError = L("appclone.error.invalidApp")
            return
        }
        library.addExtra(url)
        source = url
    }

    private func applyProbe(for url: URL) {
        do {
            let result = try AppCloneProber.probe(url)
            probe = result
            probeError = ""
            let takenNames = clones.map(\.name)
            let takenIDs = clones.map(\.bundleID)
            cloneName = AppCloneService.suggestedName(for: result.info.name, existing: takenNames)
            displayName = cloneName
            bundleID = AppCloneService.suggestedBundleID(for: result.info.bundleID, existing: takenIDs)
            strategy = result.recipe.strategy
        } catch {
            probe = nil
            probeError = error.localizedDescription
        }
    }

    private func create() {
        guard let source else { return }
        busy = true
        statusText = L("appcloneview.status.creating")
        statusOK = nil
        let request = AppCloneRequest(
            source: source,
            cloneName: cloneName,
            displayName: displayName.isEmpty ? cloneName : displayName,
            bundleID: bundleID,
            strategy: strategy,
            injection: injection,
            proxy: useProxy ? proxy : nil,
            outputDirectory: placeInUserApplications ? AppClonePaths.userApplications : nil
        )
        Task {
            do {
                let record = try await Task.detached(priority: .userInitiated) {
                    try FileSystemHelper.withSecurityScopedAccess(to: [source]) {
                        try AppCloneService.clone(request)
                    }
                }.value
                clones = AppCloneService.list()
                library.addExtra(record.cloneURL)
                cloneName = AppCloneService.suggestedName(for: probe?.info.name ?? record.displayName, existing: clones.map(\.name))
                displayName = cloneName
                bundleID = AppCloneService.suggestedBundleID(
                    for: probe?.info.bundleID ?? record.sourceBundleID,
                    existing: clones.map(\.bundleID)
                )
                statusText = L("appcloneview.status.created", record.displayName)
                statusOK = true
            } catch {
                statusText = error.localizedDescription
                statusOK = false
            }
            busy = false
        }
    }

    private func update(_ record: AppCloneRecord) {
        busy = true
        statusText = L("appcloneview.status.updating")
        statusOK = nil
        Task {
            do {
                let updated = try await Task.detached(priority: .userInitiated) {
                    try AppCloneService.update(id: record.id)
                }.value
                clones = AppCloneService.list()
                statusText = L("appcloneview.status.updated", updated.displayName)
                statusOK = true
            } catch {
                statusText = error.localizedDescription
                statusOK = false
            }
            busy = false
        }
    }

    private func remove(_ record: AppCloneRecord, deleteData: Bool) {
        pendingRemoval = nil
        busy = true
        do {
            try AppCloneService.remove(id: record.id, deleteData: deleteData)
            clones = AppCloneService.list()
            statusText = L("appcloneview.status.removed", record.displayName)
            statusOK = true
        } catch {
            statusText = error.localizedDescription
            statusOK = false
        }
        busy = false
    }
}
