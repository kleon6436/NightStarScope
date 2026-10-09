import Combine
import CoreLocation
import MapKit

/// 地点検索を外部サービスへ委譲する。
protocol LocationSearchServicing: Sendable {
    func search(query: String) async throws -> [MKMapItem]
}

/// MKLocalSearch を使う標準検索実装。
struct MKLocationSearchService: LocationSearchServicing {
    func search(query: String) async throws -> [MKMapItem] {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        let response = try await MKLocalSearch(request: request).start()
        return response.mapItems
    }
}

/// 検索 UI の表示状態を保持する。
struct LocationSearchState {
    enum Phase: Equatable {
        case idle
        case loading
        case results
        case empty
        case failure
    }

    let phase: Phase
    let query: String
    let results: [MKMapItem]
    let errorMessage: String?

    static var idle: LocationSearchState {
        LocationSearchState(phase: .idle, query: "", results: [], errorMessage: nil)
    }

    static func loading(query: String, previousResults: [MKMapItem] = []) -> LocationSearchState {
        LocationSearchState(phase: .loading, query: query, results: previousResults, errorMessage: nil)
    }

    static func results(query: String, items: [MKMapItem]) -> LocationSearchState {
        LocationSearchState(phase: .results, query: query, results: items, errorMessage: nil)
    }

    static func empty(query: String) -> LocationSearchState {
        LocationSearchState(phase: .empty, query: query, results: [], errorMessage: nil)
    }

    static func failure(query: String, errorMessage: String) -> LocationSearchState {
        LocationSearchState(phase: .failure, query: query, results: [], errorMessage: errorMessage)
    }

    var isSearching: Bool {
        phase == .loading
    }
}

/// 解決済みの地点名とタイムゾーン識別子。
struct ResolvedLocationDetails: Sendable, Equatable {
    let name: String
    let timeZoneIdentifier: String?
}

/// MKMapItem から表示名とタイムゾーンを抽出する。
enum MapItemLocationDetailsExtractor {
    static func details(from item: MKMapItem) -> ResolvedLocationDetails {
        let coordinate: CLLocationCoordinate2D
        let regionIdentifier: String?
        if #available(iOS 26, macOS 26, *) {
            coordinate = item.location.coordinate
            regionIdentifier = item.addressRepresentations?.region?.identifier
        } else {
            coordinate = item.placemark.coordinate
            regionIdentifier = nil
        }

        let timeZoneIdentifier = ApproximateTimeZoneResolver.exactIdentifier(
            for: coordinate,
            preferredIdentifier: item.timeZone?.identifier,
            regionIdentifier: regionIdentifier
        )

        if #available(iOS 26, macOS 26, *) {
            if let repr = item.addressRepresentations,
               let city = repr.cityWithContext,
               !city.isEmpty {
                return ResolvedLocationDetails(name: city, timeZoneIdentifier: timeZoneIdentifier)
            }

            if let address = item.address {
                let text = address.shortAddress ?? address.fullAddress
                if !text.isEmpty {
                    return ResolvedLocationDetails(name: text, timeZoneIdentifier: timeZoneIdentifier)
                }
            }
        }

        return ResolvedLocationDetails(
            name: item.name ?? L10n.tr("現在地"),
            timeZoneIdentifier: timeZoneIdentifier
        )
    }
}

/// 緯度経度から近似タイムゾーンを推定する。
enum ApproximateTimeZoneResolver {
    static func exactIdentifier(
        for coordinate: CLLocationCoordinate2D,
        preferredIdentifier: String? = nil,
        regionIdentifier: String? = nil
    ) -> String? {
        if let preferredIdentifier,
           TimeZone(identifier: preferredIdentifier) != nil,
           !isProvisionalIdentifier(preferredIdentifier) {
            return preferredIdentifier
        }

        if let regionIdentifier,
           let regionBackedIdentifier = regionBackedIdentifier(
            for: coordinate,
            regionIdentifier: regionIdentifier
           ) {
            return regionBackedIdentifier
        }
        return nil
    }

    static func identifier(
        for coordinate: CLLocationCoordinate2D,
        regionIdentifier: String? = nil
    ) -> String {
        exactIdentifier(for: coordinate, regionIdentifier: regionIdentifier)
            ?? approximateIdentifier(for: coordinate)
    }

    static func approximateIdentifier(for coordinate: CLLocationCoordinate2D) -> String {
        heuristicIdentifier(for: coordinate) ?? provisionalIdentifier(for: coordinate)
    }

    static func provisionalIdentifier(for coordinate: CLLocationCoordinate2D) -> String {
        fixedOffsetTimeZoneIdentifier(forHoursFromGMT: wholeHourOffset(for: coordinate))
    }

    static func isProvisionalIdentifier(_ identifier: String) -> Bool {
        identifier == "Etc/GMT" || identifier.hasPrefix("Etc/GMT+") || identifier.hasPrefix("Etc/GMT-")
    }

    private static func regionBackedIdentifier(
        for coordinate: CLLocationCoordinate2D,
        regionIdentifier: String
    ) -> String? {
        let normalizedRegionIdentifier = regionIdentifier.uppercased()

        switch normalizedRegionIdentifier {
        case "AU":
            // 州境の判定が曖昧な地点は誤ったゾーンを確定値として保存しないよう nil を返す。
            return australianIdentifier(for: coordinate)
        case "NZ":
            return heuristicIdentifier(for: coordinate) ?? "Pacific/Auckland"
        default:
            return singleRegionTimeZoneIdentifiers[normalizedRegionIdentifier]
        }
    }

    private static func heuristicIdentifier(for coordinate: CLLocationCoordinate2D) -> String? {
        if let australianIdentifier = australianIdentifier(for: coordinate) {
            return australianIdentifier
        }
        let matches = timeZoneHeuristics.filter { $0.contains(coordinate: coordinate) }
        guard let firstMatch = matches.first else { return nil }

        let ambiguousContinentalUSMatches = Set(matches.map(\.identifier))
            .intersection(continentalUSHeuristicIdentifiers)
        guard ambiguousContinentalUSMatches.count <= 1 else { return nil }

        return firstMatch.identifier
    }

    /// オーストラリアの州境に沿ってタイムゾーンを推定する。範囲外や州境付近で判断できない地点は nil を返す。
    static func australianIdentifier(for coordinate: CLLocationCoordinate2D) -> String? {
        let latitude = coordinate.latitude
        let longitude = coordinate.longitude
        if (-32.0 ... -31.0).contains(latitude), (158.8 ... 159.4).contains(longitude) {
            return "Australia/Lord_Howe"
        }
        guard (-44.0 ... -10.0).contains(latitude), (112.0 ... 154.0).contains(longitude) else {
            return nil
        }
        // タスマニア（キング島・フリンダース島を含む）
        if latitude < -39.2, longitude > 143.5 {
            return "Australia/Hobart"
        }
        // 西オーストラリア（東端のユークラ周辺は独自の UTC+8:45）
        if longitude < 129 {
            if (-32.5 ... -31.0).contains(latitude), longitude >= 125.5 {
                return "Australia/Eucla"
            }
            return "Australia/Perth"
        }
        // 北部準州（南緯 26 度以北、東経 138 度以西）
        if longitude < 138, latitude > -26 {
            return "Australia/Darwin"
        }
        // 南オーストラリア（南緯 26 度以南、東経 141 度以西）
        if longitude <= 141, latitude <= -26 {
            return "Australia/Adelaide"
        }
        // クイーンズランド西部（東経 138〜141 度、南緯 26 度以北）
        if longitude < 141 {
            return "Australia/Brisbane"
        }
        // 東経 141 度以東: クイーンズランドとニューサウスウェールズ（州境は南緯 29 度〜28.2 度付近）
        if latitude > -28.15 {
            return "Australia/Brisbane"
        }
        if latitude <= -29.0 {
            // NSW / ACT / VIC は同じ UTC+10 と夏時間規則
            return "Australia/Sydney"
        }
        // 南緯 29 度線が州境の区間（東経 148.9 度まで）は北側がクイーンズランド
        if longitude < 148.9 {
            return "Australia/Brisbane"
        }
        // 河川沿いの州境付近は判断しない
        return nil
    }

    private static func wholeHourOffset(for coordinate: CLLocationCoordinate2D) -> Int {
        min(max(Int((coordinate.longitude / 15.0).rounded()), -12), 14)
    }

    private static func fixedOffsetTimeZoneIdentifier(forHoursFromGMT hourOffset: Int) -> String {
        guard hourOffset != 0 else { return "Etc/GMT" }
        let sign = hourOffset > 0 ? "-" : "+"
        return "Etc/GMT\(sign)\(abs(hourOffset))"
    }

    private static let singleRegionTimeZoneIdentifiers = [
        "AF": "Asia/Kabul",
        "AT": "Europe/Vienna",
        "AE": "Asia/Dubai",
        "BD": "Asia/Dhaka",
        "BE": "Europe/Brussels",
        "BG": "Europe/Sofia",
        "BH": "Asia/Bahrain",
        "AR": "America/Argentina/Buenos_Aires",
        "CH": "Europe/Zurich",
        "CN": "Asia/Shanghai",
        "CZ": "Europe/Prague",
        "DE": "Europe/Berlin",
        "DK": "Europe/Copenhagen",
        "EG": "Africa/Cairo",
        "EE": "Europe/Tallinn",
        "FI": "Europe/Helsinki",
        "GR": "Europe/Athens",
        "HK": "Asia/Hong_Kong",
        "HU": "Europe/Budapest",
        "IE": "Europe/Dublin",
        "IN": "Asia/Kolkata",
        "IR": "Asia/Tehran",
        "IS": "Atlantic/Reykjavik",
        "IT": "Europe/Rome",
        "IL": "Asia/Jerusalem",
        "JP": "Asia/Tokyo",
        "KR": "Asia/Seoul",
        "KW": "Asia/Kuwait",
        "LK": "Asia/Colombo",
        "LT": "Europe/Vilnius",
        "LU": "Europe/Luxembourg",
        "LV": "Europe/Riga",
        "MO": "Asia/Macau",
        "MY": "Asia/Kuala_Lumpur",
        "NL": "Europe/Amsterdam",
        "NO": "Europe/Oslo",
        "NP": "Asia/Kathmandu",
        "OM": "Asia/Muscat",
        "PH": "Asia/Manila",
        "PK": "Asia/Karachi",
        "PL": "Europe/Warsaw",
        "QA": "Asia/Qatar",
        "RO": "Europe/Bucharest",
        "SA": "Asia/Riyadh",
        "SE": "Europe/Stockholm",
        "SG": "Asia/Singapore",
        "SK": "Europe/Bratislava",
        "TH": "Asia/Bangkok",
        "TR": "Europe/Istanbul",
        "TW": "Asia/Taipei",
        "UA": "Europe/Kyiv",
        "UY": "America/Montevideo",
        "VN": "Asia/Ho_Chi_Minh",
        "ZA": "Africa/Johannesburg"
    ]

    /// 緯度経度の矩形で近似するタイムゾーン表。先頭から評価するため、狭い・具体的な矩形を先に置く。
    /// オーストラリアは `australianIdentifier(for:)` で別に判定する。
    private static let timeZoneHeuristics = [
        // 南アジア・東南アジア（インド・中国との境界より先に評価）
        TimeZoneHeuristic(latitudeRange: 27.4...30.2, longitudeRange: 80.4...83, identifier: "Asia/Kathmandu"),
        TimeZoneHeuristic(latitudeRange: 27.3...29.3, longitudeRange: 83...84.6, identifier: "Asia/Kathmandu"),
        TimeZoneHeuristic(latitudeRange: 26.4...28.3, longitudeRange: 84.6...88.2, identifier: "Asia/Kathmandu"),
        TimeZoneHeuristic(latitudeRange: 16...23.8, longitudeRange: 92.2...98.4, identifier: "Asia/Yangon"),
        TimeZoneHeuristic(latitudeRange: 23.8...28.5, longitudeRange: 95...98.6, identifier: "Asia/Yangon"),
        TimeZoneHeuristic(latitudeRange: 10...16, longitudeRange: 97.5...98.8, identifier: "Asia/Yangon"),
        TimeZoneHeuristic(latitudeRange: 6.5...20.5, longitudeRange: 97.3...105.7, identifier: "Asia/Bangkok"),
        // 中東（イラン・エジプトの広い矩形より先に評価）
        TimeZoneHeuristic(latitudeRange: 29.45...33.4, longitudeRange: 34.2...34.98, identifier: "Asia/Jerusalem"),
        TimeZoneHeuristic(latitudeRange: 29.9...33.4, longitudeRange: 34.98...35.7, identifier: "Asia/Jerusalem"),
        TimeZoneHeuristic(latitudeRange: 22...31.7, longitudeRange: 24.7...34.9, identifier: "Africa/Cairo"),
        TimeZoneHeuristic(latitudeRange: 24.4...26.2, longitudeRange: 50.7...51.7, identifier: "Asia/Qatar"),
        TimeZoneHeuristic(latitudeRange: 22.5...26.1, longitudeRange: 51.6...56.4, identifier: "Asia/Dubai"),
        TimeZoneHeuristic(latitudeRange: 16.6...24.5, longitudeRange: 55.4...59.9, identifier: "Asia/Muscat"),
        TimeZoneHeuristic(latitudeRange: 28.5...30.1, longitudeRange: 46.5...48.4, identifier: "Asia/Kuwait"),
        TimeZoneHeuristic(latitudeRange: 16.3...22, longitudeRange: 38.8...50.8, identifier: "Asia/Riyadh"),
        TimeZoneHeuristic(latitudeRange: 22...28.5, longitudeRange: 35.5...50.8, identifier: "Asia/Riyadh"),
        TimeZoneHeuristic(latitudeRange: 29.1...35, longitudeRange: 38.8...45.5, identifier: "Asia/Baghdad"),
        TimeZoneHeuristic(latitudeRange: 35...37.4, longitudeRange: 38.8...44.8, identifier: "Asia/Baghdad"),
        TimeZoneHeuristic(latitudeRange: 35...35.9, longitudeRange: 44.8...46, identifier: "Asia/Baghdad"),
        TimeZoneHeuristic(latitudeRange: 32...33.6, longitudeRange: 45.5...46, identifier: "Asia/Baghdad"),
        TimeZoneHeuristic(latitudeRange: 29.1...32, longitudeRange: 45.5...47.9, identifier: "Asia/Baghdad"),
        // アフガニスタン（パキスタン・イランより先に評価）
        TimeZoneHeuristic(latitudeRange: 31.5...35.6, longitudeRange: 61...69.9, identifier: "Asia/Kabul"),
        TimeZoneHeuristic(latitudeRange: 35.6...37, longitudeRange: 63...69.9, identifier: "Asia/Kabul"),
        TimeZoneHeuristic(latitudeRange: 29.4...31.5, longitudeRange: 61.6...65.8, identifier: "Asia/Kabul"),
        TimeZoneHeuristic(latitudeRange: 34.3...37.5, longitudeRange: 69.9...71.3, identifier: "Asia/Kabul"),
        // パキスタン（イラン・インドより先に評価）
        TimeZoneHeuristic(latitudeRange: 24.2...28, longitudeRange: 61.8...70, identifier: "Asia/Karachi"),
        TimeZoneHeuristic(latitudeRange: 28...30.5, longitudeRange: 61.5...72.5, identifier: "Asia/Karachi"),
        TimeZoneHeuristic(latitudeRange: 30.5...37, longitudeRange: 69.9...74.6, identifier: "Asia/Karachi"),
        TimeZoneHeuristic(latitudeRange: 25...39.8, longitudeRange: 44...63.3, identifier: "Asia/Tehran"),
        TimeZoneHeuristic(latitudeRange: 5...38, longitudeRange: 67...92, identifier: "Asia/Kolkata"),
        // 北米
        TimeZoneHeuristic(latitudeRange: 46...53, longitudeRange: -60.5 ... -52, identifier: "America/St_Johns"),
        TimeZoneHeuristic(latitudeRange: 43...49.5, longitudeRange: -66.5 ... -56, identifier: "America/Halifax"),
        TimeZoneHeuristic(latitudeRange: 31...38, longitudeRange: -115 ... -109, identifier: "America/Phoenix"),
        TimeZoneHeuristic(latitudeRange: 51...72, longitudeRange: -171 ... -129, identifier: "America/Anchorage"),
        TimeZoneHeuristic(latitudeRange: 25...52, longitudeRange: -129 ... -113, identifier: "America/Los_Angeles"),
        TimeZoneHeuristic(latitudeRange: 25...52, longitudeRange: -115 ... -101, identifier: "America/Denver"),
        TimeZoneHeuristic(latitudeRange: 25...52, longitudeRange: -106 ... -84, identifier: "America/Chicago"),
        TimeZoneHeuristic(latitudeRange: 25...52, longitudeRange: -90 ... -60, identifier: "America/New_York"),
        // 太平洋
        TimeZoneHeuristic(latitudeRange: -11 ... -6, longitudeRange: -142 ... -138, identifier: "Pacific/Marquesas"),
        TimeZoneHeuristic(latitudeRange: -45.5 ... -42, longitudeRange: -177.5 ... -175, identifier: "Pacific/Chatham"),
        TimeZoneHeuristic(latitudeRange: -48 ... -33, longitudeRange: 166...179.9, identifier: "Pacific/Auckland"),
        // 西ヨーロッパ（ポルトガル・スペイン・フランスを英国より先に評価）
        TimeZoneHeuristic(latitudeRange: 36.9...42.2, longitudeRange: -9.6 ... -7.05, identifier: "Europe/Lisbon"),
        TimeZoneHeuristic(latitudeRange: 35.9...43.8, longitudeRange: -9.4...3.4, identifier: "Europe/Madrid"),
        TimeZoneHeuristic(latitudeRange: 42.3...48.9, longitudeRange: -5.2...8.3, identifier: "Europe/Paris"),
        TimeZoneHeuristic(latitudeRange: 48.9...50.4, longitudeRange: -1.95...1.4, identifier: "Europe/Paris"),
        TimeZoneHeuristic(latitudeRange: 48.9...51.1, longitudeRange: 1.4...8.3, identifier: "Europe/Paris"),
        TimeZoneHeuristic(latitudeRange: 49.8...61.5, longitudeRange: -11...1.8, identifier: "Europe/London"),
        // 中央ヨーロッパ東部（CET。東経 20 度以東でも Athens の矩形より先に評価）
        TimeZoneHeuristic(latitudeRange: 49...54.3, longitudeRange: 14.1...23.6, identifier: "Europe/Warsaw"),
        TimeZoneHeuristic(latitudeRange: 54.3...54.9, longitudeRange: 14.1...19.6, identifier: "Europe/Warsaw"),
        TimeZoneHeuristic(latitudeRange: 48.6...49.6, longitudeRange: 16.8...22.1, identifier: "Europe/Bratislava"),
        TimeZoneHeuristic(latitudeRange: 45.7...48.6, longitudeRange: 16.1...21, identifier: "Europe/Budapest"),
        TimeZoneHeuristic(latitudeRange: 47.2...48.6, longitudeRange: 21...22.1, identifier: "Europe/Budapest"),
        TimeZoneHeuristic(latitudeRange: 45...46.2, longitudeRange: 18.8...20.6, identifier: "Europe/Belgrade"),
        TimeZoneHeuristic(latitudeRange: 41...45, longitudeRange: 18.8...21.3, identifier: "Europe/Belgrade"),
        TimeZoneHeuristic(latitudeRange: 41...44.5, longitudeRange: 21.3...22.5, identifier: "Europe/Belgrade"),
        TimeZoneHeuristic(latitudeRange: 40.3...41, longitudeRange: 19.2...21, identifier: "Europe/Tirane"),
        TimeZoneHeuristic(latitudeRange: 63.5...65, longitudeRange: 17...21.2, identifier: "Europe/Stockholm"),
        TimeZoneHeuristic(latitudeRange: 65...69, longitudeRange: 17...23.3, identifier: "Europe/Stockholm"),
        // ベラルーシ・ロシア西部（UTC+3、夏時間なし）
        TimeZoneHeuristic(latitudeRange: 51.9...54, longitudeRange: 23.6...31.5, identifier: "Europe/Minsk"),
        TimeZoneHeuristic(latitudeRange: 54...55.5, longitudeRange: 26.9...31, identifier: "Europe/Minsk"),
        TimeZoneHeuristic(latitudeRange: 55.5...60.9, longitudeRange: 28.3...36, identifier: "Europe/Moscow"),
        TimeZoneHeuristic(latitudeRange: 52.4...55.5, longitudeRange: 31...36, identifier: "Europe/Moscow"),
        TimeZoneHeuristic(latitudeRange: 60.9...69.5, longitudeRange: 31.6...36, identifier: "Europe/Moscow"),
        // ヨーロッパの広域（具体的な矩形に当たらなかった地点のみ）
        TimeZoneHeuristic(latitudeRange: 35...72, longitudeRange: 0...20, identifier: "Europe/Paris"),
        TimeZoneHeuristic(latitudeRange: 35...72, longitudeRange: 20...36, identifier: "Europe/Athens"),
        // 南米・アフリカ
        TimeZoneHeuristic(latitudeRange: -56 ... -17, longitudeRange: -76 ... -65, identifier: "America/Santiago"),
        TimeZoneHeuristic(latitudeRange: -56 ... -21, longitudeRange: -73 ... -52, identifier: "America/Argentina/Buenos_Aires"),
        TimeZoneHeuristic(latitudeRange: -35 ... 7, longitudeRange: -51 ... -34, identifier: "America/Sao_Paulo"),
        TimeZoneHeuristic(latitudeRange: -14 ... 6, longitudeRange: -75 ... -58, identifier: "America/Bogota"),
        TimeZoneHeuristic(latitudeRange: -35 ... -21, longitudeRange: 16 ... 33, identifier: "Africa/Johannesburg")
    ]

    private static let continentalUSHeuristicIdentifiers: Set<String> = [
        "America/Los_Angeles",
        "America/Denver",
        "America/Chicago",
        "America/New_York",
        "America/Phoenix"
    ]
}

private struct TimeZoneHeuristic {
    let latitudeRange: ClosedRange<Double>
    let longitudeRange: ClosedRange<Double>
    let identifier: String

    func contains(coordinate: CLLocationCoordinate2D) -> Bool {
        latitudeRange.contains(coordinate.latitude) && longitudeRange.contains(coordinate.longitude)
    }
}

/// 逆ジオコーディングで地点名を解決する。
protocol LocationNameResolving: Sendable {
    func resolveDetails(for coordinate: CLLocationCoordinate2D) async -> ResolvedLocationDetails
}

/// CLLocation / MKReverseGeocodingRequest を使う標準実装。
struct ReverseGeocodingLocationNameResolver: LocationNameResolving {
    func resolveDetails(for coordinate: CLLocationCoordinate2D) async -> ResolvedLocationDetails {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return await resolveMapItemDetails(for: location)
    }

    private func resolveMapItemDetails(for location: CLLocation) async -> ResolvedLocationDetails {
        if #available(iOS 26, macOS 26, *) {
            guard let request = MKReverseGeocodingRequest(location: location) else {
                return ResolvedLocationDetails(name: L10n.tr("現在地"), timeZoneIdentifier: nil)
            }

            request.preferredLocale = .autoupdatingCurrent
            let mapItems = try? await request.mapItems
            guard let item = mapItems?.first else {
                return ResolvedLocationDetails(name: L10n.tr("現在地"), timeZoneIdentifier: nil)
            }

            return MapItemLocationDetailsExtractor.details(from: item)
        } else {
            let geocoder = CLGeocoder()
            let placemarks: [CLPlacemark]? = try? await withCheckedThrowingContinuation { continuation in
                geocoder.reverseGeocodeLocation(location, preferredLocale: .autoupdatingCurrent) { placemarks, error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: placemarks ?? [])
                    }
                }
            }
            guard let placemark = placemarks?.first else {
                return ResolvedLocationDetails(name: L10n.tr("現在地"), timeZoneIdentifier: nil)
            }
            let name = placemark.locality ?? placemark.name ?? L10n.tr("現在地")
            return ResolvedLocationDetails(name: name, timeZoneIdentifier: placemark.timeZone?.identifier)
        }
    }
}

/// 選択地点の永続化レイヤー。
protocol LocationStorage: AnyObject {
    var latitude: Double? { get set }
    var longitude: Double? { get set }
    var name: String? { get set }
    var timeZoneIdentifier: String? { get set }
}

/// UserDefaults に地点情報を保存する実装。
final class UserDefaultsLocationStorage: LocationStorage {
    private let userDefaults: UserDefaults

    /// UserDefaults バックエンドを指定して初期化する。
    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    var latitude: Double? {
        get {
            guard userDefaults.object(forKey: "location.latitude") != nil else { return nil }
            return userDefaults.double(forKey: "location.latitude")
        }
        set {
            if let value = newValue {
                userDefaults.set(value, forKey: "location.latitude")
            } else {
                userDefaults.removeObject(forKey: "location.latitude")
            }
        }
    }

    var longitude: Double? {
        get {
            guard userDefaults.object(forKey: "location.longitude") != nil else { return nil }
            return userDefaults.double(forKey: "location.longitude")
        }
        set {
            if let value = newValue {
                userDefaults.set(value, forKey: "location.longitude")
            } else {
                userDefaults.removeObject(forKey: "location.longitude")
            }
        }
    }

    var name: String? {
        get { userDefaults.string(forKey: "location.name") }
        set {
            if let value = newValue {
                userDefaults.set(value, forKey: "location.name")
            } else {
                userDefaults.removeObject(forKey: "location.name")
            }
        }
    }

    var timeZoneIdentifier: String? {
        get { userDefaults.string(forKey: "location.timeZoneIdentifier") }
        set {
            if let value = newValue {
                userDefaults.set(value, forKey: "location.timeZoneIdentifier")
            } else {
                userDefaults.removeObject(forKey: "location.timeZoneIdentifier")
            }
        }
    }
}
