//
//  GlassControlGroup.swift
//  Nagi
//
//  Persistent cache for adjacent GlassControlView instances.  The item
//  identity is independent from the reader's observable state, so changing a
//  label, tint, or enabled state does not recreate the control tree.
//

import UIKit

@MainActor
final class GlassControlGroup<ID: Hashable>: UIView {
    struct Item {
        let id: ID
        let image: UIImage?
        let accessibilityLabel: String
        let tintColor: UIColor?
        let isEnabled: Bool
        let reduceMotion: Bool
        let title: String?
        let isSelected: Bool
        let cornerRadius: CGFloat?
        let contentColor: UIColor?
        let action: (() -> Void)?

        init(
            id: ID,
            image: UIImage?,
            accessibilityLabel: String,
            tintColor: UIColor?,
            isEnabled: Bool = true,
            reduceMotion: Bool = false,
            title: String? = nil,
            isSelected: Bool = false,
            cornerRadius: CGFloat? = nil,
            contentColor: UIColor? = nil,
            action: (() -> Void)? = nil
        ) {
            self.id = id
            self.image = image
            self.accessibilityLabel = accessibilityLabel
            self.tintColor = tintColor
            self.isEnabled = isEnabled
            self.reduceMotion = reduceMotion
            self.title = title
            self.isSelected = isSelected
            self.cornerRadius = cornerRadius
            self.contentColor = contentColor
            self.action = action
        }
    }

    private let containerView: GlassContainerView
    private var controls: [ID: GlassControlView] = [:]
    private var actionTargets: [ID: ActionTarget] = [:]
    private var orderedIDs: [ID] = []
    private var itemFrames: [ID: CGRect] = [:]
    private var cachedContainerFrame = CGRect.null

    init(spacing: CGFloat = 0, backend: GlassBackend? = nil) {
        containerView = GlassContainerView(spacing: spacing, backend: backend)
        super.init(frame: .zero)

        backgroundColor = .clear
        isOpaque = false
        clipsToBounds = false
        addSubview(containerView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func control(for id: ID) -> GlassControlView? {
        controls[id]
    }

    func update(items: [Item]) {
        let incomingIDs = Set(items.map(\.id))
        for id in orderedIDs where !incomingIDs.contains(id) {
            if let control = controls.removeValue(forKey: id) {
                containerView.removeItemView(control)
            }
            actionTargets.removeValue(forKey: id)
            itemFrames.removeValue(forKey: id)
        }

        orderedIDs = items.map(\.id)
        for item in items {
            let control: GlassControlView
            if let existing = controls[item.id] {
                control = existing
            } else {
                control = GlassControlView()
                controls[item.id] = control
                containerView.addItemView(control)

                let target = ActionTarget()
                actionTargets[item.id] = target
                control.addTarget(
                    target,
                    action: #selector(ActionTarget.invoke(_:)),
                    for: .primaryActionTriggered
                )
            }

            control.update(
                image: item.image,
                accessibilityLabel: item.accessibilityLabel,
                tintColor: item.tintColor,
                isEnabled: item.isEnabled,
                reduceMotion: item.reduceMotion,
                title: item.title,
                isSelected: item.isSelected,
                cornerRadius: item.cornerRadius,
                contentColor: item.contentColor
            )
            actionTargets[item.id]?.action = item.action
        }

        setNeedsLayout()
    }

    /// Frames are expressed in this group's coordinate space.  The cache is
    /// updated only by the reader controller's real layout pass.
    func setItemFrames(_ frames: [ID: CGRect]) {
        guard itemFrames != frames else { return }
        itemFrames = frames
        setNeedsLayout()
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard isUserInteractionEnabled, alpha > 0.01 else { return nil }
        let hitView = super.hitTest(point, with: event)
        return hitView === self ? nil : hitView
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let activeFrames = orderedIDs.compactMap { itemFrames[$0] }
        guard var union = activeFrames.first else {
            containerView.frame = .zero
            cachedContainerFrame = .zero
            return
        }
        for frame in activeFrames.dropFirst() {
            union = union.union(frame)
        }

        let containerFrame = union.insetBy(dx: -4, dy: -4)
        if containerFrame != cachedContainerFrame {
            cachedContainerFrame = containerFrame
            containerView.frame = containerFrame
        }

        for id in orderedIDs {
            guard let frame = itemFrames[id], let control = controls[id] else { continue }
            control.frame = frame.offsetBy(
                dx: -containerFrame.minX,
                dy: -containerFrame.minY
            )
        }
    }

    private final class ActionTarget: NSObject {
        var action: (() -> Void)?

        @objc func invoke(_ sender: UIControl) {
            _ = sender
            action?()
        }
    }
}
