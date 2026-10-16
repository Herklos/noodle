import CloudKit
import Testing
import UIKit
import UserNotifications
@testable import NoodleMobile

@Suite struct AppBundleTests {
    @Test func homeScreenNameIsNoodle() {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
        #expect(name == "Noodle Dev")
    }

    @Test func versionComesFromTheVersionFile() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        #expect(version?.split(separator: ".").count == 3)
    }

    /// Invitation links and QR codes are noodle://join-hub links, the same as on the Mac.
    @Test func invitationLinksOpenTheApp() {
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []
        #expect(types.contains { ($0["CFBundleURLSchemes"] as? [String])?.contains("noodle") == true })
    }

    /// The notification extension ships inside the app, as its own bundle, and shares the app's group,
    /// where the Hubs the phone joined are kept; without it a notification could not name the bot.
    @Test func theNotificationExtensionSharesTheAppsGroup() throws {
        let app = try #require(Bundle.main.bundleIdentifier)
        let group = try #require(AppGroup.identifier)
        #expect(group == "group.\(app)")
        let container = try #require(FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group))
        #expect(AppGroup.hubs?.path.hasPrefix(container.path) == true)
        let plugIn = try #require(Bundle.main.builtInPlugInsURL?.appendingPathComponent("NoodleMobileNotifications.appex"))
        let bundle = try #require(Bundle(url: plugIn))
        #expect(bundle.bundleIdentifier == "\(app).notifications")
        #expect(bundle.object(forInfoDictionaryKey: "NoodleAppGroup") as? String == group)
        let point = (bundle.object(forInfoDictionaryKey: "NSExtension") as? [String: Any])?["NSExtensionPointIdentifier"] as? String
        #expect(point == "com.apple.usernotifications.service")
    }

    /// The share extension ships inside the app and shares its group, where the Hubs and the list it offers
    /// are kept. It takes the conversations iOS suggests, which the app tells iOS about.
    @Test func theShareExtensionSharesTheAppsGroupAndTakesSuggestions() throws {
        let app = try #require(Bundle.main.bundleIdentifier)
        let plugIn = try #require(Bundle.main.builtInPlugInsURL?.appendingPathComponent("NoodleMobileShare.appex"))
        let bundle = try #require(Bundle(url: plugIn))
        #expect(bundle.bundleIdentifier == "\(app).share")
        #expect(bundle.object(forInfoDictionaryKey: "NoodleAppGroup") as? String == AppGroup.identifier)
        let extensionInfo = try #require(bundle.object(forInfoDictionaryKey: "NSExtension") as? [String: Any])
        #expect(extensionInfo["NSExtensionPointIdentifier"] as? String == "com.apple.share-services")
        let attributes = try #require(extensionInfo["NSExtensionAttributes"] as? [String: Any])
        #expect((attributes["IntentsSupported"] as? [String])?.contains("INSendMessageIntent") == true)
        #expect((Bundle.main.object(forInfoDictionaryKey: "NSUserActivityTypes") as? [String])?.contains("INSendMessageIntent") == true)
    }

    /// iOS finds the app's answers to a tapped notification and one arriving while open. In Swift 6 a
    /// callback in the wrong form still builds but is never called, so this asks as iOS does.
    @Test @MainActor func notificationCallbacksReachTheApp() {
        let delegate = AppDelegate()
        #expect(delegate.responds(to: #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:))))
        #expect(delegate.responds(to: #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:willPresent:withCompletionHandler:))))
    }

    /// A tapped notification, delivered off the main thread as iOS delivers it, is answered on the main
    /// thread, which iOS insists on, and picks the conversation to open. Answered elsewhere, the app aborts.
    @Test func aTappedNotificationIsAnsweredOnTheMainThread() async throws {
        let conversation = UUID()
        let content = UNMutableNotificationContent()
        content.userInfo = ["ck": ["ce": 2, "cid": "iCloud.com.pdparchitect.noodle", "nid": UUID().uuidString,
                                   "qry": ["dbs": 2, "fo": 1, "rid": "record", "sid": "unread-abc", "zid": "_defaultZone",
                                           "zoid": "_defaultOwner",
                                           "af": ["topic": "abc", "conversation": conversation.uuidString]]]]
        let request = UNNotificationRequest(identifier: "tapped", content: content, trigger: nil)
        // iOS has no public way to make these; tests only.
        let notification = try #require((UNNotification.self as AnyObject)
            .perform(NSSelectorFromString("notificationWithRequest:date:"), with: request, with: Date())?.takeUnretainedValue())
        let response = try #require((UNNotificationResponse.self as AnyObject)
            .perform(NSSelectorFromString("responseWithNotification:actionIdentifier:"), with: notification,
                     with: UNNotificationDefaultActionIdentifier)?.takeUnretainedValue())
        let delegate = await AppDelegate()
        let answeredOnMain: Bool = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                typealias Tap = @convention(c) (AnyObject, Selector, UNUserNotificationCenter, AnyObject, @escaping @convention(block) () -> Void) -> Void
                let selector = #selector(UNUserNotificationCenterDelegate.userNotificationCenter(_:didReceive:withCompletionHandler:))
                let tap = unsafeBitCast(delegate.method(for: selector), to: Tap.self)
                tap(delegate, selector, UNUserNotificationCenter.current(), response) { continuation.resume(returning: Thread.isMainThread) }
            }
        }
        #expect(answeredOnMain)
        #expect(await delegate.opening == NotificationRoute(topic: "abc", conversation: conversation))
    }

    /// CloudKit's error, as logged, carries its code and reason but never the subscription's name,
    /// which holds the topic.
    @Test @MainActor func loggedCloudKitErrorsLeaveTheTopicOut() {
        let error = CKError(.invalidArguments, userInfo: [
            NSLocalizedDescriptionKey: "Error saving record subscription with id unread-secret-topic to server",
            "ServerErrorDescription": "attempting to create a subscription in a production container",
        ])
        let logged = HubNotifications.describe(error)
        #expect(!logged.contains("secret-topic"))
        #expect(logged.contains("attempting to create a subscription in a production container"))
        #expect(logged.contains("12"))
    }

    /// iOS refuses the camera and the Hub's local address to an app that does not say why it needs them,
    /// and leaves Save Image out of the share sheet without the photo library one.
    @Test func permissionsSayWhyTheyAreNeeded() {
        for key in ["NSCameraUsageDescription", "NSLocalNetworkUsageDescription", "NSMicrophoneUsageDescription", "NSPhotoLibraryAddUsageDescription"] {
            #expect((Bundle.main.object(forInfoDictionaryKey: key) as? String)?.isEmpty == false, "\(key)")
        }
    }
}
