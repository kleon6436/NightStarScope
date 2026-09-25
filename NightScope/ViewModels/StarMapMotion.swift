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
        let lookingVector = rotationMatrix.referenceVector(forDeviceVectorX: 0, y: 0, z: -1)
        let screenUpVector = rotationMatrix.referenceVector(forDeviceVector: screenOrientation.screenUpDeviceVector)
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

    private static func normalizedVector(
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

    private static func projectedOntoPlane(
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

    private static func cross(
        _ lhs: (east: Double, north: Double, up: Double),
        _ rhs: (east: Double, north: Double, up: Double)
    ) -> (east: Double, north: Double, up: Double) {
        (
            east: lhs.north * rhs.up - lhs.up * rhs.north,
            north: lhs.up * rhs.east - lhs.east * rhs.up,
            up: lhs.east * rhs.north - lhs.north * rhs.east
        )
    }

    private static func dot(
        _ lhs: (east: Double, north: Double, up: Double),
        _ rhs: (east: Double, north: Double, up: Double)
    ) -> Double {
        lhs.east * rhs.east + lhs.north * rhs.north + lhs.up * rhs.up
    }
}
