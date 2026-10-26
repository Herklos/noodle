import SwiftUI
import UIKit

/// A click with the pointer's secondary button, as a right-click or a two-finger click on a trackpad, which on
/// iPad opens what touching and holding does. Only a pointer clicks it; touches are left alone.
@MainActor struct SecondaryClick: UIGestureRecognizerRepresentable {
    let action: () -> Void

    static func recognizer() -> UITapGestureRecognizer {
        let recognizer = UITapGestureRecognizer()
        recognizer.buttonMaskRequired = .secondary
        recognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        return recognizer
    }

    func makeUIGestureRecognizer(context: Context) -> UITapGestureRecognizer { Self.recognizer() }

    func handleUIGestureRecognizerAction(_ recognizer: UITapGestureRecognizer, context: Context) {
        if recognizer.state == .ended { action() }
    }
}

extension View {
    /// Runs `action` on a secondary click, as touching and holding the view does.
    func onSecondaryClick(perform action: @escaping () -> Void) -> some View {
        gesture(SecondaryClick(action: action))
    }
}
