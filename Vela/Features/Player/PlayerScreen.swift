import SwiftUI
import UIKit
import VelaFoundation

/// Full-screen player. Hosts whichever engine the coordinator chose and layers
/// Vela's own controls on top when the engine has no system UI of its own.
struct PlayerScreen: View {
    let coordinator: PlaybackCoordinator
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let engine = coordinator.engine {
                EngineHostView(engine: engine)
                    .id(coordinator.engineGeneration)
                    .ignoresSafeArea()
                    .opacity(coordinator.phase == .ready || coordinator.isSwitchingEngine ? 1 : 0)
                if engine.kind == .advanced, coordinator.phase == .ready {
                    AdvancedPlayerOverlay(coordinator: coordinator)
                        .ignoresSafeArea()
                }
            }
            switch coordinator.phase {
            case .preparing:
                preparingView
            case .failed(let error):
                PlayerErrorView(error: error) { coordinator.close() }
            case .finished:
                Color.black.ignoresSafeArea()
            case .ready:
                EmptyView()
            }
        }
        .remoteMessageBanner()
        .onAppear {
            ImagePipelineHolder.shared = environment.images
            coordinator.begin()
        }
        .onDisappear {
            coordinator.close()
        }
        .onExitCommand {
            // Reaches us when the native transport bar is hidden (AVKit swallows Menu otherwise).
            coordinator.close()
        }
        .onChange(of: coordinator.engineGeneration) { _, _ in
            wireNativeEngine()
        }
        .onChange(of: coordinator.phase) { _, phase in
            if phase == .ready { wireNativeEngine() }
        }
    }

    private var preparingView: some View {
        VStack(spacing: Spacing.m) {
            ProgressView().scaleEffect(1.5)
            Text(coordinator.isSwitchingEngine ? L10n.switchingPlayer : L10n.preparingPlayback)
                .font(Typography.meta)
                .foregroundStyle(Color.velaSecondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(coordinator.isSwitchingEngine ? Color.black.opacity(0.4) : Color.black)
        .transition(.opacity)
    }

    private func wireNativeEngine() {
        guard let native = coordinator.engine as? NativePlaybackEngine else { return }
        native.subtitleTimelineProvider = { [weak coordinator] in coordinator?.subtitleTimeline }
        native.subtitleScale = environment.preferences.subtitleSize.scale
    }
}

/// Embeds an engine's view controller.
struct EngineHostView: UIViewControllerRepresentable {
    let engine: any PlaybackEngine

    func makeUIViewController(context: Context) -> UIViewController {
        let container = EngineContainerViewController()
        container.embed(engine.viewController)
        return container
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}
}

final class EngineContainerViewController: UIViewController {
    private weak var child: UIViewController?

    override var preferredFocusEnvironments: [any UIFocusEnvironment] {
        child.map { [$0] } ?? super.preferredFocusEnvironments
    }

    func embed(_ controller: UIViewController) {
        child?.willMove(toParent: nil)
        child?.view.removeFromSuperview()
        child?.removeFromParent()
        addChild(controller)
        controller.view.frame = view.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(controller.view)
        controller.didMove(toParent: self)
        child = controller
        view.backgroundColor = .black
        setNeedsFocusUpdate()
    }
}

struct PlayerErrorView: View {
    let error: VelaError
    let close: () -> Void
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        let presentation = ErrorPresentation(error)
        VStack(spacing: Spacing.m) {
            Image(systemName: "play.slash")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(Color.velaSecondaryText)
            Text(presentation.title).font(Typography.sectionTitle)
            Text(presentation.message)
                .font(Typography.body)
                .foregroundStyle(Color.velaSecondaryText)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 900)
            if environment.preferences.debugModeEnabled {
                Text(Log.redact(error.description))
                    .font(Typography.mono)
                    .foregroundStyle(Color.velaTertiaryText)
                    .frame(maxWidth: 1200)
                    .lineLimit(5)
            }
            Button(L10n.close, action: close)
                .buttonStyle(PillButtonStyle())
                .padding(.top, Spacing.s)
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
        .onExitCommand(perform: close)
    }
}
