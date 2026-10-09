import XCTest
import Combine
import CoreLocation
import MapKit
@testable import NightScope

@MainActor
final class StarMapViewModelTests: XCTestCase {
    final class InMemoryLocationStorage: LocationStorage {
        var latitude: Double?
        var longitude: Double?
        var name: String?
        var timeZoneIdentifier: String?
    }

    struct NoopLocationSearchService: LocationSearchServicing {
        func search(query: String) async throws -> [MKMapItem] {
            []
        }
    }

    actor FixedLocationNameResolver: LocationNameResolving {
        let resolvedName: String
        let timeZoneIdentifier: String?

        init(resolvedName: String, timeZoneIdentifier: String?) {
            self.resolvedName = resolvedName
            self.timeZoneIdentifier = timeZoneIdentifier
        }

        func resolveDetails(for coordinate: CLLocationCoordinate2D) async -> ResolvedLocationDetails {
            ResolvedLocationDetails(name: resolvedName, timeZoneIdentifier: timeZoneIdentifier)
        }
    }

    private func waitUntil(
        timeout: TimeInterval = 1.0,
        file: StaticString = #filePath,
        line: UInt = #line,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("条件を満たすまでにタイムアウトしました", file: file, line: line)
    }

    private func makeTokyoAppController() -> AppController {
        let storage = InMemoryLocationStorage()
        storage.latitude = 35.6762
        storage.longitude = 139.6503
        storage.name = "東京"
        storage.timeZoneIdentifier = "Asia/Tokyo"

        let locationController = LocationController(
            storage: storage,
            searchService: NoopLocationSearchService(),
            locationNameResolver: FixedLocationNameResolver(
                resolvedName: "東京",
                timeZoneIdentifier: "Asia/Tokyo"
            )
        )

        return AppController(
            locationController: locationController,
            calculationService: MockNightCalculationService()
        )
    }

    private func observationCalendar(for timeZone: TimeZone) -> Calendar {
        ObservationTimeZone.gregorianCalendar(timeZone: timeZone)
    }

    private func makeStaticComputationDependency() -> StarMapComputationDependency {
        StarMapComputationDependency(
            computeSnapshot: { _, _, _, _, _, _ in
                StarMapComputation.Snapshot(
                    starPositions: [],
                    sunAltitude: -20,
                    moonAltitude: -10,
                    moonAzimuth: 180,
                    moonPhase: 0.1,
                    galacticCenterAltitude: 30,
                    galacticCenterAzimuth: 180,
                    constellationLines: [],
                    constellationLabels: [],
                    planetPositions: [],
                    meteorShowerRadiants: [],
                    milkyWayBandPoints: []
                )
            }
        )
    }

    func test_StarMapPresentation_azimuthName_normalizesDegrees() {
        XCTAssertEqual(StarMapPresentation.azimuthName(for: -1), L10n.tr("北"))
        XCTAssertEqual(StarMapPresentation.azimuthName(for: 44), L10n.tr("北東"))
        XCTAssertEqual(StarMapPresentation.azimuthName(for: 225), L10n.tr("南西"))
        XCTAssertEqual(StarMapPresentation.azimuthName(for: 359), L10n.tr("北"))
    }

    func test_StarMapPresentation_azimuthName_supportsEightDirections() {
        XCTAssertEqual(StarMapPresentation.azimuthName(for: 0), L10n.tr("北"))
        XCTAssertEqual(StarMapPresentation.azimuthName(for: 45), L10n.tr("北東"))
        XCTAssertEqual(StarMapPresentation.azimuthName(for: 90), L10n.tr("東"))
        XCTAssertEqual(StarMapPresentation.azimuthName(for: 135), L10n.tr("南東"))
        XCTAssertEqual(StarMapPresentation.azimuthName(for: 180), L10n.tr("南"))
        XCTAssertEqual(StarMapPresentation.azimuthName(for: 225), L10n.tr("南西"))
        XCTAssertEqual(StarMapPresentation.azimuthName(for: 270), L10n.tr("西"))
        XCTAssertEqual(StarMapPresentation.azimuthName(for: 315), L10n.tr("北西"))
    }

    func test_StarMapPresentation_timeString_formatsMinutes() {
        XCTAssertEqual(StarMapPresentation.timeString(from: 0), "00:00")
        XCTAssertEqual(StarMapPresentation.timeString(from: 61), "01:01")
        XCTAssertEqual(StarMapPresentation.timeString(from: 1_439), "23:59")
    }

    func test_StarMapLayout_clampedFOV_limitsRange() {
        XCTAssertEqual(StarMapLayout.clampedFOV(20), StarMapLayout.minFOV)
        XCTAssertEqual(StarMapLayout.clampedFOV(90), 90)
        XCTAssertEqual(StarMapLayout.clampedFOV(160), StarMapLayout.maxFOV)
    }

    func test_StarMapViewModel_initialFOV_usesNaturalDefaultFieldOfView() {
        let appController = makeTokyoAppController()
        let viewModel = StarMapViewModel(appController: appController)

        XCTAssertEqual(StarMapLayout.defaultFOV, 60, accuracy: 0.001)
        XCTAssertEqual(viewModel.fov, StarMapLayout.defaultFOV, accuracy: 0.001)
    }

    func test_StarMapCanvasView_zoomedFOV_clampsAndFollowsScrollDirection() {
        XCTAssertEqual(
            StarMapCanvasView.zoomedFOV(currentFOV: 90, scrollDeltaY: 1, preciseScrolling: false),
            86,
            accuracy: 0.001
        )
        XCTAssertEqual(
            StarMapCanvasView.zoomedFOV(currentFOV: 90, scrollDeltaY: -1, preciseScrolling: true),
            91.2,
            accuracy: 0.001
        )
        XCTAssertEqual(
            StarMapCanvasView.zoomedFOV(currentFOV: 31, scrollDeltaY: 10, preciseScrolling: false),
            StarMapLayout.minFOV,
            accuracy: 0.001
        )
    }

    func test_StarMapCanvasView_cardinalLabelHelpers_placeLabelsInFixedBottomOverlay() {
        XCTAssertEqual(
            StarMapCanvasView.cardinalOverlayY(sizeHeight: 400),
            400 - Double(StarMapLayout.cardinalLabelBottomInset),
            accuracy: 0.0001
        )
        XCTAssertEqual(
            StarMapCanvasView.cardinalOverlayY(sizeHeight: 400, bottomInset: 140),
            260,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            StarMapCanvasView.clampedCardinalLabelX(-5, sizeWidth: 320),
            Double(StarMapLayout.cardinalLabelSidePadding),
            accuracy: 0.0001
        )
        XCTAssertEqual(
            StarMapCanvasView.clampedCardinalLabelX(400, sizeWidth: 320),
            320 - Double(StarMapLayout.cardinalLabelSidePadding),
            accuracy: 0.0001
        )

        let placements = StarMapCanvasView.cardinalLabelPlacements(
            size: CGSize(width: 320, height: 400),
            centerAlt: 30,
            centerAz: 0,
            roll: 0,
            fov: 90
        )
        XCTAssertEqual(placements.map(\.label), [L10n.tr("北"), L10n.tr("北東"), L10n.tr("北西")])
    }

    func test_StarMapCanvasView_horizonProjection_matchesProjectedAltitudeZeroPoints() {
        let size = CGSize(width: 390, height: 844)
        let centerAlt = 10.0
        let centerAz = 0.0
        let fov = 60.0

        for roll in [0.0, 25.0] {
            for azimuth in stride(from: -20.0, through: 20.0, by: 10.0) {
                let point = GnomonicProjectionMath.projectPoint(
                    size: size,
                    centerAlt: centerAlt,
                    centerAz: centerAz,
                    roll: roll,
                    fov: fov,
                    altitudeDegrees: 0,
                    azimuthDegrees: azimuth
                )

                XCTAssertNotNil(point)
                if let point {
                    XCTAssertEqual(
                        GnomonicProjectionMath.horizonLineValue(
                            size: size,
                            centerAlt: centerAlt,
                            centerAz: centerAz,
                            roll: roll,
                            fov: fov,
                            point: point
                        ),
                        0,
                        accuracy: 0.001
                    )
                }
            }
        }
    }

    func test_StarDisplayDensity_usesExpectedThresholdsAndLabels() {
        XCTAssertTrue(StarDisplayDensity.maximum.settingsLabel.contains(StarDisplayDensity.maximum.title))
        XCTAssertTrue(StarDisplayDensity.maximum.settingsLabel.contains("7.5"))
        XCTAssertTrue(StarDisplayDensity.large.settingsLabel.contains(StarDisplayDensity.large.title))
        XCTAssertTrue(StarDisplayDensity.large.settingsLabel.contains("6.8"))
        XCTAssertTrue(StarDisplayDensity.medium.settingsLabel.contains(StarDisplayDensity.medium.title))
        XCTAssertTrue(StarDisplayDensity.medium.settingsLabel.contains("6.0"))
        XCTAssertTrue(StarDisplayDensity.small.settingsLabel.contains(StarDisplayDensity.small.title))
        XCTAssertTrue(StarDisplayDensity.small.settingsLabel.contains("5.0"))

        XCTAssertEqual(StarDisplayDensity.maximum.maxMagnitude, 7.5, accuracy: 0.0001)
        XCTAssertEqual(StarDisplayDensity.large.maxMagnitude, 6.8, accuracy: 0.0001)
        XCTAssertEqual(StarDisplayDensity.medium.maxMagnitude, 6.0, accuracy: 0.0001)
        XCTAssertEqual(StarDisplayDensity.small.maxMagnitude, 5.0, accuracy: 0.0001)
    }

    func test_StarMapDisplaySettings_load_usesDefaultsAndPersistedValues() {
        let densityKey = StarDisplayDensity.defaultsKey
        let constellationLinesKey = StarMapDisplaySettings.showsConstellationLinesDefaultsKey
        let constellationLabelsKey = StarMapDisplaySettings.showsConstellationLabelsDefaultsKey
        let planetsKey = StarMapDisplaySettings.showsPlanetsDefaultsKey
        let meteorShowersKey = StarMapDisplaySettings.showsMeteorShowersDefaultsKey
        let milkyWayKey = StarMapDisplaySettings.showsMilkyWayDefaultsKey
        let previousDensityValue = UserDefaults.standard.object(forKey: densityKey)
        let previousConstellationLinesValue = UserDefaults.standard.object(forKey: constellationLinesKey)
        let previousConstellationLabelsValue = UserDefaults.standard.object(forKey: constellationLabelsKey)
        let previousPlanetsValue = UserDefaults.standard.object(forKey: planetsKey)
        let previousMeteorShowersValue = UserDefaults.standard.object(forKey: meteorShowersKey)
        let previousMilkyWayValue = UserDefaults.standard.object(forKey: milkyWayKey)

        defer {
            if let previousDensityValue {
                UserDefaults.standard.set(previousDensityValue, forKey: densityKey)
            } else {
                UserDefaults.standard.removeObject(forKey: densityKey)
            }

            if let previousConstellationLinesValue {
                UserDefaults.standard.set(previousConstellationLinesValue, forKey: constellationLinesKey)
            } else {
                UserDefaults.standard.removeObject(forKey: constellationLinesKey)
            }

            if let previousConstellationLabelsValue {
                UserDefaults.standard.set(previousConstellationLabelsValue, forKey: constellationLabelsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: constellationLabelsKey)
            }

            if let previousPlanetsValue {
                UserDefaults.standard.set(previousPlanetsValue, forKey: planetsKey)
            } else {
                UserDefaults.standard.removeObject(forKey: planetsKey)
            }

            if let previousMeteorShowersValue {
                UserDefaults.standard.set(previousMeteorShowersValue, forKey: meteorShowersKey)
            } else {
                UserDefaults.standard.removeObject(forKey: meteorShowersKey)
            }

            if let previousMilkyWayValue {
                UserDefaults.standard.set(previousMilkyWayValue, forKey: milkyWayKey)
            } else {
                UserDefaults.standard.removeObject(forKey: milkyWayKey)
            }
        }

        UserDefaults.standard.removeObject(forKey: densityKey)
        UserDefaults.standard.removeObject(forKey: constellationLinesKey)
        UserDefaults.standard.removeObject(forKey: constellationLabelsKey)
        UserDefaults.standard.removeObject(forKey: planetsKey)
        UserDefaults.standard.removeObject(forKey: meteorShowersKey)
        UserDefaults.standard.removeObject(forKey: milkyWayKey)

        XCTAssertEqual(StarMapDisplaySettings.load(), .defaultValue)

        UserDefaults.standard.set(StarDisplayDensity.small.rawValue, forKey: densityKey)
        UserDefaults.standard.set(false, forKey: constellationLinesKey)
        UserDefaults.standard.set(false, forKey: constellationLabelsKey)
        UserDefaults.standard.set(false, forKey: planetsKey)
        UserDefaults.standard.set(false, forKey: meteorShowersKey)
        UserDefaults.standard.set(false, forKey: milkyWayKey)

        XCTAssertEqual(
            StarMapDisplaySettings.load(),
            StarMapDisplaySettings(
                density: .small,
                showsConstellationLines: false,
                showsConstellationLabels: false,
                showsPlanets: false,
                showsMeteorShowers: false,
                showsMilkyWay: false
            )
        )
    }

    func test_StarMapViewModel_setShowsConstellationLines_updatesDisplaySettings() {
        let appController = makeTokyoAppController()
        let viewModel = StarMapViewModel(appController: appController)

        viewModel.setShowsConstellationLines(false)

        XCTAssertFalse(viewModel.showsConstellationLines)
        XCTAssertFalse(viewModel.displaySettings.showsConstellationLines)
        XCTAssertTrue(viewModel.displaySettings.showsConstellationLabels)
        XCTAssertTrue(viewModel.displaySettings.showsPlanets)
    }

    func test_StarMapViewModel_updatesConstellationLineVisibilityWhenSettingsChange() async {
        let settingsSubject = PassthroughSubject<StarMapDisplaySettings, Never>()
        let initialSettings = StarMapDisplaySettings(density: .medium, showsConstellationLines: true)
        let settingsDependency = StarMapSettingsDependency(
            currentSettings: { initialSettings },
            changes: settingsSubject.eraseToAnyPublisher()
        )
        let viewModel = StarMapViewModel(
            appController: makeTokyoAppController(),
            settingsDependency: settingsDependency,
            computationDependency: makeStaticComputationDependency()
        )

        XCTAssertTrue(viewModel.showsConstellationLines)
        XCTAssertTrue(viewModel.showsConstellationLabels)
        XCTAssertTrue(viewModel.showsPlanets)
        XCTAssertTrue(viewModel.showsMeteorShowers)
        XCTAssertTrue(viewModel.showsMilkyWay)
        XCTAssertEqual(viewModel.displaySettings.density, .medium)

        settingsSubject.send(
            StarMapDisplaySettings(
                density: .medium,
                showsConstellationLines: false,
                showsConstellationLabels: false,
                showsPlanets: false,
                showsMeteorShowers: false,
                showsMilkyWay: false
            )
        )

        await waitUntil {
            !viewModel.showsConstellationLines
                && !viewModel.showsConstellationLabels
                && !viewModel.showsPlanets
                && !viewModel.showsMeteorShowers
                && !viewModel.showsMilkyWay
        }

        XCTAssertFalse(viewModel.displaySettings.showsConstellationLines)
        XCTAssertFalse(viewModel.displaySettings.showsConstellationLabels)
        XCTAssertFalse(viewModel.displaySettings.showsPlanets)
        XCTAssertFalse(viewModel.displaySettings.showsMeteorShowers)
        XCTAssertFalse(viewModel.displaySettings.showsMilkyWay)
    }

    func test_StarMapViewModel_generatesMoonAltitudeTimelineForNightRange() {
        let appController = makeTokyoAppController()
        let viewModel = StarMapViewModel(appController: appController)

        XCTAssertFalse(viewModel.observationConditionTimeline.isEmpty)
        XCTAssertTrue(
            viewModel.observationConditionTimeline.allSatisfy { sample in
                sample.sunAltitude <= 90 && sample.sunAltitude >= -90
            }
        )
        XCTAssertGreaterThan(viewModel.timeSliderMaximumMinutes, 0)
        XCTAssertGreaterThanOrEqual(viewModel.timeSliderFraction, 0)
        XCTAssertLessThanOrEqual(viewModel.timeSliderFraction, 1)
    }

    func test_ObservationHeatBarView_qualityLabel_doesNotTreatAstronomicalTwilightAsGood() {
        XCTAssertEqual(
            ObservationHeatBarView.qualityLabel(
                moonAltitude: -10,
                moonPhase: 0,
                sunAltitude: -16
            ),
            L10n.tr("観測条件に注意")
        )
        XCTAssertEqual(
            ObservationHeatBarView.qualityLabel(
                moonAltitude: -10,
                moonPhase: 0,
                sunAltitude: -20
            ),
            L10n.tr("観測条件が良い")
        )
    }

    func test_ObservationHeatBarView_moonImpactScore_usesMoonlightThresholds() {
        XCTAssertGreaterThan(
            ObservationHeatBarView.moonImpactScore(moonAltitude: 5, moonPhase: 0.5),
            0.35
        )
        XCTAssertGreaterThan(
            ObservationHeatBarView.moonImpactScore(moonAltitude: 10, moonPhase: 0.25),
            0.65
        )
        XCTAssertLessThan(
            ObservationHeatBarView.moonImpactScore(moonAltitude: 40, moonPhase: 0),
            0.12
        )
    }

    func test_ObservationHeatBarView_combinedImpactScore_accumulatesSunAndMoon() {
        let sunOnly = ObservationHeatBarView.sunImpactScore(for: -15)
        let moonOnly = ObservationHeatBarView.moonImpactScore(moonAltitude: 10, moonPhase: 0.25)
        let combined = ObservationHeatBarView.combinedImpactScore(
            moonAltitude: 10,
            moonPhase: 0.25,
            sunAltitude: -15
        )

        XCTAssertGreaterThan(combined, sunOnly)
        XCTAssertGreaterThan(combined, moonOnly)
        XCTAssertEqual(
            ObservationHeatBarView.qualityLabel(
                moonAltitude: 10,
                moonPhase: 0.25,
                sunAltitude: -15
            ),
            L10n.tr("観測条件は厳しい")
        )
    }

    func test_ObservationHeatBarView_conditionStateText_reportsMoonlightSeverity() {
        XCTAssertEqual(
            ObservationHeatBarView.conditionStateText(
                moonAltitude: 35,
                moonPhase: 0.5,
                sunAltitude: -25
            ),
            L10n.tr("月明かりの影響が強い")
        )
        XCTAssertEqual(
            ObservationHeatBarView.conditionStateText(
                moonAltitude: 20,
                moonPhase: 0.1,
                sunAltitude: -25
            ),
            L10n.tr("月明かりの影響が小さい")
        )
        XCTAssertEqual(
            ObservationHeatBarView.conditionStateText(
                moonAltitude: -5,
                moonPhase: 0.5,
                sunAltitude: -25
            ),
            L10n.tr("月は地平線の下です")
        )
        XCTAssertEqual(
            ObservationHeatBarView.conditionStateText(
                moonAltitude: 0,
                moonPhase: 0.5,
                sunAltitude: -25
            ),
            L10n.tr("月は地平線の下です")
        )
    }

    func test_StarMapMotionPose_make_convertsBackVectorToSkyPose() {
        let northHorizon = StarMapMotionPose.make(
            rotationMatrix: StarMapMotionMatrix(
                m11: 0, m12: -1, m13: 0,
                m21: 0, m22: 0, m23: 1,
                m31: -1, m32: 0, m33: 0
            )
        )
        XCTAssertEqual(northHorizon.azimuth, 0, accuracy: 0.001)
        XCTAssertEqual(northHorizon.altitude, 0, accuracy: 0.001)

        let eastHorizon = StarMapMotionPose.make(
            rotationMatrix: StarMapMotionMatrix(
                m11: -1, m12: 0, m13: 0,
                m21: 0, m22: 0, m23: 1,
                m31: 0, m32: 1, m33: 0
            )
        )
        XCTAssertEqual(eastHorizon.azimuth, 90, accuracy: 0.001)
        XCTAssertEqual(eastHorizon.altitude, 0, accuracy: 0.001)

        let southEastHorizon = StarMapMotionPose.make(
            rotationMatrix: StarMapMotionMatrix(
                m11: -0.707_107, m12: 0.707_107, m13: 0,
                m21: 0, m22: 0, m23: 1,
                m31: 0.707_107, m32: 0.707_107, m33: 0
            )
        )
        XCTAssertEqual(southEastHorizon.azimuth, 135, accuracy: 0.001)
        XCTAssertEqual(southEastHorizon.altitude, 0, accuracy: 0.001)
    }

    func test_StarMapMotionPose_make_tracksUpwardAndDownwardTilt() {
        let northUpward = StarMapMotionPose.make(
            rotationMatrix: StarMapMotionMatrix(
                m11: 0, m12: -1, m13: 0,
                m21: -0.5, m22: 0, m23: 0.866_025,
                m31: -0.866_025, m32: 0, m33: -0.5
            )
        )
        XCTAssertEqual(northUpward.azimuth, 0, accuracy: 0.001)
        XCTAssertEqual(northUpward.altitude, 30, accuracy: 0.001)

        let northDownward = StarMapMotionPose.make(
            rotationMatrix: StarMapMotionMatrix(
                m11: 0, m12: -1, m13: 0,
                m21: 0.5, m22: 0, m23: 0.866_025,
                m31: -0.866_025, m32: 0, m33: 0.5
            )
        )
        XCTAssertEqual(northDownward.azimuth, 0, accuracy: 0.001)
        XCTAssertEqual(northDownward.altitude, -10, accuracy: 0.001)
    }

    func test_StarMapMotionPose_make_tracksScreenRollInPortrait() {
        let rolledPose = StarMapMotionPose.make(
            rotationMatrix: StarMapMotionMatrix(
                m11: 0, m12: 0, m13: 1,
                m21: 0, m22: -1, m23: 0,
                m31: -1, m32: 0, m33: 0
            )
        )

        XCTAssertEqual(rolledPose.azimuth, 0, accuracy: 0.001)
        XCTAssertEqual(rolledPose.altitude, 0, accuracy: 0.001)
        XCTAssertEqual(rolledPose.roll, 90, accuracy: 0.001)
    }

    func test_StarMapMotionPose_make_appliesInterfaceOrientationToRoll() {
        let landscapePose = StarMapMotionPose.make(
            rotationMatrix: StarMapMotionMatrix(
                m11: 0, m12: -1, m13: 0,
                m21: 0, m22: 0, m23: 1,
                m31: -1, m32: 0, m33: 0
            ),
            screenOrientation: .landscapeLeft
        )

        XCTAssertEqual(landscapePose.azimuth, 0, accuracy: 0.001)
        XCTAssertEqual(landscapePose.altitude, 0, accuracy: 0.001)
        XCTAssertEqual(landscapePose.roll, -90, accuracy: 0.001)
    }

    func test_StarMapMotionPose_smoothed_wrapsAzimuthAcrossNorthWithoutJump() {
        let previous = StarMapMotionPose(azimuth: 359, altitude: 44)
        let next = StarMapMotionPose(azimuth: 1, altitude: 46)

        let smoothed = StarMapMotionPose.smoothed(previous: previous, next: next)

        XCTAssertEqual(smoothed.azimuth, 359.36, accuracy: 0.001)
        XCTAssertEqual(smoothed.altitude, 44.36, accuracy: 0.001)
    }

    func test_StarMapMotionPose_smoothed_respondsFasterToLargeMovement() {
        let previous = StarMapMotionPose(azimuth: 10, altitude: 20)
        let next = StarMapMotionPose(azimuth: 50, altitude: 45)

        let smoothed = StarMapMotionPose.smoothed(previous: previous, next: next)

        XCTAssertEqual(smoothed.azimuth, 23.6, accuracy: 0.001)
        XCTAssertEqual(smoothed.altitude, 27.5, accuracy: 0.001)
    }

    func test_StarMapCameraFieldOfView_visibleHorizontalDegrees_matchesViewportAndOrientation() {
        let fieldOfView = StarMapCameraFieldOfView(
            landscapeHorizontalDegrees: 90,
            sensorWidth: 4_000,
            sensorHeight: 3_000
        )
        let landscapeDegrees = fieldOfView.visibleHorizontalDegrees(
            viewportSize: CGSize(width: 400, height: 300),
            screenOrientation: .landscapeRight
        )
        let portraitDegrees = fieldOfView.visibleHorizontalDegrees(
            viewportSize: CGSize(width: 300, height: 400),
            screenOrientation: .portrait
        )
        let narrowPortraitDegrees = fieldOfView.visibleHorizontalDegrees(
            viewportSize: CGSize(width: 390, height: 844),
            screenOrientation: .portrait
        )

        XCTAssertNotNil(landscapeDegrees)
        XCTAssertNotNil(portraitDegrees)
        XCTAssertNotNil(narrowPortraitDegrees)
        // videoFieldOfView は横長向きの水平視野角なので、横長でアスペクトが一致すればそのまま返る。
        XCTAssertEqual(landscapeDegrees ?? 0, 90, accuracy: 0.001)
        // 縦持ちでは画面水平方向がセンサー短辺になる: 2·atan(tan45° / (4/3))
        XCTAssertEqual(portraitDegrees ?? 0, 73.7398, accuracy: 0.001)
        // 縦長ビューポートでは左右が切り取られる: 2·atan(tan45° × 390/844)
        XCTAssertEqual(narrowPortraitDegrees ?? 0, 49.6019, accuracy: 0.001)
    }

    func test_StarMapCameraSessionActivationState_rejectsStaleRequests() {
        var state = StarMapCameraSessionActivationState()

        let firstOnGeneration = state.update(isActive: true)
        let offGeneration = state.update(isActive: false)
        let secondOnGeneration = state.update(isActive: true)

        XCTAssertFalse(state.matches(generation: firstOnGeneration, isActive: true))
        XCTAssertFalse(state.matches(generation: offGeneration, isActive: false))
        XCTAssertTrue(state.matches(generation: secondOnGeneration, isActive: true))
    }

    func test_StarMapCameraSessionState_derivesVisibilityAndRunState() {
        let activeState = StarMapCameraSessionState(
            isGyroMode: true,
            isBackgroundEnabled: true,
            isAuthorized: true,
            hasCameraHardware: true,
            isSceneActive: true
        )
        let hiddenButPreparedState = StarMapCameraSessionState(
            isGyroMode: true,
            isBackgroundEnabled: false,
            isAuthorized: true,
            hasCameraHardware: true,
            isSceneActive: true
        )
        let backgroundedState = StarMapCameraSessionState(
            isGyroMode: true,
            isBackgroundEnabled: true,
            isAuthorized: true,
            hasCameraHardware: true,
            isSceneActive: false
        )
        let unauthorizedState = StarMapCameraSessionState(
            isGyroMode: true,
            isBackgroundEnabled: true,
            isAuthorized: false,
            hasCameraHardware: true,
            isSceneActive: true
        )

        XCTAssertTrue(activeState.shouldKeepPreviewAttached)
        XCTAssertTrue(activeState.isCameraBackgroundVisible)
        XCTAssertTrue(activeState.shouldRunSession)
        XCTAssertTrue(hiddenButPreparedState.shouldKeepPreviewAttached)
        XCTAssertFalse(hiddenButPreparedState.isCameraBackgroundVisible)
        XCTAssertFalse(hiddenButPreparedState.shouldRunSession)
        XCTAssertTrue(backgroundedState.shouldKeepPreviewAttached)
        XCTAssertTrue(backgroundedState.isCameraBackgroundVisible)
        XCTAssertFalse(backgroundedState.shouldRunSession)
        XCTAssertFalse(unauthorizedState.shouldKeepPreviewAttached)
        XCTAssertFalse(unauthorizedState.isCameraBackgroundVisible)
        XCTAssertFalse(unauthorizedState.shouldRunSession)
    }

    func test_StarMapCameraPreviewRotation_fallbackAngle_matchesExpectedOrientations() {
        XCTAssertEqual(
            StarMapCameraPreviewRotation.fallbackAngle(for: .portrait),
            90,
            accuracy: 0.001
        )
        XCTAssertEqual(
            StarMapCameraPreviewRotation.fallbackAngle(for: .portraitUpsideDown),
            270,
            accuracy: 0.001
        )
        XCTAssertEqual(
            StarMapCameraPreviewRotation.fallbackAngle(for: .landscapeLeft),
            180,
            accuracy: 0.001
        )
        XCTAssertEqual(
            StarMapCameraPreviewRotation.fallbackAngle(for: .landscapeRight),
            0,
            accuracy: 0.001
        )
    }

    func test_StarMapViewModel_recomputesWhenStarDisplayDensityChanges() {
        let key = StarDisplayDensity.defaultsKey
        let previousValue = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.set(StarDisplayDensity.maximum.rawValue, forKey: key)
        defer {
            if let previousValue {
                UserDefaults.standard.set(previousValue, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }

        let appController = makeTokyoAppController()
        let viewModel = StarMapViewModel(appController: appController)
        var cancellables = Set<AnyCancellable>()

        let initialExpectation = expectation(description: "initial star positions")
        var initialCount = 0
        var initialCancellable: AnyCancellable?
        initialCancellable = viewModel.$starPositions
            .sink { stars in
                guard stars.count > 0 else { return }
                guard initialCount == 0 else { return }
                initialCount = stars.count
                initialExpectation.fulfill()
                initialCancellable?.cancel()
            }
        if let initialCancellable {
            initialCancellable.store(in: &cancellables)
        }
        viewModel.activatePresentationIfNeeded()
        wait(for: [initialExpectation], timeout: 5)

        let reducedExpectation = expectation(description: "reduced star positions")
        var reducedCancellable: AnyCancellable?
        reducedCancellable = viewModel.$starPositions
            .dropFirst()
            .sink { stars in
                guard stars.count < initialCount else { return }
                reducedExpectation.fulfill()
                reducedCancellable?.cancel()
            }
        if let reducedCancellable {
            reducedCancellable.store(in: &cancellables)
        }

        viewModel.setStarDisplayDensity(.small)

        wait(for: [reducedExpectation], timeout: 5)
    }

    func test_StarMapViewModel_initialPose_usesResetAltitude() {
        let appController = makeTokyoAppController()
        let viewModel = StarMapViewModel(appController: appController)
        let size = CGSize(width: 860, height: 620)

        viewModel.viewAzimuth = 123
        viewModel.viewAltitude = 10
        viewModel.viewRoll = 25
        viewModel.updateCanvasSize(size)
        viewModel.prepareForStarMapPresentation()
        viewModel.applyInitialPoseIfNeeded()

        XCTAssertEqual(viewModel.viewAzimuth, 0)
        XCTAssertEqual(viewModel.viewAltitude, StarMapLayout.resetAltitude, accuracy: 0.001)
        XCTAssertEqual(viewModel.viewRoll, 0, accuracy: 0.001)
    }

    func test_StarMapViewModel_prepareForStarMapPresentation_onlyAppliesInitialPoseOnce() {
        let appController = makeTokyoAppController()
        let viewModel = StarMapViewModel(appController: appController)
        let size = CGSize(width: 860, height: 620)

        viewModel.updateCanvasSize(size)
        viewModel.prepareForStarMapPresentation()
        viewModel.applyInitialPoseIfNeeded()
        viewModel.viewAzimuth = 148
        viewModel.viewAltitude = 33
        viewModel.viewRoll = 5

        viewModel.prepareForStarMapPresentation()
        viewModel.applyInitialPoseIfNeeded()

        XCTAssertEqual(viewModel.viewAzimuth, 148, accuracy: 0.001)
        XCTAssertEqual(viewModel.viewAltitude, 33, accuracy: 0.001)
        XCTAssertEqual(viewModel.viewRoll, 5, accuracy: 0.001)
    }

    func test_StarMapViewModel_activatePresentationIfNeeded_syncsOnlyOnFirstActivation() {
        let appController = makeTokyoAppController()
        let viewModel = StarMapViewModel(appController: appController)
        let timeZone = appController.locationController.selectedTimeZone
        let calendar = observationCalendar(for: timeZone)
        let firstReferenceDate = calendar.date(from: DateComponents(
            year: 2026,
            month: 4,
            day: 10,
            hour: 21,
            minute: 15
        ))!
        let secondReferenceDate = calendar.date(from: DateComponents(
            year: 2026,
            month: 4,
            day: 11,
            hour: 23,
            minute: 45
        ))!

        appController.selectedDate = ObservationTimeZone.startOfDay(
            for: firstReferenceDate,
            timeZone: timeZone
        )
        viewModel.activatePresentationIfNeeded(referenceDate: firstReferenceDate)
        let firstDisplayDate = viewModel.displayDate

        viewModel.displayDate = secondReferenceDate
        viewModel.activatePresentationIfNeeded(referenceDate: secondReferenceDate)

        XCTAssertEqual(firstDisplayDate, firstReferenceDate)
        XCTAssertEqual(viewModel.displayDate, secondReferenceDate)
    }

    func test_StarMapViewModel_resetToNorth_usesResetAltitude() {
        let appController = makeTokyoAppController()
        let viewModel = StarMapViewModel(appController: appController)

        viewModel.viewAzimuth = 180
        viewModel.viewAltitude = 60
        viewModel.viewRoll = -40
        viewModel.resetToNorth()

        XCTAssertEqual(viewModel.viewAzimuth, 0)
        XCTAssertEqual(viewModel.viewAltitude, StarMapLayout.resetAltitude, accuracy: 0.001)
        XCTAssertEqual(viewModel.viewRoll, 0, accuracy: 0.001)
    }

    func test_StarMapViewModel_resetToNow_updatesObservationDateAndDisplayDate() {
        let appController = makeTokyoAppController()
        let viewModel = StarMapViewModel(appController: appController)
        let timeZone = appController.locationController.selectedTimeZone
        let calendar = observationCalendar(for: timeZone)
        let previousDate = calendar.date(from: DateComponents(year: 2026, month: 8, day: 12))!
        let referenceDate = calendar.date(from: DateComponents(
            year: 2025,
            month: 1,
            day: 1,
            hour: 21,
            minute: 7
        ))!

        appController.selectedDate = previousDate
        viewModel.syncWithSelectedDate(referenceDate: previousDate)

        viewModel.resetToNow(referenceDate: referenceDate)

        let selectedComponents = calendar.dateComponents([.year, .month, .day], from: appController.selectedDate)
        let displayComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: viewModel.displayDate)

        XCTAssertEqual(selectedComponents.year, 2025)
        XCTAssertEqual(selectedComponents.month, 1)
        XCTAssertEqual(selectedComponents.day, 1)
        XCTAssertEqual(displayComponents.year, 2025)
        XCTAssertEqual(displayComponents.month, 1)
        XCTAssertEqual(displayComponents.day, 1)
        XCTAssertEqual(displayComponents.hour, 21)
        XCTAssertEqual(displayComponents.minute, 7)
    }

    func test_StarMapViewModel_displayDate_updatesTimeSliderMinutes() {
        let appController = makeTokyoAppController()
        let viewModel = StarMapViewModel(appController: appController)
        let calendar = observationCalendar(for: appController.locationController.selectedTimeZone)
        let targetDate = calendar.date(from: DateComponents(
            year: 2026,
            month: 4,
            day: 10,
            hour: 22,
            minute: 45
        ))!

        viewModel.displayDate = targetDate

        let realMinutes = 22 * 60 + 45
        var expectedOffset = Double(realMinutes) - viewModel.nightStartMinutes
        if expectedOffset < 0 { expectedOffset += 1_440 }
        expectedOffset = max(0, min(viewModel.nightDurationMinutes, expectedOffset))

        XCTAssertEqual(viewModel.timeSliderMinutes, expectedOffset, accuracy: 0.001)
        XCTAssertEqual(viewModel.displayTimeString, "22:45")
    }

    func test_StarMapViewModel_setTimeSliderMinutes_updatesDisplayDateKeepingDate() {
        let appController = makeTokyoAppController()
        let viewModel = StarMapViewModel(appController: appController)
        let calendar = observationCalendar(for: appController.locationController.selectedTimeZone)
        let baseDate = calendar.date(from: DateComponents(
            year: 2026,
            month: 4,
            day: 10,
            hour: 21,
            minute: 15
        ))!
        appController.selectedDate = baseDate
        viewModel.displayDate = baseDate

        let sliderOffset = min(120.0, viewModel.nightDurationMinutes)
        viewModel.setTimeSliderMinutes(sliderOffset)

        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: viewModel.displayDate
        )
        let expectedRealMinutes = (viewModel.nightStartMinutes + sliderOffset)
            .truncatingRemainder(dividingBy: 1_440)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 4)
        XCTAssertEqual(components.day, 10)
        XCTAssertEqual(components.hour, Int(expectedRealMinutes) / 60)
        XCTAssertEqual(components.minute, Int(expectedRealMinutes) % 60)
        XCTAssertEqual(viewModel.timeSliderMinutes, sliderOffset, accuracy: 0.001)
    }

    func test_StarMapViewModel_timeSliderInteraction_commitsFinalDateOnEnd() {
        let appController = makeTokyoAppController()
        let viewModel = StarMapViewModel(appController: appController)
        let calendar = observationCalendar(for: appController.locationController.selectedTimeZone)
        let baseDate = calendar.date(from: DateComponents(
            year: 2026,
            month: 4,
            day: 10,
            hour: 20,
            minute: 0
        ))!
        appController.selectedDate = baseDate
        viewModel.displayDate = baseDate

        viewModel.beginTimeSliderInteraction()
        viewModel.setTimeSliderMinutes(90)

        XCTAssertTrue(viewModel.isTimeSliderScrubbing)
        XCTAssertEqual(viewModel.timeSliderMinutes, 90, accuracy: 0.001)

        viewModel.endTimeSliderInteraction()

        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: viewModel.displayDate
        )
        let expectedRealMinutes = (viewModel.nightStartMinutes + 90)
            .truncatingRemainder(dividingBy: 1_440)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 4)
        XCTAssertEqual(components.day, 10)
        XCTAssertEqual(components.hour, Int(expectedRealMinutes) / 60)
        XCTAssertEqual(components.minute, Int(expectedRealMinutes) % 60)
        XCTAssertFalse(viewModel.isTimeSliderScrubbing)
    }

    func test_StarMapViewModel_finalizeTransientInteractionState_commitsPendingSliderDate() {
        let appController = makeTokyoAppController()
        let viewModel = StarMapViewModel(appController: appController)
        let calendar = observationCalendar(for: appController.locationController.selectedTimeZone)
        let baseDate = calendar.date(from: DateComponents(
            year: 2026,
            month: 4,
            day: 10,
            hour: 20,
            minute: 0
        ))!
        appController.selectedDate = baseDate
        viewModel.displayDate = baseDate

        viewModel.beginTimeSliderInteraction()
        viewModel.setTimeSliderMinutes(120)
        viewModel.finalizeTransientInteractionState()

        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: viewModel.displayDate
        )
        let expectedRealMinutes = (viewModel.nightStartMinutes + 120)
            .truncatingRemainder(dividingBy: 1_440)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 4)
        XCTAssertEqual(components.day, 10)
        XCTAssertEqual(components.hour, Int(expectedRealMinutes) / 60)
        XCTAssertEqual(components.minute, Int(expectedRealMinutes) % 60)
        XCTAssertFalse(viewModel.isTimeSliderScrubbing)
    }

    func test_StarMapViewModel_selectedDateChange_discardsPendingTimeSliderCommit() async {
        let appController = makeTokyoAppController()
        let viewModel = StarMapViewModel(
            appController: appController,
            computationDependency: makeStaticComputationDependency()
        )
        let timeZone = appController.locationController.selectedTimeZone
        let calendar = observationCalendar(for: timeZone)
        let currentDate = calendar.date(from: DateComponents(year: 2026, month: 8, day: 12))!
        let nextDate = calendar.date(from: DateComponents(year: 2026, month: 8, day: 13))!
        let referenceDate = calendar.date(from: DateComponents(
            year: 2025,
            month: 1,
            day: 1,
            hour: 21,
            minute: 0
        ))!

        appController.selectedDate = currentDate
        viewModel.syncWithSelectedDate(referenceDate: referenceDate)
        viewModel.beginTimeSliderInteraction()
        viewModel.setTimeSliderMinutes(90)

        appController.selectedDate = nextDate

        await waitUntil(timeout: 1.0) {
            StarMapDateLogic.observationDate(
                for: viewModel.displayDate,
                timeZone: timeZone,
                nightStartMinutes: viewModel.nightStartMinutes
            ) == nextDate
        }

        try? await Task.sleep(nanoseconds: 120_000_000)

        let observationDate = StarMapDateLogic.observationDate(
            for: viewModel.displayDate,
            timeZone: timeZone,
            nightStartMinutes: viewModel.nightStartMinutes
        )
        XCTAssertEqual(observationDate, nextDate)
    }

    func test_StarMapDateLogic_nightRange_returnsFullDayDuringPolarNight() {
        let timeZone = TimeZone(identifier: "Europe/Oslo")!
        let calendar = observationCalendar(for: timeZone)
        let date = calendar.date(from: DateComponents(year: 2026, month: 12, day: 21))!
        let referenceDate = calendar.date(from: DateComponents(
            year: 2026,
            month: 12,
            day: 21,
            hour: 21,
            minute: 0
        ))!
        let range = StarMapDateLogic.nightRange(
            for: date,
            location: CLLocationCoordinate2D(latitude: 78.2232, longitude: 15.6469),
            timeZone: timeZone,
            referenceDate: referenceDate,
            fallback: .init(startMinutes: 18 * 60, durationMinutes: 600)
        )

        XCTAssertEqual(range.startMinutes, 12 * 60, accuracy: 1)
        XCTAssertEqual(range.durationMinutes, 1_440, accuracy: 1)
    }

    func test_StarMapDateLogic_maxSelectableNightOffset_capsFullDayRange() {
        XCTAssertEqual(
            StarMapDateLogic.maxSelectableNightOffset(nightDurationMinutes: 1_440),
            1_439,
            accuracy: 0.001
        )
        XCTAssertEqual(
            StarMapDateLogic.maxSelectableNightOffset(nightDurationMinutes: 600),
            600,
            accuracy: 0.001
        )
    }

    func test_StarMapDateLogic_nightRange_returnsZeroDurationWhenNoCivilDarkness() {
        let timeZone = TimeZone(identifier: "Europe/Oslo")!
        let calendar = observationCalendar(for: timeZone)
        let date = calendar.date(from: DateComponents(year: 2026, month: 6, day: 21))!
        let referenceDate = calendar.date(from: DateComponents(
            year: 2026,
            month: 6,
            day: 21,
            hour: 23,
            minute: 0
        ))!
        let range = StarMapDateLogic.nightRange(
            for: date,
            location: CLLocationCoordinate2D(latitude: 78.2232, longitude: 15.6469),
            timeZone: timeZone,
            referenceDate: referenceDate,
            fallback: .init(startMinutes: 18 * 60, durationMinutes: 600)
        )

        XCTAssertEqual(range.startMinutes, 23 * 60, accuracy: 1)
        XCTAssertEqual(range.durationMinutes, 0, accuracy: 0.1)
    }

    func test_StarMapViewModel_syncWithSelectedDate_snapsDaytimeToSelectedEvening() throws {
        let appController = makeTokyoAppController()
        let viewModel = StarMapViewModel(appController: appController)
        let calendar = observationCalendar(for: appController.locationController.selectedTimeZone)
        let selectedDate = calendar.date(from: DateComponents(year: 2026, month: 8, day: 12))!
        let referenceDate = calendar.date(from: DateComponents(
            year: 2025,
            month: 1,
            day: 1,
            hour: 6,
            minute: 7
        ))!

        appController.selectedDate = selectedDate
        viewModel.syncWithSelectedDate(referenceDate: referenceDate)

        let twilight = try XCTUnwrap(
            MilkyWayCalculator.findSunsetSunriseMinutes(
                date: selectedDate,
                location: appController.locationController.selectedLocation,
                timeZone: appController.locationController.selectedTimeZone
            )
        )
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: viewModel.displayDate
        )
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 8)
        XCTAssertEqual(components.day, 12)
        XCTAssertEqual(components.hour, Int(twilight.sunsetMinutes) / 60)
        XCTAssertEqual(components.minute, Int(twilight.sunsetMinutes) % 60)
        XCTAssertEqual(viewModel.timeSliderMinutes, 0, accuracy: 0.001)
    }

    func test_StarMapViewModel_syncWithSelectedDate_keepsCurrentTimeDuringNight() {
        let appController = makeTokyoAppController()
        let viewModel = StarMapViewModel(appController: appController)
        let calendar = observationCalendar(for: appController.locationController.selectedTimeZone)
        let selectedDate = calendar.date(from: DateComponents(year: 2026, month: 8, day: 12))!
        let referenceDate = calendar.date(from: DateComponents(
            year: 2025,
            month: 1,
            day: 1,
            hour: 21,
            minute: 7
        ))!

        appController.selectedDate = selectedDate
        viewModel.syncWithSelectedDate(referenceDate: referenceDate)

        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: viewModel.displayDate
        )
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 8)
        XCTAssertEqual(components.day, 12)
        XCTAssertEqual(components.hour, 21)
        XCTAssertEqual(components.minute, 7)
        let realMinutes = 21 * 60 + 7
        var expectedOffset = Double(realMinutes) - viewModel.nightStartMinutes
        if expectedOffset < 0 { expectedOffset += 1_440 }
        expectedOffset = max(0, min(viewModel.nightDurationMinutes, expectedOffset))
        XCTAssertEqual(viewModel.timeSliderMinutes, expectedOffset, accuracy: 0.001)
    }

    func test_StarMapViewModel_syncWithSelectedDate_movesAfterMidnightIntoNextDay() {
        let appController = makeTokyoAppController()
        let viewModel = StarMapViewModel(appController: appController)
        let calendar = observationCalendar(for: appController.locationController.selectedTimeZone)
        let selectedDate = calendar.date(from: DateComponents(year: 2026, month: 8, day: 12))!
        let referenceDate = calendar.date(from: DateComponents(
            year: 2025,
            month: 1,
            day: 1,
            hour: 2,
            minute: 7
        ))!

        appController.selectedDate = selectedDate
        viewModel.syncWithSelectedDate(referenceDate: referenceDate)

        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: viewModel.displayDate
        )
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 8)
        XCTAssertEqual(components.day, 13)
        XCTAssertEqual(components.hour, 2)
        XCTAssertEqual(components.minute, 7)
    }

    func test_StarMapViewModel_setTimeSliderMinutes_keepsObservationNightAcrossMidnight() {
        let appController = makeTokyoAppController()
        let viewModel = StarMapViewModel(appController: appController)
        let calendar = observationCalendar(for: appController.locationController.selectedTimeZone)
        let selectedDate = calendar.date(from: DateComponents(year: 2026, month: 8, day: 12))!
        let referenceDate = calendar.date(from: DateComponents(
            year: 2025,
            month: 1,
            day: 1,
            hour: 2,
            minute: 7
        ))!

        appController.selectedDate = selectedDate
        viewModel.syncWithSelectedDate(referenceDate: referenceDate)
        viewModel.setTimeSliderMinutes(0)

        let twilight = MilkyWayCalculator.findSunsetSunriseMinutes(
            date: selectedDate,
            location: appController.locationController.selectedLocation,
            timeZone: appController.locationController.selectedTimeZone
        )
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: viewModel.displayDate
        )

        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 8)
        XCTAssertEqual(components.day, 12)
        XCTAssertEqual(components.hour, Int((twilight?.sunsetMinutes ?? 0)) / 60)
        XCTAssertEqual(components.minute, Int((twilight?.sunsetMinutes ?? 0)) % 60)
    }

    func test_StarMapViewModel_setTimeSliderMinutes_clampsPolarNightEndpoint() {
        let storage = InMemoryLocationStorage()
        storage.latitude = 78.2232
        storage.longitude = 15.6469
        storage.name = "ロングイェールビーン"
        storage.timeZoneIdentifier = "Europe/Oslo"

        let locationController = LocationController(
            storage: storage,
            searchService: NoopLocationSearchService(),
            locationNameResolver: FixedLocationNameResolver(
                resolvedName: "ロングイェールビーン",
                timeZoneIdentifier: "Europe/Oslo"
            )
        )
        let appController = AppController(
            locationController: locationController,
            calculationService: MockNightCalculationService()
        )
        let viewModel = StarMapViewModel(
            appController: appController,
            computationDependency: makeStaticComputationDependency()
        )
        let timeZone = TimeZone(identifier: "Europe/Oslo")!
        let calendar = observationCalendar(for: timeZone)
        let selectedDate = calendar.date(from: DateComponents(year: 2026, month: 12, day: 21))!
        let referenceDate = calendar.date(from: DateComponents(
            year: 2026,
            month: 12,
            day: 21,
            hour: 21,
            minute: 0
        ))!

        appController.selectedDate = selectedDate
        viewModel.syncWithSelectedDate(referenceDate: referenceDate)
        viewModel.setTimeSliderMinutes(1_440)

        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: viewModel.displayDate)
        XCTAssertEqual(viewModel.nightDurationMinutes, 1_440, accuracy: 1)
        XCTAssertEqual(viewModel.timeSliderMaximumMinutes, 1_439, accuracy: 0.001)
        XCTAssertEqual(viewModel.timeSliderMinutes, 1_439, accuracy: 0.001)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 12)
        XCTAssertEqual(components.day, 22)
        XCTAssertEqual(components.hour, 11)
        XCTAssertEqual(components.minute, 59)
    }

    func test_StarMapViewModel_updatesTimeSliderWhenTimeZoneChanges() async {
        let storage = InMemoryLocationStorage()
        storage.latitude = 35.6762
        storage.longitude = 139.6503
        storage.name = "東京"
        storage.timeZoneIdentifier = "Asia/Tokyo"

        let locationController = LocationController(
            storage: storage,
            searchService: NoopLocationSearchService(),
            locationNameResolver: FixedLocationNameResolver(
                resolvedName: "ロサンゼルス",
                timeZoneIdentifier: "America/Los_Angeles"
            )
        )
        let appController = AppController(
            locationController: locationController,
            calculationService: MockNightCalculationService()
        )
        let viewModel = StarMapViewModel(appController: appController)
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let displayDate = utcCalendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 12,
            hour: 4,
            minute: 0
        ))!

        viewModel.displayDate = displayDate
        let initialTimeSliderMinutes = viewModel.timeSliderMinutes

        locationController.selectCoordinate(
            CLLocationCoordinate2D(latitude: 34.0522, longitude: -118.2437)
        )

        await waitUntil(timeout: 2.0) {
            locationController.selectedTimeZone.identifier == "America/Los_Angeles"
                && abs(viewModel.timeSliderMinutes - initialTimeSliderMinutes) > 0.5
        }

        let expectedRealMinutes = StarMapDateLogic.clockMinutes(
            for: displayDate,
            timeZone: locationController.selectedTimeZone
        )
        let expectedOffset = StarMapDateLogic.realMinutesToNightOffset(
            expectedRealMinutes,
            nightStartMinutes: viewModel.nightStartMinutes,
            nightDurationMinutes: viewModel.nightDurationMinutes
        )

        XCTAssertEqual(locationController.selectedTimeZone.identifier, "America/Los_Angeles")
        XCTAssertEqual(viewModel.timeSliderMinutes, expectedOffset, accuracy: 0.001)
    }

    func test_StarMapViewModel_timeZoneChange_reanchorsDisplayDateToObservationNight() async {
        let storage = InMemoryLocationStorage()
        storage.latitude = 35.6762
        storage.longitude = 139.6503
        storage.name = "東京"
        storage.timeZoneIdentifier = "Asia/Tokyo"

        let locationController = LocationController(
            storage: storage,
            searchService: NoopLocationSearchService(),
            locationNameResolver: FixedLocationNameResolver(
                resolvedName: "ロサンゼルス",
                timeZoneIdentifier: "America/Los_Angeles"
            )
        )
        let appController = AppController(
            locationController: locationController,
            calculationService: MockNightCalculationService()
        )
        let viewModel = StarMapViewModel(appController: appController)
        let tokyo = TestTimeZones.tokyo
        let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
        let tokyoCalendar = ObservationTimeZone.gregorianCalendar(timeZone: tokyo)
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current

        appController.selectedDate = tokyoCalendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 12
        ))!
        let initialDisplayDate = utcCalendar.date(from: DateComponents(
            year: 2026,
            month: 8,
            day: 12,
            hour: 4,
            minute: 0
        ))!
        viewModel.displayDate = initialDisplayDate

        locationController.selectCoordinate(
            CLLocationCoordinate2D(latitude: 34.0522, longitude: -118.2437)
        )

        let expectedDate = StarMapDateLogic.resolvedPresentationDate(
            for: appController.selectedDate,
            referenceDate: initialDisplayDate,
            location: CLLocationCoordinate2D(latitude: 34.0522, longitude: -118.2437),
            timeZone: losAngeles
        )

        // VM の再同期は購読経由で非同期に走るため、VM 自身の状態を待つ。
        await waitUntil(timeout: 2.0) {
            viewModel.displayDate == expectedDate
        }

        XCTAssertEqual(locationController.selectedTimeZone.identifier, losAngeles.identifier)
        XCTAssertEqual(viewModel.displayDate, expectedDate)
    }

    func test_StarMapViewModel_setObservationDate_preservesDisplayedNightTime() {
        let appController = makeTokyoAppController()
        let viewModel = StarMapViewModel(appController: appController)
        let tokyo = TestTimeZones.tokyo
        let calendar = ObservationTimeZone.gregorianCalendar(timeZone: tokyo)

        let selectedDate = calendar.date(from: DateComponents(year: 2026, month: 8, day: 12))!
        let nextDate = calendar.date(from: DateComponents(year: 2026, month: 8, day: 13))!
        let referenceDate = calendar.date(from: DateComponents(
            year: 2025,
            month: 1,
            day: 1,
            hour: 21,
            minute: 7
        ))!

        appController.selectedDate = selectedDate
        viewModel.syncWithSelectedDate(referenceDate: referenceDate)
        viewModel.setObservationDate(nextDate)

        let displayComponents = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: viewModel.displayDate)
        let selectedComponents = calendar.dateComponents([.year, .month, .day], from: appController.selectedDate)

        XCTAssertEqual(selectedComponents.year, 2026)
        XCTAssertEqual(selectedComponents.month, 8)
        XCTAssertEqual(selectedComponents.day, 13)
        XCTAssertEqual(displayComponents.year, 2026)
        XCTAssertEqual(displayComponents.month, 8)
        XCTAssertEqual(displayComponents.day, 13)
        XCTAssertEqual(displayComponents.hour, 21)
        XCTAssertEqual(displayComponents.minute, 7)
    }

    func test_StarMapViewModel_locationChange_clearsTerrainAndIgnoresStaleFetch() async {
        let appController = makeTokyoAppController()
        let losAngeles = CLLocationCoordinate2D(latitude: 34.0522, longitude: -118.2437)
        let sanFrancisco = CLLocationCoordinate2D(latitude: 37.7749, longitude: -122.4194)
        let terrainDependency = StarMapTerrainDependency(
            fetchProfile: { latitude, longitude in
                switch (latitude, longitude) {
                case (34.0522, -118.2437):
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    return TerrainProfile(horizonAngles: Array(repeating: 2, count: 72))
                case (37.7749, -122.4194):
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    return TerrainProfile(horizonAngles: Array(repeating: 3, count: 72))
                default:
                    try? await Task.sleep(nanoseconds: 20_000_000)
                    return TerrainProfile(horizonAngles: Array(repeating: 1, count: 72))
                }
            }
        )
        let viewModel = StarMapViewModel(
            appController: appController,
            terrainDependency: terrainDependency,
            computationDependency: makeStaticComputationDependency()
        )
        viewModel.activatePresentationIfNeeded()

        await waitUntil(timeout: 1.0) {
            viewModel.terrainProfile?.horizonAngles.first == 1
        }

        appController.locationController.selectCoordinate(losAngeles)

        await waitUntil(timeout: 1.0) {
            viewModel.terrainProfile == nil
        }

        appController.locationController.selectCoordinate(sanFrancisco)

        await waitUntil(timeout: 1.0) {
            viewModel.terrainProfile?.horizonAngles.first == 3
        }

        try? await Task.sleep(nanoseconds: 220_000_000)

        XCTAssertEqual(viewModel.terrainProfile?.horizonAngles.first, 3)
    }

    func test_StarMapViewModel_terrainFetchState_reflectsLoadingAndResult() async {
        let appController = makeTokyoAppController()
        let losAngeles = CLLocationCoordinate2D(latitude: 34.0522, longitude: -118.2437)
        let terrainDependency = StarMapTerrainDependency(
            fetchProfile: { latitude, longitude in
                if latitude == losAngeles.latitude && longitude == losAngeles.longitude {
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    return nil
                }
                try? await Task.sleep(nanoseconds: 20_000_000)
                return TerrainProfile(horizonAngles: Array(repeating: 1, count: 72))
            }
        )

        let viewModel = StarMapViewModel(
            appController: appController,
            terrainDependency: terrainDependency,
            computationDependency: makeStaticComputationDependency()
        )
        viewModel.activatePresentationIfNeeded()

        await waitUntil(timeout: 1.0) {
            viewModel.terrainFetchState == .available
                && viewModel.terrainProfile?.horizonAngles.first == 1
        }

        appController.locationController.selectCoordinate(losAngeles)

        await waitUntil(timeout: 1.0) {
            viewModel.terrainFetchState == .loading
                && viewModel.terrainProfile == nil
        }

        await waitUntil(timeout: 1.0) {
            viewModel.terrainFetchState == .unavailable
                && viewModel.terrainProfile == nil
        }
    }

    func test_StarMapViewModel_setObservationDate_triggersNightRecalculation() async {
        let calculationService = MockNightCalculationService()
        let storage = InMemoryLocationStorage()
        storage.latitude = 35.6762
        storage.longitude = 139.6503
        storage.name = "東京"
        storage.timeZoneIdentifier = "Asia/Tokyo"
        let locationController = LocationController(
            storage: storage,
            searchService: NoopLocationSearchService(),
            locationNameResolver: FixedLocationNameResolver(
                resolvedName: "東京",
                timeZoneIdentifier: "Asia/Tokyo"
            )
        )
        let appController = AppController(
            locationController: locationController,
            calculationService: calculationService
        )
        let viewModel = StarMapViewModel(appController: appController)
        let tokyo = TestTimeZones.tokyo
        let calendar = ObservationTimeZone.gregorianCalendar(timeZone: tokyo)
        let nextDate = calendar.date(from: DateComponents(year: 2026, month: 8, day: 13))!

        viewModel.setObservationDate(nextDate)

        await waitUntil {
            appController.selectedDate == nextDate
        }

        for _ in 0..<30 {
            let nightCalls = await calculationService.getNightSummaryCallCount()
            if nightCalls > 0 {
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }

        let nightCallCount = await calculationService.getNightSummaryCallCount()
        XCTAssertGreaterThanOrEqual(nightCallCount, 1)
    }

    func test_StarMapViewModel_terrainCacheKey_roundsCoordinatesConsistently() {
        XCTAssertEqual(
            StarMapViewModel.terrainCacheKey(latitude: 35.1234, longitude: 139.5678),
            "35.123,139.568"
        )
        XCTAssertEqual(
            StarMapViewModel.terrainCacheKey(latitude: -35.1251, longitude: -139.5651),
            "-35.125,-139.565"
        )
    }

    func test_ConstellationData_containsAll88IAUConstellationsIncludingSouthernSky() {
        XCTAssertEqual(ConstellationData.constellations.count, 88)

        let englishNames = Set(ConstellationData.constellations.map(\.englishName))
        XCTAssertEqual(englishNames.count, 88)

        ["Crux", "Centaurus", "Carina", "Musca", "Pavo", "Tucana", "Indus", "Octans"].forEach {
            XCTAssertTrue(englishNames.contains($0), "\($0) が星座カタログに含まれていません")
        }
    }

    func test_ConstellationData_englishDisplayName_normalizesPreferredLabels() {
        let displayNames = Dictionary(
            uniqueKeysWithValues: ConstellationData.constellations.map { ($0.englishName, $0.englishDisplayName) }
        )

        XCTAssertEqual(displayNames["Boötes"], "Bootes")
        XCTAssertEqual(displayNames["Corona Austrina"], "Corona Australis")
        XCTAssertEqual(displayNames["Serpens Caput"], "Serpens")
    }

    func test_ConstellationEntry_resolvedDisplayName_normalizesTranslatedEnglishLabels() {
        let entry = ConstellationEntry(
            japaneseName: "うしかい座",
            englishName: "Boötes",
            centerRA: 0,
            centerDec: 0,
            segments: []
        )

        XCTAssertEqual(
            entry.resolvedDisplayName(localizedJapaneseName: "Boötes", preferredLanguage: "en"),
            "Bootes"
        )
        XCTAssertEqual(
            entry.resolvedDisplayName(localizedJapaneseName: "うしかい座", preferredLanguage: "en"),
            "Bootes"
        )
        XCTAssertEqual(
            entry.resolvedDisplayName(localizedJapaneseName: "うしかい座", preferredLanguage: "ja"),
            "うしかい座"
        )
    }

    func test_ConstellationData_segmentsStayWithinValidEquatorialCoordinateRanges() {
        for constellation in ConstellationData.constellations {
            XCTAssertFalse(constellation.segments.isEmpty, "\(constellation.englishName) に星座線がありません")
            XCTAssertTrue((0...360).contains(constellation.centerRA), "\(constellation.englishName) の中心RAが不正です")
            XCTAssertTrue((-90...90).contains(constellation.centerDec), "\(constellation.englishName) の中心Decが不正です")

            for segment in constellation.segments {
                XCTAssertTrue((0...360).contains(segment.ra1), "\(constellation.englishName) の ra1 が不正です")
                XCTAssertTrue((0...360).contains(segment.ra2), "\(constellation.englishName) の ra2 が不正です")
                XCTAssertTrue((-90...90).contains(segment.dec1), "\(constellation.englishName) の dec1 が不正です")
                XCTAssertTrue((-90...90).contains(segment.dec2), "\(constellation.englishName) の dec2 が不正です")
            }
        }
    }

    func test_StarMapComputation_southernLatitudeShowsMajorSouthernConstellationLabels() {
        let snapshot = StarMapComputation.compute(
            latitude: -45,
            longitude: 0,
            julianDate: 2_461_041.5,
            localSiderealTime: 186,
            activeMeteorShowers: [],
            starDisplayDensity: .small
        )

        let visibleLabelNames = Set(snapshot.constellationLabels.map(\.name))
        let expectedVisibleLabels = ["Crux", "Centaurus", "Carina", "Musca", "Triangulum Australe"]
            .compactMap { englishName in
                ConstellationData.constellations.first(where: { $0.englishName == englishName })?.localizedName
            }

        expectedVisibleLabels.forEach {
            XCTAssertTrue(visibleLabelNames.contains($0), "\($0) が南半球スナップショットに表示されていません")
        }
        XCTAssertGreaterThan(snapshot.constellationLines.count, 20)
    }

    func test_StarMapCanvasView_optimizedConstellationLabelPlacements_avoidsOverlaps() {
        let candidates = [
            ConstellationLabelCandidate(
                name: "みなみじゅうじ座",
                anchor: CGPoint(x: 150, y: 100),
                priority: 40
            ),
            ConstellationLabelCandidate(
                name: "ケンタウルス座",
                anchor: CGPoint(x: 154, y: 104),
                priority: 39
            ),
            ConstellationLabelCandidate(
                name: "りゅうこつ座",
                anchor: CGPoint(x: 158, y: 108),
                priority: 38
            )
        ]

        let placements = ConstellationLabelLayoutEngine.optimizedPlacements(
            candidates: candidates,
            canvasSize: CGSize(width: 320, height: 220)
        )

        XCTAssertEqual(placements.count, candidates.count)
        for index in placements.indices {
            for otherIndex in placements.indices where otherIndex > index {
                XCTAssertFalse(
                    placements[index].bounds.insetBy(dx: -4, dy: -2)
                        .intersects(placements[otherIndex].bounds.insetBy(dx: -4, dy: -2)),
                    "星座ラベルが重なっています: \(placements[index].name) / \(placements[otherIndex].name)"
                )
            }
        }
    }

    func test_StarMapCanvasView_optimizedConstellationLabelPlacements_skipsLowerPriorityWhenSpaceRunsOut() {
        let primaryLabel = "みなみのかんむり座"
        let secondaryLabel = "みなみのさんかく座"
        let primarySize = ConstellationLabelLayoutEngine.estimateLabelSize(text: primaryLabel)
        let secondarySize = ConstellationLabelLayoutEngine.estimateLabelSize(text: secondaryLabel)
        let canvasSize = CGSize(
            width: max(primarySize.width, secondarySize.width) + 12,
            height: max(primarySize.height, secondarySize.height) + 12
        )
        let anchor = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)

        let placements = ConstellationLabelLayoutEngine.optimizedPlacements(
            candidates: [
                ConstellationLabelCandidate(
                    name: primaryLabel,
                    anchor: anchor,
                    priority: 30
                ),
                ConstellationLabelCandidate(
                    name: secondaryLabel,
                    anchor: anchor,
                    priority: 10
                )
            ],
            canvasSize: canvasSize
        )

        XCTAssertEqual(placements.map(\.name), [primaryLabel])
    }

    func test_StarMapCanvasView_optimizedConstellationLabelPlacements_clampsIntoCanvasBounds() throws {
        let placements = ConstellationLabelLayoutEngine.optimizedPlacements(
            candidates: [
                ConstellationLabelCandidate(
                    name: "Corona Australis",
                    anchor: CGPoint(x: 6, y: 6),
                    priority: 20
                )
            ],
            canvasSize: CGSize(width: 240, height: 160)
        )

        let placement = try XCTUnwrap(placements.first)
        XCTAssertGreaterThanOrEqual(placement.bounds.minX, 0)
        XCTAssertGreaterThanOrEqual(placement.bounds.minY, 0)
        XCTAssertLessThanOrEqual(placement.bounds.maxX, 240)
        XCTAssertLessThanOrEqual(placement.bounds.maxY, 160)
    }

    func test_StarMapCanvasView_optimizedConstellationLabelPlacements_respectsReservedBottomInset() throws {
        let placements = ConstellationLabelLayoutEngine.optimizedPlacements(
            candidates: [
                ConstellationLabelCandidate(
                    name: "みなみのうお座",
                    anchor: CGPoint(x: 120, y: 150),
                    priority: 20
                )
            ],
            canvasSize: CGSize(width: 240, height: 180),
            reservedBottomInset: 44
        )

        let placement = try XCTUnwrap(placements.first)
        XCTAssertLessThanOrEqual(placement.bounds.maxY, 180 - 44)
    }

    // MARK: - 日付変更後の「現在」

    private func makeTokyoAfterMidnightReference() -> (calendar: Calendar, today: Date, previousDay: Date, now: Date) {
        let calendar = observationCalendar(for: TestTimeZones.tokyo)
        let today = calendar.date(from: DateComponents(year: 2026, month: 1, day: 2))!
        let previousDay = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let now = calendar.date(from: DateComponents(year: 2026, month: 1, day: 2, hour: 2, minute: 7))!
        return (calendar, today, previousDay, now)
    }

    func test_StarMapViewModel_currentObservationDate_afterMidnightBelongsToPreviousEvening() {
        let reference = makeTokyoAfterMidnightReference()
        let tokyo = CLLocationCoordinate2D(latitude: 35.6762, longitude: 139.6503)
        let morning = reference.calendar.date(from: DateComponents(year: 2026, month: 1, day: 2, hour: 10))!
        let evening = reference.calendar.date(from: DateComponents(year: 2026, month: 1, day: 2, hour: 21))!

        XCTAssertEqual(
            StarMapViewModel.currentObservationDate(for: reference.now, location: tokyo, timeZone: TestTimeZones.tokyo),
            reference.previousDay
        )
        XCTAssertEqual(
            StarMapViewModel.currentObservationDate(for: morning, location: tokyo, timeZone: TestTimeZones.tokyo),
            reference.today
        )
        XCTAssertEqual(
            StarMapViewModel.currentObservationDate(for: evening, location: tokyo, timeZone: TestTimeZones.tokyo),
            reference.today
        )
    }

    func test_StarMapViewModel_resetToNow_afterMidnightShowsCurrentInstant() {
        let appController = makeTokyoAppController()
        let viewModel = StarMapViewModel(
            appController: appController,
            computationDependency: makeStaticComputationDependency()
        )
        let reference = makeTokyoAfterMidnightReference()

        // 明夜（暦日の今日）を選んでいても、「現在」は進行中の前夜の現在時刻へ戻す。
        appController.selectedDate = reference.today
        viewModel.resetToNow(referenceDate: reference.now)

        XCTAssertEqual(appController.selectedDate, reference.previousDay)
        XCTAssertEqual(viewModel.displayDate, reference.now)
        XCTAssertEqual(viewModel.displayTimeString, "02:07")
    }

    func test_StarMapViewModel_activatePresentationIfNeeded_afterMidnightLaunchShowsCurrentInstant() {
        let appController = makeTokyoAppController()
        let viewModel = StarMapViewModel(
            appController: appController,
            computationDependency: makeStaticComputationDependency()
        )
        let reference = makeTokyoAfterMidnightReference()

        // AppController は深夜の起動で進行中の前夜を「今日」に選ぶため、星図を開いても選択日は動かない。
        appController.onStart(referenceDate: reference.now, refreshExternalData: false)
        XCTAssertEqual(appController.selectedDate, reference.previousDay)
        viewModel.activatePresentationIfNeeded(referenceDate: reference.now)

        XCTAssertEqual(appController.selectedDate, reference.previousDay)
        XCTAssertEqual(viewModel.displayDate, reference.now)
        XCTAssertEqual(viewModel.displayTimeString, "02:07")
    }

    /// 深夜に明夜（暦日の今日）を選んでいる場合、星図を開いても選択日を黙って前夜へ戻さない。
    func test_StarMapViewModel_syncWithSelectedDate_afterMidnightKeepsExplicitNextNight() {
        let appController = makeTokyoAppController()
        let viewModel = StarMapViewModel(
            appController: appController,
            computationDependency: makeStaticComputationDependency()
        )
        let reference = makeTokyoAfterMidnightReference()

        appController.selectedDate = reference.today
        viewModel.activatePresentationIfNeeded(referenceDate: reference.now)
        viewModel.syncWithSelectedDate(referenceDate: reference.now)

        let displayComponents = reference.calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: viewModel.displayDate
        )
        XCTAssertEqual(appController.selectedDate, reference.today)
        XCTAssertEqual(displayComponents.day, 3)
        XCTAssertEqual(displayComponents.hour, 2)
        XCTAssertEqual(displayComponents.minute, 7)
    }

    /// 星図を開いたまま深夜 0 時を越えて前景復帰しても、選択日は今夜のままで、表示は 24 時間先へ飛ばない。
    func test_StarMapViewModel_openAcrossMidnight_keepsShowingRealInstant() async {
        let appController = makeTokyoAppController()
        let viewModel = StarMapViewModel(
            appController: appController,
            computationDependency: makeStaticComputationDependency()
        )
        let calendar = observationCalendar(for: TestTimeZones.tokyo)
        let tonight = calendar.date(from: DateComponents(year: 2026, month: 8, day: 12))!
        let evening = calendar.date(from: DateComponents(year: 2026, month: 8, day: 12, hour: 23))!
        let afterMidnight = calendar.date(from: DateComponents(year: 2026, month: 8, day: 13, hour: 0, minute: 30))!

        appController.onStart(referenceDate: evening, refreshExternalData: false)
        viewModel.activatePresentationIfNeeded(referenceDate: evening)
        XCTAssertEqual(viewModel.displayDate, evening)

        appController.handleSceneDidBecomeActive(referenceDate: afterMidnight, refreshExternalData: false)
        // 選択日の変更通知はメインキュー経由で届くため、反映の機会を与える。
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(appController.selectedDate, tonight)
        XCTAssertEqual(viewModel.displayDate, evening)

        viewModel.resetToNow(referenceDate: afterMidnight)
        XCTAssertEqual(appController.selectedDate, tonight)
        XCTAssertEqual(viewModel.displayDate, afterMidnight)
        XCTAssertEqual(viewModel.displayTimeString, "00:30")
    }

    func test_StarMapViewModel_setObservationDate_afterResetToNowAtMidnightKeepsPickedDate() {
        let appController = makeTokyoAppController()
        let viewModel = StarMapViewModel(
            appController: appController,
            computationDependency: makeStaticComputationDependency()
        )
        let reference = makeTokyoAfterMidnightReference()

        appController.selectedDate = reference.today
        viewModel.resetToNow(referenceDate: reference.now)
        viewModel.setObservationDate(reference.today)

        let displayComponents = reference.calendar.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: viewModel.displayDate
        )
        XCTAssertEqual(appController.selectedDate, reference.today)
        XCTAssertEqual(displayComponents.day, 3)
        XCTAssertEqual(displayComponents.hour, 2)
        XCTAssertEqual(displayComponents.minute, 7)
    }

    // MARK: - 同一タイムゾーン内の地点変更

    func test_StarMapViewModel_locationChangeWithinSameTimeZone_recomputesSkyForNewLocation() async {
        let appController = makeTokyoAppController()
        // 計算に渡された緯度を sunAltitude に入れて、どの地点で再計算されたかを判別する。
        let viewModel = StarMapViewModel(
            appController: appController,
            terrainDependency: StarMapTerrainDependency(fetchProfile: { _, _ in nil }),
            computationDependency: StarMapComputationDependency(
                computeSnapshot: { latitude, _, _, _, _, _ in
                    StarMapComputation.Snapshot(
                        starPositions: [],
                        sunAltitude: latitude,
                        moonAltitude: -10,
                        moonAzimuth: 180,
                        moonPhase: 0.1,
                        galacticCenterAltitude: 30,
                        galacticCenterAzimuth: 180,
                        constellationLines: [],
                        constellationLabels: [],
                        planetPositions: [],
                        meteorShowerRadiants: [],
                        milkyWayBandPoints: []
                    )
                }
            )
        )
        let calendar = observationCalendar(for: TestTimeZones.tokyo)
        appController.selectedDate = calendar.date(from: DateComponents(year: 2026, month: 8, day: 12))!
        let referenceDate = calendar.date(from: DateComponents(year: 2025, month: 1, day: 1, hour: 22, minute: 0))!
        viewModel.activatePresentationIfNeeded(referenceDate: referenceDate)

        await waitUntil(timeout: 2.0) {
            abs(viewModel.sunAltitude - 35.6762) < 0.0001
        }
        let displayDateBeforeChange = viewModel.displayDate

        // 大阪（同じ Asia/Tokyo）。夜間の表示日時は変わらないが、天体位置は再計算されなければならない。
        appController.locationController.selectCoordinate(
            CLLocationCoordinate2D(latitude: 34.6937, longitude: 135.5023)
        )

        await waitUntil(timeout: 2.0) {
            abs(viewModel.sunAltitude - 34.6937) < 0.0001
        }
        XCTAssertEqual(viewModel.displayDate, displayDateBeforeChange)
        XCTAssertEqual(viewModel.displayTimeString, "22:00")
    }

    // MARK: - 描画ヘルパー

    func test_StarMapCanvasView_cardinalLabelPlacements_doesNotStackOffscreenLabels() {
        let size = CGSize(width: 390, height: 844)
        let placements = StarMapCanvasView.cardinalLabelPlacements(
            size: size,
            centerAlt: 30,
            centerAz: 20,
            roll: 0,
            fov: 60
        )

        // 東 (画面外右) は北東と同じ位置へ寄せられて重なるため表示しない。
        XCTAssertFalse(placements.map(\.label).contains(L10n.tr("東")))
        XCTAssertTrue(placements.map(\.label).contains(L10n.tr("北")))
        XCTAssertTrue(placements.map(\.label).contains(L10n.tr("北東")))
        for index in placements.indices {
            XCTAssertGreaterThanOrEqual(placements[index].x, Double(StarMapLayout.cardinalLabelSidePadding))
            XCTAssertLessThanOrEqual(placements[index].x, size.width - Double(StarMapLayout.cardinalLabelSidePadding))
            for otherIndex in placements.indices where otherIndex > index {
                XCTAssertGreaterThanOrEqual(
                    abs(placements[index].x - placements[otherIndex].x),
                    StarMapLayout.cardinalLabelMinimumSpacing
                )
            }
        }
    }

    func test_StarMapCanvasView_isSelectableForHitTest_excludesBelowHorizonAndTerrain() {
        XCTAssertFalse(StarMapCanvasView.isSelectableForHitTest(altitude: -1, azimuth: 0, terrain: nil))
        XCTAssertTrue(StarMapCanvasView.isSelectableForHitTest(altitude: 0.5, azimuth: 0, terrain: nil))

        let mountains = TerrainProfile(horizonAngles: Array(repeating: 10, count: 72))
        XCTAssertFalse(StarMapCanvasView.isSelectableForHitTest(altitude: 5, azimuth: 90, terrain: mountains))
        XCTAssertTrue(StarMapCanvasView.isSelectableForHitTest(altitude: 15, azimuth: 90, terrain: mountains))

        let lowHorizon = TerrainProfile(horizonAngles: Array(repeating: -3, count: 72))
        XCTAssertTrue(StarMapCanvasView.isSelectableForHitTest(altitude: 0.5, azimuth: 90, terrain: lowHorizon))
        XCTAssertFalse(StarMapCanvasView.isSelectableForHitTest(altitude: -1, azimuth: 90, terrain: lowHorizon))
    }

    func test_StarMapLayout_clampedCameraFOV_allowsNarrowCameraFieldOfView() {
        XCTAssertEqual(StarMapLayout.clampedCameraFOV(20), 20, accuracy: 0.001)
        XCTAssertEqual(StarMapLayout.clampedFOV(20), StarMapLayout.minFOV, accuracy: 0.001)
    }

    func test_StarMapComputation_milkyWayBandSegmentIndexPairs_closesLoopAndSkipsGaps() {
        let fullBand = stride(from: 0.0, to: 360.0, by: 5.0).map {
            MilkyWayBandPoint(az: $0, alt: 10, halfH: 5, li: $0)
        }
        let fullPairs = StarMapComputation.milkyWayBandSegmentIndexPairs(for: fullBand)
        XCTAssertEqual(fullPairs.count, fullBand.count)
        XCTAssertTrue(fullPairs.contains { $0.start == fullBand.count - 1 && $0.end == 0 })

        // 地平線下で 20°〜340° が間引かれた場合: 340→355→0→15 だけがつながる。
        let partialBand = fullBand.filter { $0.li < 20 || $0.li >= 340 }
        let partialPairs = StarMapComputation.milkyWayBandSegmentIndexPairs(for: partialBand)
        let connectedLongitudes = partialPairs.map { (partialBand[$0.start].li, partialBand[$0.end].li) }
        XCTAssertFalse(connectedLongitudes.contains { $0.0 == 15 && $0.1 == 340 })
        XCTAssertTrue(connectedLongitudes.contains { $0.0 == 355 && $0.1 == 0 })
        XCTAssertEqual(partialPairs.count, partialBand.count - 1)
    }

    func test_StarMapCanvasView_moonLitPolygon_rendersCorrectPhaseShapes() {
        XCTAssertEqual(StarMapCanvasView.moonIlluminatedFraction(phase: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(StarMapCanvasView.moonIlluminatedFraction(phase: 0.25), 0.5, accuracy: 1e-9)
        XCTAssertEqual(StarMapCanvasView.moonIlluminatedFraction(phase: 0.5), 1, accuracy: 1e-9)
        XCTAssertEqual(StarMapCanvasView.moonIlluminatedFraction(phase: 0.75), 0.5, accuracy: 1e-9)

        let center = CGPoint(x: 100, y: 100)
        let radius = 10.0
        func area(_ points: [CGPoint]) -> Double {
            guard points.count >= 3 else { return 0 }
            var sum = 0.0
            for index in points.indices {
                let a = points[index]
                let b = points[(index + 1) % points.count]
                sum += Double(a.x * b.y - b.x * a.y)
            }
            return abs(sum) / 2
        }
        let discArea = Double.pi * radius * radius

        XCTAssertTrue(StarMapCanvasView.moonLitPolygon(center: center, radius: radius, phase: 0).isEmpty)

        // 上弦: 右半分だけが光る
        let firstQuarter = StarMapCanvasView.moonLitPolygon(center: center, radius: radius, phase: 0.25, segments: 64)
        XCTAssertTrue(firstQuarter.allSatisfy { $0.x >= center.x - 1e-6 })
        XCTAssertEqual(area(firstQuarter), discArea / 2, accuracy: discArea * 0.01)

        // 下弦: 左半分だけが光る
        let lastQuarter = StarMapCanvasView.moonLitPolygon(center: center, radius: radius, phase: 0.75, segments: 64)
        XCTAssertTrue(lastQuarter.allSatisfy { $0.x <= center.x + 1e-6 })
        XCTAssertEqual(area(lastQuarter), discArea / 2, accuracy: discArea * 0.01)

        // 満ちていく十三夜: 右側の縁を含み、輝面比に応じた面積になる
        let waxingGibbous = StarMapCanvasView.moonLitPolygon(center: center, radius: radius, phase: 0.4, segments: 64)
        XCTAssertTrue(waxingGibbous.contains { $0.x > center.x + radius - 1e-6 })
        XCTAssertEqual(
            area(waxingGibbous),
            discArea * StarMapCanvasView.moonIlluminatedFraction(phase: 0.4),
            accuracy: discArea * 0.01
        )

        // 満月: 円全体
        let full = StarMapCanvasView.moonLitPolygon(center: center, radius: radius, phase: 0.5, segments: 64)
        XCTAssertEqual(area(full), discArea, accuracy: discArea * 0.01)
    }

    // MARK: - ジャイロ姿勢の平滑化

    func test_StarMapMotionVectors_smoothed_doesNotSpinWhenCrossingZenith() {
        func vectors(tiltDegrees: Double) -> StarMapMotionVectors {
            // 北の地平線から東西軸まわりに持ち上げた姿勢（tilt > 90° で天頂を越える）
            let radians = tiltDegrees * .pi / 180
            return StarMapMotionVectors(
                forward: (east: 0, north: cos(radians), up: sin(radians)),
                screenUp: (east: 0, north: -sin(radians), up: cos(radians))
            )
        }
        let previous = vectors(tiltDegrees: 89)
        let next = vectors(tiltDegrees: 91)

        // 個別の方位・ロールは天頂を越えると 180° 反転する
        XCTAssertEqual(previous.pose.azimuth, 0, accuracy: 0.001)
        XCTAssertEqual(next.pose.azimuth, 180, accuracy: 0.001)
        XCTAssertEqual(abs(next.pose.roll), 180, accuracy: 0.001)

        let smoothedPose = StarMapMotionVectors.smoothed(previous: previous, next: next).pose
        let basis = GnomonicProjectionMath.cameraBasis(
            centerAlt: smoothedPose.altitude,
            centerAz: smoothedPose.azimuth,
            roll: smoothedPose.roll
        )

        // 描画上のカメラ姿勢は前回からわずかに動くだけで、回転・跳躍しない
        XCTAssertEqual(basis.forward.x, 0, accuracy: 0.001)
        XCTAssertGreaterThan(basis.forward.z, 0.999)
        XCTAssertEqual(basis.right.x, 1, accuracy: 0.001)
        XCTAssertLessThan(basis.up.y, -0.999)
    }
}
