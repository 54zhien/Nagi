
import UIKit

struct NagiSearchParams: Equatable {
    var containerSize: CGSize
    var backgroundFrame: CGRect
    var closeFrame: CGRect
    var isActive: Bool
    var isDark: Bool
    var reduceTransparency: Bool
}

final class NagiNavigationSearchView: UIView, UITextFieldDelegate, UIGestureRecognizerDelegate {
    private static let searchSymbolConfiguration = UIImage.SymbolConfiguration(
        pointSize: 22,
        weight: .medium
    )

    private struct ActiveInput {
        let container: UIView
        let textField: UITextField
    }

    private let backgroundView: NagiGlassBackgroundView
    private let iconView: UIImageView
    private var close: (background: NagiGlassBackgroundView, iconView: UIImageView)?
    private var closingClose: (background: NagiGlassBackgroundView, iconView: UIImageView)?
    private var activeInput: ActiveInput?
    private var closingInput: ActiveInput?
    private var previousParams: NagiSearchParams?
    private var pendingQuery = ""
    private var inputGeneration = 0
    private var closeGeneration = 0

    var onActivate: (() -> Void)?
    var onCancel: (() -> Void)?
    var onQueryChanged: ((String) -> Void)?

    private var isActive = false

    override init(frame: CGRect) {
        self.backgroundView = NagiGlassBackgroundView(frame: .zero)
        self.iconView = UIImageView(
            image: UIImage(
                systemName: "magnifyingglass",
                withConfiguration: Self.searchSymbolConfiguration
            )
        )
        self.close = nil
        self.closingClose = nil
        self.activeInput = nil
        self.closingInput = nil
        super.init(frame: frame)

        clipsToBounds = false
        isUserInteractionEnabled = true

        backgroundView.isUserInteractionEnabled = true
        backgroundView.contentView.clipsToBounds = true
        addSubview(backgroundView)

        iconView.tintColor = .secondaryLabel
        iconView.contentMode = .scaleToFill
        iconView.isUserInteractionEnabled = false
        backgroundView.contentView.addSubview(iconView)

        let recognizer = UITapGestureRecognizer(target: self, action: #selector(backgroundTapped))
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = self
        addGestureRecognizer(recognizer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @discardableResult
    func prepare(params: NagiSearchParams) -> Bool {
        guard params != previousParams else {
            return false
        }

        let previousIsActive = isActive
        let previousShowsClose = previousParams?.isActive ?? false
        let showsClose = params.isActive

        previousParams = params
        isActive = params.isActive

        if previousIsActive != params.isActive {
            inputGeneration += 1
        }
        if previousShowsClose != showsClose {
            closeGeneration += 1
        }

        if params.isActive {
            ensureCloseSurface(for: params)
            ensureActiveInput()
        }

        let backgroundSize = params.backgroundFrame.size
        let backgroundRadius = min(backgroundSize.width, backgroundSize.height) * 0.5
        let backgroundChanged = backgroundView.prepare(params: NagiGlassParams(
            size: backgroundSize,
            cornerRadius: backgroundRadius,
            isDark: params.isDark,
            tintColor: glassTintColor(isDark: params.isDark),
            reduceTransparency: params.reduceTransparency
        ))

        let closeChanged: Bool
        if let close {
            let closeFrame = resolvedCloseFrame(for: params)
            let closeSize = closeFrame.size
            let closeRadius = min(closeSize.width, closeSize.height) * 0.5
            closeChanged = close.background.prepare(params: NagiGlassParams(
                size: closeSize,
                cornerRadius: closeRadius,
                isDark: params.isDark,
                tintColor: glassTintColor(isDark: params.isDark),
                reduceTransparency: params.reduceTransparency
            ))
        } else {
            closeChanged = false
        }

        return backgroundChanged || closeChanged
    }

    func applyInternalGeometry(
        params: NagiSearchParams,
        transition: NagiTabTransition
    ) {
        let backgroundSize = params.backgroundFrame.size
        let backgroundRadius = min(backgroundSize.width, backgroundSize.height) * 0.5
        let showsClose = params.isActive

        transition.setFrame(view: backgroundView, frame: params.backgroundFrame)
        backgroundView.applyGeometry(
            params: NagiGlassParams(
                size: backgroundSize,
                cornerRadius: backgroundRadius,
                isDark: params.isDark,
                tintColor: glassTintColor(isDark: params.isDark),
                reduceTransparency: params.reduceTransparency
            ),
            transition: transition
        )

        if let close {
            if !showsClose {
                self.close = nil
                closingClose = close
            }
            let closeFrame = resolvedCloseFrame(for: params)
            let closeSize = closeFrame.size
            let closeRadius = min(closeSize.width, closeSize.height) * 0.5
            transition.setBounds(
                view: close.background,
                bounds: CGRect(origin: .zero, size: closeSize)
            )
            transition.setPosition(
                view: close.background,
                position: CGPoint(x: closeFrame.midX, y: closeFrame.midY)
            )
            close.background.applyGeometry(
                params: NagiGlassParams(
                    size: closeSize,
                    cornerRadius: closeRadius,
                    isDark: params.isDark,
                    tintColor: glassTintColor(isDark: params.isDark),
                    reduceTransparency: params.reduceTransparency
                ),
                transition: transition,
                applyVisibility: false
            )
            if showsClose {
                transition.setCornerRadius(
                    view: close.background,
                    radius: closeRadius
                )
                transition.setScale(view: close.background, scale: 1.0)
            }
            let generation = closeGeneration
            transition.setAlpha(
                view: close.background,
                alpha: showsClose ? 1.0 : 0.0,
                completion: showsClose
                    ? nil
                    : { [weak self, weak closeBackground = close.background] completed in
                        guard completed, let closeBackground else {
                            return
                        }

                        closeBackground.removeFromSuperview()
                        guard let self,
                              self.previousParams?.isActive != true,
                              self.closeGeneration == generation,
                              self.closingClose?.background === closeBackground else {
                            return
                        }

                        self.closingClose = nil
                    }
            )
            close.background.isUserInteractionEnabled = showsClose
        }

        backgroundView.contentView.clipsToBounds = true
        close?.background.contentView.clipsToBounds = true
        layoutControls(for: params, transition: transition)
    }

    private func resolvedCloseFrame(for params: NagiSearchParams) -> CGRect {
        if params.isActive {
            return params.closeFrame
        }

        return CGRect(
            x: max(0, params.containerSize.width - 48),
            y: 0,
            width: 48,
            height: 48
        )
    }

    private func ensureCloseSurface(for params: NagiSearchParams) {
        guard close == nil else { return }

        let background = NagiGlassBackgroundView(frame: .zero)
        let iconView = UIImageView(image: Self.makeCloseImage())
        let closeSize = params.closeFrame.size
        let closeRadius = min(closeSize.width, closeSize.height) * 0.5
        let closeGlassParams = NagiGlassParams(
            size: closeSize,
            cornerRadius: closeRadius,
            isDark: params.isDark,
            tintColor: glassTintColor(isDark: params.isDark),
            reduceTransparency: params.reduceTransparency
        )

        _ = background.prepare(params: closeGlassParams)
        background.applyGeometry(
            params: closeGlassParams,
            transition: .immediate,
            applyVisibility: false
        )

        background.isUserInteractionEnabled = true
        background.contentView.clipsToBounds = true
        iconView.tintColor = .secondaryLabel
        iconView.contentMode = .center
        iconView.isUserInteractionEnabled = false
        iconView.accessibilityLabel = "关闭搜索"

        let recognizer = UITapGestureRecognizer(
            target: self,
            action: #selector(cancelSearch(_:))
        )
        recognizer.cancelsTouchesInView = false
        background.contentView.addGestureRecognizer(recognizer)
        background.contentView.addSubview(iconView)

        background.bounds = CGRect(origin: .zero, size: closeSize)
        background.center = CGPoint(
            x: params.closeFrame.midX,
            y: params.closeFrame.midY
        )
        background.transform = CGAffineTransform(scaleX: 0.001, y: 0.001)
        background.alpha = 1
        insertSubview(background, at: 0)
        if let image = iconView.image {
            iconView.frame = CGRect(
                x: (closeSize.width - image.size.width) * 0.5,
                y: (closeSize.height - image.size.height) * 0.5,
                width: image.size.width,
                height: image.size.height
            )
        }
        close = (background: background, iconView: iconView)
    }

    private static func makeCloseImage() -> UIImage? {
        let size = CGSize(width: 40, height: 40)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { rendererContext in
            let context = rendererContext.cgContext
            context.setLineWidth(2)
            context.setLineCap(.round)
            context.setStrokeColor(UIColor.white.cgColor)
            context.move(to: CGPoint(x: 12, y: 12))
            context.addLine(to: CGPoint(x: 28, y: 28))
            context.move(to: CGPoint(x: 28, y: 12))
            context.addLine(to: CGPoint(x: 12, y: 28))
            context.strokePath()
        }
        return image.withRenderingMode(.alwaysTemplate)
    }

    private func ensureActiveInput() {
        guard activeInput == nil else { return }

        let container = UIView(frame: .zero)
        container.backgroundColor = .clear
        container.alpha = 0

        let textField = UITextField(frame: .zero)
        textField.delegate = self
        textField.backgroundColor = .clear
        textField.borderStyle = .none
        textField.clearButtonMode = .whileEditing
        textField.font = .preferredFont(forTextStyle: .body)
        textField.textColor = .label
        textField.tintColor = UIColor(named: "AccentColor") ?? .tintColor
        textField.placeholder = "搜索书名"
        textField.returnKeyType = .search
        textField.autocorrectionType = .no
        textField.adjustsFontForContentSizeCategory = true
        textField.accessibilityLabel = "搜索书名"
        textField.text = pendingQuery
        textField.addTarget(
            self,
            action: #selector(textDidChange(_:)),
            for: .editingChanged
        )

        container.addSubview(textField)
        backgroundView.contentView.addSubview(container)

        activeInput = ActiveInput(
            container: container,
            textField: textField
        )
    }

    func setQuery(_ query: String) {
        pendingQuery = query

        guard let textField = activeInput?.textField,
              textField.text != query else {
            return
        }

        textField.text = query
    }

    @discardableResult
    func becomeSearchFirstResponder() -> Bool {
        activeInput?.textField.becomeFirstResponder() ?? false
    }

    func resignSearchFirstResponder() {
        activeInput?.textField.resignFirstResponder()
    }

    private func layoutControls(for params: NagiSearchParams, transition: NagiTabTransition) {
        let backgroundBounds = CGRect(
            origin: .zero,
            size: params.backgroundFrame.size
        )
        let active = params.isActive
        let baseIconSize = iconView.image?.size ?? CGSize(width: 22, height: 22)
        let targetIconSize: CGSize

        if active {
            let iconFraction: CGFloat = 0.8
            targetIconSize = CGSize(
                width: baseIconSize.width * iconFraction,
                height: baseIconSize.height * iconFraction
            )
        } else {
            targetIconSize = baseIconSize
        }

        let targetIconFrame: CGRect

        if active {
            targetIconFrame = CGRect(
                x: 12,
                y: floor((backgroundBounds.height - targetIconSize.height) * 0.5),
                width: targetIconSize.width,
                height: targetIconSize.height
            )
        } else {
            targetIconFrame = CGRect(
                x: floor((backgroundBounds.width - targetIconSize.width) * 0.5),
                y: floor((backgroundBounds.height - targetIconSize.height) * 0.5),
                width: targetIconSize.width,
                height: targetIconSize.height
            )
        }

        transition.setPosition(
            view: iconView,
            position: CGPoint(
                x: targetIconFrame.midX,
                y: targetIconFrame.midY
            )
        )
        transition.setBounds(
            view: iconView,
            bounds: CGRect(
                origin: .zero,
                size: targetIconFrame.size
            )
        )
        transition.setTintColor(
            view: iconView,
            color: active
                ? (UIColor(named: "AccentColor") ?? .tintColor)
                : .secondaryLabel
        )
        transition.setAlpha(view: iconView, alpha: 1)

        if active, let input = activeInput {
            transition.setFrame(
                view: input.container,
                frame: backgroundBounds
            )
            transition.setFrame(
                view: input.textField,
                frame: CGRect(
                    x: 36,
                    y: 0,
                    width: max(0, backgroundBounds.width - 40),
                    height: backgroundBounds.height
                )
            )

            let inputAlphaTransition: NagiTabTransition = transition.isImmediate
                ? .immediate
                : .easeInOut(duration: 0.25)
            inputAlphaTransition.setAlpha(
                view: input.container,
                alpha: 1
            )
            input.container.isUserInteractionEnabled = true
            input.textField.isUserInteractionEnabled = true
        } else if let input = activeInput {
            activeInput = nil
            closingInput = input

            let inputAlphaTransition: NagiTabTransition = transition.isImmediate
                ? .immediate
                : .easeInOut(duration: 0.25)
            let generation = inputGeneration
            inputAlphaTransition.setAlpha(
                view: input.container,
                alpha: 0
            ) { [weak self, weak container = input.container] completed in
                guard completed, let container else {
                    return
                }

                container.removeFromSuperview()
                guard let self,
                      !self.isActive,
                      self.inputGeneration == generation,
                      self.closingInput?.container === container else {
                    return
                }

                self.closingInput = nil
            }
            input.container.isUserInteractionEnabled = false
            input.textField.isUserInteractionEnabled = false
        }

        if let close {
            if active {
                let closeBounds = CGRect(origin: .zero, size: params.closeFrame.size)
                transition.setFrame(
                    view: close.iconView,
                    frame: CGRect(
                        x: (closeBounds.width - close.iconView.bounds.width) * 0.5,
                        y: (closeBounds.height - close.iconView.bounds.height) * 0.5,
                        width: close.iconView.bounds.width,
                        height: close.iconView.bounds.height
                    )
                )
            }
            close.iconView.isUserInteractionEnabled = false
        }
    }

    private func glassTintColor(isDark: Bool) -> UIColor {
        isDark
            ? UIColor.white.withAlphaComponent(0.025)
            : UIColor.white.withAlphaComponent(0.1)
    }

    @objc private func backgroundTapped() {
        if isActive {
            activeInput?.textField.becomeFirstResponder()
        } else {
            onActivate?()
        }
    }

    @objc private func textDidChange(_ sender: UITextField) {
        pendingQuery = sender.text ?? ""
        onQueryChanged?(pendingQuery)
    }

    @objc private func cancelSearch(_ recognizer: UITapGestureRecognizer) {
        onCancel?()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    func textFieldShouldClear(_ textField: UITextField) -> Bool {
        pendingQuery = ""
        onQueryChanged?("")
        return true
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        var candidate = touch.view
        while let view = candidate {
            if view is UIControl {
                return false
            }
            candidate = view.superview
        }
        return true
    }
}
