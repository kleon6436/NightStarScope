import Foundation

struct ObservationAdvisorInput: Sendable, Equatable {
    let language: String
    let isUnfavorable: Bool
    let dateString: String
    let locationName: String
    let tierLabel: String
    let viewingWindowSummary: String
    let moonSummary: String
    let weatherSummary: String
    let lightPollutionSummary: String
    let isRetryPrompt: Bool

    init(
        language: String,
        isUnfavorable: Bool,
        dateString: String,
        locationName: String,
        tierLabel: String,
        viewingWindowSummary: String,
        moonSummary: String,
        weatherSummary: String,
        lightPollutionSummary: String,
        isRetryPrompt: Bool = false
    ) {
        self.language = language
        self.isUnfavorable = isUnfavorable
        self.dateString = dateString
        self.locationName = locationName
        self.tierLabel = tierLabel
        self.viewingWindowSummary = viewingWindowSummary
        self.moonSummary = moonSummary
        self.weatherSummary = weatherSummary
        self.lightPollutionSummary = lightPollutionSummary
        self.isRetryPrompt = isRetryPrompt
    }
}
