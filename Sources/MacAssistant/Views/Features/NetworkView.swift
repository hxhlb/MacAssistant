import SwiftUI
import MacAssistantKit

struct NetworkView: View {
    @State private var interfaces = NetworkService.localInterfaces()
    @State private var ports: [ListeningPort] = []
    @State private var portFilter = ""
    @State private var lookedUp: [PortProcess] = []
    @State private var lookingUp = false
    @State private var publicIP = L("networkview.tapToFetch")
    @State private var loadingPublic = false
    @State private var pingHost = "apple.com"
    @State private var pingOutput = ""
    @State private var pinging = false
    @StateObject private var task = TaskState()
    @State private var sampler = SystemLiveSampler()
    @State private var rate = NetworkRateSnapshot.empty

    var body: some View {
        FeatureScaffold(title: L("networkview.title"), subtitle: L("networkview.subtitle")) {
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("networkview.liveRates")).font(.headline)
                    HStack(spacing: 16) {
                        rateColumn(L("networkview.down"), NetworkService.formatBytesPerSecond(rate.bytesInPerSecond))
                        rateColumn(L("networkview.up"), NetworkService.formatBytesPerSecond(rate.bytesOutPerSecond))
                    }
                    Text(
                        L(
                            "networkview.session",
                            FileSystemHelper.humanReadableSize(Int64(clamping: rate.sessionBytesIn)),
                            FileSystemHelper.humanReadableSize(Int64(clamping: rate.sessionBytesOut))
                        )
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    if !rate.interfaces.isEmpty {
                        ForEach(rate.interfaces) { iface in
                            HStack {
                                Text(iface.name).frame(width: 72, alignment: .leading)
                                Text(NetworkService.formatBytesPerSecond(iface.bytesInPerSecond))
                                    .font(.caption.monospacedDigit())
                                Text("↓")
                                Text(NetworkService.formatBytesPerSecond(iface.bytesOutPerSecond))
                                    .font(.caption.monospacedDigit())
                                Text("↑")
                                Spacer()
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("networkview.localIP")).font(.headline)
                    if interfaces.isEmpty {
                        Text(L("networkview.noInterfaces")).foregroundStyle(.secondary)
                    }
                    ForEach(interfaces) { iface in
                        HStack {
                            Label(iface.name, systemImage: "cable.connector").frame(width: 120, alignment: .leading)
                            Text(iface.ipv4).font(.callout.monospaced()).textSelection(.enabled)
                            Spacer()
                            CopyButton(text: iface.ipv4)
                        }
                    }
                    Divider()
                    HStack {
                        Label(L("networkview.publicIP"), systemImage: "globe").frame(width: 130, alignment: .leading)
                        Text(publicIP).font(.callout.monospaced()).textSelection(.enabled)
                        Spacer()
                        Button {
                            loadingPublic = true
                            DispatchQueue.global().async {
                                let ip = NetworkService.publicIP() ?? L("networkview.fetchFailed")
                                DispatchQueue.main.async { publicIP = ip; loadingPublic = false }
                            }
                        } label: {
                            Label(loadingPublic ? L("networkview.fetching") : L("networkview.fetch"), systemImage: "arrow.down.circle")
                        }.disabled(loadingPublic)
                    }
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(L("networkview.listeningPorts")).font(.headline)
                        Spacer()
                        Button {
                            refreshPorts()
                        } label: { Label(L("networkview.refresh"), systemImage: "arrow.clockwise") }
                    }
                    Text(L("networkview.ports.detail"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    HStack {
                        TextField(L("networkview.port.placeholder"), text: $portFilter)
                            .textFieldStyle(.soft)
                            .frame(maxWidth: 200)
                        Button { lookupPort() } label: {
                            Label(
                                lookingUp ? L("networkview.port.querying") : L("networkview.port.query"),
                                systemImage: "magnifyingglass"
                            )
                        }
                        .disabled(lookingUp || parsedPort == nil)
                    }
                    if displayedPorts.isEmpty && extraLookup.isEmpty {
                        Text(portsEmptyText).foregroundStyle(.secondary)
                    } else {
                        ForEach(displayedPorts) { port in
                            portRow(
                                command: port.command,
                                pid: port.pid,
                                detail: "\(port.node)  \(port.name)"
                            )
                        }
                        ForEach(extraLookup) { proc in
                            portRow(
                                command: proc.command,
                                pid: proc.pid,
                                detail: L("networkview.port.notListening")
                            )
                        }
                    }
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("networkview.ping")).font(.headline)
                    HStack {
                        TextField(L("networkview.ping.placeholder"), text: $pingHost).textFieldStyle(.soft)
                        Button {
                            pinging = true
                            pingOutput = ""
                            let host = pingHost
                            DispatchQueue.global().async {
                                let out = (try? NetworkService.ping(host: host))?.combinedOutput ?? L("networkview.pingFailed")
                                DispatchQueue.main.async { pingOutput = out; pinging = false }
                            }
                        } label: { Label(pinging ? L("networkview.pinging") : L("networkview.start"), systemImage: "dot.radiowaves.left.and.right") }
                            .disabled(pinging || pingHost.isEmpty)
                    }
                    if !pingOutput.isEmpty { ConsoleView(text: pingOutput, minHeight: 120) }
                }
            }

            Card {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(L("networkview.flushDNS")).font(.headline)
                        Spacer()
                        Button {
                            flushDNS()
                        } label: {
                            Label(L("networkview.flushDNS.action"), systemImage: "arrow.clockwise")
                        }
                        .disabled(task.running)
                    }
                    Text(L("networkview.flushDNS.detail")).font(.footnote).foregroundStyle(.secondary)
                    HStack {
                        Text(NetworkService.flushDNSCommand)
                            .font(.footnote.monospaced()).textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .insetSurfaceBackground(RoundedRectangle(cornerRadius: 8), legacyFill: .primary.opacity(0.05))
                        CopyButton(text: NetworkService.flushDNSCommand)
                    }
                    if task.running || !task.log.isEmpty {
                        HStack(alignment: .top) {
                            if task.running { ProgressView().controlSize(.small) }
                            StatusBadge(ok: task.ok)
                            Text(task.log.isEmpty ? "…" : task.log)
                                .font(.footnote.monospaced())
                                .textSelection(.enabled)
                            Spacer()
                        }
                    }
                }
            }
        } trailing: {
            Button {
                interfaces = NetworkService.localInterfaces()
                refreshPorts()
                tickRates()
            } label: { Label(L("networkview.refresh"), systemImage: "arrow.clockwise") }
        }
        .task {
            refreshPorts()
            tickRates()
            try? await Task.sleep(nanoseconds: 200_000_000)
            tickRates()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled else { break }
                tickRates()
            }
        }
    }

    private func rateColumn(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.title3.monospacedDigit().weight(.semibold))
                .textSelection(.enabled)
        }
    }

    private var parsedPort: Int? {
        guard let port = Int(portFilter.trimmingCharacters(in: .whitespaces)), (1...65535).contains(port) else {
            return nil
        }
        return port
    }

    private var displayedPorts: [ListeningPort] {
        guard let port = parsedPort else { return ports }
        return ports.filter { $0.refers(to: port) }
    }

    private var extraLookup: [PortProcess] {
        let listening = Set(displayedPorts.map(\.pid))
        return lookedUp.filter { !listening.contains($0.pid) }
    }

    private var portsEmptyText: String {
        if lookingUp { return L("networkview.port.querying") }
        if parsedPort != nil { return L("networkview.port.empty") }
        return L("networkview.portsEmpty")
    }

    private func portRow(command: String, pid: String, detail: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(command).lineLimit(1)
                Text("PID \(pid)  \(detail)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            Button(L("networkview.kill")) { killPids([pid], force: false) }
                .buttonStyle(.borderless)
                .disabled(task.running)
            Button(role: .destructive) { killPids([pid], force: true) } label: {
                Text(L("networkview.forceKill"))
            }
            .buttonStyle(.borderless)
            .disabled(task.running)
        }
        .font(.callout)
        .padding(8)
        .insetSurfaceBackground(RoundedRectangle(cornerRadius: 8), legacyFill: .black.opacity(0.04))
    }

    private func tickRates() {
        var next = sampler
        rate = next.tick().network
        sampler = next
    }

    private func refreshPorts() {
        ports = NetworkService.listeningPorts()
        if parsedPort != nil {
            lookupPort()
        } else {
            lookedUp = []
        }
    }

    private func lookupPort() {
        guard let port = parsedPort else {
            lookedUp = []
            return
        }
        lookingUp = true
        DispatchQueue.global(qos: .userInitiated).async {
            let found = NetworkService.processes(onPort: port)
            DispatchQueue.main.async {
                lookedUp = found
                lookingUp = false
            }
        }
    }

    private func killPids(_ pids: [String], force: Bool) {
        guard !pids.isEmpty else { return }
        let copy = pids
        performNetwork { try NetworkService.kill(pids: copy, force: force) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { refreshPorts() }
    }

    private func flushDNS() {
        performNetwork { try NetworkService.flushDNS() }
    }

    private func performNetwork(_ work: @escaping @Sendable () throws -> CommandResult) {
        guard !task.running else { return }
        performTask(task) {
            let r = try work()
            var text = r.combinedOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                text = r.succeeded ? L("repairview.doneNoOutput") : L("repairview.exitCode", Int(r.exitCode))
            }
            if !r.succeeded {
                throw NSError(
                    domain: "Network",
                    code: Int(r.exitCode),
                    userInfo: [NSLocalizedDescriptionKey: text]
                )
            }
            return text
        }
    }
}
