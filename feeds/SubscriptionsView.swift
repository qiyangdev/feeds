import Combine
import CoreData
import OSLog
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

private let subscriptionCountLogger = Logger(
    subsystem: "dev.qiyang.feeds",
    category: "SubscriptionCounts"
)

private struct SubscriptionCountRequest: Hashable {
    let feedIDs: [UUID]
    let revision: Int
}

struct SubscriptionsView: View {
    @Binding var selection: SubscriptionSelection?

    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Feed.dateAdded) private var allFeeds: [Feed]
    @State private var presentedSheet: SubscriptionSheet?
    @State private var errorMessage: String?
    @State private var articleCounts = SubscriptionArticleCounts.empty
    @State private var countRevision = 0
    @State private var countController = SubscriptionArticleCountController()
    @SceneStorage(SceneStorageKeys.iCloudSectionExpanded)
    private var isICloudExpanded = true

    private var feeds: [Feed] {
        allFeeds.filter(\.isActive)
    }

    private var activeFeedIDs: Set<UUID> {
        Set(feeds.map(\.id))
    }

    private var countRequest: SubscriptionCountRequest {
        SubscriptionCountRequest(
            feedIDs: activeFeedIDs.sorted {
                $0.uuidString < $1.uuidString
            },
            revision: countRevision
        )
    }

    var body: some View {
        Group {
            if feeds.isEmpty {
                ContentUnavailableView {
                    Label(
                        "No Feeds Yet",
                        systemImage: "dot.radiowaves.left.and.right"
                    )
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
                                .badge(articleCounts.total)
                                .accessibilityValue(
                                    articleCountDescription(articleCounts.total)
                                )
                        }
                        .tag(SubscriptionSelection.all)
                        .accessibilityIdentifier("allArticlesRow")
                    }

                    Section("iCloud", isExpanded: $isICloudExpanded) {
                        ForEach(feeds) { feed in
                            let unreadCount = articleCounts.unreadCount(
                                for: feed.id
                            )
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
        .onReceive(
            NotificationCenter.default.publisher(for: ModelContext.didSave)
                .receive(on: DispatchQueue.main)
        ) { _ in
            countRevision &+= 1
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSPersistentCloudKitContainer.eventChangedNotification
            )
            .receive(on: DispatchQueue.main)
        ) { notification in
            guard
                let event = notification.userInfo?[
                    NSPersistentCloudKitContainer.eventNotificationUserInfoKey
                ] as? NSPersistentCloudKitContainer.Event,
                event.type == .import,
                event.endDate != nil,
                event.succeeded
            else {
                return
            }
            countRevision &+= 1
        }
        .task(id: countRequest) {
            let modelContainer = modelContext.container
            do {
                try await Task.sleep(for: .milliseconds(100))
                try Task.checkCancellation()
                let counts = try await countController.counts(
                    in: modelContainer,
                    activeFeedIDs: countRequest.feedIDs
                )
                try Task.checkCancellation()
                articleCounts = counts
            } catch {
                guard !(error is CancellationError) else { return }
                subscriptionCountLogger.error(
                    "Unable to update subscription counts: \(error.localizedDescription, privacy: .public)"
                )
            }
        }
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

    private func articleCountDescription(_ count: Int) -> String {
        count == 1
            ? "1 article"
            : "\(count) articles"
    }

    private func unreadCountDescription(_ count: Int) -> String {
        count == 1 ? "1 unread article" : "\(count) unread articles"
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

nonisolated struct SubscriptionArticleCounts: Equatable, Sendable {
    static let empty = SubscriptionArticleCounts(
        total: 0,
        unreadByFeedID: [:]
    )

    let total: Int
    private let unreadByFeedID: [UUID: Int]

    init(total: Int, unreadByFeedID: [UUID: Int]) {
        self.total = total
        self.unreadByFeedID = unreadByFeedID
    }

    init(articles: [Article], activeFeedIDs: Set<UUID>) {
        var total = 0
        var unreadByFeedID: [UUID: Int] = [:]

        for article in articles where activeFeedIDs.contains(article.feedID) {
            total += 1
            if !article.isRead {
                unreadByFeedID[article.feedID, default: 0] += 1
            }
        }

        self.init(total: total, unreadByFeedID: unreadByFeedID)
    }

    func unreadCount(for feedID: UUID) -> Int {
        unreadByFeedID[feedID, default: 0]
    }
}

private struct FeedIconView: View {
    let data: Data?
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7)
                .fill(.secondary.opacity(0.1))

            Group {
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else {
                    placeholder
                }
            }
            .frame(width: 20, height: 20)
        }
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)
        .task(id: data) {
            image = nil
            let thumbnail = await FeedIconService.thumbnail(from: data)
            guard !Task.isCancelled else { return }
            image = thumbnail
        }
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
