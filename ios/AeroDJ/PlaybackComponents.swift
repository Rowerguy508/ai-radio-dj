import AeroDJCore
import SwiftUI

/// Contract-owned shared leaf views (ui-contract.md §11). Each renders values and
/// sends intents, never owns a service. Previews use `PlaybackFixtures` and Fry's
/// sample station state. Nothing here reads a device model or size class for layout.

// MARK: - ArtworkView

/// Square artwork, scaled frame (`size` in points, from the container). Placeholder
/// is a system-tinted rounded rectangle with a music note — never a spinner.
struct ArtworkView: View {
    let url: URL?
    let size: CGFloat

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .failure, .empty:
                        placeholder
                    @unknown default:
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var placeholder: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.quaternary)
            .overlay(
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.28, weight: .medium))
                    .foregroundStyle(.secondary)
            )
    }
}

// MARK: - DJStatusLine

/// Truthful DJ line from `DJPresentationState` (§2.3). The LIVE badge is the only
/// red element and appears only while `.isLive` (real speech audio playing). The
/// spoken line text comes from `snapshot.dj`, not rendered as a second status.
struct DJStatusLine: View {
    let state: DJPresentationState
    let spokenLine: String?
    let onReview: (() -> Void)?

    init(state: DJPresentationState, spokenLine: String? = nil, onReview: (() -> Void)? = nil) {
        self.state = state
        self.spokenLine = spokenLine
        self.onReview = onReview
    }

    var body: some View {
        switch state {
        case .speaking:
            if let spokenLine, !spokenLine.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    liveBadge
                    Text(spokenLine)
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .truncationMode(.tail)
                        .accessibilityLabel(spokenLine)
                }
            } else {
                liveBadge
            }
        case .preparing:
            Text("DJ is getting ready")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .ready(_, let includesBriefing, _):
            Text(includesBriefing ? "Briefing after this song" : "Up next: DJ after this song")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .unavailable(let reason):
            switch reason {
            case .consentReviewRequired(let n):
                Button("\(n) to review") { onReview?() }
                    .font(.subheadline.weight(.medium))
            case .voiceFailed, .budgetReached:
                Text("DJ voice unavailable")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        case .idle:
            EmptyView()
        }
    }

    private var liveBadge: some View {
        Text("LIVE")
            .font(.caption.weight(.bold))
            .foregroundStyle(Color.white)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(.red))
    }
}

// MARK: - TransportRow

/// Unified transport: Play/Pause (64 pt min target) and Skip (44 pt min).
/// Haptics fire only on user actions, never on snapshot/DJ changes.
struct TransportRow: View {
    let transport: TransportState
    let actions: PlaybackActions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 32) {
            Button {
                if transport == .playing { actions.pause() }
                else { Task { await actions.resume() } }
            } label: {
                Image(systemName: transport == .playing ? "pause.fill" : "play.fill")
                    .font(.system(size: 40, weight: .medium))
                    .frame(width: 64, height: 64)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(transport == .playing ? "Pause" : "Play")
            .sensoryFeedback(.impact, trigger: transport)

            Button {
                Task { await actions.skip() }
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 28, weight: .medium))
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Skip")
            .sensoryFeedback(.impact, trigger: transport == .playing ? 1 : 2)
        }
        .animation(reduceMotion ? .none : .default, value: transport)
    }
}

// MARK: - QueueAffordance

/// Single row under transport in compact: "Up next: <first>" + chevron. Never
/// shows a bare count. Tap opens the queue (sheet in compact, workspace in Studio).
struct QueueAffordance: View {
    let upNext: [TrackInfo]
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text("Up next: \(upNext.first?.title ?? "nothing queued")")
                    .font(.subheadline)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - PlaybackErrorBanner

/// Renders a `PlaybackError` per §9 without blaming the user. Recoverable
/// failures show Try again + Dismiss and leave transport in place; others state
/// what is needed. Speech failures are a subtle caption, never a modal.
struct PlaybackErrorBanner: View {
    let error: PlaybackError?
    let actions: PlaybackActions

    var body: some View {
        if let error {
            switch error.kind {
            case .notAuthorized:
                errorCard(
                    title: "Allow Apple Music to play your station.",
                    detail: nil,
                    primary: AnyView(Button("Allow") { /* routes to system prompt (engine-owned) */ }.buttonStyle(.borderedProminent)),
                    dismiss: nil
                )
            case .subscriptionRequired:
                errorCard(
                    title: "An Apple Music subscription is required.",
                    detail: nil,
                    primary: nil,
                    dismiss: nil
                )
            case .resumeFailed:
                errorCard(
                    title: error.message,
                    detail: nil,
                    primary: AnyView(Button("Try again") {
                        Task { await actions.resume() }
                    }.buttonStyle(.borderedProminent)),
                    dismiss: AnyView(Button("Dismiss") { actions.dismissError() })
                )
            case .playbackFailed where error.isRecoverable:
                errorCard(
                    title: error.message,
                    detail: nil,
                    primary: AnyView(Button("Try again") { actions.dismissError() }.buttonStyle(.borderedProminent)),
                    dismiss: AnyView(Button("Dismiss") { actions.dismissError() })
                )
            case .playbackFailed:
                errorCard(
                    title: error.message,
                    detail: nil,
                    primary: nil,
                    dismiss: AnyView(Button("Dismiss") { actions.dismissError() })
                )
            case .speechFailed:
                // Subtle caption; music continues. Never a modal.
                Label(error.message, systemImage: "speaker.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func errorCard(title: String, detail: String?, primary: AnyView?, dismiss: AnyView?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: "exclamationmark.triangle")
                .font(.subheadline.weight(.semibold))
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                if let primary { primary }
                if let dismiss { dismiss }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Previews

/// `PlaybackActions` is `@MainActor`; previews construct it on the main actor.
private func previewActions() -> PlaybackActions {
    MainActor.assumeIsolated {
        PlaybackActions(pause: {}, resume: {}, skip: {}, dismissError: {}, editUpNext: { _ in })
    }
}

#Preview("Speaking") {
    VStack(spacing: 16) {
        DJStatusLine(state: .speaking(afterTrack: 0, includesBriefing: false),
                     spokenLine: PlaybackFixtures.djSpeaking.dj.speakingLine)
    }
    .padding()
}

#Preview("Ready / preparing / unavailable / idle") {
    VStack(alignment: .leading, spacing: 16) {
        DJStatusLine(state: .ready(afterTrack: 0, includesBriefing: false, seconds: 12))
        DJStatusLine(state: .preparing(afterTrack: 0, includesBriefing: true))
        DJStatusLine(state: .unavailable(.consentReviewRequired(pendingCount: 3)), onReview: {})
        DJStatusLine(state: .unavailable(.voiceFailed))
        DJStatusLine(state: .idle)
    }
    .padding()
}

#Preview("Artwork") {
    HStack(spacing: 16) {
        ArtworkView(url: nil, size: 160)
        ArtworkView(url: nil, size: 96)
    }
    .padding()
}

#Preview("Transport") {
    let playing = previewActions()
    VStack(spacing: 24) {
        TransportRow(transport: .playing, actions: playing)
        TransportRow(transport: .paused, actions: playing)
    }
    .padding()
}

#Preview("Queue affordance") {
    QueueAffordance(upNext: PlaybackFixtures.playing.upNext) {}
        .padding()
}

#Preview("Playback error states") {
    let actions = previewActions()
    return VStack(spacing: 12) {
        PlaybackErrorBanner(error: PlaybackFixtures.recoverableError.error, actions: actions)
        PlaybackErrorBanner(error: PlaybackError(kind: .notAuthorized, message: "denied", isRecoverable: false), actions: actions)
        PlaybackErrorBanner(error: PlaybackError(kind: .speechFailed, message: "The DJ line could not play.", isRecoverable: true), actions: actions)
    }
    .padding()
}
