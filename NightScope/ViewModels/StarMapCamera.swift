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
/// `AVCaptureDevice.Format.videoFieldOfView` はセンサー横長（landscape）向きの水平視野角なので、
/// 対角視野角ではなく横長向きの水平視野角として受け取る。
struct StarMapCameraFieldOfView: Equatable, Sendable {
    /// センサー横長向き（長辺方向）の水平視野角（度）
    let landscapeHorizontalDegrees: Double
    let sensorWidth: Int32
    let sensorHeight: Int32

    /// センサー長辺 / 短辺。フォーマットの幅・高さの向きに依存しないよう長辺基準で求める。
    private var sensorAspectRatio: Double? {
        guard sensorWidth > 0, sensorHeight > 0 else { return nil }
        let longSide = Double(max(sensorWidth, sensorHeight))
        let shortSide = Double(min(sensorWidth, sensorHeight))
        return longSide / shortSide
    }

    private var landscapeVerticalDegrees: Double? {
        guard let sensorAspectRatio, landscapeHorizontalDegrees > 0, landscapeHorizontalDegrees < 180 else {
            return nil
        }
        let halfHorizontalRadians = landscapeHorizontalDegrees * .pi / 360
        return atan(tan(halfHorizontalRadians) / sensorAspectRatio) * 360 / .pi
    }

    func visibleHorizontalDegrees(
        viewportSize: CGSize,
        screenOrientation: StarMapScreenOrientation
    ) -> Double? {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return nil }
        guard let sensorAspectRatio,
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

        // resizeAspectFill: ビューポートの方が横長なら左右いっぱいに表示され、上下が切り取られる。
        if viewportAspectRatio >= contentAspectRatio {
            return contentHorizontalDegrees
        }

        // ビューポートの方が縦長なら上下いっぱいに表示され、左右が切り取られる。
        let visibleHalfHorizontalRadians = atan(
            tan(contentVerticalDegrees * .pi / 360) * viewportAspectRatio
        )
        return visibleHalfHorizontalRadians * 360 / .pi
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
