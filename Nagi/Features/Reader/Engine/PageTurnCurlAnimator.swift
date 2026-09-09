import CoreImage
import CoreImage.CIFilterBuiltins
import Metal
import MetalKit
import QuartzCore
import UIKit

/// A GPU-backed interactive page curl for already prepared page images.
///
/// The reader prepares both images before installing this object. Once the
/// view is installed, a frame only changes the filter's time and asks Core
/// Image to render the existing image graph into the Metal drawable. Readium
/// navigation and locator commits remain outside this visual animator.
@MainActor
final class PageTurnCurlAnimator: NSObject, PageTurnAnimating, MTKViewDelegate {
    private struct MetalResources {
        let device: MTLDevice
        let commandQueue: MTLCommandQueue
        let context: CIContext
    }

    private struct Settlement {
        let revision: UInt
        let start: CGFloat
        let end: CGFloat
        let startTime: CFTimeInterval
        let duration: CFTimeInterval
        let completion: (Bool) -> Void
        let success: Bool
    }

    private let hostView: UIView
    private let sourceCurrentImage: CIImage?
    private let sourceTargetImage: CIImage?
    private let isDark: Bool
    private let mirroredDirection: Bool
    private let translationIsValid: Bool
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    private static let sharedMetalResources: MetalResources? = {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue() else { return nil }
        let context = CIContext(mtlDevice: device, options: [
            .priorityRequestLow: false,
            .cacheIntermediates: false
        ])
        return MetalResources(device: device, commandQueue: commandQueue, context: context)
    }()
    private static var didAttemptPipelineWarmup = false
    private static var hasWarmedPipeline = false

    private var metalView: MTKView?
    private var commandQueue: MTLCommandQueue?
    private var ciContext: CIContext?
    private var pageCurlFilter: (CIFilter & CIPageCurlWithShadowTransition)?
    private var preparedExtent: CGRect = .zero
    private var mirroredOutput = false
    private var installed = false
    private var displayLink: CADisplayLink?
    private var settlement: Settlement?
    private var renderRequested = false
    private var lastRenderSucceeded = false
    private var pendingFrameCompletion: ((Bool) -> Void)?
    private var revision: UInt = 0

    private(set) var progress: CGFloat = 0

    init(
        hostView: UIView,
        currentImage: UIImage,
        targetImage: UIImage,
        completionTranslationX: CGFloat,
        isDark: Bool
    ) {
        self.hostView = hostView
        sourceCurrentImage = CIImage(image: currentImage)
        sourceTargetImage = CIImage(image: targetImage)
        self.isDark = isDark
        mirroredDirection = completionTranslationX < 0
        translationIsValid = completionTranslationX.isFinite
            && abs(completionTranslationX) > 0.001
        super.init()
    }

    /// Compiles the Core Image page-curl pipeline before the first gesture.
    /// The render is intentionally tiny and runs only once per process.
    static func preparePipelineIfNeeded() {
        guard !hasWarmedPipeline, !didAttemptPipelineWarmup else { return }
        didAttemptPipelineWarmup = true
        guard let resources = sharedMetalResources else { return }
        let extent = CGRect(x: 0, y: 0, width: 64, height: 64)
        let current = CIImage(color: CIColor(red: 0.96, green: 0.96, blue: 0.96))
            .cropped(to: extent)
        let target = CIImage(color: CIColor(red: 0.90, green: 0.90, blue: 0.90))
            .cropped(to: extent)
        let filter = makeFilter(
            currentImage: current,
            targetImage: target,
            extent: extent,
            isDark: false
        )
        filter.time = 0.5
        guard let output = filter.outputImage?.cropped(to: extent) else { return }
        hasWarmedPipeline = resources.context.createCGImage(output, from: extent) != nil
    }

    init(
        hostView: UIView,
        currentImage: CIImage,
        targetImage: CIImage,
        completionTranslationX: CGFloat,
        isDark: Bool
    ) {
        self.hostView = hostView
        sourceCurrentImage = currentImage
        sourceTargetImage = targetImage
        self.isDark = isDark
        mirroredDirection = completionTranslationX < 0
        translationIsValid = completionTranslationX.isFinite
            && abs(completionTranslationX) > 0.001
        super.init()
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
              let sourceCurrentImage,
              let sourceTargetImage,
              sourceCurrentImage.extent.width > 0,
              sourceCurrentImage.extent.height > 0,
              sourceTargetImage.extent.width > 0,
              sourceTargetImage.extent.height > 0,
              let resources = Self.sharedMetalResources else {
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

        let extent = CGRect(origin: .zero, size: drawableSize)
        guard let currentImage = Self.prepare(sourceCurrentImage, for: extent),
              let targetImage = Self.prepare(sourceTargetImage, for: extent) else {
            return false
        }

        let shouldMirror = mirroredDirection
        let filteredCurrentImage = shouldMirror
            ? Self.mirror(currentImage, in: extent)
            : currentImage
        let filteredTargetImage = shouldMirror
            ? Self.mirror(targetImage, in: extent)
            : targetImage

        let filter = Self.makeFilter(
            currentImage: filteredCurrentImage,
            targetImage: filteredTargetImage,
            extent: extent,
            isDark: isDark
        )

        guard filter.outputImage != nil else {
            return false
        }

        let metalView = MTKView(frame: bounds, device: resources.device)
        metalView.delegate = self
        metalView.frame = bounds
        metalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        metalView.contentMode = .scaleToFill
        metalView.contentScaleFactor = scale
        metalView.drawableSize = drawableSize
        metalView.colorPixelFormat = .bgra8Unorm
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
        ciContext = resources.context
        pageCurlFilter = filter
        preparedExtent = extent
        mirroredOutput = shouldMirror
        self.metalView = metalView
        installed = true
        progress = 0

        hostView.addSubview(metalView)
        setFilterTime(0)
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
        setFilterTime(progress)
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
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue?.makeCommandBuffer(),
              let context = ciContext,
              let filter = pageCurlFilter,
              let outputImage = filter.outputImage else {
            resolvePendingFrameCompletion(false)
            return
        }

        let image = mirroredOutput
            ? Self.mirror(outputImage, in: preparedExtent)
            : outputImage.cropped(to: preparedExtent)
        let bounds = CGRect(origin: .zero, size: view.drawableSize)
        context.render(
            image,
            to: drawable.texture,
            commandBuffer: commandBuffer,
            bounds: bounds,
            colorSpace: colorSpace
        )
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
        commandBuffer.present(drawable)
        commandBuffer.commit()
        lastRenderSucceeded = true
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        guard view === metalView, size.width > 0, size.height > 0 else { return }
        // A geometry change invalidates this animator. The reader must prepare
        // a new pair of page surfaces before installing another one.
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
            setFilterTime(target)
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
            setFilterTime(value)

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

    // MARK: - Core Image preparation

    private func setFilterTime(_ value: CGFloat) {
        guard let pageCurlFilter else { return }
        pageCurlFilter.time = Float(Self.clamp(value))
    }

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

    private static func prepare(_ image: CIImage, for extent: CGRect) -> CIImage? {
        let sourceExtent = image.extent.standardized
        guard sourceExtent.width > 0, sourceExtent.height > 0,
              sourceExtent.width.isFinite, sourceExtent.height.isFinite else {
            return nil
        }

        let normalized = image.transformed(by: CGAffineTransform(
            translationX: -sourceExtent.minX,
            y: -sourceExtent.minY
        ))
        let scale = max(extent.width / sourceExtent.width, extent.height / sourceExtent.height)
        guard scale.isFinite, scale > 0 else { return nil }

        let scaled = normalized.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let scaledExtent = scaled.extent
        let offsetX = (extent.width - scaledExtent.width) * 0.5
        let offsetY = (extent.height - scaledExtent.height) * 0.5
        let positioned = scaled.transformed(by: CGAffineTransform(translationX: offsetX, y: offsetY))
        return positioned.clampedToExtent().cropped(to: extent)
    }

    private static func mirror(_ image: CIImage, in extent: CGRect) -> CIImage {
        let transform = CGAffineTransform(scaleX: -1, y: 1)
            .translatedBy(x: -extent.width, y: 0)
        return image.transformed(by: transform).cropped(to: extent)
    }

    private static func makeFilter(
        currentImage: CIImage,
        targetImage: CIImage,
        extent: CGRect,
        isDark: Bool
    ) -> CIFilter & CIPageCurlWithShadowTransition {
        let filter = CIFilter.pageCurlWithShadowTransition()
        filter.inputImage = currentImage
        filter.targetImage = targetImage
        // The source page is also the physical back of the turning sheet. The
        // filter mirrors it onto the back face without any per-frame upload.
        filter.backsideImage = currentImage
        filter.extent = extent
        filter.time = 0
        filter.angle = 0
        filter.radius = Float(max(32, min(extent.width * 0.72, 420)))
        filter.shadowAmount = isDark ? 0.30 : 0.24
        filter.shadowExtent = extent.insetBy(
            dx: extent.width * 0.04,
            dy: extent.height * 0.04
        )
        filter.shadowSize = Float(max(6, min(extent.width * 0.012, 14)))
        return filter
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
        pageCurlFilter = nil
        ciContext = nil
        commandQueue = nil
        preparedExtent = .zero
        mirroredOutput = false
        lastRenderSucceeded = false
    }
}
