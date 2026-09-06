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
    private struct Vertex {
        var position: SIMD2<Float>
        var uv: SIMD2<Float>
    }

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
    private let commandQueue: MTLCommandQueue
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
    private var submittedFrameID: UInt64 = 0
    private var completedFrameID: UInt64 = 0
    private var pendingFrameID: UInt64?
    private var pendingGPUCompletion: ((Bool) -> Void)?

    init?(
        hostView: UIView,
        currentView: UIView,
        targetView: UIView,
        completionTranslationX: CGFloat,
        direction: PageDirection,
        isDark: Bool
    ) {
        guard completionTranslationX.isFinite, completionTranslationX != 0,
              let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let fullscreenVertex = library.makeFunction(name: "page_turn_fullscreen_vertex"),
              let targetFunction = library.makeFunction(name: "page_turn_target_fragment"),
              let curlVertexFunction = library.makeFunction(name: "page_turn_curl_vertex"),
              let curlFragmentFunction = library.makeFunction(name: "page_turn_curl_fragment"),
              let backFragmentFunction = library.makeFunction(name: "page_turn_curl_back_fragment")
        else { return nil }

        let bounds = hostView.bounds.integral
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let scale = Self.displayScale(for: hostView)
        let radius = Self.cornerRadius(for: hostView, bounds: bounds)
        let (vertices, indices) = Self.makeGrid()

        guard let targetImage = Self.snapshotImage(for: targetView, scale: scale),
              let currentImage = Self.snapshotImage(for: currentView, scale: scale),
              let targetTexture = Self.makeTexture(device: device, image: targetImage),
              let currentTexture = Self.makeTexture(device: device, image: currentImage),
              targetTexture.width > 0, targetTexture.height > 0,
              currentTexture.width > 0, currentTexture.height > 0,
              let vertexBuffer = Self.makeBuffer(device: device, values: vertices),
              let indexBuffer = Self.makeBuffer(device: device, values: indices)
        else { return nil }

        let targetDescriptor = MTLRenderPipelineDescriptor()
        targetDescriptor.vertexFunction = fullscreenVertex
        targetDescriptor.fragmentFunction = targetFunction
        targetDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        let curlDescriptor = MTLRenderPipelineDescriptor()
        curlDescriptor.vertexFunction = curlVertexFunction
        curlDescriptor.fragmentFunction = curlFragmentFunction
        curlDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        curlDescriptor.colorAttachments[0].isBlendingEnabled = true
        curlDescriptor.colorAttachments[0].rgbBlendOperation = .add
        curlDescriptor.colorAttachments[0].alphaBlendOperation = .add
        curlDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        curlDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        curlDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        curlDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        let backDescriptor = MTLRenderPipelineDescriptor()
        backDescriptor.vertexFunction = curlVertexFunction
        backDescriptor.fragmentFunction = backFragmentFunction
        backDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        backDescriptor.colorAttachments[0].isBlendingEnabled = true
        backDescriptor.colorAttachments[0].rgbBlendOperation = .add
        backDescriptor.colorAttachments[0].alphaBlendOperation = .add
        backDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        backDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        backDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        backDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        guard let targetPipeline = try? device.makeRenderPipelineState(descriptor: targetDescriptor),
              let curlPipeline = try? device.makeRenderPipelineState(descriptor: curlDescriptor),
              let backPipeline = try? device.makeRenderPipelineState(descriptor: backDescriptor)
        else { return nil }

        let metalView = MTKView(frame: bounds, device: device)
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.framebufferOnly = true
        metalView.isPaused = true
        metalView.enableSetNeedsDisplay = true
        metalView.contentScaleFactor = scale
        metalView.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
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
        self.commandQueue = commandQueue
        self.vertexBuffer = vertexBuffer
        self.indexBuffer = indexBuffer
        self.indexCount = indices.count
        self.targetTexture = targetTexture
        self.currentTexture = currentTexture
        self.targetPipeline = targetPipeline
        self.curlPipeline = curlPipeline
        self.backPipeline = backPipeline
        self.completionTranslationX = completionTranslationX
        self.pageDirection = direction
        self.isDark = isDark
        self.displayScale = scale
        self.cornerRadius = radius
        self.aspect = Float(bounds.width / max(bounds.height, 1))
        super.init()
        metalView.delegate = self
    }

    func install() {
        animationRevision &+= 1
        stopAnimation()
        metalView.frame = hostView.bounds
        metalView.contentScaleFactor = displayScale
        metalView.drawableSize = CGSize(
            width: max(1, hostView.bounds.width * displayScale),
            height: max(1, hostView.bounds.height * displayScale)
        )
        metalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        metalView.removeFromSuperview()
        hostView.addSubview(metalView)
        metalView.layer.zPosition = 0
        update(progress: 0)
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

    func remove() {
        animationRevision &+= 1
        stopAnimation()
        pendingFrameID = nil
        pendingGPUCompletion = nil
        metalView.delegate = nil
        metalView.removeFromSuperview()
    }

    // A temporary zero size is normal while the view is detached or the scene
    // rotates. Only an actual draw/command failure is terminal.
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard !renderFailure,
              let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let colorTexture = descriptor.colorAttachments[0].texture,
              colorTexture.pixelFormat == .bgra8Unorm,
              drawable.texture.pixelFormat == .bgra8Unorm,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else {
            renderFailure = true
            return
        }

        var uniforms = makeUniforms(side: 0)
        encoder.setRenderPipelineState(targetPipeline)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.setFragmentTexture(pageDirection == .forward ? targetTexture : currentTexture, index: 0)
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: indexCount,
                                      indexType: .uint32, indexBuffer: indexBuffer,
                                      indexBufferOffset: 0)

        encoder.setRenderPipelineState(curlPipeline)
        uniforms = makeUniforms(side: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.setFragmentTexture(pageDirection == .forward ? currentTexture : targetTexture, index: 0)
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: indexCount,
                                      indexType: .uint32, indexBuffer: indexBuffer,
                                      indexBufferOffset: 0)

        encoder.setRenderPipelineState(backPipeline)
        uniforms = makeUniforms(side: 1)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.setFragmentTexture(pageDirection == .forward ? currentTexture : targetTexture, index: 0)
        encoder.drawIndexedPrimitives(type: .triangle, indexCount: indexCount,
                                      indexType: .uint32, indexBuffer: indexBuffer,
                                      indexBufferOffset: 0)

        encoder.endEncoding()
        let frameID = submittedFrameID &+ 1
        submittedFrameID = frameID
        commandBuffer.addCompletedHandler { [weak self] buffer in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if buffer.status != .completed { self.renderFailure = true }
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
        let physicalCompletion: Float = completionTranslationX < 0 ? -1 : 1
        // A backward turn brings the target sheet in from the opposite edge;
        // a forward turn sends the current sheet toward its completion edge.
        return pageDirection == .forward ? physicalCompletion : -physicalCompletion
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
        else if renderFailure || submittedFrameID == 0 { completion?(false) }
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
        completion?(!renderFailure)
    }

    private func stopAnimation() {
        displayLink?.invalidate()
        displayLink = nil
        animationCompletion = nil
        cancellationCompletion = nil
    }

    private static func displayScale(for view: UIView) -> CGFloat {
        let scale = view.window?.windowScene?.screen.scale ?? view.traitCollection.displayScale
        return scale.isFinite && scale > 0 ? scale : max(1, UIScreen.main.scale)
    }

    private static func cornerRadius(for view: UIView, bounds: CGRect) -> Float {
        let explicit = view.layer.cornerRadius
        let radius = explicit > 0 ? explicit : min(bounds.width, bounds.height) * 0.04
        return Float(max(0, min(radius / max(bounds.height, 1), 0.5)))
    }

    private static func snapshotImage(for view: UIView, scale: CGFloat) -> CGImage? {
        let bounds = view.bounds.integral
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        return UIGraphicsImageRenderer(bounds: bounds, format: format).image {
            view.layer.render(in: $0.cgContext)
        }.cgImage
    }

    private static func makeTexture(device: MTLDevice, image: CGImage) -> MTLTexture? {
        let loader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option: Any] = [
            .SRGB: false, .textureUsage: MTLTextureUsage.shaderRead.rawValue
        ]
        return try? loader.newTexture(cgImage: image, options: options)
    }

    private static func makeGrid() -> ([Vertex], [UInt32]) {
        let columns = 64, rows = 64
        var vertices: [Vertex] = []
        vertices.reserveCapacity((columns + 1) * (rows + 1))
        for row in 0 ... rows {
            let v = Float(row) / Float(rows)
            for column in 0 ... columns {
                let u = Float(column) / Float(columns)
                vertices.append(Vertex(position: SIMD2<Float>(u * 2 - 1, 1 - v * 2), uv: SIMD2<Float>(u, v)))
            }
        }
        var indices: [UInt32] = []
        indices.reserveCapacity(columns * rows * 6)
        let stride = columns + 1
        for row in 0 ..< rows {
            for column in 0 ..< columns {
                let topLeft = UInt32(row * stride + column)
                let topRight = topLeft + 1
                let bottomLeft = UInt32((row + 1) * stride + column)
                let bottomRight = bottomLeft + 1
                indices += [topLeft, bottomLeft, topRight, topRight, bottomLeft, bottomRight]
            }
        }
        return (vertices, indices)
    }

    private static func makeBuffer<T>(device: MTLDevice, values: [T]) -> MTLBuffer? {
        values.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return nil }
            return device.makeBuffer(bytes: baseAddress, length: rawBuffer.count, options: [])
        }
    }
}
