import AVFoundation
import Combine
import SwiftUI

#if os(iOS) || os(visionOS)
    import AVFAudio
#endif

private actor ArticleAudioSessionCoordinator {
    static let shared = ArticleAudioSessionCoordinator()

    private var activeOwners: Set<UUID> = []
    private var latestGenerationByOwner: [UUID: UInt64] = [:]

    func setActive(
        _ shouldBeActive: Bool,
        owner: UUID,
        generation: UInt64
    ) throws -> Bool {
        guard generation >= (latestGenerationByOwner[owner] ?? 0) else {
            return false
        }
        latestGenerationByOwner[owner] = generation

        #if os(iOS) || os(visionOS)
            let session = AVAudioSession.sharedInstance()
            if shouldBeActive {
                if activeOwners.isEmpty {
                    try session.setCategory(.playback, mode: .spokenAudio)
                    try session.setActive(true)
                }
                activeOwners.insert(owner)
            } else {
                activeOwners.remove(owner)
                if activeOwners.isEmpty {
                    try session.setActive(
                        false,
                        options: .notifyOthersOnDeactivation
                    )
                }
                latestGenerationByOwner.removeValue(forKey: owner)
            }
        #else
            if shouldBeActive {
                activeOwners.insert(owner)
            } else {
                activeOwners.remove(owner)
                latestGenerationByOwner.removeValue(forKey: owner)
            }
        #endif
        return true
    }
}

@MainActor
final class ArticleAudioPlaybackController: ObservableObject {
    enum PlaybackState: Equatable {
        case idle
        case loading
        case playing
        case paused
        case failed
    }

    @Published private(set) var activeAudioID: String?
    @Published private(set) var activeSourceURL: URL?
    @Published private(set) var state: PlaybackState = .idle
    @Published private(set) var position: TimeInterval = 0
    @Published private(set) var duration: TimeInterval?
    @Published private(set) var isBuffering = false
    @Published private(set) var errorMessage: String?

    private let player = AVPlayer()
    private var sources: [ArticleAudioSource] = []
    private var sourceIndex = 0
    private var wantsPlayback = false
    private var playbackGeneration: UInt64 = 0
    private let audioSessionOwner = UUID()
    private var audioSessionGeneration: UInt64 = 0
    private var preparationTask: Task<Void, Never>?
    private var activationTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var timeControlObservation: NSKeyValueObservation?
    private var itemStatusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var failureObserver: NSObjectProtocol?
    #if os(iOS) || os(visionOS)
        private var interruptionObserver: NSObjectProtocol?
        private var routeChangeObserver: NSObjectProtocol?
        private var resumesAfterInterruption = false
    #endif

    init() {
        installPlayerObservation()
        installAudioSessionObservers()
    }

    func toggle(_ audio: ArticleAudioDescriptor) {
        guard !audio.sources.isEmpty else { return }
        if activeAudioID != audio.id {
            start(audio)
            return
        }

        switch state {
        case .loading, .playing:
            pause()
        case .paused:
            playCurrentSource()
        case .failed, .idle:
            start(audio)
        }
    }

    func seek(to requestedTime: TimeInterval) {
        guard activeAudioID != nil,
            let duration,
            duration.isFinite,
            duration > 0
        else {
            return
        }
        let clampedTime = min(max(0, requestedTime), duration)
        position = clampedTime
        let tolerance = CMTime(seconds: 0.25, preferredTimescale: 600)
        player.seek(
            to: CMTime(seconds: clampedTime, preferredTimescale: 600),
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        )
    }

    func skip(by interval: TimeInterval) {
        seek(to: position + interval)
    }

    func stop() {
        playbackGeneration &+= 1
        preparationTask?.cancel()
        preparationTask = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        removeItemObservers()
        activeAudioID = nil
        activeSourceURL = nil
        sources = []
        sourceIndex = 0
        wantsPlayback = false
        position = 0
        duration = nil
        isBuffering = false
        errorMessage = nil
        state = .idle
        requestAudioSession(active: false)
    }

    func pause() {
        guard activeAudioID != nil else { return }
        pausePlayback()
    }

    func shutdown() {
        stop()
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
        removeAudioSessionObservers()
    }

    private func start(_ audio: ArticleAudioDescriptor) {
        stop()
        installAudioSessionObservers()
        activeAudioID = audio.id
        sources = audio.sources
        sourceIndex = 0
        wantsPlayback = true
        prepareCurrentSource()
    }

    private func prepareCurrentSource() {
        guard sources.indices.contains(sourceIndex) else {
            failPlayback("None of this article's audio sources could be played.")
            return
        }

        playbackGeneration &+= 1
        let generation = playbackGeneration
        preparationTask?.cancel()
        removeItemObservers()
        position = 0
        duration = nil
        isBuffering = wantsPlayback
        errorMessage = nil
        state = wantsPlayback ? .loading : .paused

        let source = sources[sourceIndex]
        activeSourceURL = source.url
        let item = AVPlayerItem(url: source.url)
        player.replaceCurrentItem(with: item)
        installTimeObserverIfNeeded()
        installItemObservers(for: item, generation: generation)
        if wantsPlayback {
            beginPlayback(item: item, generation: generation)
        }

        preparationTask = Task { @MainActor [weak self, weak item] in
            guard let self, let item else { return }
            do {
                let isPlayable = try await item.asset.load(.isPlayable)
                try Task.checkCancellation()
                guard generation == playbackGeneration,
                    player.currentItem === item
                else {
                    return
                }
                guard isPlayable else {
                    tryNextSource(
                        after: "This audio format is not playable."
                    )
                    return
                }

                if let loadedDuration = try? await item.asset.load(.duration) {
                    let seconds = loadedDuration.seconds
                    if seconds.isFinite && seconds > 0 {
                        duration = seconds
                    }
                }
                guard generation == playbackGeneration,
                    player.currentItem === item
                else {
                    return
                }
                isBuffering = wantsPlayback
                    && player.timeControlStatus
                        == .waitingToPlayAtSpecifiedRate
                if !wantsPlayback, state != .failed {
                    state = .paused
                }
            } catch is CancellationError {
                return
            } catch {
                guard generation == playbackGeneration else { return }
                tryNextSource(after: error.localizedDescription)
            }
        }
    }

    private func playCurrentSource() {
        wantsPlayback = true
        guard let item = player.currentItem else {
            prepareCurrentSource()
            return
        }
        if let duration, position >= duration - 0.5 {
            seek(to: 0)
        }
        beginPlayback(item: item, generation: playbackGeneration)
    }

    private func pausePlayback() {
        guard activeAudioID != nil else { return }
        wantsPlayback = false
        player.pause()
        state = .paused
        isBuffering = false
        requestAudioSession(active: false)
    }

    private func tryNextSource(after failure: String) {
        guard sourceIndex + 1 < sources.count else {
            failPlayback(failure)
            return
        }
        sourceIndex += 1
        prepareCurrentSource()
    }

    private func failPlayback(_ message: String) {
        playbackGeneration &+= 1
        preparationTask?.cancel()
        preparationTask = nil
        player.pause()
        removeItemObservers()
        wantsPlayback = false
        isBuffering = false
        errorMessage = message
        state = .failed
        requestAudioSession(active: false)
    }

    private func beginPlayback(
        item: AVPlayerItem,
        generation: UInt64
    ) {
        guard wantsPlayback else { return }
        state = .loading
        isBuffering = true
        let sessionRequest = nextAudioSessionRequest()
        activationTask?.cancel()
        activationTask = Task { @MainActor [weak self, weak item] in
            guard let self, let item else { return }
            do {
                let accepted = try await ArticleAudioSessionCoordinator.shared
                    .setActive(
                        true,
                        owner: sessionRequest.owner,
                        generation: sessionRequest.generation
                    )
                try Task.checkCancellation()
                guard accepted,
                    generation == playbackGeneration,
                    player.currentItem === item,
                    wantsPlayback
                else {
                    return
                }
                player.play()
                synchronizePlaybackState()
            } catch is CancellationError {
                return
            } catch {
                guard generation == playbackGeneration, wantsPlayback else {
                    return
                }
                failPlayback(error.localizedDescription)
            }
        }
    }

    private func requestAudioSession(active: Bool) {
        if !active {
            activationTask?.cancel()
            activationTask = nil
        }
        let request = nextAudioSessionRequest()
        Task.detached {
            _ = try? await ArticleAudioSessionCoordinator.shared.setActive(
                active,
                owner: request.owner,
                generation: request.generation
            )
        }
    }

    private func nextAudioSessionRequest() -> (
        owner: UUID,
        generation: UInt64
    ) {
        audioSessionGeneration &+= 1
        return (audioSessionOwner, audioSessionGeneration)
    }

    private func installTimeObserverIfNeeded() {
        guard timeObserver == nil else { return }
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            Task { @MainActor [weak self] in
                guard let self, activeAudioID != nil else { return }
                let seconds = time.seconds
                if seconds.isFinite && seconds >= 0 {
                    position = seconds
                }
                synchronizePlaybackState()
            }
        }
    }

    private func installPlayerObservation() {
        timeControlObservation = player.observe(
            \.timeControlStatus,
            options: [.new]
        ) { [weak self] _, _ in
            Task { @MainActor [weak self] in
                self?.synchronizePlaybackState()
            }
        }
    }

    private func synchronizePlaybackState() {
        guard activeAudioID != nil, state != .failed else { return }
        switch player.timeControlStatus {
        case .playing:
            guard wantsPlayback else {
                player.pause()
                return
            }
            state = .playing
            isBuffering = false
        case .waitingToPlayAtSpecifiedRate:
            if wantsPlayback {
                state = .loading
                isBuffering = true
            }
        case .paused:
            isBuffering = false
            if state == .playing {
                wantsPlayback = false
                state = .paused
                requestAudioSession(active: false)
            } else if !wantsPlayback {
                state = .paused
            }
        @unknown default:
            break
        }
    }

    private func installItemObservers(
        for item: AVPlayerItem,
        generation: UInt64
    ) {
        itemStatusObservation = item.observe(
            \.status,
            options: [.new]
        ) { [weak self, weak item] _, _ in
            Task { @MainActor [weak self, weak item] in
                guard let self, let item,
                    generation == playbackGeneration,
                    player.currentItem === item,
                    item.status == .failed
                else {
                    return
                }
                tryNextSource(
                    after: item.error?.localizedDescription
                        ?? "Audio playback failed."
                )
            }
        }

        endObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, generation == playbackGeneration else {
                    return
                }
                player.pause()
                player.seek(to: .zero)
                wantsPlayback = false
                position = 0
                isBuffering = false
                state = .paused
                requestAudioSession(active: false)
            }
        }

        failureObserver = NotificationCenter.default.addObserver(
            forName: AVPlayerItem.failedToPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { [weak self] notification in
            let message = (
                notification.userInfo?[
                    AVPlayerItemFailedToPlayToEndTimeErrorKey
                ] as? Error
            )?.localizedDescription ?? "Audio playback failed."
            Task { @MainActor [weak self] in
                guard let self, generation == playbackGeneration else {
                    return
                }
                tryNextSource(after: message)
            }
        }
    }

    private func removeItemObservers() {
        itemStatusObservation?.invalidate()
        itemStatusObservation = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
        if let failureObserver {
            NotificationCenter.default.removeObserver(failureObserver)
            self.failureObserver = nil
        }
    }

    private func installAudioSessionObservers() {
        #if os(iOS) || os(visionOS)
            guard interruptionObserver == nil,
                routeChangeObserver == nil
            else {
                return
            }
            let center = NotificationCenter.default
            interruptionObserver = center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor [weak self] in
                    self?.handleInterruption(notification)
                }
            }
            routeChangeObserver = center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: AVAudioSession.sharedInstance(),
                queue: .main
            ) { [weak self] notification in
                Task { @MainActor [weak self] in
                    self?.handleRouteChange(notification)
                }
            }
        #endif
    }

    private func removeAudioSessionObservers() {
        #if os(iOS) || os(visionOS)
            let center = NotificationCenter.default
            if let interruptionObserver {
                center.removeObserver(interruptionObserver)
                self.interruptionObserver = nil
            }
            if let routeChangeObserver {
                center.removeObserver(routeChangeObserver)
                self.routeChangeObserver = nil
            }
        #endif
    }

    #if os(iOS) || os(visionOS)
        private func handleInterruption(_ notification: Notification) {
            guard let rawType = notification.userInfo?[
                AVAudioSessionInterruptionTypeKey
            ] as? UInt,
                let type = AVAudioSession.InterruptionType(rawValue: rawType)
            else {
                return
            }

            switch type {
            case .began:
                resumesAfterInterruption = wantsPlayback
                pausePlayback()
            case .ended:
                let rawOptions = notification.userInfo?[
                    AVAudioSessionInterruptionOptionKey
                ] as? UInt ?? 0
                let shouldResume = AVAudioSession.InterruptionOptions(
                    rawValue: rawOptions
                ).contains(.shouldResume)
                let resume = resumesAfterInterruption && shouldResume
                resumesAfterInterruption = false
                if resume, activeAudioID != nil {
                    playCurrentSource()
                }
            @unknown default:
                break
            }
        }

        private func handleRouteChange(_ notification: Notification) {
            guard let rawReason = notification.userInfo?[
                AVAudioSessionRouteChangeReasonKey
            ] as? UInt,
                AVAudioSession.RouteChangeReason(rawValue: rawReason)
                    == .oldDeviceUnavailable
            else {
                return
            }
            resumesAfterInterruption = false
            pausePlayback()
        }
    #endif
}

struct ArticleAudioPlayerView: View {
    let audio: ArticleAudioDescriptor
    @ObservedObject var controller: ArticleAudioPlaybackController
    let appearance: ArticleReadingAppearance

    @Environment(\.colorScheme) private var systemColorScheme
    @State private var scrubPosition: TimeInterval = 0
    @State private var isScrubbing = false

    private var isActive: Bool {
        controller.activeAudioID == audio.id
    }

    private var duration: TimeInterval? {
        guard isActive,
            let duration = controller.duration,
            duration.isFinite,
            duration > 0
        else {
            return nil
        }
        return duration
    }

    private var displayedPosition: TimeInterval {
        isScrubbing ? scrubPosition : (isActive ? controller.position : 0)
    }

    private var displayedSourceURL: URL? {
        if isActive, let activeSourceURL = controller.activeSourceURL {
            return activeSourceURL
        }
        return audio.sources.first?.url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "waveform")
                    .font(.title3)
                    .foregroundStyle(
                        appearance.theme.accentColor(for: systemColorScheme)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(audio.label ?? "Article Audio")
                        .font(.headline)
                        .lineLimit(2)
                    if let host = displayedSourceURL?.host() {
                        Text(
                            audio.sources.count == 1
                                ? host
                                : "\(host) · \(audio.sources.count) sources"
                        )
                        .font(.caption)
                        .foregroundStyle(
                            appearance.theme.secondaryTextColor(
                                for: systemColorScheme
                            )
                        )
                    }
                }

                Spacer(minLength: 8)

                if let sourceURL = displayedSourceURL {
                    Link(destination: sourceURL) {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .buttonStyle(.plain)
                    .help("Open audio source")
                    .accessibilityLabel("Open audio source")
                }
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    transportControls
                    progressControls
                }

                VStack(spacing: 8) {
                    transportControls
                    progressControls
                }
            }

            if isActive,
                controller.state == .failed,
                let errorMessage = controller.errorMessage
            {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(
            appearance.theme.accentColor(for: systemColorScheme)
                .opacity(0.08),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    appearance.theme.accentColor(for: systemColorScheme)
                        .opacity(0.2)
                )
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("articleAudioPlayer")
    }

    private var transportControls: some View {
        HStack(spacing: 8) {
            Button {
                controller.skip(by: -15)
            } label: {
                Image(systemName: "gobackward.15")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isActive || controller.position <= 0)
            .accessibilityLabel("Go back 15 seconds")

            Button {
                controller.toggle(audio)
            } label: {
                Group {
                    if isActive
                        && controller.state == .loading
                        && controller.isBuffering
                    {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(
                            systemName: isActive
                                && controller.state == .playing
                                ? "pause.fill" : "play.fill"
                        )
                    }
                }
                .frame(width: 20, height: 20)
                .padding(12)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.circle)
            .accessibilityLabel(
                isActive && controller.state == .playing
                    ? "Pause audio" : "Play audio"
            )

            Button {
                controller.skip(by: 15)
            } label: {
                Image(systemName: "goforward.15")
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isActive || duration == nil)
            .accessibilityLabel("Go forward 15 seconds")
        }
    }

    private var progressControls: some View {
        HStack(spacing: 8) {
            Text(Self.formattedTime(displayedPosition))
                .font(.caption.monospacedDigit())
                .foregroundStyle(
                    appearance.theme.secondaryTextColor(
                        for: systemColorScheme
                    )
                )

            if let duration {
                Slider(
                    value: Binding(
                        get: { displayedPosition },
                        set: { scrubPosition = $0 }
                    ),
                    in: 0...duration,
                    onEditingChanged: { editing in
                        isScrubbing = editing
                        if editing {
                            scrubPosition = controller.position
                        } else {
                            controller.seek(to: scrubPosition)
                        }
                    }
                )
                .frame(minWidth: 120)
                .accessibilityLabel("Audio position")
                .accessibilityValue(
                    "\(Self.formattedTime(displayedPosition)) of \(Self.formattedTime(duration))"
                )

                Text(Self.formattedTime(duration))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(
                        appearance.theme.secondaryTextColor(
                            for: systemColorScheme
                        )
                    )
            } else {
                Spacer(minLength: 120)
                Text("–:––")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(
                        appearance.theme.secondaryTextColor(
                            for: systemColorScheme
                        )
                    )
                    .accessibilityLabel("Audio duration unavailable")
            }
        }
        .frame(maxWidth: .infinity)
    }

    private static func formattedTime(_ interval: TimeInterval) -> String {
        guard interval.isFinite, interval >= 0 else { return "0:00" }
        let totalSeconds = Int(interval.rounded(.down))
        let hours = totalSeconds / 3_600
        let minutes = (totalSeconds % 3_600) / 60
        let seconds = totalSeconds % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
