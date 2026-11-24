import XCTest

/// UI tests drive the real popover. The app is launched with `--show-popover`, which
/// opens the popover immediately (the same code path as clicking the status item).
/// Requires the test runner to have Accessibility permission on the machine.
final class PopoverUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += ["--show-popover", "-AppleLanguages", "(en)"]
        app.launch()
    }

    override func tearDownWithError() throws {
        // Leave the machine sober.
        let sober = app.buttons["mode.sober"]
        if sober.exists { sober.click() }
        app.terminate()
    }

    func testPopoverShowsAllModesAndDuration() throws {
        for id in ["mode.bump", "mode.high", "mode.overdose", "mode.sober"] {
            XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 10), "\(id) missing")
            XCTAssertTrue(app.buttons[id].isHittable, "\(id) not hittable")
        }
        XCTAssertTrue(app.radioGroups["duration"].exists || app.segmentedControls["duration"].exists)
        XCTAssertTrue(app.staticTexts["Keep your Mac awake."].exists)
    }

    func testSelectingBumpUpdatesSelectedStateThenSober() throws {
        let bump = app.buttons["mode.bump"]
        XCTAssertTrue(bump.waitForExistence(timeout: 10))
        bump.click()
        let selected = NSPredicate(format: "isSelected == true")
        expectation(for: selected, evaluatedWith: bump)
        waitForExpectations(timeout: 10)

        let sober = app.buttons["mode.sober"]
        sober.click()
        expectation(for: selected, evaluatedWith: sober)
        waitForExpectations(timeout: 10)
        XCTAssertFalse(bump.isSelected)
    }

    func testKeyboardShortcutsSelectModes() throws {
        XCTAssertTrue(app.buttons["mode.high"].waitForExistence(timeout: 10))
        app.typeKey("2", modifierFlags: [])
        expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: app.buttons["mode.high"])
        waitForExpectations(timeout: 10)
        app.typeKey("0", modifierFlags: [])
        expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: app.buttons["mode.sober"])
        waitForExpectations(timeout: 10)
    }

    func testDurationSelectorChangesSelection() throws {
        let group = app.radioGroups["duration"].exists ? app.radioGroups["duration"] : app.segmentedControls["duration"]
        XCTAssertTrue(group.waitForExistence(timeout: 10))
        let fourHours = group.radioButtons["4h"]
        XCTAssertTrue(fourHours.exists)
        fourHours.click()
        XCTAssertTrue(fourHours.isSelected)
        group.radioButtons["1h"].click()
        XCTAssertTrue(group.radioButtons["1h"].isSelected)
    }
}
