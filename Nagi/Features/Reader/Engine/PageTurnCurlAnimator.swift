import CoreGraphics
import Metal
import MetalKit
import QuartzCore
import UIKit

/// A GPU-backed page-turn animator for detached reader surfaces.
///
/// The two composite UIViews are rasterized and uploaded before `install()` so
/// that gesture updates only change a small uniform buffer and submit a draw.
/// The live Readium view and the reader chrome are never part of this view
/// hierarchy; the caller owns the host view's position below its controls.
@MainActor
final class PageTurnCurlAnimator: NSObject, PageTurnAnimating, MTKViewDelegate {
    private struct Vertex {
        var position: SIMD2<Float>
        var uv: SIMD2<Float>
    }

    private struct Uniforms {
        var progress: Float
        var direction: Float
        var isDark: Float
        var padding: Float = 0
    }

    private let hostView: UIView
    private let metalView: MTKView
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let vertexBuffer: MTLBuffer
    private let indexBuffer: MTLBuffer
    private let indexCount: Int
    private let targetTexture: MTLTexture
    private let currentTexture: MTLTexture
    private let targetPipeline: MTLRenderPipelineState
    private let curlPipeline: MTLRenderPipelineState
    private let completionTranslationX: CGFloat
    private let isDark: Bool

    private var displayLink: CADisplayLink?
    private var animationStartTime: CFTimeInterval = 0
    private var animationDuration: CFTimeInterval = 0
    private var animationStartProgress: CGFloat = 0
    private var animationTargetProgress: CGFloat = 0
    private var animationCompletion: ((Bool) -> Void)?
    private var cancellationCompletion: (() -> Void)?
    private var animationRevision = 0
    private(set) var progress: CGFloat = 0

    /// Fails when Metal, the shader library, the mesh, or either pre-uploaded
    /// page texture cannot be created. The caller can then use a CPU fallback.
    init?(
        hostView: UIView,
        currentView: UIView,
        targetView: UIView,
        completionTranslationX: CGFloat,
        isDark: Bool
    ) {
        guard completionTranslationX.isFinite, completionTranslationX != 0,
              let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let targetFunction = library.makeFunction(name: "page_turn_target_fragment"),
              let curlVertexFunction = library.makeFunction(name: "page_turn_curl_vertex"),
              let curlFragmentFunction = library.makeFunction(name: "page_turn_curl_fragment")
        else { return nil }

        guard let targetImage = Self.snapshotImage(for: targetView),
              let currentImage = Self.snapshotImage(for: currentView),
              let targetTexture = Self.makeTexture(device: device, image: targetImage),
              let currentTexture = Self.makeTexture(device: device, image: currentImage),
              let (vertices, indices) = Self.makeGrid(),
              let vertexBuffer = Self.makeBuffer(device: device, values: vertices),
              let indexBuffer = Self.makeBuffer(device: device, values: indices)
        else { return nil }

        let targetDescriptor = MTLRenderPipelineDescriptor()
        targetDescriptor.vertexFunction = library.makeFunction(name: "page_turn_fullscreen_vertex")
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

        guard let targetPipeline = try? device.makeRenderPipelineState(descriptor: targetDescriptor),
              let curlPipeline = try? device.makeRenderPipelineState(descriptor: curlDescriptor)
        else { return nil }

        let metalView = MTKView(frame: hostView.bounds, device: device)
        metalView.colorPixelFormat = .bgra8Unorm
        metalView.framebufferOnly = true
        metalView.isPaused = true
        metalView.enableSetNeedsDisplay = true
        let maximumFramesPerSecond = hostView.window?.windowScene?.screen.maximumFramesPerSecond ?? 60
        metalView.preferredFramesPerSecond = min(120, maximumFramesPerSecond)
        metalView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        metalView.isOpaque = true
        metalView.isUserInteractionEnabled = false
        metalView.accessibilityElementsHidden = true
        metalView.isAccessibilityElement = false

        self.hostView = hostView
        self.metalView = metalView
        self.device = device
        self.commandQueue = commandQueue
        self.vertexBuffer = vertexBuffer
        self.indexBuffer = indexBuffer
        self.indexCount = indices.count
        self.targetTexture = targetTexture
        self.currentTexture = currentTexture
        self.targetPipeline = targetPipeline
        self.curlPipeline = curlPipeline
        self.completionTranslationX = completionTranslationX
        self.isDark = isDark
        super.init()
        metalView.delegate = self
    }

    func install() {
        animationRevision &+= 1
        stopAnimation()
        metalView.frame = hostView.bounds
        metalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        metalView.removeFromSuperview()
        hostView.addSubview(metalView)
        metalView.layer.zPosition = 0
        update(progress: 0)
    }

    func update(progress rawProgress: CGFloat) {
        progress = min(max(rawProgress.isFinite ? rawProgress : 0, 0), 1)
        metalView.draw()
    }

    func animateCompletion(completion: @escaping (Bool) -> Void) {
        beginDisplayLink(
            targetProgress: 1,
            duration: 0.22 * max(0.001, 1 - progress),
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
        metalView.delegate = nil
        metalView.removeFromSuperview()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        encoder.setRenderPipelineState(targetPipeline)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        var uniforms = Uniforms(progress: 0, direction: direction, isDark: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.setFragmentTexture(targetTexture, index: 0)
        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: indexCount,
            indexType: .uint32,
            indexBuffer: indexBuffer,
            indexBufferOffset: 0
        )

        encoder.setRenderPipelineState(curlPipeline)
        uniforms = Uniforms(progress: Float(progress), direction: direction, isDark: isDark ? 1 : 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.setFragmentTexture(currentTexture, index: 0)
        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: indexCount,
            indexType: .uint32,
            indexBuffer: indexBuffer,
            indexBufferOffset: 0
        )

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private var direction: Float {
        completionTranslationX < 0 ? -1 : 1
    }

    private func beginDisplayLink(
        targetProgress: CGFloat,
        duration: TimeInterval,
        completion: ((Bool) -> Void)?,
        cancellation: (() -> Void)?
    ) {
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
            minimum: min(60, maximumFramesPerSecond),
            maximum: min(120, maximumFramesPerSecond),
            preferred: min(120, maximumFramesPerSecond)
        )
        self.displayLink = displayLink
        displayLink.add(to: .main, forMode: .common)
    }

    @objc private func displayLinkTick(_ link: CADisplayLink) {
        if animationStartTime == 0 {
            animationStartTime = link.timestamp
        }
        let elapsed = max(0, link.timestamp - animationStartTime)
        let normalized = min(1, elapsed / animationDuration)
        let eased = 1 - pow(1 - normalized, 3)
        let nextProgress = animationStartProgress
            + (animationTargetProgress - animationStartProgress) * eased
        update(progress: nextProgress)

        guard normalized >= 1 else { return }
        let completion = animationCompletion
        let cancellation = cancellationCompletion
        stopAnimation()
        if animationTargetProgress == 0 {
            cancellation?()
        } else {
            completion?(true)
        }
    }

    private func stopAnimation() {
        displayLink?.invalidate()
        displayLink = nil
        animationCompletion = nil
        cancellationCompletion = nil
    }

    private static func snapshotImage(for view: UIView) -> CGImage? {
        let bounds = view.bounds.integral
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = view.window?.windowScene?.screen.scale ?? view.traitCollection.displayScale
        format.opaque = true
        return UIGraphicsImageRenderer(bounds: bounds, format: format).image { context in
            view.layer.render(in: context.cgContext)
        }.cgImage
    }

    private static func makeTexture(device: MTLDevice, image: CGImage) -> MTLTexture? {
        let loader = MTKTextureLoader(device: device)
        return try? loader.newTexture(cgImage: image, options: [.SRGB: false])
    }

    private static func makeGrid() -> ([Vertex], [UInt32]) {
        let columns = 64
        let rows = 64
        var vertices: [Vertex] = []
        vertices.reserveCapacity((columns + 1) * (rows + 1))
        for row in 0 ... rows {
            let v = Float(row) / Float(rows)
            for column in 0 ... columns {
                let u = Float(column) / Float(columns)
                vertices.append(Vertex(
                    position: SIMD2<Float>(u * 2 - 1, 1 - v * 2),
                    uv: SIMD2<Float>(u, v)
                ))
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
            return device.makeBuffer(
                bytes: baseAddress,
                length: rawBuffer.count,
                options: []
            )
        }
    }
}
