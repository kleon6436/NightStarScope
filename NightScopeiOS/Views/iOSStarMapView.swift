import SwiftUI
@preconcurrency import AVFoundation
import UIKit

// MARK: - 星空ビュー
/// 星空マップとカメラ背景、操作パネルを統合する画面。
struct iOSStarMapView: View {
    @ObservedObject var viewModel: StarMapViewModel

    @StateObject private var motionController = StarMapMotionController()
    @StateObject private var cameraController = StarMapCameraController()
    @State private var isCameraBackgroundEnabled = false
    @State private var isPresentingDisplaySettings = false
    @State private var isRequestingCameraPermission = false
    @State private var cameraNotice: CameraNotice?
    @State private var cameraPermissionRequestID = 0
    @State private var bottomControlPanelHeight: CGFloat = 0
    @State private var isPresentingDatePicker = false
    @State private var interfaceOrientation: UIInterfaceOrientation = .portrait
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    backgroundLayer

                    StarMapCanvasView(
                        viewModel: viewModel,
                        showsCardinalOverlay: true,
                        cardinalOverlayBottomInset: cardinalOverlayBottomInset + proxy.safeAreaInsets.bottom,
                        backgroundColor: controlState.isCameraBackgroundVisible ? .clear : StarMapPalette.canvasBackground,
                        drawsDynamicSky: !controlState.isCameraBackgroundVisible,
                        horizonOverlayStyle: IOSDesignTokens.StarMap.horizonOverlayStyle,
                        fovOverride: cameraAlignedHorizontalFOV
                    )
                        .ignoresSafeArea(edges: [.top, .bottom])

                    topOverlaySection
                        .padding(.horizontal, Spacing.sm)
                        .padding(.top, Spacing.sm)
                    bottomControlPanel
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.height
                        } action: { newHeight in
                            bottomControlPanelHeight = newHeight
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                }
            }
            .toolbarBackground(.hidden, for: .navigationBar)
        }
        .onAppear {
            viewModel.activatePresentationIfNeeded()
            updateInterfaceOrientation()
            cameraController.refreshAuthorizationStatus()
            syncMotionState()
            syncCameraSession()
        }
        .onDisappear {
            invalidatePendingCameraPermissionRequest()
            viewModel.finalizeTransientInteractionState()
            stopMotion()
            cameraController.setSessionActive(false)
        }
        .onChange(of: viewModel.isGyroMode) { handleGyroChange() }
        .onChange(of: isCameraBackgroundEnabled) { syncCameraSession() }
        .onChange(of: scenePhase) { _, newPhase in
            handleScenePhaseChange(newPhase)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            updateInterfaceOrientation()
        }
        .onChange(of: cameraController.authorizationStatus) { _, newStatus in
            handleCameraAuthorizationChange(newStatus)
        }
        .onChange(of: cameraController.lastErrorMessage) { _, newMessage in
            handleCameraErrorChange(newMessage)
        }
        .sheet(isPresented: $isPresentingDisplaySettings) {
            iOSStarMapDisplaySettingsSheetView(motionController: motionController)
        }
    }

    private var backgroundLayer: some View {
        ZStack {
            // カメラ背景を切り替えても、セッション再構成を避けるため preview は保持する。
            if cameraSessionState.shouldKeepPreviewAttached {
                ZStack {
                    StarMapCameraPreviewView(
                        session: cameraController.session,
                        screenOrientation: screenOrientation,
                        videoDevice: cameraController.previewDevice
                    )
                    .opacity(controlState.isCameraBackgroundVisible ? 1 : 0)
                    .accessibilityHidden(true)

                    LinearGradient(
                        colors: [
                            Color.black.opacity(0.28),
                            Color.black.opacity(0.08),
                            Color.black.opacity(0.22)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .opacity(controlState.isCameraBackgroundVisible ? 1 : 0)
                }
            }
            Color.black.opacity(controlState.isCameraBackgroundVisible ? 0.14 : 1)
        }
        .ignoresSafeArea()
    }

    private var topOverlaySection: some View {
        iOSStarMapHeaderOverlay(
            controlState: controlState,
            onOpenDisplaySettings: openDisplaySettings,
            onToggleCameraBackground: toggleCameraBackground,
            onToggleGyroMode: toggleGyroMode,
            onOpenSettings: openAppSettings
        )
    }

    // MARK: - 下部コントロール

    private var bottomControlPanel: some View {
        VStack(spacing: Spacing.xs) {
            primaryControlRow
            timelineRow
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, IOSDesignTokens.StarMap.panelVerticalPadding)
        .iOSMaterialPanel(
            material: .ultraThinMaterial,
            cornerRadius: IOSDesignTokens.StarMap.panelCornerRadius,
            style: .continuous,
            showsBorder: false
        )
        .padding(.horizontal, Spacing.sm)
        .padding(.bottom, bottomControlBottomPadding)
    }

    private var bottomControlBottomPadding: CGFloat {
        Spacing.sm
    }

    private var cardinalOverlayBottomInset: CGFloat {
        // 下部パネルの実高さを使って、方位ラベルが重ならないようにする。
        max(
            StarMapLayout.cardinalLabelBottomInset,
            bottomControlPanelHeight + bottomControlBottomPadding
        )
    }

    /// 時刻・観測日・空の状況・「現在」を 1 行にまとめた主操作行。
    private var primaryControlRow: some View {
        HStack(spacing: Spacing.xs) {
            Text(viewModel.displayTimeString)
                .font(.title2.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white)

            observationDateButton

            Spacer(minLength: Spacing.xs)

            skyStatusLabel

            nowButton
        }
    }

    /// 観測日を示すコンパクトラベル。タップで DatePicker を popover 表示する。
    private var observationDateButton: some View {
        Button {
            isPresentingDatePicker = true
        } label: {
            HStack(spacing: IOSDesignTokens.StarMap.statusIconSpacing) {
                Text(viewModel.observationDate, format: .dateTime.month(.abbreviated).day())
                Image(systemName: "chevron.down")
                    .font(.system(size: IOSDesignTokens.StarMap.statusIconSize))
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(minHeight: IOSDesignTokens.StarMap.minimumTapTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.tr("観測日"))
        .accessibilityValue(Text(viewModel.observationDate, format: .dateTime.year().month().day()))
        .popover(isPresented: $isPresentingDatePicker) {
            DatePicker("", selection: observationDateBinding, displayedComponents: [.date])
                .labelsHidden()
                .datePickerStyle(.graphical)
                .padding(Spacing.sm)
                .presentationCompactAdaptation(.popover)
        }
    }

    /// 現在時刻へ戻すカプセルボタン。見た目は 28pt、当たり判定は 44pt を確保する。
    private var nowButton: some View {
        Button {
            viewModel.resetToNow()
        } label: {
            Text("現在")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .padding(.horizontal, Spacing.xs)
                .frame(height: IOSDesignTokens.StarMap.nowButtonHeight)
                .glassEffectCompat(
                    in: RoundedRectangle(
                        cornerRadius: IOSDesignTokens.StarMap.nowButtonHeight / 2,
                        style: .continuous
                    )
                )
                .frame(height: IOSDesignTokens.StarMap.minimumTapTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.tr("現在"))
    }

    /// ヒートバーと時刻スライダーを重ねた時間軸行。
    private var timelineRow: some View {
        VStack(alignment: .leading, spacing: IOSDesignTokens.StarMap.timelineSpacing) {
            ObservationHeatBarView(
                observationConditionTimeline: viewModel.observationConditionTimeline,
                sliderFraction: viewModel.timeSliderFraction,
                currentMoonAltitude: viewModel.moonAltitude,
                currentMoonPhase: viewModel.moonPhase,
                currentSunAltitude: viewModel.sunAltitude,
                currentTimeText: viewModel.displayTimeString
            )
            // Slider のつまみ半径ぶん内側に寄せ、スライダーのトラック端と揃える。
            .padding(.horizontal, IOSDesignTokens.StarMap.heatBarTrackInset)

            Slider(
                value: timeSliderBinding,
                in: 0...viewModel.timeSliderMaximumMinutes,
                step: 1,
                onEditingChanged: timeSliderEditingChanged
            )
            .tint(.accentColor)
            .accessibilityLabel(L10n.tr("時刻"))
            .accessibilityValue(viewModel.displayTimeString)
        }
    }

    private var observationDateBinding: Binding<Date> {
        Binding(
            get: { viewModel.observationDate },
            set: { viewModel.setObservationDate($0) }
        )
    }

    /// 月高度と流星群を 1 行に詰めたステータスクラスタ。
    private var skyStatusLabel: some View {
        HStack(spacing: Spacing.xs) {
            if viewModel.moonAltitude > 0 {
                statusChip(
                    systemImage: "moon.fill",
                    text: L10n.format("月 %.0f°", viewModel.moonAltitude),
                    tint: .white.opacity(0.8)
                )
            }
            if let meteorStatus {
                statusChip(
                    systemImage: "sparkles",
                    text: meteorStatus.text,
                    tint: meteorStatus.tint
                )
            }
        }
        .lineLimit(1)
        .layoutPriority(-1)
    }

    /// 活動中の流星群を優先し、無ければ次の流星群を返す。
    private var meteorStatus: (text: String, tint: Color)? {
        if let radiant = viewModel.meteorShowerRadiants.first {
            return (
                L10n.format("%@活動中", radiant.shower.localizedName),
                StarMapPalette.meteorAccent
            )
        }
        if let next = viewModel.nextMeteorShower {
            return (
                L10n.format("%@ %d日後", next.shower.localizedName, next.daysUntilPeak),
                .secondary
            )
        }
        return nil
    }

    private func statusChip(systemImage: String, text: String, tint: Color) -> some View {
        HStack(spacing: IOSDesignTokens.StarMap.statusIconSpacing) {
            Image(systemName: systemImage)
                .font(.system(size: IOSDesignTokens.StarMap.statusIconSize))
            Text(text)
                .font(.caption)
        }
        .foregroundStyle(tint)
        .accessibilityElement(children: .combine)
    }

    private var controlState: iOSStarMapControlState {
        let isCameraBackgroundVisible = cameraSessionState.isCameraBackgroundVisible

        let displayedCameraNotice: CameraNotice? = {
            guard viewModel.isGyroMode else { return nil }
            if !cameraController.hasCameraHardware {
                return .cameraUnavailable
            }
            return cameraNotice
        }()

        let cameraButtonHelpText: String = {
            if isRequestingCameraPermission {
                return L10n.tr("カメラ権限の確認中です")
            }
            if !viewModel.isGyroMode {
                return L10n.tr("カメラ背景はジャイロ操作中のみ利用できます")
            }
            if !cameraController.hasCameraHardware {
                return L10n.tr("この環境ではカメラ背景を利用できません")
            }
            return isCameraBackgroundVisible
                ? L10n.tr("カメラ背景をオフにする")
                : L10n.tr("カメラ背景をオンにする")
        }()

        let cameraButtonHintText: String = {
            if isRequestingCameraPermission {
                return L10n.tr("権限ダイアログの完了後に背景を切り替えます")
            }
            if !viewModel.isGyroMode {
                return L10n.tr("ジャイロ操作をオンにすると利用できます")
            }
            if !cameraController.hasCameraHardware {
                return L10n.tr("カメラを利用できるデバイスで使用してください")
            }
            return L10n.tr("実際の空の映像を背景に重ねて表示します")
        }()

        return iOSStarMapControlState(
            displaySettings: viewModel.displaySettings,
            canEnableGyroMode: motionController.canEnableGyroMode,
            isGyroMode: viewModel.isGyroMode,
            isCameraBackgroundVisible: isCameraBackgroundVisible,
            canToggleCameraBackground: viewModel.isGyroMode && cameraController.hasCameraHardware && !isRequestingCameraPermission,
            cameraButtonHelpText: cameraButtonHelpText,
            cameraButtonHintText: cameraButtonHintText,
            displayedCameraNotice: displayedCameraNotice,
            terrainFetchState: viewModel.terrainFetchState
        )
    }

    private var cameraSessionState: StarMapCameraSessionState {
        StarMapCameraSessionState(
            isGyroMode: viewModel.isGyroMode,
            isBackgroundEnabled: isCameraBackgroundEnabled,
            isAuthorized: cameraController.authorizationStatus == .authorized,
            hasCameraHardware: cameraController.hasCameraHardware,
            isSceneActive: scenePhase == .active
        )
    }

    private var screenOrientation: StarMapScreenOrientation {
        interfaceOrientation.starMapScreenOrientation
    }

    private var cameraAlignedHorizontalFOV: Double? {
        guard cameraSessionState.isCameraBackgroundVisible,
              let cameraFieldOfView = cameraController.cameraFieldOfView else {
            return nil
        }
        return cameraFieldOfView.visibleHorizontalDegrees(
            viewportSize: viewModel.canvasSize,
            screenOrientation: screenOrientation
        )
    }

    private func toggleGyroMode() {
        withAnimation(reduceMotion ? .none : .standard) {
            viewModel.isGyroMode.toggle()
        }
    }

    private func openDisplaySettings() {
        isPresentingDisplaySettings = true
    }

    // MARK: - CoreMotion 制御

    private func handleGyroChange() {
        syncMotionState()
        if !viewModel.isGyroMode {
            stopMotion()
            disableCameraBackground(clearNotice: true)
        }
        syncCameraSession()
    }

    private func startMotion() {
        motionController.updateScreenOrientation(screenOrientation)
        motionController.start(
            onPoseUpdate: { pose in
                let offset = UserDefaults.standard.double(
                    forKey: StarMapDisplaySettings.compassAzimuthOffsetDefaultsKey
                )
                let corrected = pose.azimuth + offset
                viewModel.viewAzimuth = (corrected.truncatingRemainder(dividingBy: 360) + 360)
                    .truncatingRemainder(dividingBy: 360)
                viewModel.viewAltitude = pose.altitude
                viewModel.viewRoll = pose.roll
            },
            onFailure: {
                viewModel.isGyroMode = false
            }
        )
    }

    private func stopMotion() {
        motionController.stop()
    }

    private func toggleCameraBackground() {
        guard viewModel.isGyroMode else { return }
        guard !isRequestingCameraPermission else { return }
        guard cameraController.hasCameraHardware else {
            cameraNotice = .cameraUnavailable
            return
        }

        if isCameraBackgroundEnabled {
            disableCameraBackground(clearNotice: true)
            return
        }

        cameraNotice = nil

        switch cameraController.authorizationStatus {
        case .authorized:
            isCameraBackgroundEnabled = true
        case .notDetermined:
            invalidatePendingCameraPermissionRequest()
            isRequestingCameraPermission = true
            let requestID = cameraPermissionRequestID
            Task { @MainActor in
                let granted = await cameraController.requestAccess()
                guard requestID == cameraPermissionRequestID else { return }
                isRequestingCameraPermission = false

                if granted, viewModel.isGyroMode {
                    cameraNotice = nil
                    isCameraBackgroundEnabled = true
                } else if granted {
                    disableCameraBackground(clearNotice: true)
                } else {
                    disableCameraBackground(clearNotice: false)
                    cameraNotice = .cameraPermissionDenied
                }
            }
        case .denied:
            disableCameraBackground(clearNotice: false)
            cameraNotice = .cameraPermissionDenied
        case .restricted:
            disableCameraBackground(clearNotice: false)
            cameraNotice = .cameraRestricted
        @unknown default:
            disableCameraBackground(clearNotice: false)
            cameraNotice = .cameraUnexpectedFailure(L10n.tr("カメラの利用状況を判定できませんでした。"))
        }
    }

    private func disableCameraBackground(clearNotice: Bool) {
        invalidatePendingCameraPermissionRequest()
        isCameraBackgroundEnabled = false
        syncCameraSession()
        if clearNotice {
            cameraNotice = nil
        }
    }

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        if phase == .active {
            updateInterfaceOrientation()
            cameraController.refreshAuthorizationStatus()
        } else {
            viewModel.finalizeTransientInteractionState()
        }
        syncMotionState()
        syncCameraSession()
    }

    private func syncCameraSession() {
        cameraController.setSessionActive(cameraSessionState.shouldRunSession)
    }

    private func syncMotionState() {
        let shouldRunMotion = viewModel.isGyroMode && scenePhase == .active
        if shouldRunMotion {
            startMotion()
        } else {
            stopMotion()
        }
    }

    private func handleCameraAuthorizationChange(_ status: AVAuthorizationStatus) {
        if status != .notDetermined {
            isRequestingCameraPermission = false
        }
        if status == .authorized {
            cameraNotice = nil
        }
        if status != .authorized && isCameraBackgroundEnabled {
            disableCameraBackground(clearNotice: false)
            switch status {
            case .denied:
                cameraNotice = .cameraPermissionDenied
            case .restricted:
                cameraNotice = .cameraRestricted
            default:
                break
            }
        }
        syncCameraSession()
    }

    private func handleCameraErrorChange(_ message: String?) {
        guard let message else { return }
        disableCameraBackground(clearNotice: false)
        cameraNotice = .cameraUnexpectedFailure(message)
    }

    private func invalidatePendingCameraPermissionRequest() {
        cameraPermissionRequestID &+= 1
        isRequestingCameraPermission = false
    }

    private func updateInterfaceOrientation() {
        let resolvedOrientation: UIInterfaceOrientation

        if UIDevice.current.userInterfaceIdiom == .phone {
            resolvedOrientation = .portrait
        } else {
            resolvedOrientation = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .first(where: { $0.activationState == .foregroundActive })?
                .effectiveGeometry.interfaceOrientation ?? interfaceOrientation
        }

        interfaceOrientation = resolvedOrientation
        motionController.updateScreenOrientation(resolvedOrientation.starMapScreenOrientation)
    }

    private func openAppSettings() {
        guard let settingsURL = URL(string: UIApplication.openSettingsURLString) else { return }
        openURL(settingsURL)
    }

    private var timeSliderBinding: Binding<Double> {
        Binding(
            get: { viewModel.timeSliderMinutes },
            set: { viewModel.setTimeSliderMinutes($0) }
        )
    }

    private func timeSliderEditingChanged(_ isEditing: Bool) {
        if isEditing {
            viewModel.beginTimeSliderInteraction()
        } else {
            viewModel.endTimeSliderInteraction()
        }
    }
}

// MARK: - プレビュー

#Preview {
    let appController = AppController()
    let vm = StarMapViewModel(appController: appController)
    return iOSStarMapView(viewModel: vm)
        .preferredColorScheme(.dark)
}
