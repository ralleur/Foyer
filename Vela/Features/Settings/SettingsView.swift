import SwiftUI
import VelaFoundation
import JellyfinKit
import PlaybackDecision

/// Deliberately small settings surface. Technical detail lives under Debug.
struct SettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        NavigationStack {
            @Bindable var prefs = environment.preferences
            List {
                accountSection
                Section(L10n.audioLanguage + " & " + L10n.subtitles) {
                    NavigationLink {
                        LanguagePickerView(title: L10n.audioLanguage, selection: audioBinding(0), allowNone: false)
                    } label: {
                        SettingsRow(title: L10n.audioLanguage, value: languageName(prefs.languages.audioLanguages.first))
                    }
                    NavigationLink {
                        LanguagePickerView(title: L10n.secondaryAudioLanguage, selection: audioBinding(1), allowNone: true)
                    } label: {
                        SettingsRow(title: L10n.secondaryAudioLanguage, value: languageName(prefs.languages.audioLanguages.dropFirst().first))
                    }
                    NavigationLink {
                        LanguagePickerView(title: L10n.subtitleLanguage, selection: subtitleBinding(0), allowNone: false)
                    } label: {
                        SettingsRow(title: L10n.subtitleLanguage, value: languageName(prefs.languages.subtitleLanguages.first))
                    }
                    NavigationLink {
                        LanguagePickerView(title: L10n.secondarySubtitleLanguage, selection: subtitleBinding(1), allowNone: true)
                    } label: {
                        SettingsRow(title: L10n.secondarySubtitleLanguage, value: languageName(prefs.languages.subtitleLanguages.dropFirst().first))
                    }
                    NavigationLink {
                        OptionPickerView(title: L10n.subtitleBehavior, options: SubtitleMode.allCases, selection: $prefs.languages.subtitleMode,
                                         label: subtitleModeTitle, footnote: L10n.subtitleModeSmartHint)
                    } label: {
                        SettingsRow(title: L10n.subtitleBehavior, value: subtitleModeTitle(prefs.languages.subtitleMode))
                    }
                    Toggle(L10n.preferSDH, isOn: $prefs.languages.preferSDH)
                    Toggle(L10n.preferOriginalAudio, isOn: $prefs.languages.preferOriginalAudio)
                    NavigationLink {
                        OptionPickerView(title: L10n.subtitleSize, options: SubtitleSize.allCases, selection: $prefs.subtitleSize, label: sizeTitle)
                    } label: {
                        SettingsRow(title: L10n.subtitleSize, value: sizeTitle(prefs.subtitleSize))
                    }
                }
                Section(L10n.play) {
                    NavigationLink {
                        OptionPickerView(title: L10n.playbackQuality, options: BitrateOption.allCases, selection: bitrateBinding, label: { $0.title })
                    } label: {
                        SettingsRow(title: L10n.playbackQuality, value: BitrateOption(bitrate: prefs.playback.maxStreamingBitrate).title)
                    }
                    NavigationLink {
                        OptionPickerView(title: L10n.directPlay, options: DirectPlayMode.allCases, selection: $prefs.playback.directPlayMode, label: directPlayTitle)
                    } label: {
                        SettingsRow(title: L10n.directPlay, value: directPlayTitle(prefs.playback.directPlayMode))
                    }
                    if environment.capabilities.advancedEngineAvailable {
                        NavigationLink {
                            OptionPickerView(title: L10n.advancedEngine, options: AdvancedEngineMode.allCases, selection: $prefs.playback.advancedEngineMode,
                                             label: advancedTitle, footnote: L10n.advancedEngineHint)
                        } label: {
                            SettingsRow(title: L10n.advancedEngine, value: advancedTitle(prefs.playback.advancedEngineMode))
                        }
                    }
                    Toggle(L10n.autoPlayNext, isOn: $prefs.autoPlayNextEpisode)
                    Toggle(L10n.showBadges, isOn: $prefs.showTechnicalBadges)
                }
                Section(L10n.debug) {
                    Toggle(L10n.debugMode, isOn: $prefs.debugModeEnabled)
                    NavigationLink(L10n.logs) { DebugLogView() }
                    NavigationLink(L10n.capabilities) { CapabilitiesView() }
                    NavigationLink(L10n.lastPlaybackDecision) { LastDecisionView() }
                    Button(L10n.clearCache) {
                        environment.images.clearCaches()
                        HomeSnapshot.clear()
                    }
                }
                Section(L10n.about) {
                    SettingsRow(title: L10n.appVersion, value: DeviceInfo.appVersion)
                    NavigationLink(L10n.licenses) { LicensesView() }
                }
            }
            .listStyle(.grouped)
            .navigationTitle(L10n.settings)
        }
    }

    // MARK: Account

    @ViewBuilder private var accountSection: some View {
        if let session = environment.sessionStore.active {
            Section(L10n.account) {
                SettingsRow(title: L10n.server, value: "\(session.account.serverName) · \(ServerAddress.display(session.account.serverURL))")
                SettingsRow(title: L10n.account, value: session.account.userName)
                if let version = session.account.serverVersion {
                    SettingsRow(title: "Jellyfin", value: version)
                }
                NavigationLink(L10n.switchUser) { AccountSwitcherView() }
                Button(role: .destructive) {
                    Task { await environment.sessionStore.signOut(session.account) }
                } label: {
                    Text(L10n.signOut).foregroundStyle(Color.velaDanger)
                }
                .accessibilityIdentifier("signOutButton")
            }
        }
    }

    // MARK: Bindings & labels

    private func audioBinding(_ index: Int) -> Binding<String?> {
        Binding(
            get: { environment.preferences.languages.audioLanguages.dropFirst(index).first },
            set: { newValue in
                var list = environment.preferences.languages.audioLanguages
                while list.count <= index { list.append("") }
                if let newValue { list[index] = newValue } else if index < list.count { list.remove(at: index) }
                environment.preferences.languages.audioLanguages = list.filter { !$0.isEmpty }
            }
        )
    }

    private func subtitleBinding(_ index: Int) -> Binding<String?> {
        Binding(
            get: { environment.preferences.languages.subtitleLanguages.dropFirst(index).first },
            set: { newValue in
                var list = environment.preferences.languages.subtitleLanguages
                while list.count <= index { list.append("") }
                if let newValue { list[index] = newValue } else if index < list.count { list.remove(at: index) }
                environment.preferences.languages.subtitleLanguages = list.filter { !$0.isEmpty }
            }
        )
    }

    private var bitrateBinding: Binding<BitrateOption> {
        Binding(
            get: { BitrateOption(bitrate: environment.preferences.playback.maxStreamingBitrate) },
            set: { environment.preferences.playback.maxStreamingBitrate = $0.bitrate }
        )
    }

    private func languageName(_ code: String?) -> String {
        guard let code, !code.isEmpty else { return L10n.none }
        return LanguageCode.displayName(code) ?? code
    }

    private func subtitleModeTitle(_ mode: SubtitleMode) -> String {
        switch mode {
        case .off: L10n.subtitleModeOff
        case .forcedOnly: L10n.subtitleModeForced
        case .smart: L10n.subtitleModeSmart
        case .always: L10n.subtitleModeAlways
        }
    }

    private func sizeTitle(_ size: SubtitleSize) -> String {
        switch size {
        case .small: L10n.sizeSmall
        case .medium: L10n.sizeMedium
        case .large: L10n.sizeLarge
        }
    }

    private func directPlayTitle(_ mode: DirectPlayMode) -> String {
        switch mode {
        case .preferred: L10n.directPlayPreferred
        case .forced: L10n.directPlayForced
        case .serverDecides: L10n.directPlayServer
        }
    }

    private func advancedTitle(_ mode: AdvancedEngineMode) -> String {
        switch mode {
        case .automatic: L10n.advancedAutomatic
        case .always: L10n.advancedAlways
        case .never: L10n.advancedNever
        }
    }
}

enum BitrateOption: Int, CaseIterable, Hashable {
    case original = 0
    case mbps120 = 120
    case mbps80 = 80
    case mbps40 = 40
    case mbps20 = 20
    case mbps10 = 10
    case mbps6 = 6
    case mbps3 = 3

    init(bitrate: Int?) {
        guard let bitrate, bitrate > 0 else { self = .original; return }
        self = BitrateOption(rawValue: bitrate / 1_000_000) ?? .original
    }

    var bitrate: Int? { self == .original ? nil : rawValue * 1_000_000 }

    var title: String { self == .original ? L10n.qualityOriginal : L10n.qualityMbps(rawValue) }
}

struct SettingsRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Generic single-choice list with checkmarks.
struct OptionPickerView<Option: Hashable>: View {
    let title: String
    let options: [Option]
    @Binding var selection: Option
    let label: (Option) -> String
    var footnote: String? = nil
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                ForEach(options, id: \.self) { option in
                    Button {
                        selection = option
                        dismiss()
                    } label: {
                        HStack {
                            Text(label(option))
                            Spacer()
                            if option == selection { Image(systemName: "checkmark") }
                        }
                    }
                }
            } footer: {
                if let footnote { Text(footnote) }
            }
        }
        .listStyle(.grouped)
        .navigationTitle(title)
    }
}

struct LanguagePickerView: View {
    let title: String
    @Binding var selection: String?
    let allowNone: Bool
    @Environment(\.dismiss) private var dismiss

    private static let codes = ["de", "en", "fr", "es", "it", "pt", "nl", "sv", "da", "no", "fi", "pl", "cs", "hu", "ro", "ru", "uk", "tr", "el", "ja", "ko", "zh", "hi", "ar", "he", "th", "vi", "id"]

    var body: some View {
        List {
            if allowNone {
                Button {
                    selection = nil
                    dismiss()
                } label: {
                    HStack { Text(L10n.none); Spacer(); if selection == nil { Image(systemName: "checkmark") } }
                }
            }
            ForEach(Self.codes, id: \.self) { code in
                Button {
                    selection = code
                    dismiss()
                } label: {
                    HStack {
                        Text(LanguageCode.displayName(code) ?? code)
                        Spacer()
                        if LanguageCode.matches(selection, code) { Image(systemName: "checkmark") }
                    }
                }
            }
        }
        .listStyle(.grouped)
        .navigationTitle(title)
    }
}

struct AccountSwitcherView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section(L10n.savedAccounts) {
                ForEach(environment.sessionStore.accounts) { account in
                    Button {
                        environment.sessionStore.switchAccount(account)
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(account.userName)
                                Text("\(account.serverName) · \(ServerAddress.display(account.serverURL))").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if account.id == environment.sessionStore.active?.account.id { Image(systemName: "checkmark") }
                        }
                    }
                }
            }
            Section {
                Button(L10n.addServer) {
                    // Keeps the current token; onboarding lets the user add another server or account.
                    environment.sessionStore.detachActiveForOnboarding()
                }
            }
        }
        .listStyle(.grouped)
        .navigationTitle(L10n.switchUser)
    }
}
