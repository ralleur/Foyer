import SwiftUI
import FoyerFoundation
import JellyfinKit
import PlaybackDecision

struct DebugLogView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var entries: [LogEntry] = []
    @State private var category: LogCategory?
    @State private var minimumLevel: LogLevel = .debug

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.s) {
            HStack {
                Picker("Category", selection: $category) {
                    Text("All").tag(LogCategory?.none)
                    ForEach(LogCategory.allCases, id: \.self) { Text($0.rawValue).tag(LogCategory?.some($0)) }
                }
                .pickerStyle(.segmented)
                Spacer()
                Button("Clear") {
                    environment.logBuffer.clear()
                    refresh()
                }
            }
            .padding(.horizontal, Spacing.screenEdge)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(filtered.reversed()) { entry in
                        Text(entry.formatted)
                            .font(Typography.mono)
                            .foregroundStyle(color(for: entry.level))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .focusable()
                    }
                }
                .padding(.horizontal, Spacing.screenEdge)
            }
        }
        .navigationTitle(L10n.logs)
        .onAppear(perform: refresh)
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                refresh()
            }
        }
    }

    private var filtered: [LogEntry] {
        entries.filter { (category == nil || $0.category == category) && $0.level >= minimumLevel }
    }

    private func refresh() { entries = environment.logBuffer.snapshot }

    private func color(for level: LogLevel) -> Color {
        switch level {
        case .debug: Color.foyerTertiaryText
        case .info, .notice: Color.foyerSecondaryText
        case .warning: Color.foyerAccent
        case .error: Color.foyerDanger
        }
    }
}

struct CapabilitiesView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let caps = environment.capabilities
        List {
            Section(L10n.capabilities) {
                SettingsRow(title: "Model", value: caps.modelName)
                SettingsRow(title: "HEVC hardware", value: caps.supportsHEVCHardware ? "yes" : "no")
                SettingsRow(title: "HEVC 10-bit", value: caps.supportsHEVC10Bit ? "yes" : "no")
                SettingsRow(title: "AV1 hardware", value: caps.supportsAV1Hardware ? "yes" : "no")
                SettingsRow(title: "HDR10", value: caps.supportsHDR10 ? "yes" : "no")
                SettingsRow(title: "HLG", value: caps.supportsHLG ? "yes" : "no")
                SettingsRow(title: "Dolby Vision", value: caps.supportsDolbyVision ? "yes" : "no")
                SettingsRow(title: "Max resolution", value: "\(caps.maxVideoWidth)×\(caps.maxVideoHeight) @ \(Int(caps.maxFrameRate))")
                SettingsRow(title: "Audio output channels", value: "\(caps.maxOutputChannels)")
                SettingsRow(title: "Advanced engine", value: caps.advancedEngineAvailable ? AdvancedPlaybackEngine.versionDescription : "not linked")
                SettingsRow(title: "Advanced engine HDR output", value: caps.advancedEngineSupportsHDROutput ? "yes" : "no (tone-mapped)")
            }
            Section(L10n.server) {
                if let account = environment.sessionStore.active?.account {
                    SettingsRow(title: "URL", value: ServerAddress.display(account.serverURL))
                    SettingsRow(title: "Jellyfin", value: account.serverVersion ?? "?")
                    SettingsRow(title: "Device ID", value: DeviceInfo.persistentDeviceId)
                }
            }
            Section("Cache") {
                SettingsRow(title: "Image disk cache", value: ByteCountFormatter.string(fromByteCount: Int64(environment.images.diskUsageBytes), countStyle: .file))
            }
        }
        .listStyle(.grouped)
        .navigationTitle(L10n.capabilities)
    }
}

struct LastDecisionView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                if let report = PlaybackDecisionJournal.shared.last {
                    Text(report.title).font(Typography.sectionTitle)
                    Text(report.summary)
                        .font(Typography.mono)
                        .foregroundStyle(Color.foyerSecondaryText)
                    if let stats = report.statistics {
                        Text(stats)
                            .font(Typography.mono)
                            .foregroundStyle(Color.foyerTertiaryText)
                    }
                } else {
                    Text(L10n.none).foregroundStyle(Color.foyerSecondaryText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.xl)
            .focusable()
        }
        .navigationTitle(L10n.lastPlaybackDecision)
    }
}

/// Keeps the most recent playback decision for the debug screen.
@MainActor
final class PlaybackDecisionJournal {
    static let shared = PlaybackDecisionJournal()

    struct Report {
        var title: String
        var summary: String
        var statistics: String?
    }

    private(set) var last: Report?

    func record(title: String, decision: PlaybackDecision, mediaSummary: String) {
        last = Report(title: title, summary: mediaSummary + "\n\n" + decision.summary, statistics: nil)
    }

    func updateStatistics(_ text: String) {
        last?.statistics = text
    }
}

struct LicensesView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.l) {
                Text(L10n.licenses).font(Typography.screenTitle)
                license("Foyer", "GNU General Public License v3.0 — the app itself. Source: github.com/ralleur/foyer")
                license("MPVKit (libmpv, FFmpeg, libass, libplacebo, MoltenVK, dav1d and others)",
                        "LGPL v3.0 build of MPVKit (no GPL components enabled). Component licenses: mpv LGPLv2.1+, FFmpeg LGPLv2.1+, libass ISC, libplacebo LGPLv2.1+, MoltenVK Apache 2.0, dav1d BSD-2, FreeType FTL, HarfBuzz MIT, FriBidi LGPLv2.1+, libdovi MIT, uchardet MPL 1.1, GnuTLS LGPLv2.1+, nettle LGPLv3, GMP LGPLv3, shaderc Apache 2.0, lcms2 MIT, libunibreak Zlib. Full texts: LICENSES.md in the repository.")
                license("Jellyfin", "The Jellyfin server and API are GPL-2.0 licensed projects. Foyer talks to the public HTTP API and includes no Jellyfin code.")
            }
            .padding(Spacing.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
            .focusable()
        }
    }

    private func license(_ name: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(name).font(Typography.bodyEmphasis)
            Text(text).font(Typography.cardSubtitle).foregroundStyle(Color.foyerSecondaryText)
        }
    }
}
