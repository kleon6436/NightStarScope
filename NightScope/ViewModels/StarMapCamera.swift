import Foundation
import CoreGraphics

/// 画面向きに応じたスクリーン座標系を表す。
enum StarMapScreenOrientation: Sendable {
    case portrait
    case portraitUpsideDown
    case landscapeLeft
    case landscapeRight

    fileprivate var isLandscape: Bool {
        switch self {
        case .landscapeLeft, .landscapeRight:
            true
        case .portrait, .portraitUpsideDown:
            false
        }
    }

    var screenUpDeviceVector: (x: Double, y: Double, z: Double) {
        switch self {
        case .portrait:
            (x: 0, y: 1, z: 0)
        case .portraitUpsideDown:
            (x: 0, y: -1, z: 0)
        case .landscapeLeft:
            (x: -1, y: 0, z: 0)
        case .landscapeRight:
            (x: 1, y: 0, z: 0)
        }
    }
}

/// カメラの画角から、描画上で見える水平視野角を求める。
struct StarMapCameraFieldOfView: Equatable, Sendable {
    let diagonalDegrees: Double
    let sensorWidth: Int32
    let sensorHeight: Int32

    private var sensorAspectRatio: Double? {
        guard sensorWidth > 0, sensorHeight > 0 else { return nil }
        return Double(sensorWidth) / Double(sensorHeight)
    }

    private var landscapeHorizontalDegrees: Double? {
        degreesForAxis(multiplier: sensorAspectRatio)
    }

    private var landscapeVerticalDegrees: Double? {
        guard let sensorAspectRatio else { return nil }
        return degreesForAxis(multiplier: 1.0 / sensorAspectRatio)
    }

    func visibleHorizontalDegrees(
        viewportSize: CGSize,
        screenOrientation: StarMapScreenOrientation
    ) -> Double? {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return nil }
        guard let sensorAspectRatio,
              let landscapeHorizontalDegrees,
              let landscapeVerticalDegrees else {
            return nil
        }

        let viewportAspectRatio = viewportSize.width / viewportSize.height
        let contentAspectRatio = screenOrientation.isLandscape
            ? sensorAspectRatio
            : 1.0 / sensorAspectRatio
        let contentHorizontalDegrees = screenOrientation.isLandscape
            ? landscapeHorizontalDegrees
            : landscapeVerticalDegrees
        let contentVerticalDegrees = screenOrientation.isLandscape
            ? landscapeVerticalDegrees
            : landscapeHorizontalDegrees

        if viewportAspectRatio >= contentAspectRatio {
            return contentHorizontalDegrees
        }

        let visibleHalfHorizontalRadians = atan(
            tan(contentVerticalDegrees * .pi / 360) * viewportAspectRatio
        )
        return visibleHalfHorizontalRadians * 360 / .pi
    }

    private func degreesForAxis(multiplier: Double?) -> Double? {
        guard let multiplier else { return nil }
        let halfDiagonalRadians = diagonalDegrees * .pi / 360
        let base = tan(halfDiagonalRadians) / sqrt(multiplier * multiplier + 1)
        return atan(multiplier * base) * 360 / .pi
    }
}

/// カメラセッションを維持すべきかを表す状態。
struct StarMapCameraSessionState: Equatable, Sendable {
    let isGyroMode: Bool
    let isBackgroundEnabled: Bool
    let isAuthorized: Bool
    let hasCameraHardware: Bool
    let isSceneActive: Bool

    var shouldKeepPreviewAttached: Bool {
        isGyroMode && isAuthorized && hasCameraHardware
    }

    var isCameraBackgroundVisible: Bool {
        isGyroMode && isBackgroundEnabled && isAuthorized && hasCameraHardware
    }

    var shouldRunSession: Bool {
        isSceneActive && isCameraBackgroundVisible
    }
}

/// プレビューの向きを画面向きへ合わせるための回転角。
enum StarMapCameraPreviewRotation {
    static func fallbackAngle(for screenOrientation: StarMapScreenOrientation) -> CGFloat {
        switch screenOrientation {
        case .portrait:
            90
        case .portraitUpsideDown:
            270
        case .landscapeLeft:
            180
        case .landscapeRight:
            0
        }
    }
}

/// カメラ有効/無効の切り替え順を識別する世代番号付き状態。
struct StarMapCameraSessionActivationState: Sendable {
    private(set) var generation: UInt = 0
    private(set) var isActive = false

    @discardableResult
    mutating func update(isActive: Bool) -> UInt {
        generation &+= 1
        self.isActive = isActive
        return generation
    }

    func matches(generation: UInt, isActive: Bool) -> Bool {
        self.generation == generation && self.isActive == isActive
    }
}
