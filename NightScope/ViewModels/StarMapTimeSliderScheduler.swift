import Foundation

/// 夜間タイムスライダーの確定を trailing-edge debounce で遅延させる。
@MainActor
final class StarMapTimeSliderScheduler {
    private let commitInterval: TimeInterval
    private var lastCommitTime: TimeInterval = 0
    private var pendingDate: Date?
    private var commitTask: Task<Void, Never>?

    init(commitInterval: TimeInterval) {
        self.commitInterval = commitInterval
    }

    deinit {
        commitTask?.cancel()
    }

    /// date を保留として記録し、commitInterval 経過後（または即座）に onCommit を呼ぶ。
    func schedulePendingCommit(date: Date, onCommit: @escaping (Date) -> Void) {
        pendingDate = date
        let now = Date.timeIntervalSinceReferenceDate
        let elapsed = now - lastCommitTime
        if elapsed >= commitInterval {
            flushPendingCommit(onCommit: onCommit)
            return
        }
        cancelTask()
        let remaining = commitInterval - elapsed
        commitTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.flushPendingCommit(onCommit: onCommit)
        }
    }

    /// 保留中の日時があれば即座にコミットする。
    func flushPendingCommit(onCommit: (Date) -> Void) {
        guard let date = pendingDate else { return }
        pendingDate = nil
        cancelTask()
        lastCommitTime = Date.timeIntervalSinceReferenceDate
        onCommit(date)
    }

    /// 保留中の日時をコミットせず破棄する。
    func discardPending() {
        pendingDate = nil
        cancelTask()
    }

    private func cancelTask() {
        commitTask?.cancel()
        commitTask = nil
    }
}
