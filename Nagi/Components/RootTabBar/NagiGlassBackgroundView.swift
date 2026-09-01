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
    var isInteractive: Bool
    var isVisible: Bool
    var reduceTransparency: Bool

    static func == (lhs: NagiGlassParams, rhs: NagiGlassParams) -> Bool {
        lhs.size == rhs.size &&
        lhs.cornerRadius == rhs.cornerRadius &&
        lhs.isDark == rhs.isDark &&
        colorsEqual(lhs.tintColor, rhs.tintColor) &&
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
    let contentView: UIView

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
        self.contentView = UIView(frame: .zero)
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
        contentView.backgroundColor = .clear
        contentView.isOpaque = false
        contentView.clipsToBounds = true
        contentView.layer.cornerCurve = .continuous
        addSubview(contentView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        fallbackView.frame = bounds
        effectView.frame = bounds
        contentView.frame = bounds
        fallbackView.layer.cornerRadius = layer.cornerRadius
        effectView.layer.cornerRadius = layer.cornerRadius
        contentView.layer.cornerRadius = layer.cornerRadius
        contentView.layer.cornerCurve = .continuous
        effectView.clipsToBounds = true
    }

    @discardableResult
    func prepare(params: NagiGlassParams) -> Bool {
        guard params != previousParams else {
            return false
        }
        let previousEffectKey = currentEffectKey
        previousParams = params

        // Size, corner radius, visibility, and search presentation state are
        // geometry/visibility inputs. They must never recreate the glass.
        let effectKey = "regular|\(params.isDark)|\(params.isInteractive)"
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
        return true
    }

    func applyGeometry(params: NagiGlassParams, applyVisibility: Bool = true) {
        layer.cornerRadius = params.cornerRadius
        layer.cornerCurve = .continuous
        if applyVisibility {
            alpha = params.isVisible ? 1 : 0
        }
        fallbackView.frame = bounds
        effectView.frame = bounds
        contentView.frame = bounds
        fallbackView.layer.cornerRadius = params.cornerRadius
        effectView.layer.cornerRadius = params.cornerRadius
        setNeedsLayout()
    }

    func update(params: NagiGlassParams) {
        guard prepare(params: params) else {
            return
        }
        applyGeometry(params: params)
    }
}
