import SwiftUI

/// 星空指数の内訳（星空 / 気象 / 光害）を 1 か所で描く。
/// カード内の展開表示と今夜タブの両方から使い、表示ロジックの二重管理を避ける。
struct IndexBreakdownView: View {
    /// 3 項目の並べ方。
    enum Arrangement {
        /// 横 3 分割。限られた縦幅に収めたいとき。
        case row
        /// 縦積み。ラベル・バー・値を 1 行に並べる。
        case column
    }

    let index: StarGazingIndex
    let lightPollutionViewModel: StarGazingIndexCardViewModel?
    var layout: Arrangement = .column

    var body: some View {
        switch layout {
        case .row:
            HStack(alignment: .top, spacing: Spacing.sm) {
                ForEach(items) { item in
                    columnItem(item)
                }
            }
        case .column:
            VStack(alignment: .leading, spacing: Spacing.xs) {
                ForEach(items) { item in
                    rowItem(item)
                }
            }
        }
    }

    // MARK: - Item Views

    private func columnItem(_ item: Item) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(item.valueText)
                .font(.caption.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            progressBar(item)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.label)
        .accessibilityValue(item.valueText)
    }

    private func rowItem(_ item: Item) -> some View {
        HStack(alignment: .center, spacing: Spacing.xs) {
            Text(item.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: true, vertical: false)
                .panelTooltip(item.label)
            progressBar(item)
                .frame(maxWidth: .infinity)
            Text(item.valueText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.label)
        .accessibilityValue(item.valueText)
    }

    @ViewBuilder
    private func progressBar(_ item: Item) -> some View {
        if let score = item.score, let maxScore = item.maxScore {
            ProgressView(value: Double(score), total: Double(maxScore))
                .progressViewStyle(.linear)
                .tint(item.tint)
                .frame(height: Metrics.barHeight)
        } else {
            Capsule()
                .fill(Color.secondary.opacity(Metrics.emptyBarOpacity))
                .frame(height: Metrics.barHeight)
        }
    }

    // MARK: - Items

    private var items: [Item] {
        Self.items(for: index, lightPollutionStatusText: lightPollutionStatusText)
    }

    /// 光害スコアが未取得のときに値欄へ出す文言。
    private var lightPollutionStatusText: String {
        guard let lightPollutionViewModel, lightPollutionViewModel.fetchFailed else {
            return L10n.tr("取得中...")
        }
        return L10n.tr("取得失敗")
    }

    /// 表示項目を値として組み立てる。View に依存しないため、そのまま検証できる。
    static func items(for index: StarGazingIndex, lightPollutionStatusText: String) -> [Item] {
        [
            Item(
                label: L10n.tr("星空"),
                score: index.constellationScore,
                maxScore: StarGazingIndex.maxConstellationScore,
                tint: .indigo
            ),
            index.hasWeatherData
                ? Item(
                    label: L10n.tr("気象"),
                    score: index.weatherScore,
                    maxScore: StarGazingIndex.maxWeatherScore,
                    tint: .cyan
                )
                : Item(label: L10n.tr("気象"), statusText: L10n.tr("データなし"), tint: .cyan),
            index.hasLightPollutionData
                ? Item(
                    label: L10n.tr("光害"),
                    score: index.lightPollutionScore,
                    maxScore: StarGazingIndex.maxLightPollutionScore,
                    tint: .orange
                )
                : Item(label: L10n.tr("光害"), statusText: lightPollutionStatusText, tint: .orange)
        ]
    }

    /// 1 項目分の表示値。スコアが無い場合は `score`/`maxScore` が nil になる。
    struct Item: Identifiable {
        let label: String
        let score: Int?
        let maxScore: Int?
        let valueText: String
        let tint: Color

        var id: String { label }

        init(label: String, score: Int, maxScore: Int, tint: Color) {
            self.label = label
            self.score = score
            self.maxScore = maxScore
            self.valueText = "\(score)/\(maxScore)"
            self.tint = tint
        }

        init(label: String, statusText: String, tint: Color) {
            self.label = label
            self.score = nil
            self.maxScore = nil
            self.valueText = statusText
            self.tint = tint
        }
    }

    private enum Metrics {
        static let barHeight: CGFloat = 4
        static let emptyBarOpacity: Double = 0.25
    }
}
