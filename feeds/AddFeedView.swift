import SwiftData
import SwiftUI

struct AddFeedView: View {
    let onAdded: (Feed) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @State private var urlText = ""
    @State private var automaticallyExtractsArticleContent = false
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var isURLFieldFocused: Bool

    var body: some View {
        NavigationStack {
            formContent
                .navigationTitle("Add Feed")
                #if !os(macOS)
                    .navigationBarTitleDisplayMode(.inline)
                #endif
                .onAppear {
                    isURLFieldFocused = true
                }
                .interactiveDismissDisabled(isSaving)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .cancel) {
                            dismiss()
                        } label: {
                            Text("Cancel")
                        }
                        .disabled(isSaving)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(role: .confirm, action: addFeed) {
                            if isSaving {
                                ProgressView()
                                    .controlSize(.small)
                                    .accessibilityLabel("Adding feed")
                            } else {
                                Text("Add")
                            }
                        }
                        .disabled(
                            urlText.trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ).isEmpty || isSaving
                        )
                        .accessibilityIdentifier("confirmAddFeedButton")
                    }
                }
                .alert(
                    "Unable to Add Feed",
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
            .frame(minWidth: 520, minHeight: 340)
        #endif
    }

    @ViewBuilder
    private var formContent: some View {
        Form {
            Section {
                urlField
            } header: {
                Text("Feed")
            } footer: {
                Text(
                    "Supports RSS 2.0 and Atom. The feed is validated and its latest articles are downloaded before it is saved."
                )
            }

            Section {
                Toggle(
                    "Automatically Extract Article Content",
                    isOn: $automaticallyExtractsArticleContent
                )
                .accessibilityIdentifier("addFeedAutoExtractToggle")
            } header: {
                Text("Reading")
            } footer: {
                Text(
                    "Extract full content when opening articles from this feed. Previously extracted articles are reused."
                )
            }
        }
        #if os(macOS)
            .formStyle(.grouped)
        #endif
    }

    private var urlField: some View {
        TextField("Feed URL", text: $urlText, prompt: Text("https://"))
            .textContentType(.URL)
            .autocorrectionDisabled()
            .focused($isURLFieldFocused)
            .accessibilityIdentifier("feedURLField")
            #if !os(macOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
            #endif
    }

    private func addFeed() {
        isSaving = true
        Task { @MainActor in
            defer { isSaving = false }
            do {
                let url = try FeedSyncService.normalizedURL(from: urlText)
                let feed = try await FeedSyncService.addFeed(
                    url: url,
                    automaticallyExtractsArticleContent:
                        automaticallyExtractsArticleContent,
                    modelContext: modelContext
                )
                onAdded(feed)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

#Preview("Add Feed") {
    AddFeedView { _ in }
        .modelContainer(PreviewSampleData.makeContainer(populated: false))
}
