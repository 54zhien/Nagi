//
//  ReaderFontSizeStepperControl.swift
//  Nagi
//
//  A persistent two-sided font-size stepper for the Reader medium sheet.
//

import UIKit

@MainActor
final class ReaderFontSizeStepperControl: UIControl {
    private let surfaceView = GlassSurfaceView()
    private let smallerButton = UIButton(type: .system)
    private let largerButton = UIButton(type: .system)
    private let centerDivider = UIView()

    private var smallerIsEnabled = true
    private var largerIsEnabled = true
    private var currentState: GlassState?

    var onDecrease: (() -> Void)?
    var onIncrease: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)

        backgroundColor = .clear
        isOpaque = false
        clipsToBounds = false

        surfaceView.isUserInteractionEnabled = false
        addSubview(surfaceView)

        centerDivider.isUserInteractionEnabled = false
        addSubview(centerDivider)

        configureButton(smallerButton, accessibilityLabel: "减小字号")
        configureButton(largerButton, accessibilityLabel: "增大字号")
        addSubview(smallerButton)
        addSubview(largerButton)

        smallerButton.addTarget(
            self,
            action: #selector(smallerTapped),
            for: .primaryActionTriggered
        )
        largerButton.addTarget(
            self,
            action: #selector(largerTapped),
            for: .primaryActionTriggered
        )

        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        isSmallerEnabled: Bool,
        isLargerEnabled: Bool,
        smallerPointSize: CGFloat,
        largerPointSize: CGFloat,
        tintColor: UIColor,
        accessibilityValue: String
    ) {
        smallerIsEnabled = isSmallerEnabled
        largerIsEnabled = isLargerEnabled

        let smallerConfiguration = UIImage.SymbolConfiguration(
            pointSize: smallerPointSize,
            weight: .regular
        )
        let largerConfiguration = UIImage.SymbolConfiguration(
            pointSize: largerPointSize,
            weight: .regular
        )
        smallerButton.setImage(
            UIImage(systemName: "character", withConfiguration: smallerConfiguration),
            for: .normal
        )
        largerButton.setImage(
            UIImage(systemName: "character", withConfiguration: largerConfiguration),
            for: .normal
        )
        smallerButton.tintColor = tintColor
        largerButton.tintColor = tintColor
        smallerButton.isEnabled = isSmallerEnabled
        largerButton.isEnabled = isLargerEnabled
        smallerButton.accessibilityValue = accessibilityValue
        largerButton.accessibilityValue = accessibilityValue

        let state = GlassState(
            tint: nil,
            isEnabled: true,
            isInteractive: true,
            cornerRadius: 22
        )
        if currentState != state {
            surfaceView.update(state)
            currentState = state
        }
        setNeedsLayout()
    }

    private func configureButton(_ button: UIButton, accessibilityLabel: String) {
        button.backgroundColor = .clear
        button.adjustsImageWhenHighlighted = true
        button.imageView?.contentMode = .center
        button.accessibilityLabel = accessibilityLabel
        button.accessibilityTraits = .button
    }

    @objc private func smallerTapped() {
        guard smallerIsEnabled else { return }
        onDecrease?()
    }

    @objc private func largerTapped() {
        guard largerIsEnabled else { return }
        onIncrease?()
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, alpha > 0.01, bounds.contains(point) else {
            return nil
        }
        // Route the whole capsule, including the divider and glass surface,
        // to one of the two full-height buttons so there is no dead zone.
        return point.x < bounds.midX ? smallerButton : largerButton
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        surfaceView.frame = bounds
        let radius = max(0, min(bounds.width, bounds.height) / 2)
        surfaceView.setCornerRadius(radius)

        let halfWidth = bounds.width / 2
        smallerButton.frame = CGRect(
            x: 0,
            y: 0,
            width: halfWidth,
            height: bounds.height
        )
        largerButton.frame = CGRect(
            x: halfWidth,
            y: 0,
            width: max(0, bounds.width - halfWidth),
            height: bounds.height
        )

        let dividerHeight = min(28, max(26, bounds.height - 16))
        centerDivider.frame = CGRect(
            x: bounds.midX - 0.25,
            y: (bounds.height - dividerHeight) / 2,
            width: 0.5,
            height: dividerHeight
        )
        centerDivider.backgroundColor = UIColor.label.withAlphaComponent(0.22)
    }
}
