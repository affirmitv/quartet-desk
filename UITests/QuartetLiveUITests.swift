import XCTest

/// LIVE end-to-end UI smoke test. Drives one REAL quartet run (real API calls,
/// real token spend — keys must already be in the Keychain under service
/// tv.affirmi.quartetdesk) and attaches window screenshots at each stage.
///
/// Nothing here is mocked. If a seat fails, the failure is visible in the
/// PANEL screenshot and the test still captures the terminal state.
final class QuartetLiveUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    func testLiveQuartetRun() throws {
        let app = XCUIApplication()
        // A fresh container would otherwise open the first-run onboarding
        // sheet over the composer and stall the run.
        app.launchArguments += ["--suppress-onboarding"]
        app.launch()

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15), "Main window did not appear")

        // --- Compose the query ---
        let editor = window.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 15), "Composer TextEditor not found")
        editor.click()
        editor.typeText("Give me a one-page marketing plan for a youth basketball club launching its own team app this fall. Be specific about channels and budget.")
        snap(window, "01-composer")

        // --- Start the run ---
        let runButton = window.buttons["Run Quartet"]
        XCTAssertTrue(runButton.waitForExistence(timeout: 5), "Run Quartet button not found")
        XCTAssertTrue(runButton.isEnabled, "Run Quartet button is disabled")
        runButton.click()

        let stopButton = window.buttons["Stop"]
        XCTAssertTrue(stopButton.waitForExistence(timeout: 10), "Stop button never appeared — run did not start")

        // --- Streaming: ANSWER tab shows the panel-round banner ---
        sleep(4)
        snap(window, "02-streaming-answer-tab")

        // --- Streaming: PANEL tab shows the four seats live ---
        selectTab(window, "PANEL")
        sleep(3)
        snap(window, "02b-streaming-panel")

        // --- Back to ANSWER; try to catch synthesis streaming ---
        selectTab(window, "ANSWER")
        let synthesizing = window.staticTexts["Synthesizing…"]
        var caughtSynthesis = false
        for _ in 0..<240 { // up to 4 min for the panel round
            if synthesizing.exists {
                caughtSynthesis = true
                sleep(2) // let some synthesized text land
                snap(window, "02c-synthesis-streaming")
                break
            }
            if !stopButton.exists { break } // run already finished
            sleep(1)
        }
        if !caughtSynthesis {
            print("NOTE: synthesis streaming state was not caught on screen (window may have been too fast)")
        }

        // --- Wait for the run to finish (Run Quartet button returns) ---
        let finished = runButton.waitForExistence(timeout: 420)
        XCTAssertTrue(finished, "Run did not finish within 7 minutes")

        // --- Terminal states ---
        snap(window, "03-answer")

        selectTab(window, "PANEL")
        sleep(1)
        snap(window, "04-panel")

        selectTab(window, "DISSENT")
        sleep(1)
        snap(window, "05-dissent")

        // The cost footer renders only when a RunRecord exists with cost.
        let costFooter = window.staticTexts.containing(NSPredicate(format: "value CONTAINS '$' OR label CONTAINS '$'")).firstMatch
        XCTAssertTrue(costFooter.exists, "Cost footer with a $ amount not found after the run")

        // --- Settings window (API keys are in SecureFields → rendered masked) ---
        app.typeKey(",", modifierFlags: .command)
        sleep(2)
        // The settings scene opens a second window; screenshot whichever window is frontmost.
        let settingsWindow = app.windows.element(boundBy: 0)
        if settingsWindow.exists {
            snap(settingsWindow, "06-settings", fallbackApp: app)
        } else {
            snapApp(app, "06-settings")
        }
    }

    // MARK: - Helpers

    /// SwiftUI segmented Picker segments can surface as radio buttons or buttons
    /// depending on macOS version — try both.
    private func selectTab(_ window: XCUIElement, _ label: String) {
        let radio = window.radioButtons[label]
        if radio.exists {
            radio.click()
            return
        }
        let button = window.buttons[label]
        if button.exists {
            button.click()
            return
        }
        let segButton = window.segmentedControls.buttons[label]
        if segButton.exists {
            segButton.click()
            return
        }
        XCTFail("Could not find tab control labeled \(label)")
    }

    private func snap(_ element: XCUIElement, _ name: String, fallbackApp: XCUIApplication? = nil) {
        let shot: XCTAttachment
        if element.exists {
            shot = XCTAttachment(screenshot: element.screenshot())
        } else if let fallbackApp {
            shot = XCTAttachment(screenshot: fallbackApp.screenshot())
        } else {
            XCTFail("Cannot screenshot \(name): element missing")
            return
        }
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private func snapApp(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
