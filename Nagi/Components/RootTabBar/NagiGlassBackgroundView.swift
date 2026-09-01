//
//  NagiGlassBackgroundView.swift
//  Nagi
//
//  单个持久化 Glass surface。实际 Glass effect 只在参数改变时替换，
//  普通 frame/圆角更新不会重建 UIVisualEffectView。
//

import UIKit

struct NagiGlassParams: Equatable {
    var size: CGSize
    var cornerRadius: CGFloat
    var isDark: Bool
    var tintColor: UIColor?
    var tintKey: String
    var isInteractive: Bool
    var isVisible: Bool
    var reduceTransparency: Bool

    static func == (lhs: NagiGlassParams, rhs: NagiGlassParams) -> Bool {
        lhs.size == rhs.size &&
        lhs.cornerRadius == rhs.cornerRadius &&
        lhs.isDark == rhs.isDark &&
        colorsEqual(lhs.tintColor, rhs.tintColor) &&
        lhs.tintKey == rhs.tintKey &&
        lhs.isInteractive == rhs.isInteractive &&
        lhs.isVisible == rhs.isVisible &&
        lhs.reduceTransparency == rhs.reduceTransparency
    }

    static func colorsEqual(_ lhs: UIColor?, _ rhs: UIColor?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return lhs.isEqual(rhs)
        default:
            return false
        }
    }
}

final class NagiGlassBackgroundView: UIView {
    private let effectView: UIVisualEffectView
    private let fallbackView: UIView
    private var previousParams: NagiGlassParams?
    private var currentEffectKey: String?
    private var currentTintColor: UIColor?

    override init(frame: CGRect) {
        let effect = UIGlassEffect(style: .regular)
        effect.isInteractive = false
        self.effectView = UIVisualEffectView(effect: effect)
        self.fallbackView = UIView(frame: .zero)
        super.init(frame: frame)

        isUserInteractionEnabled = false
        clipsToBounds = false
        layer.cornerCurve = .continuous

        fallbackView.backgroundColor = .secondarySystemBackground
        fallbackView.isHidden = true
        fallbackView.isUserInteractionEnabled = false
        fallbackView.layer.cornerCurve = .continuous

        addSubview(fallbackView)
        addSubview(effectView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        fallbackView.frame = bounds
        effectView.frame = bounds
        fallbackView.layer.cornerRadius = layer.cornerRadius
        effectView.layer.cornerRadius = layer.cornerRadius
        effectView.clipsToBounds = true
    }

    func update(params: NagiGlassParams) {
        guard params != previousParams else {
            return
        }
        let previousEffectKey = currentEffectKey
        previousParams = params

        frame.size = params.size
        layer.cornerRadius = params.cornerRadius
        layer.cornerCurve = .continuous
        alpha = params.isVisible ? 1 : 0

        let effectKey = "regular|\(params.tintKey)|\(params.isDark)|\(params.isInteractive)"
        if effectKey != previousEffectKey || !NagiGlassParams.colorsEqual(currentTintColor, params.tintColor) {
            let effect = UIGlassEffect(style: .regular)
            effect.tintColor = params.tintColor
            effect.isInteractive = params.isInteractive
            effectView.effect = effect
            currentEffectKey = effectKey
            currentTintColor = params.tintColor
        }

        let useFallback = params.reduceTransparency
        fallbackView.isHidden = !useFallback
        effectView.isHidden = useFallback
        fallbackView.layer.cornerRadius = params.cornerRadius
        effectView.layer.cornerRadius = params.cornerRadius
        setNeedsLayout()
    }
}
