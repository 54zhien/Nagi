//
//  NagiTabTransition.swift
//  Nagi
//
//  Root、TabBar、搜索和键盘共用的动画描述。所有动画都直接作用于
//  UIKit frame/layer 属性，避免在关键路径中触发 Auto Layout 重排。
//

import UIKit

enum NagiTabTransition {
    case immediate
    case easeInOut(duration: TimeInterval)
    case spring(duration: TimeInterval, damping: CGFloat, velocity: CGFloat)
    case keyboard(duration: TimeInterval, curve: UIView.AnimationOptions)

    var isImmediate: Bool {
        if case .immediate = self {
            return true
        }
        return false
    }

    private var duration: TimeInterval {
        switch self {
        case .immediate:
            return 0
        case let .easeInOut(duration), let .spring(duration, _, _), let .keyboard(duration, _):
            return duration
        }
    }

    private var options: UIView.AnimationOptions {
        switch self {
        case .immediate:
            return []
        case .easeInOut:
            return [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]
        case .spring:
            return [.beginFromCurrentState, .allowUserInteraction]
        case let .keyboard(_, curve):
            return [curve, .beginFromCurrentState, .allowUserInteraction]
        }
    }

    func animate(_ changes: @escaping () -> Void, completion: ((Bool) -> Void)? = nil) {
        switch self {
        case .immediate:
            changes()
            completion?(true)
        case let .spring(duration, damping, velocity):
            UIView.animate(
                withDuration: duration,
                delay: 0,
                usingSpringWithDamping: damping,
                initialSpringVelocity: velocity,
                options: options,
                animations: changes,
                completion: completion
            )
        case .easeInOut, .keyboard:
            UIView.animate(
                withDuration: duration,
                delay: 0,
                options: options,
                animations: changes,
                completion: completion
            )
        }
    }

    static func setFrame(_ view: UIView, _ frame: CGRect) {
        view.frame = frame.integral
    }

    static func setBounds(_ view: UIView, _ bounds: CGRect) {
        view.bounds = bounds
    }

    static func setPosition(_ view: UIView, _ position: CGPoint) {
        view.layer.position = position
    }

    static func setAlpha(_ view: UIView, _ alpha: CGFloat) {
        view.alpha = alpha
    }

    static func setScale(_ view: UIView, _ scale: CGFloat) {
        view.transform = CGAffineTransform(scaleX: scale, y: scale)
    }

    static func setCornerRadius(_ view: UIView, _ radius: CGFloat) {
        view.layer.cornerRadius = radius
    }
}
