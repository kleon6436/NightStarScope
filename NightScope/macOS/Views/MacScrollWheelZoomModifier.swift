import SwiftUI
import AppKit

/// ポインタがビュー上にある間のスクロールホイール操作を拾い、ズーム量として呼び出し側へ渡す。
/// - Note: 表示中に 1 回だけローカルモニタを登録し、非表示で外す。拾ったイベントは他へ流さない。
struct MacScrollWheelZoomModifier: ViewModifier {
    let isEnabled: Bool
    let onScroll: (_ deltaY: Double, _ preciseScrolling: Bool) -> Void

    @State private var scrollWheelMonitor: Any?
    @State private var isPointerOver = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                installMonitor()
            }
            .onDisappear {
                removeMonitor()
            }
            .onHover { isPointerOver = $0 }
    }

    private func installMonitor() {
        guard scrollWheelMonitor == nil else { return }
        scrollWheelMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { event in
            handleScrollWheel(event)
        }
    }

    private func removeMonitor() {
        guard let scrollWheelMonitor else { return }
        NSEvent.removeMonitor(scrollWheelMonitor)
        self.scrollWheelMonitor = nil
    }

    private func handleScrollWheel(_ event: NSEvent) -> NSEvent? {
        guard isPointerOver, isEnabled else {
            return event
        }
        onScroll(event.scrollingDeltaY, event.hasPreciseScrollingDeltas)
        return nil
    }
}
