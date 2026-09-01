//
//  NagiGlassContainerView.swift
//  Nagi
//
//  RootTabBar 内唯一的 UIGlassContainerEffect。Main surface、搜索 surface
//  和 selection surface 作为同一容器中的兄弟关系参与 Glass 合成。
//

import UIKit

final class NagiGlassContainerView: UIView {
    let effectView: UIVisualEffectView
    let contentView: UIView

    init(spacing: CGFloat = 7) {
        let effect = UIGlassContainerEffect()
        effect.spacing = spacing
        self.effectView = UIVisualEffectView(effect: effect)
        self.contentView = effectView.contentView
        super.init(frame: .zero)

        isUserInteractionEnabled = true
        addSubview(effectView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        effectView.frame = bounds
    }
}
