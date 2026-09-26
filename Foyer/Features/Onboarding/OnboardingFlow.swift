import SwiftUI
import FoyerFoundation
import JellyfinKit

/// Server → user → password / Quick Connect. Designed for a remote: few fields, big targets.
struct OnboardingFlow: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var model: OnboardingModel?

    var body: some View {
        Group {
            if let model {
                OnboardingNavigation(model: model)
            } else {
                Color.foyerBackground
            }
        }
        .onAppear {
            if model == nil { model = OnboardingModel(sessionStore: environment.sessionStore) }
        }
    }
}

private struct OnboardingNavigation: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        NavigationStack(path: $model.path) {
            ServerEntryView(model: model)
                .navigationDestination(for: OnboardingModel.Step.self) { step in
                    switch step {
                    case .server:
                        ServerEntryView(model: model)
                    case .users:
                        UserPickerView(model: model)
                    case .password(let user):
                        PasswordView(model: model, user: user)
                    case .quickConnect:
                        QuickConnectView(model: model)
                    }
                }
        }
    }
}

private struct OnboardingScaffold<Content: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            Color.foyerBackground.ignoresSafeArea()
            VStack(alignment: .leading, spacing: Spacing.l) {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text(title)
                        .font(Typography.screenTitle)
                    if let subtitle {
                        Text(subtitle)
                            .font(Typography.body)
                            .foregroundStyle(Color.foyerSecondaryText)
                    }
                }
                content()
                Spacer()
            }
            .frame(maxWidth: 1100, alignment: .leading)
            .padding(.top, Spacing.xl)
        }
    }
}

private struct ErrorBanner: View {
    let error: any Error
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let presentation = ErrorPresentation(error)
        if !presentation.title.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text(presentation.title).font(Typography.bodyEmphasis)
                Text(presentation.message).font(Typography.meta).foregroundStyle(Color.foyerSecondaryText)
                if environment.preferences.debugModeEnabled {
                    Text(FoyerErrorDetail.text(error)).font(Typography.mono).foregroundStyle(Color.foyerTertiaryText).lineLimit(3)
                }
            }
            .padding(Spacing.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: Radius.button).fill(Color.foyerDanger.opacity(0.2)))
            .accessibilityElement(children: .combine)
        }
    }
}

struct ServerEntryView: View {
    @Bindable var model: OnboardingModel
    @Environment(AppEnvironment.self) private var environment
    @FocusState private var focusedField: Bool

    var body: some View {
        OnboardingScaffold(title: L10n.welcomeTitle, subtitle: L10n.welcomeSubtitle) {
            if let expired = environment.sessionStore.expiredAccount {
                Text(L10n.sessionExpiredBanner + " (\(expired.userName) · \(expired.serverName))")
                    .font(Typography.meta)
                    .foregroundStyle(Color.foyerAccent)
            }
            VStack(alignment: .leading, spacing: Spacing.s) {
                Text(L10n.serverAddress)
                    .font(Typography.meta)
                    .foregroundStyle(Color.foyerSecondaryText)
                TextField(L10n.serverAddressPlaceholder, text: $model.serverInput)
                    .textFieldStyle(.plain)
                    .font(Typography.body)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($focusedField)
                    .onSubmit { Task { await model.connect() } }
                    .padding(Spacing.m)
                    .background(RoundedRectangle(cornerRadius: Radius.button).fill(Color.foyerSurface))
                    .accessibilityIdentifier("serverAddressField")
            }
            if let error = model.error {
                ErrorBanner(error: error)
            }
            Button {
                Task { await model.connect() }
            } label: {
                HStack(spacing: Spacing.s) {
                    if model.isBusy { ProgressView().tint(.black) }
                    Text(model.isBusy ? L10n.connecting : L10n.connect)
                }
            }
            .buttonStyle(PillButtonStyle())
            .disabled(model.isBusy || model.serverInput.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityIdentifier("connectButton")

            if !environment.sessionStore.accounts.isEmpty {
                VStack(alignment: .leading, spacing: Spacing.s) {
                    Text(L10n.savedAccounts)
                        .font(Typography.meta)
                        .foregroundStyle(Color.foyerSecondaryText)
                        .padding(.top, Spacing.m)
                    ForEach(environment.sessionStore.accounts) { account in
                        Button {
                            model.useSavedAccount(account)
                        } label: {
                            HStack {
                                Image(systemName: "person.crop.circle")
                                VStack(alignment: .leading) {
                                    Text(account.userName).font(Typography.body)
                                    Text("\(account.serverName) · \(ServerAddress.display(account.serverURL))")
                                        .font(Typography.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(ListRowButtonStyle())
                    }
                }
            }
        }
        .onAppear { if model.serverInput.isEmpty { focusedField = true } }
    }
}

struct UserPickerView: View {
    @Bindable var model: OnboardingModel
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        OnboardingScaffold(title: L10n.chooseUser, subtitle: model.server.map { "\($0.name) · \(ServerAddress.display($0.url))" }) {
            if let server = model.server, !server.isSecure {
                Label(L10n.insecureConnection, systemImage: "lock.open")
                    .font(Typography.meta)
                    .foregroundStyle(Color.foyerSecondaryText)
            }
            if let error = model.error {
                ErrorBanner(error: error)
            }
            ScrollView(.horizontal) {
                HStack(spacing: Spacing.l) {
                    ForEach(model.users) { user in
                        Button {
                            model.choose(user)
                        } label: {
                            VStack(spacing: Spacing.s) {
                                RemoteImage(url: avatarURL(user), targetSize: CGSize(width: 200, height: 200), systemImage: "person.fill")
                                    .frame(width: 200, height: 200)
                                    .clipShape(Circle())
                                Text(user.name ?? "")
                                    .font(Typography.cardTitle)
                            }
                            .padding(Spacing.m)
                        }
                        .buttonStyle(CardButtonStyleFoyer())
                        .accessibilityIdentifier("user-\(user.name ?? "")")
                    }
                    Button {
                        model.choose(nil)
                    } label: {
                        VStack(spacing: Spacing.s) {
                            ZStack {
                                Circle().fill(Color.foyerSurface)
                                Image(systemName: "person.badge.key").font(.system(size: 60, weight: .light))
                            }
                            .frame(width: 200, height: 200)
                            Text(L10n.otherUser).font(Typography.cardTitle)
                        }
                        .padding(Spacing.m)
                    }
                    .buttonStyle(CardButtonStyleFoyer())
                    .accessibilityIdentifier("otherUserButton")
                }
                .padding(.vertical, Spacing.m)
            }
            .scrollClipDisabled()
            .focusSection()

            if model.quickConnectAvailable {
                Button(L10n.quickConnect) { model.startQuickConnect() }
                    .buttonStyle(PillButtonStyle(prominent: false))
                    .accessibilityIdentifier("quickConnectButton")
            }
        }
    }

    private func avatarURL(_ user: User) -> URL? {
        guard let server = model.server, let tag = user.primaryImageTag else { return nil }
        return environment.sessionStore.makeClient(for: server.url).userImageURL(userId: user.id, tag: tag, maxWidth: 400)
    }
}

struct PasswordView: View {
    @Bindable var model: OnboardingModel
    let user: User?
    @State private var username = ""
    @State private var password = ""
    @FocusState private var focus: Field?

    enum Field { case username, password }

    var body: some View {
        OnboardingScaffold(title: user?.name ?? L10n.signIn, subtitle: model.server?.name) {
            if user == nil {
                TextField(L10n.username, text: $username)
                    .textFieldStyle(.plain)
                    .font(Typography.body)
                    .textContentType(.username)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($focus, equals: .username)
                    .padding(Spacing.m)
                    .background(RoundedRectangle(cornerRadius: Radius.button).fill(Color.foyerSurface))
                    .accessibilityIdentifier("usernameField")
            }
            SecureField(L10n.password, text: $password)
                .textFieldStyle(.plain)
                .font(Typography.body)
                .textContentType(.password)
                .focused($focus, equals: .password)
                .onSubmit { submit() }
                .padding(Spacing.m)
                .background(RoundedRectangle(cornerRadius: Radius.button).fill(Color.foyerSurface))
                .accessibilityIdentifier("passwordField")
            if let error = model.error {
                ErrorBanner(error: error)
            }
            Button {
                submit()
            } label: {
                HStack(spacing: Spacing.s) {
                    if model.isBusy { ProgressView().tint(.black) }
                    Text(model.isBusy ? L10n.signingIn : L10n.signIn)
                }
            }
            .buttonStyle(PillButtonStyle())
            .disabled(model.isBusy || (user == nil && username.isEmpty))
            .accessibilityIdentifier("signInButton")
        }
        .onAppear {
            username = user?.name ?? ""
            focus = user == nil ? .username : .password
        }
    }

    private func submit() {
        Task { await model.signIn(username: user?.name ?? username, password: password) }
    }
}

struct QuickConnectView: View {
    @Bindable var model: OnboardingModel

    var body: some View {
        OnboardingScaffold(title: L10n.quickConnect, subtitle: L10n.quickConnectExplain) {
            if let code = model.quickConnectCode {
                Text(code.map(String.init).joined(separator: " "))
                    .font(.system(size: 110, weight: .bold, design: .rounded))
                    .kerning(6)
                    .padding(.vertical, Spacing.l)
                    .accessibilityLabel(code.map(String.init).joined(separator: " "))
                HStack(spacing: Spacing.s) {
                    ProgressView()
                    Text(L10n.quickConnectWaiting)
                        .font(Typography.meta)
                        .foregroundStyle(Color.foyerSecondaryText)
                }
            } else if let error = model.error {
                ErrorBanner(error: error)
            } else {
                ProgressView()
            }
        }
        .onDisappear { model.cancelQuickConnect() }
    }
}
