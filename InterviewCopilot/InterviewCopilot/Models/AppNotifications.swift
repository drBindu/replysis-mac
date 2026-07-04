import Foundation

extension Notification.Name {
    static let showDebugLog = Notification.Name("showDebugLog")
    // Posted when the app needs the user to sign in (e.g. they pressed Space while
    // signed out). MainView listens and presents the login sheet.
    static let showLogin    = Notification.Name("showLogin")
}
