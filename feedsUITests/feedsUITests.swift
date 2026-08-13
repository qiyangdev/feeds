import XCTest

#if os(iOS)
    import UIKit
#endif

final class feedsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testEmptyStateCanOpenAddFeedSheet() throws {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing",
            "-ui-testing-reset-preferences",
            "-ui-testing-reset-scene-state",
        ]
        app.launch()

        app.buttons["emptyAddFeedButton"].tap()

        XCTAssertTrue(app.navigationBars["Add Feed"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.textFields["feedURLField"].exists)
        XCTAssertTrue(app.switches["addFeedAutoExtractToggle"].exists)
    }

    @MainActor
    func testSplitNavigationShowsArticleDetail() throws {
        #if os(iOS)
            XCUIDevice.shared.orientation = .landscapeLeft
        #endif

        let app = XCUIApplication()
        app.launchArguments = sampleLaunchArguments(resetPreferences: true)
        app.launch()

        if app.buttons["Example Feed"].waitForExistence(timeout: 1) {
            app.buttons["Example Feed"].tap()
        }
        XCTAssertTrue(app.staticTexts["Example Article"].waitForExistence(timeout: 5))

        app.staticTexts["Example Article"].tap()
        XCTAssertTrue(
            app.staticTexts[
                "An example article for testing the three-column navigation."
            ].waitForExistence(timeout: 2)
        )
        XCTAssertTrue(app.buttons["openArticleInBrowserButton"].exists)
        XCTAssertTrue(
            app.buttons["articleReadingAppearanceButton"].exists
        )
        XCTAssertTrue(
            extractionToggle(in: app).exists
        )
        XCTAssertEqual(
            extractionToggle(in: app).value as? String,
            "Off"
        )
        XCTAssertTrue(favoriteToggle(in: app).exists)
    }

    @MainActor
    func testArticleFavoriteCanBeToggled() throws {
        #if os(iOS)
            XCUIDevice.shared.orientation = .landscapeLeft
        #endif

        let app = XCUIApplication()
        app.launchArguments = sampleLaunchArguments(resetPreferences: true)
        app.launch()

        if app.buttons["Example Feed"].waitForExistence(timeout: 2) {
            app.buttons["Example Feed"].tap()
        }
        XCTAssertTrue(
            app.staticTexts["Example Article"].waitForExistence(timeout: 5)
        )
        app.staticTexts["Example Article"].tap()

        let favoriteToggle = favoriteToggle(in: app)
        XCTAssertTrue(favoriteToggle.waitForExistence(timeout: 2))
        wait(for: favoriteToggle, value: "Off")
        favoriteToggle.tap()
        wait(for: favoriteToggle, value: "On")
        favoriteToggle.tap()
        wait(for: favoriteToggle, value: "Off")
    }

    @MainActor
    func testHideReadArticlesPreferencePersistsAcrossLaunches() throws {
        #if os(iOS)
            XCUIDevice.shared.orientation = .landscapeLeft
        #endif

        let app = XCUIApplication()
        app.launchArguments = hideReadPreferenceLaunchArguments(
            resetPreferences: true
        )
        app.launch()

        let readArticle = app.staticTexts["Read Example Article"]
        XCTAssertTrue(readArticle.waitForExistence(timeout: 5))
        let unreadRow = articleRow(titled: "Example Article", in: app)
        let readRow = articleRow(titled: "Read Example Article", in: app)
        XCTAssertTrue(unreadRow.exists)
        XCTAssertTrue(readRow.exists)
        XCTAssertEqual(
            unreadRow.value as? String,
            "Unread"
        )
        XCTAssertEqual(
            readRow.value as? String,
            "Read"
        )

        let firstLaunchMenu = app.buttons["articlesMenu"]
        XCTAssertTrue(firstLaunchMenu.waitForExistence(timeout: 5))
        firstLaunchMenu.tap()

        let firstLaunchToggle = hideReadArticlesToggle(in: app)
        XCTAssertTrue(firstLaunchToggle.waitForExistence(timeout: 2))
        firstLaunchToggle.tap()
        waitForNonexistence(of: readArticle)

        app.terminate()
        app.launchArguments = hideReadPreferenceLaunchArguments(
            resetPreferences: false
        )
        app.launch()

        XCTAssertTrue(
            app.staticTexts["Example Article"].waitForExistence(timeout: 5)
        )
        XCTAssertFalse(readArticle.exists)

        let secondLaunchMenu = app.buttons["articlesMenu"]
        XCTAssertTrue(secondLaunchMenu.waitForExistence(timeout: 5))
        secondLaunchMenu.tap()

        let secondLaunchToggle = hideReadArticlesToggle(in: app)
        XCTAssertTrue(secondLaunchToggle.waitForExistence(timeout: 2))
        secondLaunchToggle.tap()
        XCTAssertTrue(readArticle.waitForExistence(timeout: 2))
    }

    @MainActor
    func testSelectedArticleRemainsVisibleWhenHideReadMarksItRead() throws {
        #if os(iOS)
            XCUIDevice.shared.orientation = .landscapeLeft
        #endif

        let app = XCUIApplication()
        app.launchArguments = sampleLaunchArguments(resetPreferences: true)
        app.launch()

        let row = articleRow(titled: "Example Article", in: app)
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertEqual(row.value as? String, "Unread")

        let menu = app.buttons["articlesMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 2))
        menu.tap()
        let toggle = hideReadArticlesToggle(in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 2))
        toggle.tap()

        row.tap()

        XCTAssertTrue(row.waitForExistence(timeout: 2))
        wait(for: row, value: "Read")
        XCTAssertTrue(
            app.staticTexts[
                "An example article for testing the three-column navigation."
            ].waitForExistence(timeout: 2)
        )
    }

    @MainActor
    func testReadingAppearanceCanBePresentedAsSheet() throws {
        #if os(iOS)
            XCUIDevice.shared.orientation = .landscapeLeft
        #endif

        let app = XCUIApplication()
        app.launchArguments = sampleLaunchArguments(resetPreferences: true)
        app.launch()

        if app.buttons["Example Feed"].waitForExistence(timeout: 1) {
            app.buttons["Example Feed"].tap()
        }
        let articleTitle = app.staticTexts["Example Article"]
        XCTAssertTrue(articleTitle.waitForExistence(timeout: 5))
        articleTitle.tap()

        let appearanceButton = app.buttons["articleReadingAppearanceButton"]
        XCTAssertTrue(appearanceButton.waitForExistence(timeout: 2))
        appearanceButton.tap()

        let appearanceSheet =
            app.descendants(matching: .any)["articleReadingAppearanceSheet"]
        XCTAssertTrue(appearanceSheet.waitForExistence(timeout: 2))
        XCTAssertTrue(
            app.descendants(matching: .any)["articleReadingAppearancePreview"]
                .exists
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["appAppearanceModePicker"]
                .exists
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["articleReadingThemePicker"]
                .exists
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["articleFontPicker"].exists
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["articleTextSizePicker"].exists
        )
        appearanceSheet.swipeUp()

        XCTAssertTrue(
            app.descendants(matching: .any)["articleLineSpacingPicker"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["articleContentWidthPicker"]
                .waitForExistence(timeout: 2)
        )
        XCTAssertTrue(
            app.descendants(matching: .any)["articlePageMarginsPicker"]
                .waitForExistence(timeout: 2)
        )

        let doneButton =
            app.buttons["dismissArticleReadingAppearanceButton"]
        XCTAssertTrue(doneButton.exists)
        doneButton.tap()
        XCTAssertFalse(
            app.descendants(matching: .any)["articleReadingAppearanceSheet"]
                .waitForExistence(timeout: 1)
        )
    }

    #if os(iOS)
        @MainActor
        func testIPadFeedSidebarHidesNavigationTitle() throws {
            try XCTSkipUnless(
                UIDevice.current.userInterfaceIdiom == .pad,
                "Feed sidebar title behavior is tested on iPad only."
            )

            XCUIDevice.shared.orientation = .landscapeLeft

            let app = XCUIApplication()
            app.launchArguments = sampleLaunchArguments(
                resetPreferences: true
            )
            app.launch()

            let showSidebarButton = app.buttons["Show Sidebar"]
            if showSidebarButton.waitForExistence(timeout: 1) {
                showSidebarButton.tap()
            }

            XCTAssertTrue(
                app.buttons["addFeedButton"].waitForExistence(timeout: 2)
            )
            let feedsNavigationBar = app.navigationBars["Feeds"]
            XCTAssertTrue(feedsNavigationBar.exists)
            XCTAssertFalse(
                feedsNavigationBar.staticTexts["Feeds"].exists
            )
        }

        @MainActor
        func testIPadArticleDetailCanEnterAndExitFullScreen() throws {
            try XCTSkipUnless(
                UIDevice.current.userInterfaceIdiom == .pad,
                "Article full-screen mode is available on iPad only."
            )

            XCUIDevice.shared.orientation = .landscapeLeft

            let app = XCUIApplication()
            app.launchArguments = sampleLaunchArguments(
                resetPreferences: true
            )
            app.launch()

            let articleTitle = app.staticTexts["Example Article"]
            XCTAssertTrue(articleTitle.waitForExistence(timeout: 2))
            articleTitle.tap()

            let fullScreenButton =
                app.buttons["toggleArticleFullScreenButton"]
            XCTAssertTrue(fullScreenButton.waitForExistence(timeout: 2))
            wait(for: fullScreenButton, value: "Off")

            fullScreenButton.tap()

            wait(for: fullScreenButton, value: "On")

            fullScreenButton.tap()

            wait(for: fullScreenButton, value: "Off")
            XCTAssertTrue(
                app.staticTexts[
                    "An example article for testing the three-column navigation."
                ].exists
            )
        }

        @MainActor
        func testIPadRestoresSelectedArticleAndFullScreenState() throws {
            try XCTSkipUnless(
                UIDevice.current.userInterfaceIdiom == .pad,
                "Scene restoration is exercised on iPad only."
            )

            XCUIDevice.shared.orientation = .landscapeLeft

            let app = XCUIApplication()
            app.launchArguments = restorationLaunchArguments(resetState: true)
            app.launch()

            let secondFeed = app.buttons["Second Feed"]
            if !secondFeed.waitForExistence(timeout: 2) {
                let showSidebarButton = app.buttons["Show Sidebar"]
                XCTAssertTrue(showSidebarButton.waitForExistence(timeout: 2))
                showSidebarButton.tap()
            }
            XCTAssertTrue(secondFeed.waitForExistence(timeout: 2))
            secondFeed.tap()

            let secondArticle = app.staticTexts["Second Example Article"]
            XCTAssertTrue(secondArticle.waitForExistence(timeout: 3))
            secondArticle.tap()
            XCTAssertTrue(
                app.staticTexts[
                    "A second article used to verify scene restoration."
                ].waitForExistence(timeout: 2)
            )

            let fullScreenButton =
                app.buttons["toggleArticleFullScreenButton"]
            XCTAssertTrue(fullScreenButton.waitForExistence(timeout: 2))
            fullScreenButton.tap()
            wait(for: fullScreenButton, value: "On")

            app.terminate()
            app.launchArguments = restorationLaunchArguments(resetState: false)
            app.launch()

            let restoredFullScreenButton =
                app.buttons["toggleArticleFullScreenButton"]
            XCTAssertTrue(
                restoredFullScreenButton.waitForExistence(timeout: 5)
            )
            wait(for: restoredFullScreenButton, value: "On")
            XCTAssertTrue(
                app.staticTexts[
                    "A second article used to verify scene restoration."
                ].exists
            )

            restoredFullScreenButton.tap()
            wait(for: restoredFullScreenButton, value: "Off")

            let restoredArticleRow = app.buttons[
                "articleRow.22222222-2222-2222-2222-222222222221|second-example-article"
            ]
            XCTAssertTrue(restoredArticleRow.waitForExistence(timeout: 3))
        }

    #endif

    private func wait(
        for element: XCUIElement,
        value: String,
        timeout: TimeInterval = 2
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", value),
            object: element
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: timeout),
            .completed
        )
    }

    private func extractionToggle(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "extractArticleContentButton")
            .firstMatch
    }

    private func favoriteToggle(in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "toggleArticleFavoriteButton")
            .firstMatch
    }

    private func hideReadArticlesToggle(
        in app: XCUIApplication
    ) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "hideReadArticlesToggle")
            .firstMatch
    }

    private func articleRow(
        titled title: String,
        in app: XCUIApplication
    ) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "\(title),")
        ).firstMatch
    }

    private func waitForNonexistence(
        of element: XCUIElement,
        timeout: TimeInterval = 2
    ) {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: element
        )
        XCTAssertEqual(
            XCTWaiter.wait(for: [expectation], timeout: timeout),
            .completed
        )
    }

    private func hideReadPreferenceLaunchArguments(
        resetPreferences: Bool
    ) -> [String] {
        sampleLaunchArguments(resetPreferences: resetPreferences)
            + ["-ui-testing-read-sample"]
    }

    private func sampleLaunchArguments(
        resetPreferences: Bool
    ) -> [String] {
        var arguments = ["-ui-testing-sample"]
        if resetPreferences {
            arguments.append("-ui-testing-reset-preferences")
            arguments.append("-ui-testing-reset-scene-state")
        }
        return arguments
    }

    private func restorationLaunchArguments(
        resetState: Bool
    ) -> [String] {
        var arguments = ["-ui-testing-restoration-sample"]
        if resetState {
            arguments.append("-ui-testing-reset-preferences")
            arguments.append("-ui-testing-reset-scene-state")
        }
        return arguments
    }
}
