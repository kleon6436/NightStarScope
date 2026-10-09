import Foundation

/// Core Motion の回転行列を、描画用の east-north-up 座標へ変換する。
struct StarMapMotionMatrix {
    let m11: Double
    let m12: Double
    let m13: Double
    let m21: Double
    let m22: Double
    let m23: Double
    let m31: Double
    let m32: Double
    let m33: Double

    fileprivate func referenceVector(forDeviceVectorX x: Double, y: Double, z: Double) -> (east: Double, north: Double, up: Double) {
        // Core Motion の xTrueNorth / xMagneticNorth 系は基準座標が north-west-up なので、
        // 画面描画で使う east-north-up に変換してから扱う。
        let north = (m11 * x) + (m21 * y) + (m31 * z)
        let west = (m12 * x) + (m22 * y) + (m32 * z)

        return (
            east: -west,
            north: north,
            up: (m13 * x) + (m23 * y) + (m33 * z)
        )
    }

    fileprivate func referenceVector(forDeviceVector vector: (x: Double, y: Double, z: Double)) -> (east: Double, north: Double, up: Double) {
        referenceVector(forDeviceVectorX: vector.x, y: vector.y, z: vector.z)
    }
}

/// 方位・仰角・ロールを表す、カメラ姿勢の正規化済み表現。
struct StarMapMotionPose: Equatable {
    let azimuth: Double
    let altitude: Double
    let roll: Double

    init(azimuth: Double, altitude: Double, roll: Double = 0) {
        self.azimuth = Self.normalizedAzimuth(azimuth)
        self.altitude = Self.clampedAltitude(altitude)
        self.roll = Self.normalizedRoll(roll)
    }

    static func make(
        rotationMatrix: StarMapMotionMatrix,
        screenOrientation: StarMapScreenOrientation = .portrait
    ) -> Self {
        StarMapMotionVectors.make(
            rotationMatrix: rotationMatrix,
            screenOrientation: screenOrientation
        ).pose
    }

    /// 視線方向と画面上方向（east-north-up）から方位・仰角・ロールを求める。
    static func make(
        forward lookingVector: (east: Double, north: Double, up: Double),
        screenUp screenUpVector: (east: Double, north: Double, up: Double)
    ) -> Self {
        let azimuth = normalizedAzimuth(atan2(lookingVector.east, lookingVector.north) * 180 / .pi)
        let altitude = atan2(
            lookingVector.up,
            hypot(lookingVector.east, lookingVector.north)
        ) * 180 / .pi
        let azimuthRadians = azimuth * .pi / 180
        let forward = normalizedVector(lookingVector)
        let right = (
            east: cos(azimuthRadians),
            north: -sin(azimuthRadians),
            up: 0.0
        )
        let defaultUp = normalizedVector(cross(right, forward))
        let projectedScreenUp = normalizedVector(projectedOntoPlane(screenUpVector, normal: forward))
        let roll = atan2(
            dot(projectedScreenUp, right),
            dot(projectedScreenUp, defaultUp)
        ) * 180 / .pi

        return Self(azimuth: azimuth, altitude: altitude, roll: roll)
    }

    /// 方位・仰角・ロールを個別に平滑化する（天頂付近では方位とロールが同時に 180° 反転するため、
    /// ジャイロ姿勢の平滑化には `StarMapMotionVectors.smoothed` を使うこと）。
    static func smoothed(previous: Self?, next: Self) -> Self {
        guard let previous else { return next }

        let azimuthDelta = wrappedAzimuthDelta(from: previous.azimuth, to: next.azimuth)
        let altitudeDelta = next.altitude - previous.altitude
        let rollDelta = wrappedSignedAngleDelta(from: previous.roll, to: next.roll)
        let azimuthFactor = smoothingFactor(for: abs(azimuthDelta), threshold: 12, base: 0.18, boosted: 0.34)
        let altitudeFactor = smoothingFactor(for: abs(altitudeDelta), threshold: 10, base: 0.18, boosted: 0.30)
        let rollFactor = smoothingFactor(for: abs(rollDelta), threshold: 15, base: 0.20, boosted: 0.36)

        return Self(
            azimuth: previous.azimuth + (azimuthDelta * azimuthFactor),
            altitude: previous.altitude + (altitudeDelta * altitudeFactor),
            roll: previous.roll + (rollDelta * rollFactor)
        )
    }

    static func normalizedAzimuth(_ azimuth: Double) -> Double {
        let normalized = azimuth.truncatingRemainder(dividingBy: 360)
        return normalized >= 0 ? normalized : normalized + 360
    }

    static func normalizedRoll(_ roll: Double) -> Double {
        let normalized = normalizedAzimuth(roll)
        return normalized > 180 ? normalized - 360 : normalized
    }

    private static func clampedAltitude(_ altitude: Double) -> Double {
        clamp(altitude, min: -10, max: 90)
    }

    private static func clamp(_ value: Double, min minimum: Double, max maximum: Double) -> Double {
        Swift.min(Swift.max(value, minimum), maximum)
    }

    private static func smoothingFactor(
        for deltaMagnitude: Double,
        threshold: Double,
        base: Double,
        boosted: Double
    ) -> Double {
        deltaMagnitude >= threshold ? boosted : base
    }

    private static func wrappedAzimuthDelta(from source: Double, to target: Double) -> Double {
        let rawDelta = normalizedAzimuth(target) - normalizedAzimuth(source)

        if rawDelta > 180 {
            return rawDelta - 360
        }
        if rawDelta < -180 {
            return rawDelta + 360
        }

        return rawDelta
    }

    private static func wrappedSignedAngleDelta(from source: Double, to target: Double) -> Double {
        normalizedRoll(target - source)
    }

    fileprivate static func normalizedVector(
        _ vector: (east: Double, north: Double, up: Double)
    ) -> (east: Double, north: Double, up: Double) {
        let length = sqrt(vector.east * vector.east + vector.north * vector.north + vector.up * vector.up)
        guard length > 1e-10 else {
            return (east: 0, north: 0, up: 1)
        }
        return (
            east: vector.east / length,
            north: vector.north / length,
            up: vector.up / length
        )
    }

    fileprivate static func projectedOntoPlane(
        _ vector: (east: Double, north: Double, up: Double),
        normal: (east: Double, north: Double, up: Double)
    ) -> (east: Double, north: Double, up: Double) {
        let projection = dot(vector, normal)
        return (
            east: vector.east - normal.east * projection,
            north: vector.north - normal.north * projection,
            up: vector.up - normal.up * projection
        )
    }

    fileprivate static func cross(
        _ lhs: (east: Double, north: Double, up: Double),
        _ rhs: (east: Double, north: Double, up: Double)
    ) -> (east: Double, north: Double, up: Double) {
        (
            east: lhs.north * rhs.up - lhs.up * rhs.north,
            north: lhs.up * rhs.east - lhs.east * rhs.up,
            up: lhs.east * rhs.north - lhs.north * rhs.east
        )
    }

    fileprivate static func dot(
        _ lhs: (east: Double, north: Double, up: Double),
        _ rhs: (east: Double, north: Double, up: Double)
    ) -> Double {
        lhs.east * rhs.east + lhs.north * rhs.north + lhs.up * rhs.up
    }
}

/// ジャイロ姿勢を視線方向・画面上方向の単位ベクトル（east-north-up）で表す。
/// 天頂付近では方位角とロールが 180° 反転して不連続になるため、平滑化はこのベクトル表現で行い、
/// 平滑化後のベクトルから方位・仰角・ロールを一貫して求める（ジンバルロック対策）。
struct StarMapMotionVectors {
    typealias Vector = (east: Double, north: Double, up: Double)

    let forward: Vector
    let screenUp: Vector

    init(forward: Vector, screenUp: Vector) {
        let normalizedForward = StarMapMotionPose.normalizedVector(forward)
        self.forward = normalizedForward
        self.screenUp = Self.orthonormalizedUp(screenUp, forward: normalizedForward)
    }

    static func make(
        rotationMatrix: StarMapMotionMatrix,
        screenOrientation: StarMapScreenOrientation = .portrait
    ) -> Self {
        Self(
            forward: rotationMatrix.referenceVector(forDeviceVectorX: 0, y: 0, z: -1),
            screenUp: rotationMatrix.referenceVector(forDeviceVector: screenOrientation.screenUpDeviceVector)
        )
    }

    /// 平滑化済みベクトルから求めた方位・仰角・ロール。
    var pose: StarMapMotionPose {
        StarMapMotionPose.make(forward: forward, screenUp: screenUp)
    }

    /// 前回値へ向けてベクトルを補間する。動きが大きいときは追従を速める。
    static func smoothed(previous: Self?, next: Self) -> Self {
        guard let previous else { return next }

        let forwardAngle = angleDegrees(previous.forward, next.forward)
        let upAngle = angleDegrees(previous.screenUp, next.screenUp)
        let forwardFactor = forwardAngle >= 12 ? 0.34 : 0.18
        let upFactor = upAngle >= 15 ? 0.36 : 0.20

        guard let forward = interpolated(previous.forward, next.forward, factor: forwardFactor),
              let screenUp = interpolated(previous.screenUp, next.screenUp, factor: upFactor) else {
            // ほぼ反対向きで補間が退化する場合は最新値へ切り替える。
            return next
        }
        let smoothed = Self(forward: forward, screenUp: screenUp)
        guard vectorLength(smoothed.screenUp) > 0.5 else { return next }
        return smoothed
    }

    private static func interpolated(_ from: Vector, _ to: Vector, factor: Double) -> Vector? {
        let mixed = (
            east: from.east + (to.east - from.east) * factor,
            north: from.north + (to.north - from.north) * factor,
            up: from.up + (to.up - from.up) * factor
        )
        guard vectorLength(mixed) > 1e-6 else { return nil }
        return StarMapMotionPose.normalizedVector(mixed)
    }

    /// 画面上方向を視線方向に直交する単位ベクトルへ補正する。
    private static func orthonormalizedUp(_ up: Vector, forward: Vector) -> Vector {
        let projected = StarMapMotionPose.projectedOntoPlane(up, normal: forward)
        guard vectorLength(projected) > 1e-6 else { return (east: 0, north: 0, up: 0) }
        return StarMapMotionPose.normalizedVector(projected)
    }

    private static func angleDegrees(_ lhs: Vector, _ rhs: Vector) -> Double {
        let cosine = max(-1, min(1, StarMapMotionPose.dot(lhs, rhs)))
        return acos(cosine) * 180 / .pi
    }

    private static func vectorLength(_ vector: Vector) -> Double {
        sqrt(vector.east * vector.east + vector.north * vector.north + vector.up * vector.up)
    }
}
