import Foundation

enum AppPreferences {
    static let hidesReadArticles = "articleList.hidesReadArticles"
    static let articleReadingFontFamily = "articleReading.fontFamily"
    static let articleReadingTextSize = "articleReading.textSize"
    static let articleReadingLineSpacing = "articleReading.lineSpacing"
    static let articleReadingContentWidth = "articleReading.contentWidth"
    static let articleReadingTheme = "articleReading.theme"
    static let articleReadingPageMargins = "articleReading.pageMargins"
    static let appAppearanceMode = "app.appearanceMode"
    static let uiTestingContentSceneState = "uiTesting.contentSceneState.v1"

    static let articleReadingKeys = [
        articleReadingFontFamily,
        articleReadingTextSize,
        articleReadingLineSpacing,
        articleReadingContentWidth,
        articleReadingTheme,
        articleReadingPageMargins,
        appAppearanceMode,
    ]

    static func migrateLegacyReadingTheme(
        in defaults: UserDefaults = .standard
    ) {
        guard let legacyTheme = defaults.string(forKey: articleReadingTheme)
        else {
            return
        }

        switch legacyTheme {
        case "system", "light", "dark":
            defaults.set(legacyTheme, forKey: appAppearanceMode)
            defaults.set("standard", forKey: articleReadingTheme)
        default:
            break
        }
    }
}
