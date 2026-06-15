import CoreGraphics

/// 心射図法（グノモニック投影）の純粋計算関数群。
/// SwiftUI / AppKit / UIKit に依存しない pure static functions のみ含む。
struct GnomonicProjectionMath {

    struct HorizonLineCoefficients {
        let a: Double
        let b: Double
        let c: Double

        func value(at point: CGPoint) -> Double {
            a * point.x + b * point.y + c
        }
    }

    // MARK: - Cartesian / Camera Basis

    static func altAzToCartesian(alt: Double, az: Double) -> (Double, Double, Double) {
        let x = cos(alt) * sin(az)
        let y = cos(alt) * cos(az)
        let z = sin(alt)
        return (x, y, z)
    }

    static func cameraBasis(
        centerAlt: Double,
        centerAz: Double,
        roll: Double
    ) -> (
        forward: (x: Double, y: Double, z: Double),
        right: (x: Double, y: Double, z: Double),
        up: (x: Double, y: Double, z: Double)
    ) {
        let altRad = centerAlt * .pi / 180
        let azRad  = centerAz  * .pi / 180
        let rollRad = roll     * .pi / 180

        let fv = altAzToCartesian(alt: altRad, az: azRad)
        let forward = (x: fv.0, y: fv.1, z: fv.2)
        let baseRight = (x: cos(azRad), y: -sin(azRad), z: 0.0)

        let ucX = baseRight.y * forward.z - baseRight.z * forward.y
        let ucY = baseRight.z * forward.x - baseRight.x * forward.z
        let ucZ = baseRight.x * forward.y - baseRight.y * forward.x
        let ucLen = sqrt(ucX * ucX + ucY * ucY + ucZ * ucZ)
        let baseUp = ucLen > 1e-10
            ? (x: ucX / ucLen, y: ucY / ucLen, z: ucZ / ucLen)
            : (x: 0.0, y: 0.0, z: 1.0)

        let cr = cos(rollRad)
        let sr = sin(rollRad)
        let right = (
            x: baseRight.x * cr - baseUp.x * sr,
            y: baseRight.y * cr - baseUp.y * sr,
            z: baseRight.z * cr - baseUp.z * sr
        )
        let up = (
            x: baseRight.x * sr + baseUp.x * cr,
            y: baseRight.y * sr + baseUp.y * cr,
            z: baseRight.z * sr + baseUp.z * cr
        )
        return (forward: forward, right: right, up: up)
    }

    // MARK: - Projection

    static func projectionScale(size: CGSize, horizontalFOV: Double) -> Double {
        let halfFovRad = max(0.01, (horizontalFOV / 2) * .pi / 180)
        return size.width / (2 * tan(halfFovRad))
    }

    static func projectPoint(
        cx: Double,
        cy: Double,
        scale: Double,
        forward: (x: Double, y: Double, z: Double),
        right: (x: Double, y: Double, z: Double),
        up: (x: Double, y: Double, z: Double),
        altitudeRadians: Double,
        azimuthRadians: Double
    ) -> CGPoint? {
        let point = altAzToCartesian(alt: altitudeRadians, az: azimuthRadians)
        let dot = point.0 * forward.x + point.1 * forward.y + point.2 * forward.z
        guard dot > 0.1 else { return nil }

        let px = (point.0 * right.x + point.1 * right.y + point.2 * right.z) / dot * scale
        let py = (point.0 * up.x    + point.1 * up.y    + point.2 * up.z)    / dot * scale
        return CGPoint(x: cx + px, y: cy - py)
    }

    static func projectPoint(
        size: CGSize,
        centerAlt: Double,
        centerAz: Double,
        roll: Double,
        fov: Double,
        altitudeDegrees: Double,
        azimuthDegrees: Double
    ) -> CGPoint? {
        let basis = cameraBasis(centerAlt: centerAlt, centerAz: centerAz, roll: roll)
        return projectPoint(
            cx: size.width / 2,
            cy: size.height / 2,
            scale: projectionScale(size: size, horizontalFOV: fov),
            forward: basis.forward,
            right: basis.right,
            up: basis.up,
            altitudeRadians: altitudeDegrees * .pi / 180,
            azimuthRadians:  azimuthDegrees  * .pi / 180
        )
    }

    // MARK: - Horizon

    static func horizonLineCoefficients(
        cx: Double,
        cy: Double,
        scale: Double,
        forwardZ: Double,
        rightZ: Double,
        upZ: Double
    ) -> HorizonLineCoefficients {
        HorizonLineCoefficients(
            a: rightZ,
            b: -upZ,
            c: forwardZ * scale - rightZ * cx + upZ * cy
        )
    }

    static func horizonLineValue(
        size: CGSize,
        centerAlt: Double,
        centerAz: Double,
        roll: Double,
        fov: Double,
        point: CGPoint
    ) -> Double {
        let basis = cameraBasis(centerAlt: centerAlt, centerAz: centerAz, roll: roll)
        let coefficients = horizonLineCoefficients(
            cx: size.width / 2,
            cy: size.height / 2,
            scale: projectionScale(size: size, horizontalFOV: fov),
            forwardZ: basis.forward.z,
            rightZ: basis.right.z,
            upZ: basis.up.z
        )
        return coefficients.value(at: point)
    }

    static func clippedGroundPolygon(
        in rect: CGRect,
        coefficients: HorizonLineCoefficients
    ) -> [CGPoint] {
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY)
        ]
        let epsilon = 1e-6
        var clipped: [CGPoint] = []

        for i in corners.indices {
            let current = corners[i]
            let next    = corners[(i + 1) % corners.count]
            let cv = coefficients.value(at: current)
            let nv = coefficients.value(at: next)
            if cv <= epsilon { clipped.append(current) }
            if (cv <= epsilon) != (nv <= epsilon),
               let pt = lineIntersection(from: current, to: next, startValue: cv, endValue: nv) {
                clipped.append(pt)
            }
        }
        return clipped
    }

    static func horizonLineSegment(
        in rect: CGRect,
        coefficients: HorizonLineCoefficients
    ) -> (CGPoint, CGPoint)? {
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY)
        ]
        let epsilon = 1e-6
        var intersections: [CGPoint] = []

        func appendUnique(_ p: CGPoint) {
            guard !intersections.contains(where: {
                abs($0.x - p.x) < epsilon && abs($0.y - p.y) < epsilon
            }) else { return }
            intersections.append(p)
        }

        for i in corners.indices {
            let current = corners[i]
            let next    = corners[(i + 1) % corners.count]
            let cv = coefficients.value(at: current)
            let nv = coefficients.value(at: next)
            if abs(cv) < epsilon { appendUnique(current) }
            if cv * nv < 0,
               let pt = lineIntersection(from: current, to: next, startValue: cv, endValue: nv) {
                appendUnique(pt)
            }
        }
        guard intersections.count >= 2 else { return nil }
        return (intersections[0], intersections[1])
    }

    static func lineIntersection(
        from start: CGPoint,
        to end: CGPoint,
        startValue: Double,
        endValue: Double
    ) -> CGPoint? {
        let denom = startValue - endValue
        guard abs(denom) > 1e-10 else { return nil }
        let t = startValue / denom
        return CGPoint(
            x: start.x + (end.x - start.x) * t,
            y: start.y + (end.y - start.y) * t
        )
    }

    // MARK: - Drag

    static func adjustedCenter(
        altitude: Double,
        azimuth: Double,
        translation: CGSize,
        scale: Double
    ) -> (alt: Double, az: Double) {
        let yawRad   = atan2(translation.width,  scale)
        let pitchRad = atan2(translation.height, scale)

        var alt = altitude + pitchRad * 180 / .pi
        var az  = azimuth  - yawRad   * 180 / .pi

        alt = max(-10, min(89, alt))
        az  = az.truncatingRemainder(dividingBy: 360)
        if az < 0 { az += 360 }
        return (alt, az)
    }
}
