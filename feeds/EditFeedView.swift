import SwiftData
import SwiftUI

struct EditFeedView: View {
    let feed: Feed
    let onUpdated: (Feed) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var title: String
    @State private var urlText: String
    @State private var automaticallyExtractsArticleContent: Bool
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(feed: Feed, onUpdated: @escaping (Feed) -> Void = { _ in }) {
        self.feed = feed
        self.onUpdated = onUpdated
        _title = State(initialValue: feed.title)
        _urlText = State(initialValue: feed.feedURLString)
        _automaticallyExtractsArticleContent = State(
            initialValue: feed.automaticallyExtractsArticleContent
        )
    }

    var body: some View {
        NavigationStack {
            formContent
                .navigationTitle("Edit Feed")
                #if !os(macOS)
                    .navigationBarTitleDisplayMode(.inline)
                #endif
                .interactiveDismissDisabled(isSaving)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                            .disabled(isSaving)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(action: save) {
                            if isSaving {
                                ProgressView()
                                    .controlSize(.small)
                                    .accessibilityLabel("Saving feed")
                            } else {
                                Text("Save")
                            }
                        }
                        .disabled(isSaveDisabled)
                        .accessibilityIdentifier("confirmEditFeedButton")
                    }
                }
                .alert(
                    "Unable to Save Feed",
                    isPresented: Binding(
                        get: { errorMessage != nil },
                        set: { if !$0 { errorMessage = nil } }
                    )
                ) {
                    Button("OK", role: .cancel) { errorMessage = nil }
                } message: {
                    Text(errorMessage ?? "Unknown error")
                }
        }
        #if os(macOS)
            .frame(minWidth: 520, minHeight: 320)
        #endif
    }

    @ViewBuilder
    private var formContent: some View {
        #if os(macOS)
            VStack(alignment: .leading, spacing: 12) {
                Grid(
                    alignment: .leadingFirstTextBaseline,
                    horizontalSpacing: 12,
                    verticalSpacing: 12
                ) {
                    GridRow {
                        Text("Name")
                        titleField
                    }
                    GridRow {
                        Text("Feed URL")
                        urlField
                    }
                    GridRow {
                        Text("Reading")
                        autoExtractToggle
                    }
                }
                Text(
                    "Changing the URL validates the new feed and replaces the articles from the previous source."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(
                    "When automatic extraction is enabled, opening an article extracts its full web content. Previously extracted content is reused."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(20)
        #else
            Form {
                Section("Name") {
                    titleField
                }

                Section {
                    urlField
                } header: {
                    Text("Feed URL")
                } footer: {
                    Text(
                        "Changing the URL validates the new feed and replaces the articles from the previous source."
                    )
                }

                Section {
                    autoExtractToggle
                } header: {
                    Text("Reading")
                } footer: {
                    Text(
                        "Extract full content when opening articles from this feed. Previously extracted articles are reused."
                    )
                }
            }
        #endif
    }

    private var titleField: some View {
        TextField("Feed Name", text: $title)
            .accessibilityIdentifier("editFeedTitleField")
    }

    private var urlField: some View {
        TextField("https://example.com/feed.xml", text: $urlText)
            .textContentType(.URL)
            #if !os(macOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            #endif
            .autocorrectionDisabled()
            .accessibilityIdentifier("editFeedURLField")
    }

    private var autoExtractToggle: some View {
        Toggle(
            "Automatically Extract Article Content",
            isOn: $automaticallyExtractsArticleContent
        )
        .accessibilityIdentifier("editFeedAutoExtractToggle")
    }

    private var isSaveDisabled: Bool {
        title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || urlText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || isSaving
    }

    private func save() {
        isSaving = true
        Task { @MainActor in
            defer { isSaving = false }
            do {
                let url = try FeedSyncService.normalizedURL(from: urlText)
                let updatedFeed = try await FeedSyncService.updateFeed(
                    feed,
                    title: title,
                    url: url,
                    automaticallyExtractsArticleContent:
                        automaticallyExtractsArticleContent,
                    modelContext: modelContext
                )
                onUpdated(updatedFeed)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

#Preview("Edit Feed") {
    let container = PreviewSampleData.makeContainer()

    EditFeedView(feed: PreviewSampleData.primaryFeed(in: container))
        .modelContainer(container)
}
