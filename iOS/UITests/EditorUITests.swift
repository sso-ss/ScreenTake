import XCTest

final class EditorUITests: XCTestCase {
    @MainActor
    func testPhotosImportEditAndSave() throws {
        let app = XCUIApplication()
        app.launch()
        let importButton = app.buttons["Import Video"]
        XCTAssertTrue(importButton.waitForExistence(timeout: 20))
        importButton.tap()
        let photos = app.buttons["Photos"]
        if photos.waitForExistence(timeout: 3), photos.isHittable { photos.tap() }
        let movie = app.images.matching(NSPredicate(format: "label BEGINSWITH 'Video,'")).firstMatch
        guard movie.waitForExistence(timeout: 10) else {
            capture("Photos picker state")
            XCTFail("The seeded video must be available in Photos.")
            return
        }
        movie.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let frame = app.buttons["Frame"]
        XCTAssertTrue(frame.waitForExistence(timeout: 30))
        frame.tap()
        app.segmentedControls.buttons["1:1"].tap()
        app.buttons["Backdrop"].tap()
        app.buttons["Lagoon"].tap()
        app.buttons["Trim"].tap()
        capture("iPhone portrait editor")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["Export"].isHittable)
        XCTAssertTrue(app.buttons["Frame"].isHittable)
        capture("iPhone landscape editor")
        XCUIDevice.shared.orientation = .portrait
        app.buttons["Zoom"].tap()
        let zoom = app.switches["Zoom"]
        XCTAssertTrue(zoom.waitForExistence(timeout: 5))
        if zoom.value as? String == "0" { zoom.tap() }
        app.buttons["Set at Playhead"].tap()
        app.buttons["Export"].tap()
        XCTAssertTrue(app.staticTexts["Video Ready"].waitForExistence(timeout: 90))
        capture("iPhone export ready")
        app.buttons["Save to Photos"].tap()
        XCTAssertTrue(app.staticTexts["Saved to Photos"].waitForExistence(timeout: 20))
        app.buttons["Done"].tap()
        app.buttons["Frame"].tap()
        XCTAssertTrue(app.segmentedControls.buttons["1:1"].isSelected)
    }

    @MainActor
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}