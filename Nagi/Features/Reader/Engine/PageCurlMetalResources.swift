import Metal
import MetalKit

/// Must stay layout-compatible with `PageCurlUniforms` in PageCurlShaders.metal.
/// Eight `Float` fields, same order, 32 bytes on both sides.
struct PageCurlUniforms {
    var progress: Float = 0
    var foldSign: Float = 1
    var aspect: Float = 1
    var curlRadius: Float = 0.18
    var shadowStrength: Float = 0.24
    var highlightStrength: Float = 0.10
    var paperTint: Float = 0.35
    var isDark: Float = 0
}

/// Process-wide Metal objects for the page curl.
///
/// Everything is built once, lazily, and shared by every animator. The reader
/// warms this up before the first gesture, so a gesture never pays for shader
/// or pipeline creation.
///
/// `shared` is nil when any piece fails to build — a missing shader library, a
/// device without the required formats. The reader then degrades to its cover
/// transition, since there is no second curl engine. Note that a `.metal` file
/// left out of the app target still builds cleanly and only fails here, so
/// `unavailableReason` is what turns that silent failure into a reportable one.
@MainActor
final class PageCurlMetalResources {
    static let shared: PageCurlMetalResources? = build()

    /// Set when `shared` is nil. Read it from the debug surface to explain why
    /// the Metal curl is not running.
    private(set) static var unavailableReason: String?

    static let colorPixelFormat: MTLPixelFormat = .bgra8Unorm
    static let depthPixelFormat: MTLPixelFormat = .depth32Float

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let meshPipeline: MTLRenderPipelineState
    let targetPipeline: MTLRenderPipelineState
    let shadowPipeline: MTLRenderPipelineState
    let depthState: MTLDepthStencilState
    /// Same comparison, but without writing. Used by the blended shadow so it
    /// cannot occlude the sheet that is drawn after it.
    let depthStateWithoutWrite: MTLDepthStencilState
    let sampler: MTLSamplerState
    let mesh: PageCurlMesh

    private init(
        device: MTLDevice,
        commandQueue: MTLCommandQueue,
        meshPipeline: MTLRenderPipelineState,
        targetPipeline: MTLRenderPipelineState,
        shadowPipeline: MTLRenderPipelineState,
        depthState: MTLDepthStencilState,
        depthStateWithoutWrite: MTLDepthStencilState,
        sampler: MTLSamplerState,
        mesh: PageCurlMesh
    ) {
        self.device = device
        self.commandQueue = commandQueue
        self.meshPipeline = meshPipeline
        self.targetPipeline = targetPipeline
        self.shadowPipeline = shadowPipeline
        self.depthState = depthState
        self.depthStateWithoutWrite = depthStateWithoutWrite
        self.sampler = sampler
        self.mesh = mesh
    }

    private static func build() -> PageCurlMetalResources? {
        guard let device = MTLCreateSystemDefaultDevice() else {
            unavailableReason = "no Metal device"
            return nil
        }
        guard let commandQueue = device.makeCommandQueue() else {
            unavailableReason = "no command queue"
            return nil
        }
        guard let library = device.makeDefaultLibrary() else {
            unavailableReason = "PageCurlShaders.metal is not in the app target"
            return nil
        }

        func makePipeline(
            vertex: String,
            fragment: String,
            blending: Bool
        ) -> MTLRenderPipelineState? {
            guard let vertexFunction = library.makeFunction(name: vertex),
                  let fragmentFunction = library.makeFunction(name: fragment) else {
                return nil
            }

            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragmentFunction
            descriptor.depthAttachmentPixelFormat = depthPixelFormat

            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = colorPixelFormat
            attachment.isBlendingEnabled = blending
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .sourceAlpha
            attachment.sourceAlphaBlendFactor = .sourceAlpha
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha

            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }

        guard let meshPipeline = makePipeline(
            vertex: "pageCurlVertex",
            fragment: "pageCurlFragment",
            blending: false
        ) else {
            unavailableReason = "pageCurlVertex/pageCurlFragment not found"
            return nil
        }
        guard let targetPipeline = makePipeline(
            vertex: "pageCurlFullscreenVertex",
            fragment: "pageCurlTargetFragment",
            blending: false
        ) else {
            unavailableReason = "pageCurlTargetFragment not found"
            return nil
        }
        guard let shadowPipeline = makePipeline(
            vertex: "pageCurlFullscreenVertex",
            fragment: "pageCurlShadowFragment",
            blending: true
        ) else {
            unavailableReason = "pageCurlShadowFragment not found"
            return nil
        }

        // `.lessEqual` rather than `.less`: the page plane, the shadow and the
        // flat parts of the sheet all sit at the same depth, so submission
        // order has to decide which wins — and that is exactly the order the
        // three passes are encoded in. Curled material is lifted toward the
        // viewer by the vertex shader, so it still occludes the flat sheet.
        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .lessEqual
        depthDescriptor.isDepthWriteEnabled = true
        guard let depthState = device.makeDepthStencilState(descriptor: depthDescriptor) else {
            unavailableReason = "no depth stencil state"
            return nil
        }

        let noWriteDescriptor = MTLDepthStencilDescriptor()
        noWriteDescriptor.depthCompareFunction = .lessEqual
        noWriteDescriptor.isDepthWriteEnabled = false
        guard let depthStateWithoutWrite = device.makeDepthStencilState(
            descriptor: noWriteDescriptor
        ) else {
            unavailableReason = "no blended depth stencil state"
            return nil
        }

        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .notMipmapped
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: samplerDescriptor) else {
            unavailableReason = "no sampler state"
            return nil
        }

        guard let mesh = PageCurlMesh(device: device) else {
            unavailableReason = "could not allocate the sheet mesh"
            return nil
        }

        return PageCurlMetalResources(
            device: device,
            commandQueue: commandQueue,
            meshPipeline: meshPipeline,
            targetPipeline: targetPipeline,
            shadowPipeline: shadowPipeline,
            depthState: depthState,
            depthStateWithoutWrite: depthStateWithoutWrite,
            sampler: sampler,
            mesh: mesh
        )
    }
}
