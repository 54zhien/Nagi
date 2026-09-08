import Metal
import MetalKit
import UIKit

struct PageTurnPreparedTextures {
    let current: MTLTexture
    let target: MTLTexture
}

@MainActor
final class PageTurnMetalContext {
    struct Vertex {
        var position: SIMD2<Float>
        var uv: SIMD2<Float>
    }

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let targetPipeline: MTLRenderPipelineState
    let curlPipeline: MTLRenderPipelineState
    let backPipeline: MTLRenderPipelineState
    let depthState: MTLDepthStencilState
    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    let indexCount: Int

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let commandQueue = device.makeCommandQueue(),
              let library = device.makeDefaultLibrary(),
              let fullscreenVertex = library.makeFunction(name: "page_turn_fullscreen_vertex"),
              let targetFunction = library.makeFunction(name: "page_turn_target_fragment"),
              let curlVertexFunction = library.makeFunction(name: "page_turn_curl_vertex"),
              let curlFragmentFunction = library.makeFunction(name: "page_turn_curl_fragment"),
              let backFragmentFunction = library.makeFunction(name: "page_turn_curl_back_fragment")
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
        curlDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        curlDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        curlDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        curlDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        let backDescriptor = MTLRenderPipelineDescriptor()
        backDescriptor.vertexFunction = curlVertexFunction
        backDescriptor.fragmentFunction = backFragmentFunction
        backDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm

        for descriptor in [targetDescriptor, curlDescriptor, backDescriptor] {
            descriptor.depthAttachmentPixelFormat = .depth32Float
        }
        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .greater
        depthDescriptor.isDepthWriteEnabled = true
        let (vertices, indices) = Self.makeGrid()

        guard let depthState = device.makeDepthStencilState(descriptor: depthDescriptor),
              let targetPipeline = try? device.makeRenderPipelineState(descriptor: targetDescriptor),
              let curlPipeline = try? device.makeRenderPipelineState(descriptor: curlDescriptor),
              let backPipeline = try? device.makeRenderPipelineState(descriptor: backDescriptor),
              let vertexBuffer = Self.makeBuffer(device: device, values: vertices),
              let indexBuffer = Self.makeBuffer(device: device, values: indices)
        else { return nil }

        self.device = device
        self.commandQueue = commandQueue
        self.targetPipeline = targetPipeline
        self.curlPipeline = curlPipeline
        self.backPipeline = backPipeline
        self.depthState = depthState
        self.vertexBuffer = vertexBuffer
        self.indexBuffer = indexBuffer
        indexCount = indices.count
    }

    func makePreparedTextures(
        currentImage: UIImage,
        targetImage: UIImage
    ) -> PageTurnPreparedTextures? {
        guard let currentImage = currentImage.cgImage,
              let targetImage = targetImage.cgImage else { return nil }
        let loader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option: Any] = [
            .SRGB: false,
            .textureUsage: MTLTextureUsage.shaderRead.rawValue,
        ]
        guard let current = try? loader.newTexture(cgImage: currentImage, options: options),
              let target = try? loader.newTexture(cgImage: targetImage, options: options) else {
            return nil
        }
        return PageTurnPreparedTextures(current: current, target: target)
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
