import SwiftUI

/// 光害取得状態を星空指数カードへ伝える ViewModel。
@MainActor
@Observable
final class StarGazingIndexCardViewModel {
    // 光害サービス（@Observable）の状態をそのまま転送し、読み出し時に Observation が追跡する。
    var isLoading: Bool { lightPollutionService.isLoading }
    var fetchFailed: Bool { lightPollutionService.fetchFailed }
    var isOutOfCoverage: Bool { lightPollutionService.isOutOfCoverage }

    @ObservationIgnored private let lightPollutionService: LightPollutionService

    init(lightPollutionService: LightPollutionService) {
        self.lightPollutionService = lightPollutionService
    }
}
