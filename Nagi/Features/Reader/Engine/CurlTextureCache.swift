import CoreGraphics
import Metal
import ReadiumNavigator
import UIKit

/// Page textures for the Metal curl, uploaded while the reader is idle.
///
/// This is the whole point of the off-gesture pipeline: converting a page image
/// into a texture is the expensive part, and doing it on the first `.changed`
/// of a pan is what makes the curl feel late. The reader rasterises and uploads
/// here instead, and the gesture only ever looks a texture up.
@MainActor
final class CurlTextureCache {
    struct Entry {
        let texture: MTLTexture
        let geometry: NavigatorPageSurfaceGeometry
    }

    /// Three live textures is the working set (current, forward, backward); the
    /// cap leaves one slot of slack before eviction, and matters because a
    /// full-screen texture is roughly 12 MB at 3x.
    private let maximumEntryCount: Int
    private var entries: [NavigatorPagePositionIdentity: Entry] = [:]
    /// Insertion order, oldest first. Eviction is deliberately trivial: the
    /// working set is tiny and refreshed wholesale by `removeAll()` on every
    /// invalidation the reader already has.
    private var insertionOrder: [NavigatorPagePositionIdentity] = []

    init(maximumEntryCount: Int = 4) {
        self.maximumEntryCount = max(1, maximumEntryCount)
    }

    var count: Int { entries.count }

    /// Returns the texture only when the stored geometry still matches, so a
    /// viewport change can never hand the renderer a stale-sized page.
    func texture(
        for identity: NavigatorPagePositionIdentity,
        matching geometry: NavigatorPageSurfaceGeometry
    ) -> MTLTexture? {
        guard let entry = entries[identity], entry.geometry == geometry else {
            return nil
        }
        return entry.texture
    }

    func store(
        _ texture: MTLTexture,
        geometry: NavigatorPageSurfaceGeometry,
        for identity: NavigatorPagePositionIdentity
    ) {
        if entries[identity] == nil {
            insertionOrder.append(identity)
        }
        entries[identity] = Entry(texture: texture, geometry: geometry)

        while insertionOrder.count > maximumEntryCount, let oldest = insertionOrder.first {
            insertionOrder.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }

    func remove(_ identity: NavigatorPagePositionIdentity) {
        entries.removeValue(forKey: identity)
        insertionOrder.removeAll { $0 == identity }
    }

    func removeAll() {
        entries.removeAll()
        insertionOrder.removeAll()
    }

    // MARK: - Upload

    /// Converts a rasterised page into a texture, normalising the pixel format
    /// on the way.
    ///
    /// The conversion through an explicit CGContext is not incidental: a
    /// `CGImage`'s byte order depends on how it was produced, while a Metal
    /// texture declared `.bgra8Unorm` demands one specific layout. Redrawing
    /// into a context we configure ourselves is what guarantees the two agree
    /// and keeps the page colours from coming out swapped.
    ///
    /// Shared storage rather than private: on iOS the memory is unified, this
    /// runs a handful of times per page well away from the gesture, and it
    /// avoids a staging buffer and a blit for every texture.
    static func makeTexture(from image: UIImage, device: MTLDevice) -> MTLTexture? {
        guard let cgImage = image.cgImage else { return nil }

        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return nil }

        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue

        // The context points straight into `bytes`, so the draw has to happen
        // inside the accessor — the pointer is only valid for its duration.
        let didDraw = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                  let context = CGContext(
                      data: base,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: bytesPerRow,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: bitmapInfo
                  ) else {
                return false
            }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard didDraw else { return nil }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }

        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: bytes,
            bytesPerRow: bytesPerRow
        )
        return texture
    }
}
