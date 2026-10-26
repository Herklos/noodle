@testable import NoodleMobile
import Testing
import UIKit

/// A mouse or trackpad on iPad: a right-click opens what touching and holding does.
@MainActor @Suite struct PointerTests {
    /// The app takes the pointer's clicks as a pointer's, which tell its buttons apart, not as a finger's.
    @Test func thePointerClicksAsAPointer() {
        #expect(Bundle.main.object(forInfoDictionaryKey: "UIApplicationSupportsIndirectInputEvents") as? Bool == true)
    }

    /// A message's right-click is the pointer's secondary button alone; a finger's tap and a left-click are not it.
    @Test func aRightClickIsTheSecondaryButtonOfAPointer() {
        let recognizer = SecondaryClick.recognizer()
        #expect(recognizer.buttonMaskRequired == .secondary)
        #expect(recognizer.allowedTouchTypes == [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)])
        #expect(recognizer.numberOfTapsRequired == 1)
    }
}
