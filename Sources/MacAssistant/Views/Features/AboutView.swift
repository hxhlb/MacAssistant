import SwiftUI
import AppKit
import MacAssistantKit

struct AboutView: View {
    @ObservedObject var updates: UpdateCoordinator
    @AppStorage(LocalizationSettings.defaultsKey) private var language = AppLanguage.system.rawValue

    /// 与检查更新用的是同一个版本号来源,避免页面显示和比较结果对不上。
    private var version: String { updates.currentVersion }

    /// 只有 Info.plist 里 MacAssistantBuildKind 明确带 Developer ID 且不含 ad-hoc 标记才算已公证发行版。
    /// 缺失、未知或含 ad-hoc 的一律按开发构建处理:宁可多给一次拦截提示,也绝不把未公证产物显示成已公证。
    private var isNotarizedRelease: Bool {
        guard let kind = Bundle.main.object(forInfoDictionaryKey: "MacAssistantBuildKind") as? String else {
            return false
        }
        let lower = kind.lowercased()
        return lower.contains("developer id") && !lower.contains("ad-hoc")
    }

    var body: some View {
        FeatureScaffold(title: SidebarItem.about.title, subtitle: L("about.tagline")) {
            Card {
                identityHeader
            }
            Card {
                VStack(alignment: .leading, spacing: 0) {
                    languageRow
                    Divider().padding(.vertical, 12)
                    updateBlock
                }
            }
            Card {
                privacyBlock
            }
            footer
        }
        .navigationTitle(SidebarItem.about.title)
    }

    /// 仓库最早提交在 2026，版权跨度从那时起到今年。
    private var copyrightText: String {
        let startYear = 2026
        let currentYear = Calendar.current.component(.year, from: Date())
        return L("about.copyright", startYear, currentYear)
    }

    private var identityHeader: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 56, height: 56)
                .accessibilityLabel(L("about.icon.accessibility"))

            VStack(alignment: .leading, spacing: 3) {
                Text(L("root.appName"))
                    .font(.title2.weight(.semibold))
                Text("\(L("about.version", version))  ·  \(L("about.developer"))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                buildKindBadge
            }
            .accessibilityElement(children: .combine)

            Spacer(minLength: 0)
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            HStack(spacing: 18) {
                socialLink(
                    glyph: .github,
                    title: L("about.github"),
                    url: ProductLinks.github,
                    accessibilityLabel: L("about.github.accessibility"),
                    identifier: "about.github"
                )
                socialLink(
                    glyph: .x,
                    title: L("about.twitter"),
                    url: ProductLinks.twitter,
                    accessibilityLabel: L("about.twitter.accessibility"),
                    identifier: "about.twitter"
                )
                socialLink(
                    glyph: .telegram,
                    title: L("about.channel"),
                    url: ProductLinks.releaseChannel,
                    accessibilityLabel: L("about.channel.accessibility"),
                    identifier: "about.telegram"
                )
            }
            Text(copyrightText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 36)
    }

    private func socialLink(
        glyph: BrandIcon.Glyph,
        title: String,
        url: URL,
        accessibilityLabel: String,
        identifier: String
    ) -> some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 6) {
                BrandIcon(glyph: glyph, size: 12)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.callout)
            }
            .foregroundStyle(Color.accentColor)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(url.absoluteString)
        .accessibilityIdentifier(identifier)
    }

    private func settingsLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .frame(width: 16, alignment: .center)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.body.weight(.medium))
        }
    }

    private var languageRow: some View {
        HStack(spacing: 12) {
            settingsLabel(L("about.language.title"), systemImage: "globe")
            Spacer(minLength: 12)
            Picker("", selection: $language) {
                ForEach(AppLanguage.allCases) { option in
                    Text(option.displayName).tag(option.rawValue)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .accessibilityLabel(L("about.language.title"))
            .accessibilityIdentifier("about.language")
        }
    }

    private var updateBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                settingsLabel(L("about.updates.title"), systemImage: "arrow.triangle.2.circlepath")
                Spacer(minLength: 12)
                if updates.isDownloading {
                    ProgressView().controlSize(.small)
                } else {
                    Button {
                        Task { await updates.runManualCheck() }
                    } label: {
                        if updates.isChecking {
                            ProgressView().controlSize(.small)
                        } else {
                            Text(L("about.checkForUpdates"))
                        }
                    }
                    .disabled(updates.isChecking)
                    .accessibilityLabel(L("about.checkForUpdates.accessibility"))
                    .accessibilityIdentifier("about.checkForUpdates")
                }
            }

            HStack(spacing: 12) {
                settingsLabel(L("about.automaticUpdateCheck"), systemImage: "clock.arrow.circlepath")
                Spacer(minLength: 12)
                Toggle("", isOn: $updates.automaticCheckEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
                    .accessibilityLabel(L("about.automaticUpdateCheck"))
                    .accessibilityHint(L("about.automaticUpdateCheck.hint"))
                    .accessibilityIdentifier("about.automaticUpdateCheck")
            }

            if let status = updates.statusText {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if case .finished = updates.downloadState {
                        Button(L("about.revealDownload")) {
                            updates.revealDownloadedFile()
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
                .accessibilityIdentifier("about.updateStatus")
            }
        }
    }

    private var privacyBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("about.privacy"))
                .font(.headline)
            Text(L("about.privacy.detail"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var buildKindBadge: some View {
        if isNotarizedRelease {
            Label(L("about.buildKind.notarized"), systemImage: "checkmark.seal")
                .font(.caption)
                .foregroundStyle(.green)
                .accessibilityIdentifier("about.buildKind")
        } else {
            Label(L("about.buildKind.development"), systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .accessibilityIdentifier("about.buildKind")
        }
    }
}
