import CoreGraphics
import Metal
import MetalKit
import QuartzCore
import UIKit

/// GPU-backed paper-turn renderer for detached reader surfaces.
///
/// Snapshots and texture uploads happen before `install()`; interactive
/// updates only change uniforms and submit an already-created mesh.
@MainActor
final class PageTurnCurlAnimator: NSObject, PageTurnAnimating, MTKViewDelegate {
    // Must match PageTurnUniforms in PageTurnCurlShaders.metal.
    private struct Uniforms {
        var progress: Float
        var direction: Float
        var isDark: Float
        var side: Float
        var cornerRadius: Float
        var aspect: Float
        var pageDirection: Float
        var padding1: Float = 0
    }

    private let hostView: UIView
    private let metalView: MTKView
    private let fallbackCurrentView: UIView
    private let fallbackTargetView: UIView
    private let commandQueue: MTLCommandQueue
    private let depthState: MTLDepthStencilState
    private let vertexBuffer: MTLBuffer
    private let indexBuffer: MTLBuffer
    private let indexCount: Int
    private let targetTexture: MTLTexture
    private let currentTexture: MTLTexture
    private let targetPipeline: MTLRenderPipelineState
    private let curlPipeline: MTLRenderPipelineState
    private let backPipeline: MTLRenderPipelineState
    private let completionTranslationX: CGFloat
    private let pageDirection: PageDirection
    private let isDark: Bool
    private let displayScale: CGFloat
    private let cornerRadius: Float
    private let aspect: Float

    private var displayLink: CADisplayLink?
    private var animationStartTime: CFTimeInterval = 0
    private var animationDuration: CFTimeInterval = 0
    private var animationStartProgress: CGFloat = 0
    private var animationTargetProgress: CGFloat = 0
    private var animationCompletion: ((Bool) -> Void)?
    private var cancellationCompletion: (() -> Void)?
    private var animationRevision = 0
    private(set) var progress: CGFloat = 0

    // GPU errors can arrive after encoding. Defer a successful completion
    // until the final submitted frame has completed successfully.
    private var renderFailure = false
    private var drawableRetryCount = 0
    private var submittedFrameID: UInt64 = 0
    private var completedFrameID: UInt64 = 0
    private var pendingFrameID: UInt64?
    private var pendingGPUCompletion: ((Bool) -> Void)?

    init?(
        context: PageTurnMetalContext?,
        hostView: UIView,
        preparedTextures: PageTurnPreparedTextures?,
        currentView: UIView,
        targetView: UIView,
        completionTranslationX: CGFloat,
        direction: PageDirection,
        isDark: Bool
    ) {
        guard let context, let preparedTextures,
              completionTranslationX.isFinite, completionTranslationX != 0 else { return nil }

        let bounds = hostView.bounds.integral
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = Self.displayScale(for: hostView)
        let radius = Self.cornerRadius(for: hostView, bounds: bounds)
        let targetTexture = preparedTextures.target
        let currentTexture = preparedTextures.current
        guard targetTexture.width > 0, targetTexture.height > 0,
              currentTexture.width > 0, currentTexture.height > 0 else { return nil }

        let metalView = MTKView(frame: bounds, device: context.device)
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.framebufferOnly = true
        metalView.isPaused = true
        metalView.enableSetNeedsDisplay = true
        metalView.contentScaleFactor = scale
        metalView.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        metalView.depthStencilPixelFormat = .depth32Float
        metalView.clearDepth = 0
        let maximumFramesPerSecond = hostView.window?.windowScene?.screen.maximumFramesPerSecond ?? 60
        metalView.preferredFramesPerSecond = min(120, maximumFramesPerSecond)
        // A transparent clear keeps a transient drawable failure from showing
        // an opaque black/red rectangle over the reader.
        metalView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        metalView.isOpaque = false
        metalView.isUserInteractionEnabled = false
        metalView.accessibilityElementsHidden = true
        metalView.isAccessibilityElement = false

        self.hostView = hostView
        self.metalView = metalView
        self.fallbackCurrentView = currentView
        self.fallbackTargetView = targetView
        self.commandQueue = context.commandQueue
        self.depthState = context.depthState
        self.vertexBuffer = context.vertexBuffer
        self.indexBuffer = context.indexBuffer
        self.indexCount = context.indexCount
        self.targetTexture = targetTexture
        self.currentTexture = currentTexture
        self.targetPipeline = context.targetPipeline
        self.curlPipeline = context.curlPipeline
        self.backPipeline = context.backPipeline
        self.completionTranslationX = completionTranslationX
        self.pageDirection = direction
        self.isDark = isDark
        self.displayScale = scale
        self.cornerRadius = radius
        self.aspect = Float(bounds.width / max(bounds.height, 1))
        super.init()
        metalView.delegate = self
    }

    @discardableResult
    func install() -> Bool {
        let bounds = hostView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return false }
        animationRevision &+= 1
        stopAnimation()
        drawableRetryCount = 0
        fallbackCurrentView.frame = bounds
        fallbackCurrentView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        fallbackCurrentView.isUserInteractionEnabled = false
        fallbackCurrentView.layer.cornerCurve = .continuous
        let configuredRadius = hostView.effectiveRadius(corner: .allCorners)
        fallbackCurrentView.layer.cornerRadius = configuredRadius > 0
            ? configuredRadius
            : hostView.layer.cornerRadius
        fallbackCurrentView.layer.masksToBounds = true
        fallbackCurrentView.removeFromSuperview()
        hostView.addSubview(fallbackCurrentView)
        fallbackTargetView.frame = bounds
        fallbackTargetView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        fallbackTargetView.isUserInteractionEnabled = false
        fallbackTargetView.alpha = 0
        fallbackTargetView.removeFromSuperview()
        metalView.frame = bounds
        metalView.contentScaleFactor = displayScale
        metalView.drawableSize = CGSize(
            width: max(1, bounds.width * displayScale),
            height: max(1, bounds.height * displayScale)
        )
        metalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        metalView.removeFromSuperview()
        hostView.addSubview(metalView)
        metalView.isHidden = false
        metalView.layer.zPosition = 0
        update(progress: 0)
        return true
    }

    func update(progress rawProgress: CGFloat) {
        progress = min(max(rawProgress.isFinite ? rawProgress : 0, 0), 1)
        guard !renderFailure else { return }
        metalView.draw()
    }

    func animateCompletion(completion: @escaping (Bool) -> Void) {
        beginDisplayLink(
            targetProgress: 1,
            duration: 0.24 * max(0.001, 1 - progress),
            completion: completion,
            cancellation: nil
        )
    }

    func animateCancellation(completion: @escaping () -> Void) {
        beginDisplayLink(
            targetProgress: 0,
            duration: 0.18,
            completion: nil,
            cancellation: completion
        )
    }

    func animateRestoration(completion: @escaping () -> Void) {
        animationRevision &+= 1
        stopAnimation()
        metalView.isHidden = true
        if fallbackTargetView.superview == nil {
            hostView.insertSubview(fallbackTargetView, aboveSubview: fallbackCurrentView)
        }
        fallbackCurrentView.alpha = 0
        fallbackTargetView.alpha = 1
        UIView.animate(
            withDuration: 0.12,
            delay: 0,
            options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]
        ) { [weak self] in
            self?.fallbackCurrentView.alpha = 1
            self?.fallbackTargetView.alpha = 0
        } completion: { _ in
            completion()
        }
    }

    func remove() {
        animationRevision &+= 1
        stopAnimation()
        drawableRetryCount = 0
        pendingFrameID = nil
        pendingGPUCompletion = nil
        metalView.delegate = nil
        metalView.removeFromSuperview()
        fallbackCurrentView.removeFromSuperview()
        fallbackTargetView.removeFromSuperview()
    }

    // A temporary zero size is normal while the view is detached or the scene
    // rotates. Only an actual draw/command failure is terminal.
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard !renderFailure else { return }

        // MTKView can temporarily have no drawable while the scene is
        // presenting, rotating, or recovering from a missed frame. This is
        // not a renderer failure and must not permanently disable the turn.
        guard let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let colorTexture = descriptor.colorAttachments[0].texture,
              colorTexture.pixelFormat == .bgra8Unorm,
              drawable.texture.pixelFormat == .bgra8Unorm,
              let commandBuffer = commandQueue.makeCommandBuffer()
        else {
            scheduleDrawableRetry()
            return
        }
        if let depthAttachment = descriptor.depthAttachment {
            depthAttachment.loadAction = .clear
            depthAttachment.storeAction = .dontCare
            depthAttachment.clearDepth = 0
        }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            scheduleDrawableRetry()
            return
        }
        drawableRetryCount = 0
        encoder.setDepthStencilState(depthState)

        var uniforms = makeUniforms(side: 0)
        encoder.setRenderPipelineState(targetPipeline)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        // The target is always the stable background. At progress == 0 the
        // current page fully covers it; at progress == 1 the curled page has
        // left the viewport and the target is already visible.
        encoder.setFragmentTexture(targetTexture, index: 0)
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: indexCount,
                                      indexType: .uint32, indexBuffer: indexBuffer,
                                      indexBufferOffset: 0)

        // The fixed/front face is drawn first; the explicitly opaque back
        // face then owns its folded projected band. The depth attachment
        // additionally resolves self-overlap consistently on device GPUs.
        encoder.setRenderPipelineState(curlPipeline)
        uniforms = makeUniforms(side: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.setFragmentTexture(currentTexture, index: 0)
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: indexCount,
                                      indexType: .uint32, indexBuffer: indexBuffer,
                                      indexBufferOffset: 0)

        encoder.setRenderPipelineState(backPipeline)
        uniforms = makeUniforms(side: 1)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.setFragmentTexture(currentTexture, index: 0)
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: indexCount,
                                      indexType: .uint32, indexBuffer: indexBuffer,
                                      indexBufferOffset: 0)

        encoder.endEncoding()
        let frameID = submittedFrameID &+ 1
        submittedFrameID = frameID
        commandBuffer.addCompletedHandler { [weak self] buffer in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if buffer.status != .completed {
                    self.renderFailure = true
                    self.metalView.isHidden = true
                }
                self.completedFrameID = max(self.completedFrameID, frameID)
                self.finishPendingGPUCompletionIfPossible()
            }
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func makeUniforms(side: Float) -> Uniforms {
        Uniforms(progress: Float(progress), direction: direction,
                  isDark: isDark ? 1 : 0, side: side,
                  cornerRadius: cornerRadius, aspect: aspect,
                  pageDirection: pageDirection == .forward ? 0 : 1)
    }

    private var direction: Float {
        // There is one physical direction source for both forward and
        // backward turns. The provider already supplies the signed destination
        // in container coordinates, so reversing it again for backward turns
        // made RTL/reverse turns curl from the wrong edge.
        completionTranslationX < 0 ? -1 : 1
    }

    private func beginDisplayLink(targetProgress: CGFloat, duration: TimeInterval,
                                  completion: ((Bool) -> Void)?,
                                  cancellation: (() -> Void)?) {
        animationRevision &+= 1
        stopAnimation()
        animationStartTime = 0
        animationDuration = max(0.001, duration)
        animationStartProgress = progress
        animationTargetProgress = targetProgress
        animationCompletion = completion
        cancellationCompletion = cancellation
        let displayLink = CADisplayLink(target: self, selector: #selector(displayLinkTick(_:)))
        let maximumFramesPerSecond = Float(hostView.window?.windowScene?.screen.maximumFramesPerSecond ?? 60)
        displayLink.preferredFrameRateRange = CAFrameRateRange(
            minimum: min(60, maximumFramesPerSecond), maximum: min(120, maximumFramesPerSecond),
            preferred: min(120, maximumFramesPerSecond))
        self.displayLink = displayLink
        displayLink.add(to: .main, forMode: .common)
    }

    @objc private func displayLinkTick(_ link: CADisplayLink) {
        if animationStartTime == 0 { animationStartTime = link.timestamp }
        let elapsed = max(0, link.timestamp - animationStartTime)
        let normalized = min(1, elapsed / animationDuration)
        let eased = 1 - pow(1 - normalized, 3)
        update(progress: animationStartProgress + (animationTargetProgress - animationStartProgress) * eased)
        guard normalized >= 1 else { return }
        let completion = animationCompletion
        let cancellation = cancellationCompletion
        let completing = animationTargetProgress > 0
        stopAnimation()
        if !completing { cancellation?() }
        else if renderFailure || submittedFrameID == 0 {
            animateFadeFallback(completion: completion)
        }
        else {
            pendingFrameID = submittedFrameID
            pendingGPUCompletion = completion
            finishPendingGPUCompletionIfPossible()
        }
    }

    private func finishPendingGPUCompletionIfPossible() {
        guard let pendingFrameID, completedFrameID >= pendingFrameID else { return }
        let completion = pendingGPUCompletion
        self.pendingFrameID = nil
        pendingGPUCompletion = nil
        if renderFailure {
            animateFadeFallback(completion: completion)
        } else {
            completion?(true)
        }
    }

    private func animateFadeFallback(completion: ((Bool) -> Void)?) {
        metalView.isHidden = true
        if fallbackTargetView.superview == nil {
            hostView.insertSubview(fallbackTargetView, aboveSubview: fallbackCurrentView)
        }
        fallbackTargetView.alpha = 0
        fallbackCurrentView.alpha = 1
        UIView.animate(
            withDuration: 0.12,
            delay: 0,
            options: [.beginFromCurrentState, .curveEaseOut, .allowUserInteraction]
        ) {
            self.fallbackTargetView.alpha = 1
            self.fallbackCurrentView.alpha = 0
        } completion: { finished in
            completion?(finished)
        }
    }

    private func stopAnimation() {
        displayLink?.invalidate()
        displayLink = nil
        animationCompletion = nil
        cancellationCompletion = nil
    }

    private func scheduleDrawableRetry() {
        guard drawableRetryCount < 3, metalView.superview != nil else { return }
        drawableRetryCount += 1
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.renderFailure, self.metalView.superview != nil else { return }
            self.metalView.draw()
        }
    }

    private static func displayScale(for view: UIView) -> CGFloat {
        let scale = view.window?.windowScene?.screen.scale ?? view.traitCollection.displayScale
        return scale.isFinite && scale > 0 ? scale : max(1, UIScreen.main.scale)
    }

    private static func cornerRadius(for view: UIView, bounds: CGRect) -> Float {
        let configured = view.effectiveRadius(corner: .allCorners)
        let fallback = view.layer.cornerRadius
        let radius = configured > 0 ? configured : fallback
        return Float(max(0, min(radius / max(bounds.height, 1), 0.5)))
    }

}

/// Safe terminal path for a curl renderer that cannot be constructed (for
/// example, Metal is unavailable or a pipeline/resource failed to compile).
/// It intentionally does not substitute cover/fade: the last immutable
/// current surface remains visible until the navigator commit completes.
@MainActor
final class PageTurnNoAnimationAnimator: PageTurnAnimating {
    private let hostView: UIView
    private let currentView: UIView
    private var callbackToken: UInt = 0

    init(hostView: UIView, currentView: UIView) {
        self.hostView = hostView
        self.currentView = currentView
    }

    @discardableResult
    func install() -> Bool {
        let bounds = hostView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return false }
        callbackToken &+= 1
        currentView.frame = bounds
        currentView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        currentView.isUserInteractionEnabled = false
        currentView.layer.cornerCurve = .continuous
        let configuredRadius = hostView.effectiveRadius(corner: .allCorners)
        currentView.layer.cornerRadius = configuredRadius > 0
            ? configuredRadius
            : hostView.layer.cornerRadius
        currentView.layer.masksToBounds = true
        hostView.addSubview(currentView)
        return true
    }

    func update(progress: CGFloat) {}

    func animateCompletion(completion: @escaping (Bool) -> Void) {
        // Defer one run-loop turn so ReaderViewController can enter committing
        // before it starts the safe, overlay-preserving provider commit.
        callbackToken &+= 1
        let token = callbackToken
        DispatchQueue.main.async { [weak self] in
            guard let self, self.callbackToken == token else { return }
            completion(true)
        }
    }

    func animateCancellation(completion: @escaping () -> Void) {
        callbackToken &+= 1
        let token = callbackToken
        DispatchQueue.main.async { [weak self] in
            guard let self, self.callbackToken == token else { return }
            completion()
        }
    }

    func animateRestoration(completion: @escaping () -> Void) {
        animateCancellation(completion: completion)
    }

    func remove() {
        callbackToken &+= 1
        currentView.removeFromSuperview()
    }
}
