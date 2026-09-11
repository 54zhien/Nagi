import Metal
import MetalKit
import QuartzCore
import UIKit

/// A GPU-backed interactive page curl driven by a deforming sheet mesh.
///
/// The paper is a static grid; every frame only changes a 32-byte uniform
/// struct (progress, fold direction, radius, lighting) and the vertex shader
/// re-evaluates the curvature on the GPU. Nothing per frame touches the CPU
/// bitmaps: both page textures are uploaded before the gesture starts, either
/// by `CurlTextureCache` in the preferred path or, as a fallback, here in
/// `install()`.
///
/// Readium navigation and locator commits stay outside this visual animator.
@MainActor
final class PageTurnCurlAnimator: NSObject, PageTurnAnimating, MTKViewDelegate {
    private struct Settlement {
        let revision: UInt
        let start: CGFloat
        let end: CGFloat
        let startTime: CFTimeInterval
        let duration: CFTimeInterval
        let completion: (Bool) -> Void
        let success: Bool
    }

    /// Bend radius as a fraction of the page width. Tuning knob, not a
    /// constraint: the vertex shader tapers it to zero at both ends of the
    /// gesture so the sheet settles flat.
    private static let curlRadius: Float = 0.18

    private let hostView: UIView
    private let currentTexture: MTLTexture
    private let targetTexture: MTLTexture
    private let isDark: Bool
    private let foldSign: Float
    private let translationIsValid: Bool

    private static var didAttemptPipelineWarmup = false
    private static var hasWarmedPipeline = false

    private var metalView: MTKView?
    private var commandQueue: MTLCommandQueue?
    private var renderer: PageCurlRenderer?
    private var installed = false
    private var displayLink: CADisplayLink?
    private var settlement: Settlement?
    private var renderRequested = false
    private var lastRenderSucceeded = false
    private var pendingFrameCompletion: ((Bool) -> Void)?
    private var revision: UInt = 0

    private(set) var progress: CGFloat = 0

    /// Both pages must already be on the GPU. The reader uploads them while it
    /// is idle; there is deliberately no image-based initialiser, because the
    /// whole point is that a gesture never rasterises or uploads anything.
    init(
        hostView: UIView,
        currentTexture: MTLTexture,
        targetTexture: MTLTexture,
        completionTranslationX: CGFloat,
        isDark: Bool
    ) {
        self.hostView = hostView
        self.currentTexture = currentTexture
        self.targetTexture = targetTexture
        self.isDark = isDark
        foldSign = Self.foldSign(for: completionTranslationX)
        translationIsValid = Self.translationIsValid(completionTranslationX)
        super.init()
    }

    /// Builds the Metal resources before the first gesture so that a gesture
    /// never pays for pipeline creation.
    ///
    /// The shader library ships precompiled in the app bundle, so unlike the
    /// old Core Image path there is no runtime shader compilation to warm —
    /// this only forces the lazy `shared` build to happen now. When the shader
    /// is missing from the app target `shared` stays nil and the reader keeps
    /// using the Core Image curl.
    static func preparePipelineIfNeeded() {
        guard !didAttemptPipelineWarmup else { return }
        didAttemptPipelineWarmup = true
        hasWarmedPipeline = PageCurlMetalResources.shared != nil
    }

    @discardableResult
    func install() -> Bool {
        invalidateAnimation()
        removeMetalView()
        resetRenderingResources()

        let bounds = hostView.bounds.integral
        guard translationIsValid,
              bounds.width > 0, bounds.height > 0,
              bounds.width.isFinite, bounds.height.isFinite,
              let resources = PageCurlMetalResources.shared else {
            return false
        }

        let scale = max(hostView.window?.screen.scale ?? hostView.traitCollection.displayScale, 1)
        let drawableSize = CGSize(
            width: floor(bounds.width * scale),
            height: floor(bounds.height * scale)
        )
        guard drawableSize.width >= 1, drawableSize.height >= 1,
              drawableSize.width.isFinite, drawableSize.height.isFinite else {
            return false
        }

        let metalView = MTKView(frame: bounds, device: resources.device)
        metalView.delegate = self
        metalView.frame = bounds
        metalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        metalView.contentMode = .scaleToFill
        metalView.contentScaleFactor = scale
        metalView.drawableSize = drawableSize
        metalView.colorPixelFormat = PageCurlMetalResources.colorPixelFormat
        metalView.depthStencilPixelFormat = PageCurlMetalResources.depthPixelFormat
        metalView.framebufferOnly = false
        metalView.enableSetNeedsDisplay = false
        metalView.isPaused = true
        metalView.isOpaque = true
        metalView.backgroundColor = isDark ? .black : .white
        metalView.clearColor = MTLClearColor(
            red: isDark ? 0 : 1,
            green: isDark ? 0 : 1,
            blue: isDark ? 0 : 1,
            alpha: 1
        )
        metalView.isUserInteractionEnabled = false
        metalView.accessibilityElementsHidden = true
        metalView.isAccessibilityElement = false

        commandQueue = resources.commandQueue
        renderer = PageCurlRenderer(resources: resources)
        self.metalView = metalView
        installed = true
        progress = 0

        hostView.addSubview(metalView)
        guard renderFrame() else {
            remove()
            return false
        }
        ensureDisplayLink()
        return true
    }

    func update(progress rawProgress: CGFloat) {
        progress = Self.clamp(rawProgress)
        guard installed else { return }
        requestRender()
    }

    func animateCompletion(completion: @escaping (Bool) -> Void) {
        guard installed else {
            completion(false)
            return
        }
        settle(to: 1, duration: 0.24 * max(0.12, 1 - progress), success: true, completion: completion)
    }

    func animateCancellation(completion: @escaping () -> Void) {
        guard installed else {
            completion()
            return
        }
        settle(to: 0, duration: 0.20 * max(0.18, progress), success: false) { _ in
            completion()
        }
    }

    func animateRestoration(completion: @escaping () -> Void) {
        guard installed else {
            completion()
            return
        }
        settle(to: 0, duration: 0.16 * max(0.20, progress), success: false) { _ in
            completion()
        }
    }

    func remove() {
        invalidateAnimation()
        installed = false
        removeMetalView()
        resetRenderingResources()
    }

    // MARK: - MTKViewDelegate

    func draw(in view: MTKView) {
        guard installed,
              view === metalView,
              let commandBuffer = commandQueue?.makeCommandBuffer(),
              let renderer else {
            resolvePendingFrameCompletion(false)
            return
        }

        let size = view.drawableSize
        guard size.width > 0, size.height > 0 else {
            resolvePendingFrameCompletion(false)
            return
        }

        guard renderer.encode(
            in: view,
            currentTexture: currentTexture,
            targetTexture: targetTexture,
            uniforms: makeUniforms(drawableSize: size),
            commandBuffer: commandBuffer
        ) else {
            resolvePendingFrameCompletion(false)
            return
        }

        if let completion = pendingFrameCompletion {
            pendingFrameCompletion = nil
            commandBuffer.addCompletedHandler { commandBuffer in
                let succeeded = commandBuffer.status == .completed
                    && commandBuffer.error == nil
                Task { @MainActor in
                    completion(succeeded)
                }
            }
        }
        guard let drawable = view.currentDrawable else {
            resolvePendingFrameCompletion(false)
            return
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
        lastRenderSucceeded = true
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        guard view === metalView, size.width > 0, size.height > 0 else { return }
        // A geometry change invalidates this animator. The reader must prepare
        // a new pair of page surfaces before installing another one.
    }

    // MARK: - Uniforms

    private func makeUniforms(drawableSize: CGSize) -> PageCurlUniforms {
        var uniforms = PageCurlUniforms()
        uniforms.progress = Float(Self.clamp(progress))
        uniforms.foldSign = foldSign
        uniforms.aspect = Float(drawableSize.width / max(drawableSize.height, 1))
        uniforms.curlRadius = Self.curlRadius
        uniforms.shadowStrength = isDark ? 0.30 : 0.24
        uniforms.highlightStrength = isDark ? 0.06 : 0.10
        uniforms.paperTint = 0.35
        uniforms.isDark = isDark ? 1 : 0
        return uniforms
    }

    // MARK: - Display-link settlement

    private func settle(
        to endpoint: CGFloat,
        duration: CFTimeInterval,
        success: Bool,
        completion: @escaping (Bool) -> Void
    ) {
        settlement = nil
        revision &+= 1
        let target = Self.clamp(endpoint)
        let start = progress
        let newRevision = revision

        guard abs(target - start) > 0.0001, duration.isFinite, duration > 0 else {
            progress = target
            _ = renderFrame { rendered in
                completion(success && target >= 1 - 0.0001 && rendered)
            }
            return
        }

        settlement = Settlement(
            revision: newRevision,
            start: start,
            end: target,
            startTime: CACurrentMediaTime(),
            duration: duration,
            completion: completion,
            success: success && target >= 1 - 0.0001
        )

        ensureDisplayLink()
        displayLink?.isPaused = false
    }

    private func ensureDisplayLink() {
        guard displayLink == nil else { return }
        let displayLink = CADisplayLink(target: self, selector: #selector(handleDisplayLink(_:)))
        if #available(iOS 15.0, *) {
            displayLink.preferredFrameRateRange = CAFrameRateRange(
                minimum: 60,
                maximum: 120,
                preferred: 120
            )
        } else {
            displayLink.preferredFramesPerSecond = 60
        }
        displayLink.isPaused = true
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
    }

    private func requestRender() {
        renderRequested = true
        ensureDisplayLink()
        displayLink?.isPaused = false
    }

    @objc
    private func handleDisplayLink(_ displayLink: CADisplayLink) {
        guard installed else {
            displayLink.invalidate()
            if self.displayLink === displayLink {
                self.displayLink = nil
            }
            return
        }
        guard self.displayLink === displayLink else {
            displayLink.invalidate()
            return
        }

        if let settlement {
            guard settlement.revision == revision else {
                self.settlement = nil
                displayLink.isPaused = true
                return
            }

            let elapsed = max(0, CACurrentMediaTime() - settlement.startTime)
            let linearProgress = min(1, elapsed / settlement.duration)
            // Smoothstep has zero velocity at both endpoints, which prevents a
            // visible snap when a fast gesture hands off to the display link.
            let easedProgress = linearProgress * linearProgress * (3 - 2 * linearProgress)
            let value = settlement.start
                + (settlement.end - settlement.start) * CGFloat(easedProgress)
            progress = value

            guard linearProgress >= 1 else {
                _ = renderFrame()
                return
            }
            self.settlement = nil
            renderRequested = false
            displayLink.isPaused = true
            let completion = settlement.completion
            _ = renderFrame { rendered in
                completion(settlement.success && rendered)
            }
            return
        }

        guard renderRequested else {
            displayLink.isPaused = true
            return
        }
        renderRequested = false
        _ = renderFrame()
        displayLink.isPaused = true
    }

    // MARK: - Textures

    // MARK: - Frame rendering

    @discardableResult
    private func renderFrame(completion: ((Bool) -> Void)? = nil) -> Bool {
        guard installed, let metalView else {
            completion?(false)
            return false
        }
        pendingFrameCompletion = completion
        lastRenderSucceeded = false
        metalView.draw()
        if !lastRenderSucceeded {
            resolvePendingFrameCompletion(false)
        }
        return lastRenderSucceeded
    }

    private func resolvePendingFrameCompletion(_ succeeded: Bool) {
        let completion = pendingFrameCompletion
        pendingFrameCompletion = nil
        completion?(succeeded)
    }

    // MARK: - Helpers

    /// `completionTranslationX < 0` means the sheet travels left, so the moving
    /// edge is the right one. The shader folds on that edge instead of the old
    /// approach of mirroring both input images.
    private static func foldSign(for completionTranslationX: CGFloat) -> Float {
        completionTranslationX < 0 ? 1 : -1
    }

    private static func translationIsValid(_ completionTranslationX: CGFloat) -> Bool {
        completionTranslationX.isFinite && abs(completionTranslationX) > 0.001
    }

    private static func clamp(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    // MARK: - Lifetime

    private func invalidateAnimation() {
        cancelDisplayLink()
    }

    private func cancelDisplayLink() {
        revision &+= 1
        displayLink?.invalidate()
        displayLink = nil
        settlement = nil
        renderRequested = false
        pendingFrameCompletion = nil
    }

    private func removeMetalView() {
        metalView?.delegate = nil
        metalView?.releaseDrawables()
        metalView?.removeFromSuperview()
        metalView = nil
    }

    private func resetRenderingResources() {
        installed = false
        renderer?.releaseDrawables()
        renderer = nil
        commandQueue = nil
        lastRenderSucceeded = false
    }
}
