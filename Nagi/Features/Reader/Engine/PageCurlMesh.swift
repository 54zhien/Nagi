import Foundation
import Metal

/// The static sheet the curl is evaluated on.
///
/// The grid never changes: it is built once and uploaded once, and every frame
/// only varies the uniforms the vertex shader reads. 96 x 64 cells is about
/// 6.3k vertices, which is trivial for the GPU and still fine enough that the
/// bend reads as a smooth surface rather than a faceted one.
struct PageCurlMesh {
    /// Layout must match `PageCurlVertex` in PageCurlShaders.metal.
    struct Vertex {
        var position: SIMD2<Float>
        var uv: SIMD2<Float>
    }

    static let columns = 96
    static let rows = 64

    let vertexBuffer: MTLBuffer
    let indexBuffer: MTLBuffer
    let indexCount: Int

    /// Returns nil when the device cannot allocate the buffers, which the
    /// caller treats the same way as a missing pipeline: fall back.
    init?(device: MTLDevice) {
        let columnCount = Self.columns
        let rowCount = Self.rows

        var vertices: [Vertex] = []
        vertices.reserveCapacity((columnCount + 1) * (rowCount + 1))

        // Row-major, top-left to bottom-right, in normalized page space.
        for row in 0...rowCount {
            let v = Float(row) / Float(rowCount)
            for column in 0...columnCount {
                let u = Float(column) / Float(columnCount)
                vertices.append(Vertex(position: SIMD2(u, v), uv: SIMD2(u, v)))
            }
        }

        var indices: [UInt16] = []
        indices.reserveCapacity(columnCount * rowCount * 6)
        let stride = UInt16(columnCount + 1)
        for row in 0..<rowCount {
            for column in 0..<columnCount {
                let topLeft = UInt16(row) * stride + UInt16(column)
                let topRight = topLeft + 1
                let bottomLeft = topLeft + stride
                let bottomRight = bottomLeft + 1

                // Counter-clockwise on screen. The renderer declares this
                // winding explicitly rather than relying on Metal's clockwise
                // default, because `[[front_facing]]` is what tells the
                // fragment stage which side of the sheet it is shading.
                indices.append(contentsOf: [
                    topLeft, bottomLeft, topRight,
                    topRight, bottomLeft, bottomRight,
                ])
            }
        }

        guard !vertices.isEmpty, !indices.isEmpty,
              let vertexBuffer = device.makeBuffer(
                  bytes: vertices,
                  length: MemoryLayout<Vertex>.stride * vertices.count,
                  options: .storageModeShared
              ),
              let indexBuffer = device.makeBuffer(
                  bytes: indices,
                  length: MemoryLayout<UInt16>.stride * indices.count,
                  options: .storageModeShared
              ) else {
            return nil
        }

        self.vertexBuffer = vertexBuffer
        self.indexBuffer = indexBuffer
        indexCount = indices.count
    }
}
