import SwiftUI

/// iOS 向け View 全体で共有する余白・サイズ・表示閾値。
enum IOSDesignTokens {
    /// 今夜タブのレイアウト。
    enum Today {
        /// 上部に敷く空のグラデーションの高さ。
        /// ヒーローとタイムライン（凡例まで）は白文字なので、下端のフェードが始まる前に
        /// 収まりきる高さが必要。文字サイズを上げた状態でも暗いまま読めるよう余裕を持たせる。
        static let heroBackgroundHeight: CGFloat = 620
        /// 要約カード 2×2 グリッドの間隔。
        static let gridSpacing: CGFloat = Spacing.sm
        /// 内訳バーを載せるカードの内側余白。
        static let breakdownPadding: CGFloat = 14
        static let loadingHeroHeight: CGFloat = 160
        static let loadingTimelineHeight: CGFloat = 90
        static let loadingGridCardHeight: CGFloat = 110
    }

    /// 星空タブの地平線オーバーレイと操作パネル。
    enum StarMap {
        static let horizonOverlayStyle = StarMapCanvasView.HorizonOverlayStyle(
            groundFillColor: Color(red: 0.31, green: 0.33, blue: 0.37),
            groundFillOpacity: 0.54,
            horizonStrokeColor: .white.opacity(0.18),
            terrainFillColor: Color(red: 0.27, green: 0.29, blue: 0.33),
            terrainFillOpacity: 0.62,
            terrainStrokeColor: .white.opacity(0.14)
        )
        /// 下部コントロールパネルの上下余白。星空を隠さないよう最小限にする。
        static let panelVerticalPadding: CGFloat = Spacing.xs
        /// 下部コントロールパネルの角丸。浮遊パネルなのでコンテナ半径に合わせる。
        static let panelCornerRadius: CGFloat = Layout.containerCornerRadius
        /// 月・流星群ステータスのアイコン寸法。caption の文字高に合わせる。
        static let statusIconSize: CGFloat = 11
        /// ステータスのアイコンと文字の間隔。
        static let statusIconSpacing: CGFloat = Spacing.xxs
        /// 「現在」ボタンのガラスカプセルの高さ。
        static let nowButtonHeight: CGFloat = 28
        /// タップ領域の最小辺（HIG 44pt）。見た目より広い当たり判定を確保する。
        static let minimumTapTarget: CGFloat = 44
        /// Slider のつまみ半径ぶんの内側余白。ヒートバーのトラック端を Slider に揃える。
        static let heatBarTrackInset: CGFloat = 14
        /// popover 内の graphical DatePicker に与える固定枠（月表示 1 か月分が収まる大きさ）。
        static let datePickerPopoverWidth: CGFloat = 320
        static let datePickerPopoverHeight: CGFloat = 340
        /// ヒートバーと Slider の間隔。ひと続きの時間軸に見せるため詰める。
        static let timelineSpacing: CGFloat = Spacing.xxs
    }

    /// 予報タブの一覧レイアウト。
    enum Forecast {
        static let rowSpacing: CGFloat = Spacing.xs
        static let loadingMinHeight: CGFloat = 220
        /// 狙い目カードと一覧の間隔。行間より広くして別セクションだと伝える。
        static let calloutSpacing: CGFloat = Spacing.sm
        /// 狙い目カードのアクセント地色・枠線。
        static let calloutTintOpacity: Double = 0.12
        static let calloutStrokeOpacity: Double = 0.28
        static let calloutStrokeWidth: CGFloat = 1
        /// 候補が 1 夜だけの一覧では「いちばんの夜」に意味がないため、この夜数未満では出さない。
        static let calloutMinimumNightCount = 2
    }

    /// 場所タブの検索・地図レイアウト。
    enum Location {
        static let searchResultsMaxHeight: CGFloat = 104
        static let estimatedSearchResultRowHeight: CGFloat = 52
        static let searchResultsVisibleRowCapacity = searchResultsMaxHeight / estimatedSearchResultRowHeight
        static let searchResultLineSpacing: CGFloat = 2
        static let defaultMapHeight: CGFloat = 220
        static let compactMapHeight: CGFloat = 160
        static let favoritesVisibleCount = 2
        static let estimatedFavoriteRowHeight: CGFloat = 52
        static let favoritesMaxHeight: CGFloat = estimatedFavoriteRowHeight * CGFloat(favoritesVisibleCount)
    }

    /// 夜カードの行レイアウト。
    enum NightRow {
        static let cardMinHeight: CGFloat = 54
        static let cardHorizontalPadding: CGFloat = Spacing.sm
        static let cardVerticalPadding: CGFloat = Spacing.xs
        static let contentSpacing: CGFloat = Spacing.xxs
        /// 同じ列の中で行を詰めるときの極小間隔。
        static let tightLineSpacing: CGFloat = Spacing.xs / 4
        static let selectionBorderWidth: CGFloat = 2
        /// 選択中の行に敷くアクセント地色。
        static let selectionTintOpacity: Double = 0.08
        static let metadataIconSpacing: CGFloat = 4
        static let metadataMinimumScaleFactor: CGFloat = 0.78
        /// 星空指数を示す角丸スクエア（StarGazingIndex.starCount の最大値と同数）。
        static let tierSquareCount = 5
        static let tierSquareSize: CGFloat = 10
        static let tierSquareSpacing: CGFloat = 2
        static let tierSquareCornerRadius: CGFloat = 2
        /// 固定幅の列。日付・雲量・右端（薄明開始＋天気）。
        static let dateColumnWidth: CGFloat = 64
        static let cloudColumnWidth: CGFloat = 48
        static let trailingColumnWidth: CGFloat = 92
        /// 選択中の行だけに開く時間別雲量ストリップ。
        static let hourlyStripHeight: CGFloat = 6
        static let hourlyStripCornerRadius: CGFloat = 3
    }
}
