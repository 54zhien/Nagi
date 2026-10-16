import ReadiumNavigator
import ReadiumShared
import UIKit
import XCTest
@testable import Nagi

/// E5-S1 host surface seam contract. These tests compile against the real
/// Nagi App module hosted by Nagi.app; the App-owned surface values and the
/// Readium bridge they reference are introduced by the S1 implementation.
final class ReaderSurfaceContractTests: XCTestCase {
    private struct FixtureKey: Hashable {
        let chapter: Int
        let page: Int
    }

    private static let originLocatorJSON = """
    {"href":"OEBPS/chapter-001.xhtml","type":"application/xhtml+xml","title":"Chapter 1","locations":{"progression":0.25,"position":3}}
    """

    private static let targetLocatorJSON = """
    {"href":"OEBPS/chapter-001.xhtml","type":"application/xhtml+xml","title":"Chapter 1","locations":{"progression":0.5,"position":4}}
    """

    // MARK: - App identity values

    func testIdenticalKeysInOneNamespaceCompareEqual() {
        let namespace = UUID()
        let key = FixtureKey(chapter: 2, page: 11)
        let otherKey = FixtureKey(chapter: 2, page: 12)

        let positionA = PagePositionIdentity(namespace: namespace, value: key)
        let positionB = PagePositionIdentity(namespace: namespace, value: FixtureKey(chapter: 2, page: 11))
        XCTAssertEqual(positionA, positionB)
        XCTAssertEqual(Set([positionA, positionB]).count, 1)
        let otherPosition = PagePositionIdentity(namespace: namespace, value: otherKey)
        XCTAssertNotEqual(positionA, otherPosition)
        XCTAssertEqual(Set([positionA, otherPosition]).count, 2)

        let surfaceA = PageSurfaceIdentity(namespace: namespace, value: key)
        let surfaceB = PageSurfaceIdentity(namespace: namespace, value: FixtureKey(chapter: 2, page: 11))
        XCTAssertEqual(surfaceA, surfaceB)
        XCTAssertEqual(Set([surfaceA, surfaceB]).count, 1)
        let otherSurface = PageSurfaceIdentity(namespace: namespace, value: otherKey)
        XCTAssertNotEqual(surfaceA, otherSurface)
        XCTAssertEqual(Set([surfaceA, otherSurface]).count, 2)
    }

    func testKeysInDifferentNamespacesStayDistinct() {
        let firstNamespace = UUID()
        let secondNamespace = UUID()
        let key = FixtureKey(chapter: 2, page: 11)

        let firstPosition = PagePositionIdentity(namespace: firstNamespace, value: key)
        let secondPosition = PagePositionIdentity(namespace: secondNamespace, value: key)
        XCTAssertNotEqual(firstPosition, secondPosition)
        XCTAssertEqual(Set([firstPosition, secondPosition]).count, 2)

        let firstSurface = PageSurfaceIdentity(namespace: firstNamespace, value: key)
        let secondSurface = PageSurfaceIdentity(namespace: secondNamespace, value: key)
        XCTAssertNotEqual(firstSurface, secondSurface)
        XCTAssertEqual(Set([firstSurface, secondSurface]).count, 2)
    }

    func testDifferentPayloadTypesDoNotCollapse() {
        let namespace = UUID()

        let intPosition = PagePositionIdentity(namespace: namespace, value: Int(1))
        let int64Position = PagePositionIdentity(namespace: namespace, value: Int64(1))
        XCTAssertNotEqual(intPosition, int64Position)
        XCTAssertEqual(Set([intPosition, int64Position]).count, 2)

        let intSurface = PageSurfaceIdentity(namespace: namespace, value: Int(1))
        let int64Surface = PageSurfaceIdentity(namespace: namespace, value: Int64(1))
        XCTAssertNotEqual(intSurface, int64Surface)
        XCTAssertEqual(Set([intSurface, int64Surface]).count, 2)
    }

    // MARK: - Readium bridge

    @MainActor
    func testAdjacentOriginMatchesCurrentPositionIdentity() throws {
        let originLocator = try XCTUnwrap(Locator(jsonString: Self.originLocatorJSON))
        let targetLocator = try XCTUnwrap(Locator(jsonString: Self.targetLocatorJSON))
        let namespace = UUID()

        let currentFork = NavigatorPagePositionIdentity(locator: originLocator, generation: 4)
        let originFork = NavigatorPagePositionIdentity(locator: originLocator, generation: 4)
        let staleFork = NavigatorPagePositionIdentity(locator: originLocator, generation: 5)
        XCTAssertEqual(currentFork, originFork)

        let currentIdentity = ReadiumPageSurfaceBridge.positionIdentity(currentFork, namespace: namespace)
        let originIdentity = ReadiumPageSurfaceBridge.positionIdentity(originFork, namespace: namespace)
        XCTAssertEqual(currentIdentity, PagePositionIdentity(namespace: namespace, value: currentFork))
        XCTAssertEqual(currentIdentity, originIdentity)
        XCTAssertNotEqual(
            currentIdentity,
            ReadiumPageSurfaceBridge.positionIdentity(staleFork, namespace: namespace)
        )
        XCTAssertNotEqual(
            currentIdentity,
            ReadiumPageSurfaceBridge.positionIdentity(originFork, namespace: UUID())
        )

        let image = Self.makeImage(pointSize: CGSize(width: 9, height: 5), scale: 3)
        let geometry = ReadiumPageSurfaceBridge.geometry(
            NavigatorPageSurfaceGeometry(
                image: image,
                contentRect: CGRect(x: 0.5, y: 1.25, width: 7.75, height: 3.5)
            )
        )
        let current = CurrentPageSurface(
            image: image,
            geometry: geometry,
            identity: currentIdentity,
            generation: 4
        )
        let rawAdjacent = NavigatorPageSurfaceIdentity(
            direction: .forward,
            locator: targetLocator,
            epoch: 4,
            leafHREF: targetLocator.href,
            leafIndex: 2
        )
        let expectedAdjacentIdentity = PageSurfaceIdentity(namespace: namespace, value: rawAdjacent)
        let adjacentIdentity = ReadiumPageSurfaceBridge.surfaceIdentity(rawAdjacent, namespace: namespace)
        XCTAssertEqual(adjacentIdentity, expectedAdjacentIdentity)
        XCTAssertEqual(
            adjacentIdentity,
            ReadiumPageSurfaceBridge.surfaceIdentity(rawAdjacent, namespace: namespace)
        )
        XCTAssertNotEqual(
            adjacentIdentity,
            ReadiumPageSurfaceBridge.surfaceIdentity(rawAdjacent, namespace: UUID())
        )
        let adjacent = PageSurface(
            direction: .forward,
            image: image,
            identity: adjacentIdentity,
            originIdentity: originIdentity,
            generation: 4,
            geometry: geometry,
            headerTitle: nil
        )

        XCTAssertEqual(adjacent.identity, expectedAdjacentIdentity)
        XCTAssertEqual(adjacent.originIdentity, current.identity)
        XCTAssertEqual(adjacent.generation, current.generation)
    }

    @MainActor
    func testGeometryCopiesEveryFieldWithoutRemeasuring() {
        let image = Self.makeImage(pointSize: CGSize(width: 9, height: 5), scale: 3)
        let contentRect = CGRect(x: 0.5, y: 1.25, width: 7.75, height: 3.5)
        let fork = NavigatorPageSurfaceGeometry(image: image, contentRect: contentRect)
        XCTAssertEqual(fork.pixelSize, CGSize(width: 27, height: 15))
        XCTAssertEqual(fork.scale, 3)

        let bridged = ReadiumPageSurfaceBridge.geometry(fork)

        XCTAssertEqual(bridged.pointSize, fork.pointSize)
        XCTAssertEqual(bridged.pixelSize, fork.pixelSize)
        XCTAssertEqual(bridged.scale, fork.scale)
        XCTAssertEqual(bridged.contentRect, fork.contentRect)
        XCTAssertEqual(bridged.contentRect, contentRect)
    }

    @MainActor
    func testEveryReadinessCaseMapsToItsAppCase() {
        let expectations: [(fork: NavigatorPageSurfaceReadiness, app: PageSurfaceReadiness)] = [
            (.unknown, .unknown),
            (.unavailable, .unavailable),
            (.preparing, .preparing),
            (.ready, .ready),
            (.failed, .failed),
        ]
        XCTAssertEqual(expectations.count, 5)

        for expectation in expectations {
            XCTAssertEqual(
                ReadiumPageSurfaceBridge.readiness(expectation.fork),
                expectation.app,
                "fork readiness \(expectation.fork)"
            )
        }
    }

    // MARK: - App-owned provider seam

    @MainActor
    func testAProviderCanExposeAnAppOwnedCurrentSurface() throws {
        let image = Self.makeImage(pointSize: CGSize(width: 9, height: 5), scale: 3)
        let identity = PagePositionIdentity(namespace: UUID(), value: FixtureKey(chapter: 2, page: 11))
        let geometry = PageSurfaceGeometry(
            pointSize: CGSize(width: 9, height: 5),
            pixelSize: CGSize(width: 27, height: 15),
            scale: 3,
            contentRect: CGRect(x: 0.5, y: 1.25, width: 7.75, height: 3.5)
        )
        let current = CurrentPageSurface(
            image: image,
            geometry: geometry,
            identity: identity,
            generation: 12
        )
        let provider: any PageSurfaceProvider = AppOwnedSurfaceProviderStub(currentSurface: current)

        let exposed = try XCTUnwrap(provider.preparedCurrentSurface())

        XCTAssertTrue(exposed === current)
        XCTAssertTrue(exposed.image === image)
        XCTAssertEqual(exposed.identity, identity)
        XCTAssertEqual(exposed.geometry, geometry)
        XCTAssertEqual(exposed.generation, 12)
        XCTAssertEqual(provider.adjacentSurfaceReadiness(direction: .forward), .unavailable)
    }

    // MARK: - Fixtures

    @MainActor
    private static func makeImage(pointSize: CGSize, scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: pointSize, format: format).image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(origin: .zero, size: pointSize))
        }
    }
}

/// Provider implemented only with App surface types. It never snapshots,
/// lays out, or navigates; it only hands back the surface it was given.
@MainActor
private final class AppOwnedSurfaceProviderStub: PageSurfaceProvider {
    private let currentSurface: CurrentPageSurface

    init(currentSurface: CurrentPageSurface) {
        self.currentSurface = currentSurface
    }

    var readingDirection: PageTurnReadingDirection { .leftToRight }
    var usesContinuousScroll: Bool { false }
    var supportsCustomPageTurns: Bool { true }
    var isPageSurfaceProviderReady: Bool { true }

    func prewarmAdjacentSurfaces(preferredDirection: PageDirection, deadline: UInt64) async {}

    func preparedCurrentSurface() -> CurrentPageSurface? {
        currentSurface
    }

    func preparedAdjacentSurface(direction: PageDirection) -> PageSurface? {
        nil
    }

    func adjacentSurfaceReadiness(direction: PageDirection) -> PageSurfaceReadiness {
        .unavailable
    }

    func takePreparedAdjacentSurface(direction: PageDirection) -> PageSurface? {
        nil
    }

    func commit(surface: PageSurface) async -> PageSurfaceCommitResult {
        .restored
    }

    func reconcile(surface: PageSurface, deadline: UInt64) async -> PageSurfaceCommitResult {
        .restored
    }

    func discardReconciliation(for surface: PageSurface) {}

    func cancel(surface: PageSurface) {}

    func navigateWithoutCustomTransition(direction: PageDirection) async -> Bool {
        false
    }

    func setBuiltInPageTurnInteractionEnabled(_ enabled: Bool) {}

    func invalidatePreparedSurfaces() {}
}
