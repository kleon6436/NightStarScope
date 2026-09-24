import XCTest
import Combine
import CoreLocation
import MapKit
@testable import NightScope

func makeTestMapItem(latitude: Double, longitude: Double, name: String? = nil) -> MKMapItem {
    let item: MKMapItem
    if #available(iOS 26, macOS 26, *) {
        item = MKMapItem(location: CLLocation(latitude: latitude, longitude: longitude), address: nil)
    } else {
        let placemark = MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
        item = MKMapItem(placemark: placemark)
    }
    item.name = name
    return item
}

enum TestTimeZones {
    static let tokyo = TimeZone(identifier: "Asia/Tokyo")!
}

func makeTestIndex(
    score: Int = 75,
    milkyWayScore: Int = 0,
    constellationScore: Int = 0,
    weatherScore: Int = 0,
    lightPollutionScore: Int = 0,
    hasWeatherData: Bool = true,
    hasLightPollutionData: Bool = true
) -> StarGazingIndex {
    StarGazingIndex(
        score: score,
        milkyWayScore: milkyWayScore,
        constellationScore: constellationScore,
        weatherScore: weatherScore,
        lightPollutionScore: lightPollutionScore,
        hasWeatherData: hasWeatherData,
        hasLightPollutionData: hasLightPollutionData
    )
}

func makeHourlyWeather(
    cloudCover: Double = 10,
    weatherCode: Int = 0,
    windSpeed: Double = 5
) -> HourlyWeather {
    HourlyWeather(
        date: Date(),
        temperatureCelsius: 15,
        cloudCoverPercent: cloudCover,
        precipitationMM: 0,
        windSpeedKmh: windSpeed,
        humidityPercent: 40,
        dewpointCelsius: 2,
        weatherCode: weatherCode,
        visibilityMeters: 20_000,
        windGustsKmh: nil,
        windSpeedKmh500hpa: nil
    )
}

func makeDayWeatherSummary(
    cloudCover: Double = 10,
    weatherCode: Int = 0,
    windSpeed: Double = 5
) -> DayWeatherSummary {
    let hour = makeHourlyWeather(cloudCover: cloudCover, weatherCode: weatherCode, windSpeed: windSpeed)
    return DayWeatherSummary(date: Date(), nighttimeHours: [hour])
}

func makeNightSummary(
    date: Date = Date(),
    withWindow: Bool = true,
    moonPhase: Double = 0.12
) -> NightSummary {
    let location = CLLocationCoordinate2D(latitude: 35.6762, longitude: 139.6503)
    let eventDate = Calendar.current.date(byAdding: .hour, value: 21, to: date) ?? date
    let event = AstroEvent(
        date: eventDate,
        galacticCenterAltitude: 28,
        galacticCenterAzimuth: 190,
        sunAltitude: -22,
        moonAltitude: -8,
        moonPhase: moonPhase
    )
    let windows: [ViewingWindow] = withWindow ? [
        ViewingWindow(
            start: eventDate,
            end: eventDate.addingTimeInterval(3600),
            peakTime: eventDate.addingTimeInterval(1800),
            peakAltitude: 32,
            peakAzimuth: 180
        )
    ] : []
    return NightSummary(
        date: date,
        location: location,
        events: [event],
        viewingWindows: windows,
        moonPhaseAtMidnight: moonPhase
    )
}

@MainActor
final class MockLocationController: LocationProviding {
    @Published var selectedLocation = CLLocationCoordinate2D(latitude: 0, longitude: 0)
    @Published var locationName = ""
    @Published var searchState: LocationSearchState = .idle
    @Published var isLocating = false
    @Published var locationError: LocationController.LocationError?
    @Published var searchFocusTrigger = 0
    @Published var currentLocationCenterTrigger = 0
    @Published var selectedTimeZone: TimeZone = .current

    private(set) var locationUpdateID = UUID()

    private(set) var requestCurrentLocationCalled = false
    private(set) var prepareForSettingsRecoveryCalled = false
    private(set) var refreshAuthorizationStateCalled = false
    private(set) var searchQuery: String?
    private(set) var selectedMapItem: MKMapItem?
    private(set) var selectedCoordinateCalls: [CLLocationCoordinate2D] = []

    var searchResults: [MKMapItem] {
        get { searchState.results }
        set {
            let query = normalizedSearchQuery
            searchState = newValue.isEmpty ? (query.isEmpty ? .idle : .empty(query: query)) : .results(query: query, items: newValue)
        }
    }

    var isSearching: Bool {
        get { searchState.isSearching }
        set {
            if newValue {
                searchState = .loading(query: normalizedSearchQuery, previousResults: searchState.results)
            } else {
                let query = normalizedSearchQuery
                searchState = query.isEmpty ? .idle : .empty(query: query)
            }
        }
    }

    var selectedLocationPublisher: AnyPublisher<CLLocationCoordinate2D, Never> {
        $selectedLocation.eraseToAnyPublisher()
    }

    var locationNamePublisher: AnyPublisher<String, Never> {
        $locationName.eraseToAnyPublisher()
    }

    var searchStatePublisher: AnyPublisher<LocationSearchState, Never> {
        $searchState.eraseToAnyPublisher()
    }

    var isLocatingPublisher: AnyPublisher<Bool, Never> {
        $isLocating.eraseToAnyPublisher()
    }

    var locationErrorPublisher: AnyPublisher<LocationController.LocationError?, Never> {
        $locationError.eraseToAnyPublisher()
    }

    var searchFocusTriggerPublisher: AnyPublisher<Int, Never> {
        $searchFocusTrigger.eraseToAnyPublisher()
    }

    var currentLocationCenterTriggerPublisher: AnyPublisher<Int, Never> {
        $currentLocationCenterTrigger.eraseToAnyPublisher()
    }

    var selectedTimeZonePublisher: AnyPublisher<TimeZone, Never> {
        $selectedTimeZone.eraseToAnyPublisher()
    }

    func requestCurrentLocation() {
        requestCurrentLocationCalled = true
    }

    func prepareForSettingsRecovery() {
        prepareForSettingsRecoveryCalled = true
    }

    func refreshAuthorizationState() {
        refreshAuthorizationStateCalled = true
    }

    func search(query: String) {
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedQuery.isEmpty {
            searchQuery = query
            searchState = .idle
            return
        }
        searchQuery = query
        searchState = .loading(query: normalizedQuery, previousResults: searchState.results)
    }

    func clearSearch() {
        searchQuery = ""
        searchState = .idle
    }

    func select(_ mapItem: MKMapItem) {
        selectedMapItem = mapItem
        if #available(iOS 26, macOS 26, *) {
            selectedLocation = mapItem.location.coordinate
        } else {
            selectedLocation = mapItem.placemark.coordinate
        }
        searchState = .idle
        currentLocationCenterTrigger += 1
        locationUpdateID = UUID()
    }

    func selectCoordinate(_ coordinate: CLLocationCoordinate2D) {
        selectedCoordinateCalls.append(coordinate)
        selectedLocation = coordinate
        searchState = .idle
        locationUpdateID = UUID()
    }

    private var normalizedSearchQuery: String {
        searchQuery?.trimmingCharacters(in: .whitespacesAndNewlines) ?? searchState.query
    }
}

@MainActor
final class MockLightPollutionService: LightPollutionProviding {
    @Published var bortleClass: Double?
    @Published var isLoading = false
    @Published var fetchFailed = false
    /// 座標ごとに返す Bortle 値。キーは小数 4 桁の "lat,lon"。未登録の座標は既定値を返す。
    var bortleByCoordinate: [String: Double]

    init(bortleByCoordinate: [String: Double] = [:]) {
        self.bortleByCoordinate = bortleByCoordinate
    }

    var bortleClassPublisher: Published<Double?>.Publisher { $bortleClass }
    var isLoadingPublisher: Published<Bool>.Publisher { $isLoading }
    var fetchFailedPublisher: Published<Bool>.Publisher { $fetchFailed }

    func fetch(latitude: Double, longitude: Double) async {
        isLoading = true
        try? await Task.sleep(nanoseconds: 1_000_000)
        isLoading = false
    }

    func fetchBortle(latitude: Double, longitude: Double) async throws -> Double {
        bortleByCoordinate[String(format: "%.4f,%.4f", latitude, longitude)] ?? 4.0
    }
}

@MainActor
final class StubComparisonController: ComparisonControlling {
    var matrix: ComparisonMatrix
    var dayCount: Int = DashboardViewModel.dayCount
    private(set) var lastLocations: [FavoriteLocation]?
    private(set) var refreshCalls: Int = 0
    private(set) var computeMatrixCalls: Int = 0

    init(matrix: ComparisonMatrix = .empty) {
        self.matrix = matrix
    }

    func refresh(referenceDate: Date, locations: [FavoriteLocation]?) async {
        refreshCalls += 1
        lastLocations = locations
    }

    func computeMatrix(referenceDate: Date, locations: [FavoriteLocation]?) async -> ComparisonMatrix {
        computeMatrixCalls += 1
        lastLocations = locations
        return matrix
    }
}

/// メモリ上に一覧を持つ FavoriteLocationStoring。save() した内容は favorites と saved に反映される。
final class InMemoryFavoriteStore: FavoriteLocationStoring, @unchecked Sendable {
    var favorites: [FavoriteLocation] {
        didSet { subject.send(favorites) }
    }
    /// 最後に save() で渡された一覧。save() が呼ばれていなければ空。
    private(set) var saved: [FavoriteLocation] = []
    private let subject: CurrentValueSubject<[FavoriteLocation], Never>

    init(favorites: [FavoriteLocation] = []) {
        self.favorites = favorites
        self.subject = CurrentValueSubject(favorites)
    }

    func loadAll() -> [FavoriteLocation] {
        favorites
    }

    var locationsPublisher: AnyPublisher<[FavoriteLocation], Never> {
        subject.eraseToAnyPublisher()
    }

    func save(_ favorites: [FavoriteLocation]) {
        saved = favorites
        self.favorites = favorites
    }
}

actor MockNightCalculationService: NightCalculating {
    private var nightSummaryResponses: [(summary: NightSummary, delayNanoseconds: UInt64)] = []
    private var upcomingResponses: [(summaries: [NightSummary], delayNanoseconds: UInt64)] = []
    private var nightSummaryCallCount = 0
    private var upcomingCallCount = 0

    func enqueueNightSummary(_ summary: NightSummary, delayMilliseconds: UInt64 = 0) {
        nightSummaryResponses.append((summary, delayMilliseconds * 1_000_000))
    }

    func enqueueUpcomingNights(_ summaries: [NightSummary], delayMilliseconds: UInt64 = 0) {
        upcomingResponses.append((summaries, delayMilliseconds * 1_000_000))
    }

    func calculateNightSummary(
        date: Date,
        location: CLLocationCoordinate2D,
        timeZone: TimeZone
    ) async -> NightSummary {
        nightSummaryCallCount += 1
        guard !nightSummaryResponses.isEmpty else {
            return .placeholder
        }
        let response = nightSummaryResponses.removeFirst()
        if response.delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: response.delayNanoseconds)
        }
        return response.summary
    }

    func calculateUpcomingNights(
        from date: Date,
        location: CLLocationCoordinate2D,
        timeZone: TimeZone,
        days: Int
    ) async -> [NightSummary] {
        upcomingCallCount += 1
        guard !upcomingResponses.isEmpty else {
            return []
        }
        let response = upcomingResponses.removeFirst()
        if response.delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: response.delayNanoseconds)
        }
        return response.summaries
    }

    func getNightSummaryCallCount() -> Int {
        nightSummaryCallCount
    }

    func getUpcomingCallCount() -> Int {
        upcomingCallCount
    }
}
