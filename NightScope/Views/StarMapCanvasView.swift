import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

// MARK: - StarMapCanvasView

/// 星空マップを描画する共有ビュー (iPhone / Mac 共通)
/// - 心射図法 (viewAltitude/viewAzimuth が画面中心)
struct StarMapCanvasView: View {
    struct CardinalOverlayPlacement: Identifiable, Equatable {
        let azimuthDegrees: Double
        let label: String
        let x: Double

        var id: Double { azimuthDegrees }
    }

    struct HorizonOverlayStyle {
        let groundFillColor: Color
        let groundFillOpacity: Double
        let horizonStrokeColor: Color
        let terrainFillColor: Color
        let terrainFillOpacity: Double
        let terrainStrokeColor: Color

        static let `default` = HorizonOverlayStyle(
            groundFillColor: Color(red: 0.08, green: 0.12, blue: 0.06),
            groundFillOpacity: 0.6,
            horizonStrokeColor: Color(red: 0.3, green: 0.5, blue: 0.3).opacity(0.5),
            terrainFillColor: StarMapPalette.groundFill,
            terrainFillOpacity: 1,
            terrainStrokeColor: Color(red: 0.2, green: 0.35, blue: 0.15).opacity(0.4)
        )
    }

    private struct GnomonicProjectionContext {
        let cx: Double
        let cy: Double
        let scale: Double
        let forward: (x: Double, y: Double, z: Double)
        let right: (x: Double, y: Double, z: Double)
        let up: (x: Double, y: Double, z: Double)

        init(size: CGSize, centerAlt: Double, centerAz: Double, rollDegrees: Double, fov: Double) {
            self.cx = size.width / 2
            self.cy = size.height / 2
            self.scale = GnomonicProjectionMath.projectionScale(size: size, horizontalFOV: fov)
            let basis = GnomonicProjectionMath.cameraBasis(
                centerAlt: centerAlt,
                centerAz: centerAz,
                roll: rollDegrees
            )
            self.forward = basis.forward
            self.right = basis.right
            self.up = basis.up
        }

        func project(altitudeRadians: Double, azimuthRadians: Double) -> CGPoint? {
            GnomonicProjectionMath.projectPoint(
                cx: cx,
                cy: cy,
                scale: scale,
                forward: forward,
                right: right,
                up: up,
                altitudeRadians: altitudeRadians,
                azimuthRadians: azimuthRadians
            )
        }
    }

    @ObservedObject var viewModel: StarMapViewModel
    var showsCardinalOverlay: Bool = true
    var cardinalOverlayBottomInset: CGFloat = StarMapLayout.cardinalLabelBottomInset
    var backgroundColor: Color = StarMapPalette.canvasBackground
    var drawsDynamicSky: Bool = true
    var horizonOverlayStyle: HorizonOverlayStyle = .default
    var fovOverride: Double? = nil
    var rollOverride: Double? = nil

    /// クリック/タップで天体を選択したときに呼ばれるコールバック (macOS で使用)
    var onStarSelected: ((StarPosition) -> Void)? = nil

    // ドラッグ中の一時オフセット (ピクセル単位, 横・縦)
    @GestureState private var gestureDragOffset: CGSize = .zero

    @GestureState private var gestureScale: Double = 1.0

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // キーボードフォーカス
    @FocusState private var isFocused: Bool

#if os(macOS)
    @State private var scrollWheelMonitor: Any?
    @State private var isPointerOverCanvas = false
#endif

    // MARK: Body

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                canvas(size: size)
                    .gesture(
                        gnomonicDragGesture(size: size),
                        including: viewModel.isGyroMode ? .none : .all
                    )
                    .gesture(
                        pinchGesture,
                        including: allowsManualFOVAdjustment ? .all : .none
                    )
                    .onTapGesture(coordinateSpace: .local) { location in
                        handleTap(at: location, size: size)
                    }

#if os(macOS)
                gyroModeIndicator
#endif

                // ピンチ中のみ視野角を表示
                if allowsManualFOVAdjustment && gestureScale != 1.0 {
                    pinchFOVOverlay
                }

                if showsCardinalOverlay && !viewModel.isTimeSliderScrubbing {
                    cardinalOverlay(size: size)
                }
            }
            .onAppear {
                viewModel.activatePresentationIfNeeded()
                onCanvasAppear(size)
#if os(macOS)
                installMacScrollWheelMonitor()
#endif
            }
            .onDisappear {
#if os(macOS)
                removeMacScrollWheelMonitor()
#endif
            }
#if os(macOS)
            .onHover { isPointerOverCanvas = $0 }
#endif
            .onChange(of: size) { _, newSize in
                onCanvasAppear(newSize)
            }
            .focusable()
            .focused($isFocused)
            // MARK: Keyboard Navigation (デフォルト phases = [.down, .repeat])
            .onKeyPress(.leftArrow) {
                handleAzimuthKey(step: -StarMapLayout.directionStep)
            }
            .onKeyPress(.rightArrow) {
                handleAzimuthKey(step: StarMapLayout.directionStep)
            }
            .onKeyPress(.upArrow) {
                handleAltitudeKey(step: StarMapLayout.directionStep)
            }
            .onKeyPress(.downArrow) {
                handleAltitudeKey(step: -StarMapLayout.directionStep)
            }
            .onKeyPress(KeyEquivalent("=")) {
                handleZoomKey(step: -StarMapLayout.zoomStep)
            }
            .onKeyPress(KeyEquivalent("-")) {
                handleZoomKey(step: StarMapLayout.zoomStep)
            }
            .onKeyPress(KeyEquivalent("n")) {
                viewModel.resetToNorth()
                return .handled
            }
        }
        .background(backgroundColor)
    }

    private var pinchFOVOverlay: some View {
        PinchFOVOverlayView(displayFov: StarMapLayout.clampedFOV(viewModel.fov / max(0.1, gestureScale)))
    }

    private var allowsManualFOVAdjustment: Bool {
        fovOverride == nil
    }

    private func handleTap(at location: CGPoint, size: CGSize) {
        isFocused = true
        if let star = nearestStar(at: location, size: size) {
            onStarSelected?(star)
        }
    }

    private func handleAzimuthKey(step: Double) -> KeyPress.Result {
        viewModel.viewAzimuth = (viewModel.viewAzimuth + step + 360)
            .truncatingRemainder(dividingBy: 360)
        return .handled
    }

    private func handleAltitudeKey(step: Double) -> KeyPress.Result {
        viewModel.viewAltitude = max(-10, min(89, viewModel.viewAltitude + step))
        return .handled
    }

    private func handleZoomKey(step: Double) -> KeyPress.Result {
        guard allowsManualFOVAdjustment else { return .ignored }
        viewModel.fov = StarMapLayout.clampedFOV(viewModel.fov + step)
        return .handled
    }

    // MARK: Canvas

    private var scintillationEnabled: Bool {
        viewModel.isNight && !reduceMotion
    }

    private func canvas(size: CGSize) -> some View {
        TimelineView(.animation(minimumInterval: 0.25, paused: !scintillationEnabled)) { timeline in
            Canvas { ctx, sz in
                let cx = sz.width / 2
                let cy = sz.height / 2
                let (centerAlt, centerAz) = effectiveGnomonicCenter(size: sz)
                let roll = effectiveGnomonicRoll()
                let fov = effectiveGnomonicFOV()
                let scintillationTime = scintillationEnabled
                    ? timeline.date.timeIntervalSinceReferenceDate : 0
                drawGnomonicProjection(ctx: ctx, cx: cx, cy: cy, size: sz,
                                       centerAlt: centerAlt, centerAz: centerAz,
                                       roll: roll, fov: fov,
                                       scintillationTime: scintillationTime)
            }
        }
    }

    private func cardinalOverlay(size: CGSize) -> some View {
        CardinalOverlayView(
            placements: cardinalLabelPlacements(size: size),
            overlayY: Self.cardinalOverlayY(
                sizeHeight: size.height,
                bottomInset: Double(cardinalOverlayBottomInset)
            )
        )
    }


    // MARK: - Gnomonic Projection (心射図法)

    /// ピンチ中のライブ視野角（心射図法用）
    private func effectiveGnomonicFOV() -> Double {
        if let fovOverride {
            return StarMapLayout.clampedFOV(fovOverride)
        }
        return StarMapLayout.clampedFOV(viewModel.fov / max(0.1, gestureScale))
    }

    private func effectiveGnomonicRoll() -> Double {
        if let rollOverride {
            return rollOverride
        }
        return viewModel.isGyroMode ? viewModel.viewRoll : 0
    }

    /// ドラッグ中のライブ中心方向（心射図法用）。
    /// スクリーン移動量をカメラ空間の角度変化に正確に変換する。
    private func effectiveGnomonicCenter(size: CGSize) -> (alt: Double, az: Double) {
        guard gestureDragOffset != .zero else {
            return (viewModel.viewAltitude, viewModel.viewAzimuth)
        }
        let fov = effectiveGnomonicFOV()
        let scale = GnomonicProjectionMath.projectionScale(size: size, horizontalFOV: fov)
        return GnomonicProjectionMath.adjustedCenter(
            altitude: viewModel.viewAltitude,
            azimuth: viewModel.viewAzimuth,
            translation: gestureDragOffset,
            scale: scale
        )
    }


    private func drawGnomonicProjection(ctx: GraphicsContext,
                                        cx: Double, cy: Double, size: CGSize,
                                        centerAlt: Double, centerAz: Double, roll: Double, fov: Double,
                                        scintillationTime: Double = 0) {
        let projection = GnomonicProjectionContext(
            size: size,
            centerAlt: centerAlt,
            centerAz: centerAz,
            rollDegrees: roll,
            fov: fov
        )

        // 動的空色の塗りつぶし
        if drawsDynamicSky {
            let skyColor = StarMapPalette.skyColor(
                sunAltitude: viewModel.sunAltitude,
                moonAltitude: viewModel.moonAltitude,
                moonPhase: viewModel.moonPhase
            )
            ctx.fill(
                Rectangle().path(in: CGRect(origin: .zero, size: size)),
                with: .color(skyColor)
            )
        }

        // 地平線・地面描画
        drawGnomonicGround(ctx: ctx, size: size, projection: projection)

        // 星座線
        if viewModel.showsConstellationLines {
            var constPath = Path()
            for line in viewModel.constellationLines {
                let a1 = max(line.startAlt, -5) * .pi / 180
                let a2 = max(line.endAlt,   -5) * .pi / 180
                if let p1 = projection.project(altitudeRadians: a1, azimuthRadians: line.startAz * .pi / 180),
                   let p2 = projection.project(altitudeRadians: a2, azimuthRadians: line.endAz * .pi / 180) {
                    constPath.move(to: p1)
                    constPath.addLine(to: p2)
                }
            }
            ctx.stroke(constPath,
                       with: .color(Color(red: 0.4, green: 0.6, blue: 0.9).opacity(0.35)),
                       lineWidth: 1)
        }

        // 天の川バンド（星座線の上、恒星の下に描画）
        if viewModel.isNight && viewModel.showsMilkyWay {
            drawGnomonicMilkyWayBand(
                ctx: ctx,
                project: { alt, az in
                    projection.project(altitudeRadians: alt, azimuthRadians: az)
                }
            )
        }

        // 恒星
        let moonBright = StarMapPalette.moonBrightness(
            moonAltitude: viewModel.moonAltitude,
            moonPhase: viewModel.moonPhase
        )
        for pos in viewModel.starPositions {
            // 地平線近くの暗い星をスキップ
            if pos.altitude < 5 && pos.star.magnitude > 6.0 { continue }
            let alt = pos.altitude * .pi / 180
            let az  = pos.azimuth  * .pi / 180
            if let pt = projection.project(altitudeRadians: alt, azimuthRadians: az) {
                drawStar(ctx: ctx, at: pt, magnitude: pos.star.magnitude,
                         isDark: viewModel.isNight, precomputedColor: pos.precomputedColor,
                         altitude: pos.altitude,
                         moonBrightness: moonBright,
                         scintillationTime: scintillationTime,
                         starRA: pos.star.ra)
                if pos.star.magnitude < 1.5, !pos.star.localizedName.isEmpty {
                    drawStarLabel(ctx: ctx, at: pt, name: pos.star.localizedName)
                }
            }
        }

        // 星座名ラベル
        if viewModel.showsConstellationLabels {
            var constellationLabelCandidates: [ConstellationLabelCandidate] = []
            for label in viewModel.constellationLabels {
                let alt = label.alt * .pi / 180
                let az  = label.az  * .pi / 180
                if let pt = projection.project(altitudeRadians: alt, azimuthRadians: az) {
                    constellationLabelCandidates.append(
                        ConstellationLabelCandidate(name: label.name, anchor: pt, priority: label.alt)
                    )
                }
            }

            for placement in viewModel.labelPlacements(
                candidates: constellationLabelCandidates,
                canvasSize: size,
                reservedBottomInset: showsCardinalOverlay ? Double(cardinalOverlayBottomInset) + 20 : 0
            ) {
                ctx.draw(
                    Text(placement.name)
                        .font(.system(size: 11))
                        .foregroundColor(Color(red: 0.6, green: 0.8, blue: 1.0).opacity(0.52)),
                    at: placement.origin,
                    anchor: .topLeading
                )
            }
        }

        // 月
        if viewModel.moonAltitude > -1 {
            let alt = viewModel.moonAltitude * .pi / 180
            if let pt = projection.project(
                altitudeRadians: alt,
                azimuthRadians: viewModel.moonAzimuth * .pi / 180
            ) {
                drawMoon(ctx: ctx, at: pt, phase: viewModel.moonPhase)
            }
        }

        // 銀河系中心
        if viewModel.galacticCenterAltitude > -1 {
            let alt = viewModel.galacticCenterAltitude * .pi / 180
            if let pt = projection.project(
                altitudeRadians: alt,
                azimuthRadians: viewModel.galacticCenterAzimuth * .pi / 180
            ) {
                drawGalacticCenter(ctx: ctx, at: pt)
            }
        }

        // 惑星
        if viewModel.showsPlanets {
            for planet in viewModel.planetPositions where planet.altitude > -1 {
                let alt = planet.altitude * .pi / 180
                if let pt = projection.project(
                    altitudeRadians: alt,
                    azimuthRadians: planet.azimuth * .pi / 180
                ) {
                    drawPlanet(ctx: ctx, at: pt, planet: planet)
                }
            }
        }

        // 流星群放射点
        if viewModel.showsMeteorShowers {
            for radiant in viewModel.meteorShowerRadiants where radiant.altitude > -1 {
                let alt = radiant.altitude * .pi / 180
                if let pt = projection.project(
                    altitudeRadians: alt,
                    azimuthRadians: radiant.azimuth * .pi / 180
                ) {
                    drawMeteorShowerRadiant(ctx: ctx, at: pt, shower: radiant.shower)
                }
            }
        }

        // 地形シルエット（最前面: 天体を自然に隠す）
        if let terrain = viewModel.terrainProfile {
            drawGnomonicTerrainSilhouette(
                ctx: ctx,
                project: { alt, az in
                    projection.project(altitudeRadians: alt, azimuthRadians: az)
                },
                centerAz: centerAz,
                fov: fov,
                size: size,
                terrain: terrain
            )
        }

        drawCrosshair(ctx: ctx, cx: cx, cy: cy)
    }

    // MARK: - Gnomonic Ground / Horizon / Cardinals

    private func drawGnomonicGround(ctx: GraphicsContext,
                                    size: CGSize,
                                    projection: GnomonicProjectionContext) {
        let rect = CGRect(origin: .zero, size: size)
        let coefficients = GnomonicProjectionMath.horizonLineCoefficients(
            cx: projection.cx,
            cy: projection.cy,
            scale: projection.scale,
            forwardZ: projection.forward.z,
            rightZ: projection.right.z,
            upZ: projection.up.z
        )
        let groundPolygon = GnomonicProjectionMath.clippedGroundPolygon(in: rect, coefficients: coefficients)

        if groundPolygon.count >= 3 {
            var groundPath = Path()
            groundPath.move(to: groundPolygon[0])
            for point in groundPolygon.dropFirst() {
                groundPath.addLine(to: point)
            }
            groundPath.closeSubpath()
            ctx.fill(
                groundPath,
                with: .color(
                    horizonOverlayStyle.groundFillColor.opacity(horizonOverlayStyle.groundFillOpacity)
                )
            )
        }

        if let horizonSegment = GnomonicProjectionMath.horizonLineSegment(in: rect, coefficients: coefficients) {
            var horizonPath = Path()
            horizonPath.move(to: horizonSegment.0)
            horizonPath.addLine(to: horizonSegment.1)
            ctx.stroke(horizonPath,
                       with: .color(horizonOverlayStyle.horizonStrokeColor),
                       lineWidth: 1)
        }
    }

    private func cardinalLabelPlacements(size: CGSize) -> [CardinalOverlayPlacement] {
        let center = effectiveGnomonicCenter(size: size)
        return Self.cardinalLabelPlacements(
            size: size,
            centerAlt: center.alt,
            centerAz: center.az,
            roll: effectiveGnomonicRoll(),
            fov: effectiveGnomonicFOV()
        )
    }

    /// 画面下部オーバーレイに表示する方位ラベルの配置候補を返します。
    nonisolated static func cardinalLabelPlacements(
        size: CGSize,
        centerAlt: Double,
        centerAz: Double,
        roll: Double,
        fov: Double
    ) -> [CardinalOverlayPlacement] {
        let cardinals: [(Double, String)] = [
            (0, StarMapPresentation.azimuthName(for: 0)),
            (45, StarMapPresentation.azimuthName(for: 45)),
            (90, StarMapPresentation.azimuthName(for: 90)),
            (135, StarMapPresentation.azimuthName(for: 135)),
            (180, StarMapPresentation.azimuthName(for: 180)),
            (225, StarMapPresentation.azimuthName(for: 225)),
            (270, StarMapPresentation.azimuthName(for: 270)),
            (315, StarMapPresentation.azimuthName(for: 315))
        ]

        return cardinals.compactMap { azimuthDegrees, label in
            guard let x = projectedCardinalLabelX(
                azimuthDegrees: azimuthDegrees,
                size: size,
                centerAlt: centerAlt,
                centerAz: centerAz,
                roll: roll,
                fov: fov
            ) else {
                return nil
            }

            return CardinalOverlayPlacement(
                azimuthDegrees: azimuthDegrees,
                label: label,
                x: x
            )
        }
    }

    /// 方位ラベルが画面端で切れないように X 座標を制限します。
    nonisolated static func clampedCardinalLabelX(_ x: Double, sizeWidth: Double) -> Double {
        let minX = Double(StarMapLayout.cardinalLabelSidePadding)
        let maxX = sizeWidth - Double(StarMapLayout.cardinalLabelSidePadding)
        return min(max(x, minX), maxX)
    }

    /// 方位ラベルの固定オーバーレイ Y 座標を返します。
    nonisolated static func cardinalOverlayY(
        sizeHeight: Double,
        bottomInset: Double = Double(StarMapLayout.cardinalLabelBottomInset)
    ) -> Double {
        sizeHeight - bottomInset
    }

    nonisolated private static func projectedCardinalLabelX(
        azimuthDegrees: Double,
        size: CGSize,
        centerAlt: Double,
        centerAz: Double,
        roll: Double,
        fov: Double
    ) -> Double? {
        guard let point = GnomonicProjectionMath.projectPoint(
            size: size,
            centerAlt: centerAlt,
            centerAz: centerAz,
            roll: roll,
            fov: fov,
            altitudeDegrees: -1.5,
            azimuthDegrees: azimuthDegrees
        ) else {
            return nil
        }
        return clampedCardinalLabelX(point.x, sizeWidth: size.width)
    }

    // MARK: - Nearest Star (クリック判定用 — 心射図法)

    /// タップ/クリック座標に最も近い明るい星 (等級 ≤ 2.5) を返す。
    /// 閾値 (pt) 以内に星がなければ nil。
    private func nearestStar(at tapPoint: CGPoint, size: CGSize,
                               threshold: CGFloat = 25) -> StarPosition? {
        guard !viewModel.isGyroMode else { return nil }

        let fov = effectiveGnomonicFOV()
        let (centerAlt, centerAz) = effectiveGnomonicCenter(size: size)
        let projection = GnomonicProjectionContext(
            size: size,
            centerAlt: centerAlt,
            centerAz: centerAz,
            rollDegrees: 0,
            fov: fov
        )

        let index = StarMapSpatialIndex(
            stars: viewModel.starPositions,
            projection: { projection.project(altitudeRadians: $0, azimuthRadians: $1) },
            canvasSize: size
        )
        return index.nearest(to: tapPoint, threshold: threshold)
    }

    // MARK: - Drag Gesture (心射図法 カメラ空間ドラッグ)

    private func gnomonicDragGesture(size: CGSize) -> some Gesture {
        DragGesture()
            .updating($gestureDragOffset) { value, state, _ in
                state = value.translation
            }
            .onEnded { [self] value in
                let fov = effectiveGnomonicFOV()
                let scale = GnomonicProjectionMath.projectionScale(size: size, horizontalFOV: fov)
                let adjustedCenter = GnomonicProjectionMath.adjustedCenter(
                    altitude: viewModel.viewAltitude,
                    azimuth: viewModel.viewAzimuth,
                    translation: value.translation,
                    scale: scale
                )
                viewModel.viewAltitude = adjustedCenter.alt
                viewModel.viewAzimuth = adjustedCenter.az
            }
    }

    // MARK: - Pinch Gesture (視野角ズーム)

    /// ピンチで水平視野角を調整する。広げると狭くなる (望遠鏡的ズームイン)。
    private var pinchGesture: some Gesture {
        MagnificationGesture()
            .updating($gestureScale) { value, state, _ in
                state = value
            }
            .onEnded { [self] value in
                guard allowsManualFOVAdjustment else { return }
                viewModel.fov = StarMapLayout.clampedFOV(viewModel.fov / value)
            }
    }

#if os(macOS)
    private func installMacScrollWheelMonitor() {
        guard scrollWheelMonitor == nil else { return }
        scrollWheelMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { event in
            handleMacScrollWheel(event)
        }
    }

    private func removeMacScrollWheelMonitor() {
        guard let scrollWheelMonitor else { return }
        NSEvent.removeMonitor(scrollWheelMonitor)
        self.scrollWheelMonitor = nil
    }

    private func handleMacScrollWheel(_ event: NSEvent) -> NSEvent? {
        guard isPointerOverCanvas, allowsManualFOVAdjustment else {
            return event
        }
        let updatedFOV = Self.zoomedFOV(
            currentFOV: viewModel.fov,
            scrollDeltaY: event.scrollingDeltaY,
            preciseScrolling: event.hasPreciseScrollingDeltas
        )
        if updatedFOV != viewModel.fov {
            viewModel.fov = updatedFOV
        }
        return nil
    }
#endif

    private func onCanvasAppear(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        viewModel.updateCanvasSize(size)
        viewModel.applyInitialPoseIfNeeded()
    }

    // MARK: - Gyro Mode Indicator

    private var gyroModeIndicator: some View {
        GyroModeIndicatorView(
            azimuth: viewModel.viewAzimuth,
            altitude: viewModel.viewAltitude
        )
    }
}

extension StarMapCanvasView {
    /// スクロール量からズーム後の視野角を計算します。
    nonisolated static func zoomedFOV(currentFOV: Double, scrollDeltaY: Double, preciseScrolling: Bool) -> Double {
        let sensitivity = preciseScrolling ? 1.2 : 4.0
        return StarMapLayout.clampedFOV(currentFOV - scrollDeltaY * sensitivity)
    }
}

// MARK: - Preview

#Preview {
    let appController = AppController()
    let vm = StarMapViewModel(appController: appController)
    return StarMapCanvasView(viewModel: vm)
        .frame(width: 400, height: 500)
}
