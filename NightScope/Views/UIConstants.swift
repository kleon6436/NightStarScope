import SwiftUI

// MARK: - Spacing

enum Spacing {
    /// 4pt
    static let xxs: CGFloat = 4
    /// 8pt
    static let xs: CGFloat = 8
    /// 16pt
    static let sm: CGFloat = 16
    /// 24pt
    static let md: CGFloat = 24
    /// 32pt
    static let lg: CGFloat = 32
}

// MARK: - Layout

enum Layout {
    /// ウインドウ・シート・タブバー・浮遊パネルの角丸半径
    static let containerCornerRadius: CGFloat = 20
    /// カードの角丸半径
    static let cardCornerRadius: CGFloat = 16
    /// カード内の行・地図・入力欄の角丸半径
    static let innerCornerRadius: CGFloat = 12
    /// カードの内側パディング
    static let cardPadding: CGFloat = 16
    /// チップ・ツールチップ・セルの角丸半径
    static let smallCornerRadius: CGFloat = 8
    /// サイドバー水平パディング
    static let sidebarHorizontalPadding: CGFloat = 16
    /// サイドバー垂直パディング
    static let sidebarVerticalPadding: CGFloat = 16
    /// 地図コンテナの角丸半径
    static let mapCornerRadius: CGFloat = innerCornerRadius
    /// 地図コンテナ内の補助ラベル間隔
    static let mapInstructionSpacing: CGFloat = 8
    /// 地図コンテナの最小高
    static let mapMinHeight: CGFloat = 160
    /// 地図コンテナの最大高
    static let mapMaxHeight: CGFloat = 200
    /// 地図上ボタン（現在地）のサイズ
    static let mapButtonSize: CGFloat = 28
    /// 地図上のアイコンサイズ
    static let mapIconSize: CGFloat = 14
    /// 地図コンテナの枠線太さ
    static let mapSeparatorLineWidth: CGFloat = 0.5
    /// サイドバー補助ラベルの固定幅
    static let sidebarStatusWidth: CGFloat = 64
}

enum SearchResultsLayout {
    static func needsScroll(resultCount: Int, visibleRowCapacity: CGFloat) -> Bool {
        CGFloat(resultCount) > floor(visibleRowCapacity)
    }
}

#if os(macOS)
enum LayoutMacOS {
    /// ウィンドウ最小幅
    static let windowMinWidth: CGFloat = 820
    /// ウィンドウ最小高
    static let windowMinHeight: CGFloat = 750
    /// サイドバー最小幅
    static let sidebarMinWidth: CGFloat = 260
    /// サイドバー理想幅
    static let sidebarIdealWidth: CGFloat = 280
    /// サイドバー最大幅（コンテンツ300pt + 左右余白16pt）
    static let sidebarMaxWidth: CGFloat = 332
    /// 要約カード4枚の共通最小幅
    static let summaryCardMinWidth: CGFloat = 220
    /// 予報テーブル「夜」列の幅（日付 + 今夜/明夜のラベルが英語でも収まる幅）
    static let forecastDateColumn: CGFloat = 150
    /// 予報テーブル「雲量」列の幅
    static let forecastCloudColumn: CGFloat = 64
    /// 予報テーブル「天気」列の幅
    static let forecastWeatherColumn: CGFloat = 140
    /// 予報テーブル「月」列の幅（月相名 + 月明かり注記が英語でも収まる幅）
    static let forecastMoonColumn: CGFloat = 210
    /// 予報テーブル「暗夜開始」列の幅
    static let forecastDarkColumn: CGFloat = 120
    /// 予報テーブル「天の川ピーク」列の幅
    static let forecastMilkyWayColumn: CGFloat = 130
    /// 予報テーブル「星空指数」列の最小幅（可変列）
    static let forecastIndexColumnMinWidth: CGFloat = 150
    /// 予報テーブル「星空指数」列の最大幅。広いウィンドウで列が離れすぎないよう上限を置く。
    static let forecastIndexColumnMaxWidth: CGFloat = 240
    /// 予報テーブルの行の高さ
    static let forecastRowHeight: CGFloat = 40
}
#endif

// MARK: - Card Visual

enum CardVisual {
    /// カード左側ビジュアルの統一幅
    static let width: CGFloat = 52
    /// 要約カード左側ビジュアル列の統一高さ
    static let metricVisualHeight: CGFloat = 44
    /// 半円ゲージの統一高さ
    static let arcHeight: CGFloat = 28
    /// 月相アイコンのフォントサイズ
    static let moonIconSize: CGFloat = 40
    /// ゲージ共通のストローク幅
    static let strokeWidth: Double = 5
    /// ゲージ共通のトラック透過度
    static let trackOpacity: Double = 0.12
}

// MARK: - Animation

extension Animation {
    /// アプリ標準スプリングアニメーション
    static let standard: Animation = .spring(duration: 0.3)
}
