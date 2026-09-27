import SwiftUI
import UIKit

/// Captures Siri Remote input for the custom player overlay: touch-surface swipes for
/// scrubbing, clicks (select / play-pause / menu / edges) and long presses.
struct RemoteInputView: UIViewControllerRepresentable {
    struct Handlers {
        var onSelect: () -> Void = {}
        var onLongSelect: () -> Void = {}
        var onPlayPause: () -> Void = {}
        var onMenu: () -> Void = {}
        var onLeft: () -> Void = {}
        var onRight: () -> Void = {}
        var onUp: () -> Void = {}
        var onDown: () -> Void = {}
        /// Horizontal translation in points since the pan began, and whether the pan ended.
        var onPan: (_ translation: CGPoint, _ ended: Bool) -> Void = { _, _ in }
        var onTouchesBegan: () -> Void = {}
    }

    var isEnabled: Bool
    var handlers: Handlers

    func makeUIViewController(context: Context) -> RemoteInputViewController {
        let controller = RemoteInputViewController()
        controller.handlers = handlers
        controller.inputEnabled = isEnabled
        return controller
    }

    func updateUIViewController(_ controller: RemoteInputViewController, context: Context) {
        controller.handlers = handlers
        if controller.inputEnabled != isEnabled {
            controller.inputEnabled = isEnabled
        }
    }
}

final class RemoteInputViewController: UIViewController {
    var handlers = RemoteInputView.Handlers()
    var inputEnabled = true {
        didSet {
            inputView_.isFocusEnabled = inputEnabled
            setNeedsFocusUpdate()
            updateFocusIfNeeded()
        }
    }

    private let inputView_ = RemoteInputUIView()

    override func loadView() {
        view = inputView_
        inputView_.backgroundColor = .clear
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        func tap(_ type: UIPress.PressType, _ selector: Selector) {
            let recognizer = UITapGestureRecognizer(target: self, action: selector)
            recognizer.allowedPressTypes = [NSNumber(value: type.rawValue)]
            view.addGestureRecognizer(recognizer)
        }
        tap(.select, #selector(selectPressed))
        tap(.playPause, #selector(playPausePressed))
        tap(.menu, #selector(menuPressed))
        tap(.leftArrow, #selector(leftPressed))
        tap(.rightArrow, #selector(rightPressed))
        tap(.upArrow, #selector(upPressed))
        tap(.downArrow, #selector(downPressed))

        let longPress = UILongPressGestureRecognizer(target: self, action: #selector(longSelect(_:)))
        longPress.allowedPressTypes = [NSNumber(value: UIPress.PressType.select.rawValue)]
        longPress.minimumPressDuration = 0.6
        view.addGestureRecognizer(longPress)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirect.rawValue)]
        view.addGestureRecognizer(pan)
    }

    override var preferredFocusEnvironments: [any UIFocusEnvironment] { [inputView_] }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        super.touchesBegan(touches, with: event)
        handlers.onTouchesBegan()
    }

    @objc private func selectPressed() { handlers.onSelect() }
    @objc private func playPausePressed() { handlers.onPlayPause() }
    @objc private func menuPressed() { handlers.onMenu() }
    @objc private func leftPressed() { handlers.onLeft() }
    @objc private func rightPressed() { handlers.onRight() }
    @objc private func upPressed() { handlers.onUp() }
    @objc private func downPressed() { handlers.onDown() }

    @objc private func longSelect(_ recognizer: UILongPressGestureRecognizer) {
        if recognizer.state == .began { handlers.onLongSelect() }
    }

    @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: view)
        switch recognizer.state {
        case .changed:
            handlers.onPan(translation, false)
        case .ended, .cancelled, .failed:
            handlers.onPan(translation, true)
        default:
            break
        }
    }
}

final class RemoteInputUIView: UIView {
    var isFocusEnabled = true
    override var canBecomeFocused: Bool { isFocusEnabled }
}
