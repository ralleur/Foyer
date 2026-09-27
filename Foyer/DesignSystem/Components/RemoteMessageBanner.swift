import SwiftUI

/// Shows a `DisplayMessage` sent by another Jellyfin client and hides it after its timeout.
struct RemoteMessageBanner: ViewModifier {
    @Environment(AppEnvironment.self) private var environment

    func body(content: Content) -> some View {
        content.overlay(alignment: .top) {
            if let message = environment.remoteControl.message {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    if let header = message.header, !header.isEmpty {
                        Text(header).font(Typography.bodyEmphasis)
                    }
                    Text(message.text).font(Typography.body)
                }
                .foregroundStyle(Color.foyerPrimaryText)
                .padding(.horizontal, Spacing.l)
                .padding(.vertical, Spacing.m)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .padding(.top, Spacing.xl)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityIdentifier("remoteMessage")
                .task(id: message.id) {
                    try? await Task.sleep(for: .seconds(message.timeout))
                    if environment.remoteControl.message?.id == message.id {
                        environment.remoteControl.message = nil
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: environment.remoteControl.message?.id)
    }
}

extension View {
    func remoteMessageBanner() -> some View { modifier(RemoteMessageBanner()) }
}
