import SwiftUI
import Testing

@testable import feeds

struct ArticleReadingAppearanceTests {
    @Test func pageMarginsRespondToAvailableWidth() {
        #expect(ArticlePageMargins.standard.horizontalPadding(for: 390) == 20)
        #expect(ArticlePageMargins.standard.horizontalPadding(for: 700) == 28)
        #expect(ArticlePageMargins.standard.horizontalPadding(for: 1_100) == 40)

        #expect(
            ArticlePageMargins.compact.horizontalPadding(for: 390)
                < ArticlePageMargins.comfortable.horizontalPadding(for: 390)
        )
    }

    @Test func appAppearanceModesResolveGlobally() {
        #expect(AppAppearanceMode.system.colorScheme == nil)
        #expect(AppAppearanceMode.light.colorScheme == .light)
        #expect(AppAppearanceMode.dark.colorScheme == .dark)
    }

    @Test func legacyThemeValuesMigrateToAppAppearance() throws {
        let suiteName = "ArticleReadingAppearanceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("dark", forKey: AppPreferences.articleReadingTheme)

        AppPreferences.migrateLegacyReadingTheme(in: defaults)

        #expect(
            defaults.string(forKey: AppPreferences.appAppearanceMode) == "dark"
        )
        #expect(
            defaults.string(forKey: AppPreferences.articleReadingTheme)
                == "standard"
        )
    }
}
