import UIKit

@MainActor
final class NagiKeyboardLayoutCoordinator {
    private weak var view: UIView?
    private var observers: [NSObjectProtocol] = []
    private let onChange: (CGRect?, NagiTabTransition) -> Void

    init(view: UIView, onChange: @escaping (CGRect?, NagiTabTransition) -> Void) {
        self.view = view
        self.onChange = onChange
        start()
    }

    deinit {
        for observer in observers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    func start() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handle(notification: notification)
        })
        observers.append(center.addObserver(
            forName: UIResponder.keyboardWillHideNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleHide(notification: notification)
        })
    }

    func stop() {
        let center = NotificationCenter.default
        observers.forEach(center.removeObserver)
        observers.removeAll()
    }

    private func handle(notification: Notification) {
        guard let view else { return }
        let frame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
        let coordinateSpace = (notification.object as? UIScreen)?.coordinateSpace
            ?? view.window?.screen.coordinateSpace
        let convertedFrame = frame.map { frame in
            if let coordinateSpace {
                return coordinateSpace.convert(frame, to: view)
            }
            return view.convert(frame, from: nil)
        }
        let effectiveFrame: CGRect?
        if let convertedFrame,
           convertedFrame.height > 0,
           convertedFrame.maxY > view.bounds.minY,
           convertedFrame.minY < view.bounds.maxY {
            effectiveFrame = convertedFrame
        } else {
            effectiveFrame = nil
        }
        onChange(effectiveFrame, transition(from: notification))
    }

    private func handleHide(notification: Notification) {
        onChange(nil, transition(from: notification))
    }

    private func transition(from notification: Notification) -> NagiTabTransition {
        let userInfo = notification.userInfo
        let duration = (userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
        let curveValue = (userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.uintValue ?? 7
        let curve = UIView.AnimationOptions(rawValue: curveValue << 16)
        return .keyboard(duration: duration, curve: curve)
    }
}
