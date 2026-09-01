//
//  KeyboardTransitionCoordinator.swift
//  Nagi
//
//  Drives the root bar from the keyboard's exact end frame and animation
//  curve, including the repeated frame notifications emitted by an
//  interactive dismissal.
//

import UIKit

@MainActor
final class KeyboardTransitionCoordinator {
    private weak var owner: RootContainerViewController?
    private var observers: [NSObjectProtocol] = []

    init(owner: RootContainerViewController) {
        self.owner = owner
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(
                forName: UIResponder.keyboardWillChangeFrameNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handle(notification)
            }
        )
        observers.append(
            center.addObserver(
                forName: UIResponder.keyboardWillHideNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handle(notification)
            }
        )
    }

    deinit {
        let center = NotificationCenter.default
        for observer in observers {
            center.removeObserver(observer)
        }
    }

    private func handle(_ notification: Notification) {
        guard let owner else { return }

        let endFrame = (notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
            ?? .null
        let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)
            .map { $0.doubleValue } ?? 0.25
        let curveRawValue = (notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)
            .map { UInt($0.intValue) }
            ?? UInt(UIView.AnimationCurve.easeInOut.rawValue)
        var options = UIView.AnimationOptions(rawValue: curveRawValue << 16)
        options.formUnion([.beginFromCurrentState, .allowUserInteraction])

        owner.applyKeyboardFrame(
            endFrame,
            duration: duration,
            options: options
        )
    }
}
