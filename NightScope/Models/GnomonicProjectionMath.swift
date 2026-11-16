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
        return projectPoint(cx: cx, cy: cy, scale: scale, forward: forward, right: right, up: up,
                            horizontal: (x: point.0, y: point.1, z: point.2))
    }

    /// 地平直交座標（x=東, y=北, z=天頂）の方向ベクトルを投影する。
    @inline(__always)
    static func projectPoint(
        cx: Double,
        cy: Double,
        scale: Double,
        forward: (x: Double, y: Double, z: Double),
        right: (x: Double, y: Double, z: Double),
        up: (x: Double, y: Double, z: Double),
        horizontal point: (x: Double, y: Double, z: Double)
    ) -> CGPoint? {
        let dot = point.x * forward.x + point.y * forward.y + point.z * forward.z
        guard dot > 0.1 else { return nil }

        let px = (point.x * right.x + point.y * right.y + point.z * right.z) / dot * scale
        let py = (point.x * up.x    + point.y * up.y    + point.z * up.z)    / dot * scale
        return CGPoint(x: cx + px, y: cy - py)
    }

    /// 赤道座標の単位ベクトルを画面へ直接投影する。カメラ基底に赤道→地平回転を掛けた行列を
    /// フレームごとに 1 回作り、恒星 1 個あたりは内積 3 回と除算だけにする（三角関数なし）。
    struct EquatorialProjector {
        let cx: Double
        let cy: Double
        let scale: Double
        let forward: (x: Double, y: Double, z: Double)
        let right: (x: Double, y: Double, z: Double)
        let up: (x: Double, y: Double, z: Double)

        init(
            cx: Double,
            cy: Double,
            scale: Double,
            forward: (x: Double, y: Double, z: Double),
            right: (x: Double, y: Double, z: Double),
            up: (x: Double, y: Double, z: Double),
            rotation: MilkyWayCalculator.SkyRotation
        ) {
            self.cx = cx
            self.cy = cy
            self.scale = scale
            // 地平座標の基底ベクトル b を、赤道座標で b·(R v) = (Rᵀ b)·v となる Rᵀ b に変換する。
            func pullBack(_ b: (x: Double, y: Double, z: Double)) -> (x: Double, y: Double, z: Double) {
                (
                    b.x * rotation.eastX + b.y * rotation.northX + b.z * rotation.upX,
                    b.x * rotation.eastY + b.y * rotation.northY + b.z * rotation.upY,
                    b.x * rotation.eastZ + b.y * rotation.northZ + b.z * rotation.upZ
                )
            }
            self.forward = pullBack(forward)
            self.right = pullBack(right)
            self.up = pullBack(up)
        }

        @inline(__always)
        func project(x: Double, y: Double, z: Double) -> CGPoint? {
            GnomonicProjectionMath.projectPoint(
                cx: cx, cy: cy, scale: scale, forward: forward, right: right, up: up,
                horizontal: (x: x, y: y, z: z)
            )
        }
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
