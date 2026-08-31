import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MacAssistantKit

/// 使用项目自有纯 Swift 引擎提取 Objective-C 声明；外部 CLI 仅为用户主动启用的增强。
/// 结果与日志存在上层传入的 `ClassDumpSession` 里，本 View 被侧栏/tab 拆掉后仍能还原。
struct ClassDumpTab: View {
    @ObservedObject var session: ClassDumpSession
    @State private var dropTargeted = false

    private var externalAvailable: Bool {
        ExternalTool.classDump.isAvailable || ExternalTool.dsdump.isAvailable
    }

    var body: some View {
        Group {
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("Class Dump", systemImage: "curlybraces.square")
                            .font(.headline)
                        Spacer()
                        Label(
                            externalAvailable ? L("classdumptab.engine.enhanced") : L("classdumptab.engine.builtIn"),
                            systemImage: externalAvailable ? "checkmark.circle" : "testtube.2"
                        )
                            .font(.caption)
                            .foregroundStyle(.green)
                    }
                    Text(L("classdumptab.intro"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    inputDropZone
                }
            }

            if session.inspecting {
                ProgressView(L("classdumptab.inspecting"))
                    .controlSize(.small)
            } else if let facts = session.facts {
                factsCard(facts)
            }

            Card {
                VStack(alignment: .leading, spacing: 12) {
                    Text(L("classdumptab.exportSettings")).font(.headline)
                    HStack {
                        FilePickerButton(
                            title: L("classdumptab.chooseOutput"),
                            systemImage: "folder",
                            chooseDirectory: true
                        ) { session.outputDirectory = $0 }
                        PathBadge(url: session.outputDirectory, placeholder: L("classdumptab.noOutput"))
                    }

                    HStack {
                        Text(L("classdumptab.architecture"))
                            .frame(width: 110, alignment: .leading)
                        TextField(L("classdumptab.architecture.placeholder"), text: $session.archText)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 300)
                        Spacer()
                    }

                    Toggle(L("classdumptab.allowExternal"), isOn: $session.allowExternalEnhancement)
                        .disabled(!externalAvailable)
                        .accessibilityHint(L("classdumptab.allowExternal.hint"))
                    if !externalAvailable {
                        Text(L("classdumptab.noExternal"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Button {
                dump()
            } label: {
                Label(session.busy ? L("classdumptab.exporting") : L("classdumptab.export"), systemImage: "square.and.arrow.down")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(
                session.busy
                    || session.inputURLs.isEmpty
                    || session.outputDirectory == nil
                    || (session.inputURLs.count == 1 && session.facts?.isEncrypted == true)
            )
            .accessibilityIdentifier("classdump.export")

            if session.busy || !session.log.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(L("classdumptab.summary")).font(.headline)
                            if session.busy { ProgressView().controlSize(.small) }
                            Spacer()
                            StatusBadge(ok: session.ok)
                        }
                        ConsoleView(text: session.log, minHeight: 90)
                    }
                }
            }

            if !session.headers.isEmpty {
                Card {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(L("classdumptab.preview")).font(.headline)
                            Spacer()
                            CopyButton(text: session.headers)
                        }
                        ConsoleView(text: String(session.headers.prefix(10_000)), minHeight: 220)
                    }
                }
            }
        }
    }

    private var inputDropZone: some View {
        VStack(spacing: 8) {
            Image(systemName: "square.and.arrow.down")
                .font(.largeTitle)
            Text(L("classdumptab.drop.title"))
                .font(.headline)
            Text(L("classdumptab.drop.hint"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if !session.inputURLs.isEmpty {
                Divider().padding(.vertical, 2)
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("classdumptab.selectedCount", session.inputURLs.count))
                        .font(.caption.weight(.medium))
                    ForEach(Array(session.inputURLs.enumerated()), id: \.element.path) { index, url in
                        HStack(spacing: 8) {
                            Text("\(index + 1)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 18, alignment: .trailing)
                            PathBadge(url: url)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 120)
        .foregroundStyle(dropTargeted ? Color.accentColor : .primary)
        .contentShape(Rectangle())
        .insetSurfaceBackground(
            RoundedRectangle(cornerRadius: 12),
            legacyFill: Color.primary.opacity(dropTargeted ? 0.10 : 0.04)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    dropTargeted ? Color.accentColor : Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: 1.5, dash: [7])
                )
        }
        .fileURLsDropTarget(isTargeted: $dropTargeted, onDrop: selectInputs)
        .onTapGesture { pickInputs() }
        .onHover { hovering in
            if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .help(L("classdumptab.drop.help"))
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(L("classdumptab.drop.title"))
        .accessibilityHint(L("classdumptab.drop.help"))
        .accessibilityAction { pickInputs() }
    }

    private func factsCard(_ facts: MachOFacts) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    facts.isEncrypted ? L("classdumptab.encrypted") : L("classdumptab.inspected"),
                    systemImage: facts.isEncrypted ? "lock.fill" : "checkmark.shield"
                )
                .font(.headline)
                .foregroundStyle(facts.isEncrypted ? .red : .primary)
                HStack(spacing: 16) {
                    fact(L("classdumptab.fact.arch"), facts.archs.joined(separator: ", "))
                    fact("Chained Fixups", facts.hasChainedFixups ? L("classdumptab.yes") : L("classdumptab.no"))
                    fact(L("classdumptab.fact.swift"), facts.hasSwift ? L("classdumptab.yes") : L("classdumptab.no"))
                    fact(L("classdumptab.fact.builtIn"), facts.nativeObjCDumpSupported ? L("classdumptab.supported") : L("classdumptab.limited"))
                }
                if facts.isEncrypted {
                    Text(L("classdumptab.encrypted.detail"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if !facts.nativeObjCDumpSupported {
                    Text(
                        externalAvailable
                            ? L("classdumptab.limited.detail.external")
                            : L("classdumptab.limited.detail")
                    )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("classdump.facts")
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption.monospacedDigit())
        }
    }

    private func pickInputs() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.item]
        panel.allowsOtherFileTypes = true
        panel.prompt = L("theme.chooseFile")
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        selectInputs(panel.urls)
    }

    private func selectInputs(_ urls: [URL]) {
        let unique = urls.reduce(into: [URL]()) { result, url in
            if !result.contains(where: { $0.standardizedFileURL.path == url.standardizedFileURL.path }) {
                result.append(url)
            }
        }
        guard let first = unique.first else { return }
        session.inputURLs = unique
        session.outputDirectory = unique.count == 1
            ? first.deletingLastPathComponent()
                .appendingPathComponent(first.deletingPathExtension().lastPathComponent + "-Headers")
            : first.deletingLastPathComponent()
        session.headers = ""
        session.log = ""
        session.ok = nil
        session.facts = nil
        guard unique.count == 1 else {
            session.inspecting = false
            return
        }
        session.inspecting = true
        Task {
            do {
                session.facts = try await Task.detached {
                    try FileSystemHelper.withSecurityScopedAccess(to: [first]) {
                        try ClassDumpService.inspect(fileAt: first)
                    }
                }.value
            } catch {
                session.log = error.localizedDescription
                session.ok = false
            }
            session.inspecting = false
        }
    }

    private func dump() {
        guard !session.inputURLs.isEmpty, let outputDirectory = session.outputDirectory else { return }
        let inputs = session.inputURLs
        let arch = session.archText.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowExternal = session.allowExternalEnhancement
        session.busy = true
        session.ok = nil
        session.log = inputs.count == 1
            ? L("classdumptab.selectingEngine")
            : L("classdumptab.batch.start", inputs.count)
        session.headers = ""

        Task {
            var succeeded = 0
            var failed = 0
            var destinations: [URL] = []
            var lines: [String] = inputs.count == 1 ? [] : [L("classdumptab.batch.start", inputs.count)]

            for (index, inputURL) in inputs.enumerated() {
                let destination = resolvedOutputDirectory(
                    selected: outputDirectory,
                    input: inputURL,
                    isBatch: inputs.count > 1
                )
                if inputs.count > 1 {
                    lines.append(L("classdumptab.batch.processing", index + 1, inputs.count, inputURL.lastPathComponent))
                    session.log = lines.joined(separator: "\n")
                }
                do {
                    let pair = try await Task.detached {
                        try FileSystemHelper.withSecurityScopedAccess(to: [inputURL, outputDirectory]) {
                        let result = try ClassDumpService.dump(
                            fileAt: inputURL,
                            arch: arch.isEmpty ? nil : arch,
                            preferExternal: false,
                            allowExternalFallback: allowExternal
                        )
                        let summary = try ClassDumpService.export(
                            result,
                            to: destination,
                            baseName: inputURL.deletingPathExtension().lastPathComponent,
                            mode: .oneFilePerClass
                        )
                        return (result, summary)
                    }
                    }.value
                    session.headers = pair.0.headers
                    succeeded += 1
                    destinations.append(destination)
                    let engine = pair.0.usedExternalTool
                        .map { L("classdumptab.engine.external", $0.commandName) }
                        ?? L("classdumptab.engine.native")
                    let capability = pair.0.capabilityReport
                    if inputs.count == 1 {
                        lines = resultLines(
                            result: pair.0,
                            fileCount: pair.1.files.count,
                            destination: destination,
                            engine: engine,
                            warnings: pair.1.warnings
                        )
                    } else {
                        lines.append(L(
                            "classdumptab.batch.success",
                            inputURL.lastPathComponent,
                            capability.exportedClassCount,
                            pair.1.files.count,
                            destination.path
                        ))
                        lines.append(contentsOf: capability.skipReasons.map { "⚠️ \($0)" })
                        lines.append(contentsOf: pair.1.warnings.map { "⚠️ \($0)" })
                    }
                } catch {
                    failed += 1
                    if inputs.count == 1 {
                        lines = ["❌ \(error.localizedDescription)"]
                    } else {
                        lines.append(L("classdumptab.batch.failure", inputURL.lastPathComponent, error.localizedDescription))
                    }
                }
                session.log = lines.joined(separator: "\n")
            }

            if inputs.count > 1 {
                lines.append(L("classdumptab.batch.done", succeeded, failed))
                session.log = lines.joined(separator: "\n")
            }
            session.ok = failed == 0
            if let revealURL = inputs.count == 1 ? destinations.first : (succeeded > 0 ? outputDirectory : nil) {
                revealInFinder(revealURL)
            }
            session.busy = false
        }
    }

    private func resultLines(
        result: HeaderDumpResult,
        fileCount: Int,
        destination: URL,
        engine: String,
        warnings: [String]
    ) -> [String] {
        let capability = result.capabilityReport
        var lines = [
            L("classdumptab.result.done", engine, capability.completeness.rawValue),
            L("classdumptab.result.classes", capability.discoveredClassCount, capability.exportedClassCount),
            L("classdumptab.result.members", capability.methodCount, capability.propertyCount, capability.protocolCount),
            L("classdumptab.result.coverage", capability.skippedCount, Int(capability.coverage * 100)),
            L("classdumptab.result.files", fileCount),
            L("classdumptab.result.directory", destination.path)
        ]
        lines.append(contentsOf: capability.skipReasons.map { "⚠️ \($0)" })
        lines.append(contentsOf: warnings.map { "⚠️ \($0)" })
        return lines
    }

    private func resolvedOutputDirectory(selected: URL, input: URL, isBatch: Bool) -> URL {
        if isBatch {
            let base = ClassDumpService.safeHeaderFileName(
                input.deletingPathExtension().lastPathComponent
            ) + "-Headers"
            return FileSystemHelper.uniqueOutputURL(
                basedOn: selected.appendingPathComponent(base, isDirectory: true)
            )
        }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: selected.path,
            isDirectory: &isDirectory
        )
        if !exists {
            return selected
        }
        if isDirectory.boolValue,
           let contents = try? FileManager.default.contentsOfDirectory(atPath: selected.path),
           contents.isEmpty {
            return selected
        }

        let base = ClassDumpService.safeHeaderFileName(
            input.deletingPathExtension().lastPathComponent
        ) + "-Headers"
        return FileSystemHelper.uniqueOutputURL(
            basedOn: selected.appendingPathComponent(base, isDirectory: true)
        )
    }
}
