import CoreGraphics
import Metal
import ReadiumNavigator
import UIKit

/// Identifies one uploaded page texture.
///
/// The role is not decoration: `NavigatorPagePositionIdentity` for an adjacent
/// surface is the position the surface was *built from*, which is the current
/// page. Keying by identity alone therefore puts the current page and both
/// neighbours under one key and they overwrite each other.
struct CurlTextureKey: Hashable {
    enum Role: Hashable {
        case current
        case forward
        case backward
    }

    let originIdentity: NavigatorPagePositionIdentity
    /// Always `originIdentity.generation`. Kept explicit so a key reads as
    /// "this page, this generation, this role" at the call site.
    let generation: Int
    let role: Role

    init(originIdentity: NavigatorPagePositionIdentity, role: Role) {
        self.originIdentity = originIdentity
        generation = originIdentity.generation
        self.role = role
    }

    // The role mapping lives here rather than at each call site: prewarming and
    // lookup must agree, and a spread of hand-written mappings is how the
    // current page and its neighbour ended up sharing a key.
    static func current(_ surface: NavigatorCurrentPageSurface) -> CurlTextureKey {
        CurlTextureKey(originIdentity: surface.identity, role: .current)
    }

    static func adjacent(_ surface: PageSurface, direction: PageDirection) -> CurlTextureKey {
        CurlTextureKey(
            originIdentity: surface.originIdentity,
            role: direction == .forward ? .forward : .backward
        )
    }
}

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
    private var entries: [CurlTextureKey: Entry] = [:]
    /// Insertion order, oldest first. Eviction is deliberately trivial: the
    /// working set is tiny and refreshed wholesale by `removeAll()` on every
    /// invalidation the reader already has.
    private var insertionOrder: [CurlTextureKey] = []

    init(maximumEntryCount: Int = 4) {
        self.maximumEntryCount = max(1, maximumEntryCount)
    }

    var count: Int { entries.count }

    /// Returns the texture only when the stored geometry still matches, so a
    /// viewport change can never hand the renderer a stale-sized page.
    func texture(
        for key: CurlTextureKey,
        matching geometry: NavigatorPageSurfaceGeometry
    ) -> MTLTexture? {
        guard let entry = entries[key], entry.geometry == geometry else {
            return nil
        }
        return entry.texture
    }

    func store(
        _ texture: MTLTexture,
        geometry: NavigatorPageSurfaceGeometry,
        for key: CurlTextureKey
    ) {
        if entries[key] == nil {
            insertionOrder.append(key)
        }
        entries[key] = Entry(texture: texture, geometry: geometry)

        while insertionOrder.count > maximumEntryCount, let oldest = insertionOrder.first {
            insertionOrder.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }

    func remove(_ key: CurlTextureKey) {
        entries.removeValue(forKey: key)
        insertionOrder.removeAll { $0 == key }
    }

    func removeAll() {
        entries.removeAll()
        insertionOrder.removeAll()
    }

    /// The pair of textures a curl for `direction` needs, or nil when either is
    /// missing or was rasterised for a different geometry.
    func curlTextures(
        currentSurface: NavigatorCurrentPageSurface,
        targetSurface: PageSurface,
        direction: PageDirection
    ) -> (current: MTLTexture, target: MTLTexture)? {
        guard let current = texture(
            for: .current(currentSurface),
            matching: currentSurface.geometry
        ), let target = texture(
            for: .adjacent(targetSurface, direction: direction),
            matching: targetSurface.geometry
        ) else {
            return nil
        }
        return (current, target)
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
