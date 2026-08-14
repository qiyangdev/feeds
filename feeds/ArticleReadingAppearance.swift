import SwiftUI

enum AppAppearanceMode: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self { self }

    var title: String {
        switch self {
        case .system:
            "System"
        case .light:
            "Light"
        case .dark:
            "Dark"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system:
            nil
        case .light:
            .light
        case .dark:
            .dark
        }
    }
}

enum ArticleReadingTheme: String, CaseIterable, Identifiable {
    case standard
    case sepia

    var id: Self { self }

    var title: String {
        switch self {
        case .standard:
            "Default"
        case .sepia:
            "Sepia"
        }
    }

    func backgroundColor(for colorScheme: ColorScheme) -> Color {
        switch (self, colorScheme) {
        case (.standard, _):
            .clear
        case (.sepia, .light):
            Color(red: 0.96, green: 0.92, blue: 0.82)
        case (.sepia, .dark):
            Color(red: 0.14, green: 0.12, blue: 0.09)
        @unknown default:
            .clear
        }
    }

    func primaryTextColor(for colorScheme: ColorScheme) -> Color {
        switch (self, colorScheme) {
        case (.standard, _):
            .primary
        case (.sepia, .light):
            Color(red: 0.22, green: 0.17, blue: 0.10)
        case (.sepia, .dark):
            Color(red: 0.89, green: 0.82, blue: 0.70)
        @unknown default:
            .primary
        }
    }

    func secondaryTextColor(for colorScheme: ColorScheme) -> Color {
        switch (self, colorScheme) {
        case (.standard, _):
            .secondary
        case (.sepia, .light):
            Color(red: 0.43, green: 0.34, blue: 0.22)
        case (.sepia, .dark):
            Color(red: 0.68, green: 0.58, blue: 0.45)
        @unknown default:
            .secondary
        }
    }

    func accentColor(for colorScheme: ColorScheme) -> Color {
        switch (self, colorScheme) {
        case (.standard, _):
            .accentColor
        case (.sepia, .light):
            Color(red: 0.46, green: 0.29, blue: 0.12)
        case (.sepia, .dark):
            Color(red: 0.79, green: 0.59, blue: 0.34)
        @unknown default:
            .accentColor
        }
    }
}

enum ArticleFontFamily: String, CaseIterable, Identifiable {
    case system
    case serif
    case rounded

    var id: Self { self }

    var title: String {
        switch self {
        case .system:
            "System"
        case .serif:
            "Serif"
        case .rounded:
            "Rounded"
        }
    }

    var design: Font.Design {
        switch self {
        case .system:
            .default
        case .serif:
            .serif
        case .rounded:
            .rounded
        }
    }
}

enum ArticleTextSize: String, CaseIterable, Identifiable {
    case small
    case standard
    case large
    case extraLarge

    var id: Self { self }

    var title: String {
        switch self {
        case .small:
            "Small"
        case .standard:
            "Standard"
        case .large:
            "Large"
        case .extraLarge:
            "Extra Large"
        }
    }

    var textStyle: Font.TextStyle {
        switch self {
        case .small:
            .callout
        case .standard:
            .body
        case .large:
            .title3
        case .extraLarge:
            .title2
        }
    }
}

enum ArticleLineSpacing: String, CaseIterable, Identifiable {
    case compact
    case standard
    case relaxed

    var id: Self { self }

    var title: String {
        switch self {
        case .compact:
            "Compact"
        case .standard:
            "Standard"
        case .relaxed:
            "Relaxed"
        }
    }

    var textSpacing: CGFloat {
        switch self {
        case .compact:
            2
        case .standard:
            5
        case .relaxed:
            9
        }
    }

    var markdownLineSpacing: CGFloat {
        switch self {
        case .compact:
            0.12
        case .standard:
            0.23
        case .relaxed:
            0.38
        }
    }

    var markdownBlockSpacing: CGFloat {
        switch self {
        case .compact:
            0.65
        case .standard:
            0.8
        case .relaxed:
            1
        }
    }
}

enum ArticleContentWidth: String, CaseIterable, Identifiable {
    case narrow
    case standard
    case wide

    var id: Self { self }

    var title: String {
        switch self {
        case .narrow:
            "Narrow"
        case .standard:
            "Standard"
        case .wide:
            "Wide"
        }
    }

    var maxWidth: CGFloat {
        switch self {
        case .narrow:
            560
        case .standard:
            720
        case .wide:
            900
        }
    }
}

enum ArticlePageMargins: String, CaseIterable, Identifiable {
    case compact
    case standard
    case comfortable

    var id: Self { self }

    var title: String {
        switch self {
        case .compact:
            "Compact"
        case .standard:
            "Standard"
        case .comfortable:
            "Comfortable"
        }
    }

    func horizontalPadding(for availableWidth: CGFloat) -> CGFloat {
        switch (self, availableWidth) {
        case (.compact, ..<500):
            12
        case (.standard, ..<500):
            20
        case (.comfortable, ..<500):
            32
        case (.compact, ..<900):
            16
        case (.standard, ..<900):
            28
        case (.comfortable, ..<900):
            48
        case (.compact, _):
            20
        case (.standard, _):
            40
        case (.comfortable, _):
            72
        }
    }
}

struct ArticleReadingAppearance: Equatable {
    let fontFamily: ArticleFontFamily
    let textSize: ArticleTextSize
    let lineSpacing: ArticleLineSpacing
    let contentWidth: ArticleContentWidth
    let theme: ArticleReadingTheme
    let pageMargins: ArticlePageMargins

    static let `default` = ArticleReadingAppearance(
        fontFamily: .system,
        textSize: .standard,
        lineSpacing: .standard,
        contentWidth: .standard,
        theme: .standard,
        pageMargins: .standard
    )

    var bodyFont: Font {
        .system(textSize.textStyle, design: fontFamily.design)
    }

    var titleFont: Font {
        .system(.largeTitle, design: fontFamily.design, weight: .bold)
    }
}

struct ArticleReadingAppearanceSheet: View {
    @Environment(\.dismiss) private var dismiss

    @Binding var appAppearanceMode: AppAppearanceMode
    @Binding var fontFamily: ArticleFontFamily
    @Binding var textSize: ArticleTextSize
    @Binding var lineSpacing: ArticleLineSpacing
    @Binding var contentWidth: ArticleContentWidth
    @Binding var theme: ArticleReadingTheme
    @Binding var pageMargins: ArticlePageMargins

    var body: some View {
        NavigationStack {
            Form {
                Section("Preview") {
                    ArticleReadingAppearancePreview(
                        appearance: appearance
                    )
                    .accessibilityIdentifier("articleReadingAppearancePreview")
                }

                Section("App Appearance") {
                    Picker("Appearance", selection: $appAppearanceMode) {
                        ForEach(AppAppearanceMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("appAppearanceModePicker")
                }

                Section("Reading Theme") {
                    Picker("Reading Theme", selection: $theme) {
                        ForEach(ArticleReadingTheme.allCases) { theme in
                            Text(theme.title).tag(theme)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("articleReadingThemePicker")
                }

                Section("Typography") {
                    LabeledContent("Font") {
                        Picker("Font", selection: $fontFamily) {
                            ForEach(ArticleFontFamily.allCases) { family in
                                Text(family.title).tag(family)
                            }
                        }
                        .fixedSize()
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("articleFontPicker")
                        #if os(iOS)
                            .labelsHidden()
                        #endif
                    }
                    LabeledContent("Text Size") {
                        Picker("Text Size", selection: $textSize) {
                            ForEach(ArticleTextSize.allCases) { size in
                                Text(size.title).tag(size)
                            }
                        }
                        .fixedSize()
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("articleTextSizePicker")
                        #if os(iOS)
                            .labelsHidden()
                        #endif
                    }
                }

                Section("Layout") {
                    LabeledContent("Line Spacing") {
                        Picker("Line Spacing", selection: $lineSpacing) {
                            ForEach(ArticleLineSpacing.allCases) { spacing in
                                Text(spacing.title).tag(spacing)
                            }
                        }
                        .fixedSize()
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("articleLineSpacingPicker")
                        #if os(iOS)
                            .labelsHidden()
                        #endif
                    }

                    LabeledContent("Page Width") {
                        Picker("Page Width", selection: $contentWidth) {
                            ForEach(ArticleContentWidth.allCases) { width in
                                Text(width.title).tag(width)
                            }
                        }
                        .fixedSize()
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("articleContentWidthPicker")
                        #if os(iOS)
                            .labelsHidden()
                        #endif
                    }

                    LabeledContent("Page Margins") {
                        Picker("Page Margins", selection: $pageMargins) {
                            ForEach(ArticlePageMargins.allCases) { margins in
                                Text(margins.title).tag(margins)
                            }
                        }
                        .fixedSize()
                        .pickerStyle(.segmented)
                        .accessibilityIdentifier("articlePageMarginsPicker")
                        #if os(iOS)
                            .labelsHidden()
                        #endif
                    }
                }

                Section {
                    Button(
                        "Reset to Defaults",
                        systemImage: "arrow.counterclockwise"
                    ) {
                        resetToDefaults()
                    }
                    .disabled(isUsingDefaults)
                    .accessibilityIdentifier(
                        "resetArticleReadingAppearanceButton"
                    )
                }
            }
            .navigationTitle("Reading Appearance")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier(
                            "dismissArticleReadingAppearanceButton"
                        )
                }
            }
        }
        .accessibilityIdentifier("articleReadingAppearanceSheet")
        #if os(iOS)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        #elseif os(macOS)
            .frame(minWidth: 420, minHeight: 360)
        #endif
    }

    private var isUsingDefaults: Bool {
        fontFamily == .system
            && textSize == .standard
            && lineSpacing == .standard
            && contentWidth == .standard
            && appAppearanceMode == .system
            && theme == .standard
            && pageMargins == .standard
    }

    private var appearance: ArticleReadingAppearance {
        ArticleReadingAppearance(
            fontFamily: fontFamily,
            textSize: textSize,
            lineSpacing: lineSpacing,
            contentWidth: contentWidth,
            theme: theme,
            pageMargins: pageMargins
        )
    }

    private func resetToDefaults() {
        appAppearanceMode = .system
        fontFamily = .system
        textSize = .standard
        lineSpacing = .standard
        contentWidth = .standard
        theme = .standard
        pageMargins = .standard
    }
}

private struct ArticleReadingAppearancePreview: View {
    let appearance: ArticleReadingAppearance

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 8) {
                Text("A Better Reading Experience")
                    .font(appearance.titleFont)
                    .contentTransition(.interpolate)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)

                Text(
                    "Adjust the typography and layout until long articles feel comfortable to read."
                )
                .font(appearance.bodyFont)
                .lineSpacing(appearance.lineSpacing.textSpacing)
                .contentTransition(.interpolate)
                .lineLimit(3)
            }
            .foregroundStyle(
                appearance.theme.primaryTextColor(for: colorScheme)
            )
            .padding(.vertical, 16)
            .padding(
                .horizontal,
                appearance.pageMargins.horizontalPadding(
                    for: geometry.size.width
                )
            )
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .leading
            )
            .background(appearance.theme.backgroundColor(for: colorScheme))
        }
        .frame(minHeight: 132)
        .clipShape(.rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
        }
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.2),
            value: appearance
        )
        .animation(
            reduceMotion ? nil : .easeInOut(duration: 0.2),
            value: colorScheme
        )
    }
}

private struct ArticleReadingAppearanceSheetPreview: View {
    @State private var appAppearanceMode = AppAppearanceMode.dark
    @State private var fontFamily = ArticleFontFamily.serif
    @State private var textSize = ArticleTextSize.large
    @State private var lineSpacing = ArticleLineSpacing.relaxed
    @State private var contentWidth = ArticleContentWidth.narrow
    @State private var theme = ArticleReadingTheme.sepia
    @State private var pageMargins = ArticlePageMargins.comfortable

    var body: some View {
        ArticleReadingAppearanceSheet(
            appAppearanceMode: $appAppearanceMode,
            fontFamily: $fontFamily,
            textSize: $textSize,
            lineSpacing: $lineSpacing,
            contentWidth: $contentWidth,
            theme: $theme,
            pageMargins: $pageMargins
        )
        .preferredColorScheme(appAppearanceMode.colorScheme)
    }
}

#Preview("Reading Appearance Sheet") {
    ArticleReadingAppearanceSheetPreview()
}
