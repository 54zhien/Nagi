//
//  NagiGlassContainerView.swift
//  Nagi
//
//  RootTabBar 内唯一的 UIGlassContainerEffect。Main surface 和搜索 surface
//  作为同一容器中的兄弟关系参与 Glass 合成。
//

import UIKit

final class NagiGlassContainerView: UIView {
    private let nativeParamsView: NagiEffectSettingsContainerView
    let effectView: UIVisualEffectView

    var contentView: UIView {
        effectView.contentView
    }

    init(spacing: CGFloat = 7) {
        let effect = UIGlassContainerEffect()
        effect.spacing = spacing

        let effectView = UIVisualEffectView(effect: effect)
        let nativeParamsView = NagiEffectSettingsContainerView(frame: .zero)

        self.effectView = effectView
        self.nativeParamsView = nativeParamsView
        super.init(frame: .zero)

        isUserInteractionEnabled = true
        clipsToBounds = false

        nativeParamsView.addSubview(effectView)
        addSubview(nativeParamsView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard alpha != 0,
              !isHidden,
              isUserInteractionEnabled else {
            return nil
        }

        for view in contentView.subviews.reversed() {
            if let result = view.hitTest(
                convert(point, to: view),
                with: event
            ), result.isUserInteractionEnabled {
                return result
            }
        }

        guard let result = contentView.hitTest(
            convert(point, to: contentView),
            with: event
        ), result !== contentView else {
            return nil
        }
        return result
    }

    func update(
        size: CGSize,
        isDark: Bool,
        transition: NagiTabTransition
    ) {
        effectView.overrideUserInterfaceStyle = isDark ? .dark : .light

        if isDark {
            nativeParamsView.lumaMin = 0.0
            nativeParamsView.lumaMax = 0.15
        } else {
            nativeParamsView.lumaMin = 0.8
            nativeParamsView.lumaMax = 0.801
        }

        let frame = CGRect(origin: .zero, size: size)
        transition.setFrame(view: nativeParamsView, frame: frame)
        if effectView.frame != frame {
            transition.animateView {
                self.effectView.frame = frame
            }
        }
    }
}
