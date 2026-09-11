import Metal
import MetalKit

/// Encodes one frame of the page curl.
///
/// Three draws per frame, in this order:
///
/// 1. the page underneath, static
/// 2. the sheet's projected shadow, blended over it
/// 3. the curling sheet itself, with the back face shaded from the front face
///
/// The only per-frame work is a 32-byte uniform struct and three draw calls.
/// Neither texture is created, resized or uploaded here — the host uploads
/// both before the gesture starts.
@MainActor
final class PageCurlRenderer {
    private let resources: PageCurlMetalResources
    private var depthTexture: MTLTexture?
    private var depthTextureSize: CGSize = .zero

    init(resources: PageCurlMetalResources) {
        self.resources = resources
    }

    /// Encodes into `view`'s drawable. Returns false when the drawable or the
    /// depth attachment is unavailable, which the animator reports as a failed
    /// frame rather than a crash.
    func encode(
        in view: MTKView,
        currentTexture: MTLTexture,
        targetTexture: MTLTexture,
        uniforms: PageCurlUniforms,
        commandBuffer: MTLCommandBuffer
    ) -> Bool {
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor else {
            return false
        }

        let drawableSize = CGSize(
            width: CGFloat(drawable.texture.width),
            height: CGFloat(drawable.texture.height)
        )
        guard let depthTexture = depthTexture(for: drawableSize) else {
            return false
        }

        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.depthAttachment.texture = depthTexture
        descriptor.depthAttachment.loadAction = .clear
        descriptor.depthAttachment.storeAction = .dontCare
        descriptor.depthAttachment.clearDepth = 1.0

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return false
        }
        encoder.label = "PageCurl"

        var uniforms = uniforms

        // 1. The page underneath.
        encoder.setRenderPipelineState(resources.targetPipeline)
        encoder.setDepthStencilState(resources.depthState)
        encoder.setFragmentTexture(targetTexture, index: 0)
        encoder.setFragmentSamplerState(resources.sampler, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        // 2. The shadow, blended and without writing depth so it cannot hide
        //    the sheet drawn next.
        encoder.setRenderPipelineState(resources.shadowPipeline)
        encoder.setDepthStencilState(resources.depthStateWithoutWrite)
        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<PageCurlUniforms>.stride,
            index: 1
        )
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        // 3. The sheet. Back-face culling stays off: the back of the turning
        //    page is a real surface and the fragment stage shades it.
        encoder.setRenderPipelineState(resources.meshPipeline)
        encoder.setDepthStencilState(resources.depthState)
        // Culling stays off — the back of the turning sheet is a real surface
        // the fragment stage shades — but the winding still has to be declared:
        // the mesh is counter-clockwise and Metal defaults to clockwise, so
        // without this `[[front_facing]]` reports the opposite of the truth and
        // the page renders with its back-face shading.
        encoder.setFrontFacing(.counterClockwise)
        encoder.setCullMode(.none)
        encoder.setVertexBuffer(resources.mesh.vertexBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(
            &uniforms,
            length: MemoryLayout<PageCurlUniforms>.stride,
            index: 1
        )
        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<PageCurlUniforms>.stride,
            index: 1
        )
        encoder.setFragmentTexture(currentTexture, index: 0)
        encoder.setFragmentSamplerState(resources.sampler, index: 0)
        encoder.drawIndexedPrimitives(
            type: .triangle,
            indexCount: resources.mesh.indexCount,
            indexType: .uint16,
            indexBuffer: resources.mesh.indexBuffer,
            indexBufferOffset: 0
        )

        encoder.endEncoding()
        return true
    }

    /// Drops the depth attachment, so a memory warning actually reclaims it.
    func releaseDrawables() {
        depthTexture = nil
        depthTextureSize = .zero
    }

    /// The depth attachment is recreated only when the drawable changes size,
    /// which mirrors how the rest of the reader treats a geometry change as a
    /// reason to rebuild rather than to stretch.
    private func depthTexture(for size: CGSize) -> MTLTexture? {
        guard size.width >= 1, size.height >= 1 else { return nil }

        if let depthTexture,
           depthTextureSize == size,
           depthTexture.width == Int(size.width),
           depthTexture.height == Int(size.height) {
            return depthTexture
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: PageCurlMetalResources.depthPixelFormat,
            width: Int(size.width),
            height: Int(size.height),
            mipmapped: false
        )
        descriptor.usage = .renderTarget
        descriptor.storageMode = .private

        guard let texture = resources.device.makeTexture(descriptor: descriptor) else {
            return nil
        }
        depthTexture = texture
        depthTextureSize = size
        return texture
    }
}
