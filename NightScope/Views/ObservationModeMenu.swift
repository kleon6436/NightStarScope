import SwiftUI

#if os(macOS)
/// 観測モードを選ぶツールバー用メニュー。選択ロジックはここ 1 か所に保つ。
struct ObservationModeMenu: View {
    @ObservedObject var observationModePreference: ObservationModePreference

    var body: some View {
        Menu {
            ForEach(ObservationMode.allCases) { mode in
                Button {
                    observationModePreference.mode = mode
                } label: {
                    HStack {
                        Label(L10n.tr(mode.titleKey), systemImage: mode.iconSystemName)
                        if observationModePreference.mode == mode {
                            Spacer()
                            Image(systemName: "checkmark")
                        }
                    }
                }
                .help(L10n.tr(mode.descriptionKey))
            }
        } label: {
            // どの観測モードが効いているかはアイコンだけでは伝わらないため、名称も出す。
            Label(
                L10n.tr(observationModePreference.mode.shortTitleKey),
                systemImage: observationModePreference.mode.iconSystemName
            )
            .labelStyle(.titleAndIcon)
            .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .help(tooltip)
        .accessibilityLabel(L10n.tr("observation.mode.change"))
    }

    private var tooltip: String {
        L10n.format(
            "%@\n%@",
            L10n.tr("observation.mode.change"),
            L10n.tr(observationModePreference.mode.descriptionKey)
        )
    }
}
#endif
