import SwiftUI

// MARK: - FocusedValues

extension FocusedValues {
    @Entry var selectedDate: Binding<Date>? = nil
    @Entry var observationTimeZone: TimeZone? = nil

    var refreshAction: (() -> Void)? {
        get { self[RefreshActionKey.self] }
        set { self[RefreshActionKey.self] = newValue }
    }
    var focusSearchAction: (() -> Void)? {
        get { self[FocusSearchActionKey.self] }
        set { self[FocusSearchActionKey.self] = newValue }
    }
    var currentLocationAction: (() -> Void)? {
        get { self[CurrentLocationActionKey.self] }
        set { self[CurrentLocationActionKey.self] = newValue }
    }
}

private struct RefreshActionKey: FocusedValueKey { typealias Value = () -> Void }
private struct FocusSearchActionKey: FocusedValueKey { typealias Value = () -> Void }
private struct CurrentLocationActionKey: FocusedValueKey { typealias Value = () -> Void }

