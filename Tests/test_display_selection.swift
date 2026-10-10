import AppKit
import ScreenCaptureKit

@main
struct DisplaySelectionTest {
    @MainActor
    static func main() {
        let screens: [(id: CGDirectDisplayID, frame: CGRect)] = [
            (29, CGRect(x: 0, y: 0, width: 1440, height: 900)),
            (7, CGRect(x: -1920, y: -180, width: 1920, height: 1080)),
            (42, CGRect(x: 0, y: 900, width: 2560, height: 1440)),
            (88, CGRect(x: 1440, y: -1080, width: 1920, height: 1080))
        ]
        let available = Set(screens.map(\.id))
        let cases: [(CGPoint, CGDirectDisplayID?)] = [
            (CGPoint(x: 400, y: 300), 29),
            (CGPoint(x: -1600, y: 100), 7),
            (CGPoint(x: 2000, y: 1200), 42),
            (CGPoint(x: 1600, y: -400), 88),
            (CGPoint(x: 0, y: 900), 42),
            (CGPoint(x: 3000, y: 400), nil)
        ]
        for (point, expected) in cases {
            let actual = CaptureOverlayController.displayID(at: point, screens: screens, availableIDs: available)
            precondition(actual == expected, "Wrong display at \(point): \(String(describing: actual))")
        }
        let firstClick = CaptureOverlayController.displayID(at: CGPoint(x: 400, y: 300), screens: screens, availableIDs: available)
        let secondClick = CaptureOverlayController.displayID(at: CGPoint(x: -1600, y: 100), screens: screens, availableIDs: available)
        precondition(firstClick == 29 && secondClick == 7)
        precondition(CaptureOverlayController.displayID(at: CGPoint(x: -1600, y: 100), screens: screens, availableIDs: [29]) == nil)
        precondition(CaptureOverlayController.displayID(at: .zero, screens: [], availableIDs: []) == nil)
        print("PASS: primary, left, above, below, boundary and gap display hit tests")
        print("PASS: new click resolves a different display; unavailable targets never fall back")
    }
}