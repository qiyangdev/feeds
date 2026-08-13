import SwiftData
import SwiftUI

#if canImport(UIKit)
    import UIKit
#elseif canImport(AppKit)
    import AppKit
#endif

private enum SubscriptionSheet: Identifiable {
    case add
    case edit(Feed)

    var id: String {
        switch self {
        case .add:
            "add"
        case .edit(let feed):
            "edit-\(feed.id.uuidString)"
        }
    }
}

struct SubscriptionsView: View {
    @Binding var selection: SubscriptionSelection?

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Feed.dateAdded) private var allFeeds: [Feed]
    @Query private var articles: [Article]
    @State private var presentedSheet: SubscriptionSheet?
    @State private var errorMessage: String?
    @SceneStorage(SceneStorageKeys.iCloudSectionExpanded)
    private var isICloudExpanded = true

    private var feeds: [Feed] {
        allFeeds.filter(\.isActive)
    }

    private var activeFeedIDs: Set<UUID> {
        Set(feeds.map(\.id))
    }

    private var activeArticles: [Article] {
        articles.filter { activeFeedIDs.contains($0.feedID) }
    }

    var body: some View {
        Group {
            if feeds.isEmpty {
                ContentUnavailableView {
                    Label("No Feeds Yet", systemImage: "dot.radiowaves.left.and.right")
                } description: {
                    Text("Add an RSS or Atom feed to start reading.")
                } actions: {
                    Button("Add Feed") { presentedSheet = .add }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("emptyAddFeedButton")
                }
            } else {
                List(selection: $selection) {
                    Section {
                        NavigationLink(value: SubscriptionSelection.all) {
                            Label("All", systemImage: "tray.full")
                                .badge(activeArticles.count)
                                .accessibilityValue(articleCountDescription)
                        }
                        .tag(SubscriptionSelection.all)
                        .accessibilityIdentifier("allArticlesRow")
                    }

                    Section("iCloud", isExpanded: $isICloudExpanded) {
                        ForEach(feeds) { feed in
                            let unreadCount = unreadCount(for: feed)
                            NavigationLink(
                                value: SubscriptionSelection.feed(feed.id)
                            ) {
                                Label {
                                    Text(feed.title)
                                        .lineLimit(1)
                                } icon: {
                                    FeedIconView(data: feed.iconData)
                                }
                                .badge(unreadCount)
                                .accessibilityValue(
                                    unreadCountDescription(unreadCount)
                                )
                            }
                            .tag(SubscriptionSelection.feed(feed.id))
                            .swipeActions(
                                edge: .trailing,
                                allowsFullSwipe: true
                            ) {
                                Button(role: .destructive) {
                                    deleteFeed(feed)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }

                                Button {
                                    presentedSheet = .edit(feed)
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }
                                .tint(.blue)
                            }
                            .contextMenu {
                                Button {
                                    presentedSheet = .edit(feed)
                                } label: {
                                    Label("Edit", systemImage: "pencil")
                                }

                                Button(role: .destructive) {
                                    deleteFeed(feed)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                        .onDelete(perform: deleteFeeds)
                    }
                }
                .refreshable {
                    await refreshAll()
                }
            }
        }
        .navigationTitle("Feeds")
#if os(iOS)
        .toolbar(
            removing: UIDevice.current.userInterfaceIdiom == .pad
                ? .title : nil
        )
#endif
        .toolbar {
#if !os(macOS)
            ToolbarItem(placement: .topBarLeading) {
                if !feeds.isEmpty { EditButton() }
            }
#endif
            ToolbarItem(placement: .primaryAction) {
                Button {
                    presentedSheet = .add
                } label: {
                    Label("Add Feed", systemImage: "plus")
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .accessibilityIdentifier("addFeedButton")
            }
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .add:
                AddFeedView { feed in
                    selection = .feed(feed.id)
                }
            case .edit(let feed):
                EditFeedView(feed: feed) { updatedFeed in
                    selection = .feed(updatedFeed.id)
                }
            }
        }
        .alert(
            "Operation Failed",
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

    private var articleCountDescription: String {
        activeArticles.count == 1
            ? "1 article"
            : "\(activeArticles.count) articles"
    }

    private func unreadCountDescription(_ count: Int) -> String {
        count == 1 ? "1 unread article" : "\(count) unread articles"
    }

    private func unreadCount(for feed: Feed) -> Int {
        articles.count { $0.feedID == feed.id && !$0.isRead }
    }

    private func deleteFeeds(at offsets: IndexSet) {
        let feedsToDelete = offsets.map { feeds[$0] }
        for feed in feedsToDelete {
            deleteFeed(feed)
        }
    }

    private func deleteFeed(_ feed: Feed) {
        do {
            if selection == .feed(feed.id) { selection = .all }
            try FeedSyncService.delete(feed, modelContext: modelContext)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func refreshAll() async {
        var failures: [String] = []
        for feed in feeds {
            do {
                try await FeedSyncService.refresh(
                    feed,
                    modelContext: modelContext
                )
            } catch {
                failures.append("\(feed.title): \(error.localizedDescription)")
            }
        }
        if !failures.isEmpty {
            errorMessage = failures.joined(separator: "\n")
        }
    }
}

private struct FeedIconView: View {
    let data: Data?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(.secondary.opacity(0.1))

            Group {
                #if canImport(UIKit)
                    if let data, let image = UIImage(data: data) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    } else {
                        placeholder
                    }
                #elseif canImport(AppKit)
                    if let data, let image = NSImage(data: data) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    } else {
                        placeholder
                    }
                #else
                    placeholder
                #endif
            }
            .frame(width: 20, height: 20)
        }
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        Image(systemName: "dot.radiowaves.left.and.right")
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(.tint)
    }
}

#Preview("Feeds") {
    @Previewable @State var selection: SubscriptionSelection? = .all

    NavigationStack {
        SubscriptionsView(selection: $selection)
    }
    .modelContainer(PreviewSampleData.makeContainer())
}

#Preview("Empty Feeds") {
    @Previewable @State var selection: SubscriptionSelection?

    NavigationStack {
        SubscriptionsView(selection: $selection)
    }
    .modelContainer(PreviewSampleData.makeContainer(populated: false))
}
