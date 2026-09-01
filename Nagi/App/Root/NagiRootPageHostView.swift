//
//  NagiRootPageHostView.swift
//  Nagi
//
//  Persistent page surface used by the UIKit root. The SwiftUI page remains
//  full-frame and keeps its system safe area; this view owns the page's
//  full-bleed background so the root never leaks its own background color.
//

import UIKit

final class NagiRootPageHostView: UIView {
    let contentView: UIView

    init(backgroundColor: UIColor) {
        self.contentView = UIView(frame: .zero)
        super.init(frame: .zero)

        self.backgroundColor = backgroundColor
        isOpaque = true
        clipsToBounds = false

        contentView.backgroundColor = .clear
        contentView.isOpaque = false
        addSubview(contentView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        contentView.frame = bounds
    }
}
