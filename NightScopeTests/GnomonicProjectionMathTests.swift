import XCTest
import CoreGraphics
@testable import NightScope

final class GnomonicProjectionMathTests: XCTestCase {

    // MARK: - cameraBasis

    func testCameraBasisOrthogonality() {
        let basis = GnomonicProjectionMath.cameraBasis(centerAlt: 45, centerAz: 90, roll: 0)
        let f = basis.forward
        let r = basis.right
        let u = basis.up

        let dotFR = f.x * r.x + f.y * r.y + f.z * r.z
        let dotFU = f.x * u.x + f.y * u.y + f.z * u.z
        let dotRU = r.x * u.x + r.y * u.y + r.z * u.z

        XCTAssertEqual(dotFR, 0, accuracy: 1e-10)
        XCTAssertEqual(dotFU, 0, accuracy: 1e-10)
        XCTAssertEqual(dotRU, 0, accuracy: 1e-10)
    }

    func testCameraBasisUnitLength() {
        let basis = GnomonicProjectionMath.cameraBasis(centerAlt: 30, centerAz: 180, roll: 15)
        let f = basis.forward
        let r = basis.right
        let u = basis.up

        let lenF = sqrt(f.x * f.x + f.y * f.y + f.z * f.z)
        let lenR = sqrt(r.x * r.x + r.y * r.y + r.z * r.z)
        let lenU = sqrt(u.x * u.x + u.y * u.y + u.z * u.z)

        XCTAssertEqual(lenF, 1.0, accuracy: 1e-10)
        XCTAssertEqual(lenR, 1.0, accuracy: 1e-10)
        XCTAssertEqual(lenU, 1.0, accuracy: 1e-10)
    }

    // MARK: - projectPoint

    func testProjectPointCenterMapsToCanvasCenter() {
        let size = CGSize(width: 400, height: 300)
        let alt = 45.0
        let az = 90.0
        let pt = GnomonicProjectionMath.projectPoint(
            size: size, centerAlt: alt, centerAz: az, roll: 0, fov: 90,
            altitudeDegrees: alt, azimuthDegrees: az
        )
        XCTAssertNotNil(pt)
        XCTAssertEqual(pt!.x, size.width / 2, accuracy: 0.01)
        XCTAssertEqual(pt!.y, size.height / 2, accuracy: 0.01)
    }

    func testProjectPointBehindCameraReturnsNil() {
        let size = CGSize(width: 400, height: 300)
        let pt = GnomonicProjectionMath.projectPoint(
            size: size, centerAlt: 45, centerAz: 0, roll: 0, fov: 90,
            altitudeDegrees: -45, azimuthDegrees: 180
        )
        XCTAssertNil(pt)
    }

    // MARK: - clippedGroundPolygon

    func testClippedGroundPolygonFullyAboveHorizon() {
        let size = CGSize(width: 400, height: 300)
        let rect = CGRect(origin: .zero, size: size)
        let coefficients = GnomonicProjectionMath.horizonLineCoefficients(
            cx: 200, cy: 150, scale: 200,
            forwardZ: 1.0, rightZ: 0.0, upZ: 0.0
        )
        let poly = GnomonicProjectionMath.clippedGroundPolygon(in: rect, coefficients: coefficients)
        XCTAssertTrue(poly.isEmpty)
    }

    func testClippedGroundPolygonFullyBelowHorizon() {
        let size = CGSize(width: 400, height: 300)
        let rect = CGRect(origin: .zero, size: size)
        let coefficients = GnomonicProjectionMath.horizonLineCoefficients(
            cx: 200, cy: 150, scale: 200,
            forwardZ: -1.0, rightZ: 0.0, upZ: 0.0
        )
        let poly = GnomonicProjectionMath.clippedGroundPolygon(in: rect, coefficients: coefficients)
        XCTAssertEqual(poly.count, 4)
    }

    // MARK: - adjustedCenter

    func testAdjustedCenterZeroTranslationIsIdentity() {
        let result = GnomonicProjectionMath.adjustedCenter(
            altitude: 45, azimuth: 90,
            translation: .zero, scale: 200
        )
        XCTAssertEqual(result.alt, 45, accuracy: 1e-10)
        XCTAssertEqual(result.az, 90, accuracy: 1e-10)
    }

    func testAdjustedCenterAltitudeClampedAt89() {
        let result = GnomonicProjectionMath.adjustedCenter(
            altitude: 85, azimuth: 0,
            translation: CGSize(width: 0, height: -10000),
            scale: 1
        )
        XCTAssertLessThanOrEqual(result.alt, 89)
    }
}
