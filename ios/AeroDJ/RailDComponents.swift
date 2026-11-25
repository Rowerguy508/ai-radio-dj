import AeroDJCore
import SwiftUI

// Mockup D (owner: "Yes, build it"): the pieces the iPhone, the closed Duo and the open Duo
// rails share. Layout numbers live in `RailDLayout` (AeroDJCore) so Linux tests them. Playback
// is not touched here: the bar seeks through the same `PlaybackScrubber.Seek` closure and
// `ScrubberState` as the horizontal scrubber it replaces. -Nova

/// What the rail needs to draw the song-position bar. Nil when there is no track or no
/// known duration; the rail then keeps its spacer above the live dot.
struct RailScrubberInput {
    let time: PlaybackTimeSource
    let transport: TransportState
    let trackID: String?
    let canSeek: Bool
    let onSeek: PlaybackScrubber.Seek?
    var isDJSpeaking: Bool = false
}

/// The vertical song-position bar in the lower rail. Elapsed above, remaining below, the fill
/// running top to bottom. One adjustable VoiceOver element ("Song position", swipe up seeks
/// forward). The drag is claimed only after a short, mostly vertical move, so the trailing-edge
/// rail does not fight Control Center, the home indicator or a sideways swipe.
struct RailScrubber: View {
    let input: RailScrubberInput

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var scrub = ScrubberState()
    @State private var elementHeight: CGFloat = 0
    @State private var claimed = false
    @State private var dragStarts = 0
    @State private var commits = 0
    @GestureState private var isTouching = false

    private var isWired: Bool { input.onSeek != nil }
    private var isInteractive: Bool { isWired && input.canSeek }

    private var key: PlaybackProgressClock.Key {
        PlaybackProgressClock.Key(transport: input.transport, trackID: input.trackID)
    }

    var body: some View {
        // As in `PlaybackScrubber`, the gesture sits outside the TimelineView, which `.id(key)`
        // rebuilds on a transport or track change.
        TimelineView(.periodic(from: .now, by: PlaybackProgressClock.interval(for: key, reduceMotion: reduceMotion))) { context in
            let _ = context.date
            let duration = input.time.duration() ?? 0
            let snapshotPosition = max(0, input.time.elapsed())
            let shown = duration > 0
                ? scrub.displayedPosition(snapshotPosition: snapshotPosition, duration: duration, now: Self.now())
                : 0
            bar(position: shown, duration: duration)
        }
        .id(key)
        .frame(width: CGFloat(RailDLayout.scrubberWidth))
        .frame(minHeight: CGFloat(RailDLayout.scrubberChrome + RailDLayout.minTrackLength), maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.height }, action: { elementHeight = $0 })
        .opacity(isWired && !input.canSeek ? 0.5 : 1)
        .contentShape(Rectangle())
        .gesture(scrubGesture, including: isInteractive ? .all : .subviews)
        .sensoryFeedback(.selection, trigger: dragStarts)
        .sensoryFeedback(.selection, trigger: commits)
        .onAppear { scrub.trackChanged(to: input.trackID) }
        .onChange(of: input.trackID) { _, new in scrub.trackChanged(to: new) }
        .onChange(of: input.canSeek) { _, new in scrub.canSeekChanged(new) }
        .onChange(of: isTouching) { _, touching in
            guard !touching else { return }
            Task { @MainActor in
                scrub.cancelDrag()
                claimed = false
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("folded.railScrubber")
    }

    private func bar(position: TimeInterval, duration: TimeInterval) -> some View {
        let fraction = ScrubberState.fraction(position: position, duration: duration)
        let dragging = scrub.isDragging
        return VStack(spacing: CGFloat(RailDLayout.timeGap)) {
            timeLabel(PlaybackTimeFormat.label(position), dragging: dragging)
            track(fraction: fraction, dragging: dragging)
            timeLabel(duration > 0 ? PlaybackTimeFormat.remaining(position: position, duration: duration) : " ",
                      dragging: dragging)
        }
        .frame(width: CGFloat(RailDLayout.scrubberWidth))
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Song position")
        .accessibilityValue(duration > 0
                            ? PlaybackTimeFormat.accessibilityValue(position: position, duration: duration)
                            : "Unknown")
        .modifier(RailScrubberAccessibility(isWired: isWired, canSeek: input.canSeek,
                                            unavailableHint: PlaybackScrubber.unavailableHint(isDJSpeaking: input.isDJSpeaking),
                                            step: { accessibilityStep($0) }))
        .accessibilityIdentifier("playback.progress")
    }

    /// Visual only: VoiceOver reads the bar's value instead.
    private func timeLabel(_ text: String, dragging: Bool) -> some View {
        Text(verbatim: text)
            .font(.system(size: CGFloat(RailDLayout.timeLabelPointSize), weight: .medium).monospacedDigit())
            .foregroundStyle(Color.white.opacity(dragging ? 0.95 : 0.6))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .frame(width: CGFloat(RailDLayout.scrubberWidth), height: CGFloat(RailDLayout.timeLabelHeight))
            .accessibilityHidden(true)
    }

    private func track(fraction: Double, dragging: Bool) -> some View {
        let width = CGFloat(dragging ? RailDLayout.trackWidthDragging : RailDLayout.trackWidth)
        let thumb = CGFloat(dragging ? RailDLayout.thumbVisibleDragging : RailDLayout.thumbVisible)
        let wired = isWired
        return GeometryReader { geo in
            let length = geo.size.height
            let offset = CGFloat(RailDLayout.thumbOffset(fraction: fraction, trackLength: Double(length)))
            ZStack(alignment: .top) {
                Capsule()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: width, height: length)
                Capsule()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: width, height: max(width, offset))
            }
            .frame(width: geo.size.width, height: length, alignment: .top)
            .overlay {
                if wired {
                    Circle()
                        .fill(Color.white.opacity(dragging ? 0.7 : 0.97))
                        .shadow(color: .black.opacity(0.25), radius: dragging ? 4 : 1.5, y: 1)
                        .frame(width: thumb, height: thumb)
                        .position(x: geo.size.width / 2, y: offset)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.75), value: dragging)
        .accessibilityHidden(true)
    }

    // MARK: Interaction

    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: CGFloat(RailDLayout.dragClaimDistance))
            .updating($isTouching) { _, touching, _ in touching = true }
            .onChanged { value in
                if !claimed {
                    guard RailDLayout.claimsDrag(translationX: Double(value.translation.width),
                                                 translationY: Double(value.translation.height)) else { return }
                    claimed = true
                }
                guard let duration = input.time.duration() else { return }
                let target = RailDLayout.position(atElementY: Double(value.location.y),
                                                  elementHeight: Double(elementHeight),
                                                  duration: duration)
                if scrub.drag(to: target, duration: duration, canSeek: input.canSeek) {
                    dragStarts += 1
                }
            }
            .onEnded { _ in
                let wasClaimed = claimed
                claimed = false
                guard wasClaimed else { return }
                // canSeek can turn false between the last move and the lift: drop, never send.
                guard input.canSeek else { scrub.cancelDrag(); return }
                guard let target = scrub.endDrag(now: Self.now()) else { return }
                send(target, commitID: scrub.commitID)
            }
    }

    /// VoiceOver adjustable: ±15 s from what the bar shows, through the same commit path.
    private func accessibilityStep(_ delta: TimeInterval) {
        guard isInteractive, let duration = input.time.duration(), duration > 0 else { return }
        let now = Self.now()
        let current = scrub.displayedPosition(snapshotPosition: max(0, input.time.elapsed()), duration: duration, now: now)
        let target = scrub.commit(current + delta, duration: duration, now: now)
        send(target, commitID: scrub.commitID)
    }

    /// One seek per release, pinned to the track the bar was showing (#171's stale-scrub guard).
    private func send(_ target: TimeInterval, commitID: Int) {
        commits += 1
        guard let onSeek = input.onSeek, input.canSeek else {
            scrub.seekFinished(commitID: commitID, succeeded: false)
            return
        }
        let pinnedTrackID = scrub.trackID
        let time = input.time
        Task { @MainActor in
            let succeeded = await onSeek(target, pinnedTrackID)
            scrub.seekFinished(commitID: commitID, succeeded: succeeded)
            guard succeeded else { return }
            try? await Task.sleep(for: .seconds(ScrubberState.holdTimeout))
            scrub.settle(snapshotPosition: max(0, time.elapsed()), now: Self.now())
        }
    }

    private static func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
}

/// Adjustable once seeking is wired (swipe up seeks forward, the system convention); a hint
/// while it is unavailable. Same rules as the horizontal scrubber.
private struct RailScrubberAccessibility: ViewModifier {
    let isWired: Bool
    let canSeek: Bool
    let unavailableHint: String
    let step: (TimeInterval) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if isWired && canSeek {
            content.accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: step(ScrubberState.accessibilityStep)
                case .decrement: step(-ScrubberState.accessibilityStep)
                @unknown default: break
                }
            }
        } else if isWired {
            content.accessibilityHint(unavailableHint)
        } else {
            content
        }
    }
}

/// "STATION" over the opened station's name: the open Duo's header (D), the same type as the
/// closed header's centre. Not a button; Queue lives on the rail. Keeps `station.title`.
struct RailDStationHeader: View {
    let name: String
    @ScaledMetric(relativeTo: .headline) private var nameSize: CGFloat = 17

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Station")
                .font(.caption2.weight(.bold))
                .tracking(1.2)
                .textCase(.uppercase)
                .foregroundStyle(Color(red: FoldedOuterLayout.playRingRed,
                                       green: FoldedOuterLayout.playRingGreen,
                                       blue: FoldedOuterLayout.playRingBlue))
            Text(name)
                .font(.system(size: nameSize, weight: .heavy))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .frame(maxWidth: .infinity, minHeight: CGFloat(RailDLayout.openHeaderHeight), alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Station, \(name)")
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier("station.title")
    }
}

/// Studio capture only: a hinge and fold reading to lay the open Duo out with, instead of the
/// SDK's (`FoldDivisionProbe`), which reports nothing in the simulator. Nil everywhere else.
struct FoldPoseOverride: Equatable, Sendable {
    var hinge: FoldAwareness.HingeSample?
    var divisions: [FoldAwareness.Division]
}

private struct FoldPoseOverrideKey: EnvironmentKey {
    static let defaultValue: FoldPoseOverride? = nil
}

extension EnvironmentValues {
    var foldPoseOverride: FoldPoseOverride? {
        get { self[FoldPoseOverrideKey.self] }
        set { self[FoldPoseOverrideKey.self] = newValue }
    }
}
