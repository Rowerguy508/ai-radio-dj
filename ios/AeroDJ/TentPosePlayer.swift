import AeroDJCore
import SwiftUI

// #465 item 3: tent / tabletop (hands-free) pose, from the owner mockup
// (onairly2-mockups/03-tent.png). A radio face on the half that faces the listener: the DJ
// orb (or the song's art) with the On Air tally, a big clock with the date, the station and
// what plays next. No buttons until the face is touched; a tap fades up big transport, the
// station dial and the break chip, and they hide again after 5 s with no touch.
//
// UI only. Every value comes from what `PlayingScreen` already passes the folded player:
// the snapshot, `DJStatusPresentation` (from `studio.djState`) and `PlaybackActions`.
// Nothing here starts, stops or seeks playback except through those actions, and nothing
// reads or writes `DJBreakSession`.
//
// Pose: `TentPoseGate` is the only switch. It reads the hinge (iOS 27.1 SDK only) and hands
// `DuoPoseDecision` a plain sample. Without a hinge, the pose is always `.flat` and the gate
// draws `PlayingScreen`'s own content untouched.

private enum TentStyle {
    static let ink = Color.white
    static let secondaryInk = Color.white.opacity(0.7)
    static let faceBase = Color(red: 5 / 255, green: 7 / 255, blue: 10 / 255)
    static let lowerBase = Color(red: 2 / 255, green: 3 / 255, blue: 4 / 255)
    /// Morning Calm tint in the mockup (rgb 47, 212, 190). Station label and the right glow.
    static let teal = Color(red: 47 / 255, green: 212 / 255, blue: 190 / 255)
    /// The tally. Red is reserved for On Air on this face.
    static let tally = Color(red: 224 / 255, green: 38 / 255, blue: 28 / 255)
    static let tallyGlow = Color(red: 1, green: 59 / 255, blue: 47 / 255)
    static let opaqueGlass = Color(red: 17 / 255, green: 21 / 255, blue: 28 / 255)
}

/// Reduce Motion, including the capture launch flag the UI tests use.
private enum TentReduceMotion {
    static func resolve(_ system: Bool) -> Bool {
        #if DEBUG
        system || UserDefaults.standard.bool(forKey: StudioCapture.reduceMotionKey)
        #else
        system
        #endif
    }
}

// MARK: - Gate

/// Draws `player` instead of the wrapped content only while `DuoPoseDecision` says `.tent`.
/// With no hinge (every device today, and any build on the 26.5 SDK) that is never, so the
/// phone, folded and unfolded paths are the wrapped content, unchanged.
struct TentPoseGate: ViewModifier {
    let player: TentPosePlayer

    @State private var hinge: DuoHingeSample?
    @State private var size: CGSize = .zero
    @State private var pose: DuoPose = .flat
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    func body(content: Content) -> some View {
        Group {
            if pose == .tent {
                player
                    .toolbar(.hidden, for: .navigationBar)
                    .transition(.opacity)
            } else {
                content
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { newSize in
            size = newSize
            update()
        }
        .modifier(TentHingeObserver(sample: $hinge))
        .onChange(of: hinge) { _, _ in update() }
        .onAppear { update() }
    }

    @MainActor
    private func update() {
        let sample: DuoHingeSample?
        #if DEBUG
        sample = TentPoseCapture.forcedHinge ?? hinge
        #else
        sample = hinge
        #endif
        let next = DuoPoseDecision.resolve(hinge: sample, containerWidth: Double(size.width),
                                           containerHeight: Double(size.height), previous: pose)
        guard next != pose else { return }
        if TentReduceMotion.resolve(systemReduceMotion) {
            pose = next
        } else {
            withAnimation(.easeInOut(duration: 0.3)) { pose = next }
        }
    }
}

/// The hinge, where the SDK has it. Xcode 26.6 (Swift 6.3, iOS 26.5 SDK, the required CI
/// build) compiles only the pass-through; the hinge path needs Xcode 27 (Swift 6.4.2) and
/// runs only on iOS 27.1 or later. Same gate as #468's `docs/device-install.md`.
private struct TentHingeObserver: ViewModifier {
    @Binding var sample: DuoHingeSample?

    func body(content: Content) -> some View {
        #if compiler(>=6.4.2)
        if #available(iOS 27.1, *) {
            // Apple's iOS 27.1 signature:
            // nonisolated func onHingeChange(isEnabled: Bool = true, _ action: @escaping (DeviceHingeContext, DeviceHingeContext) -> Void) -> some View
            content.onHingeChange(isEnabled: true) { _, context in
                sample = context.hinge.map { hinge in
                    DuoHingeSample(status: Self.status(hinge.status), angleDegrees: hinge.angle.degrees)
                }
            }
        } else {
            content
        }
        #else
        content
        #endif
    }

    #if compiler(>=6.4.2)
    @available(iOS 27.1, *)
    private static func status(_ status: DeviceHinge.Status) -> DuoHingeSample.Status {
        switch status {
        case .closed: .closed
        case .partiallyOpen: .partiallyOpen
        case .fullyOpen: .fullyOpen
        @unknown default: .unknown
        }
    }
    #endif
}

// MARK: - Player

struct TentPosePlayer: View {
    let station: StationRef
    let heading: StationHeading
    let content: NowPlayingContent
    let snapshot: PlaybackSnapshot
    let actions: PlaybackActions
    let dj: DJStatusPresentation
    /// Fry's DJ voice level for the orb. Read only.
    var speechLevel: DJPresentationStore? = nil
    var stationStops: [DuoStationSwitch.Stop] = []
    var onOpenStation: ((String) async -> Void)? = nil
    let onQueue: () -> Void
    let onTune: () -> Void

    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilitySwitchControlEnabled) private var switchControl
    @Environment(\.dismiss) private var dismiss

    @State private var lastTouch: Date?
    /// Set from `TentControlsPolicy.showsControls` on a touch and when the 5 s timer fires.
    @State private var touchedRecently = false
    @State private var hideTask: Task<Void, Never>?

    private var reduceMotion: Bool { TentReduceMotion.resolve(systemReduceMotion) }
    private var assistive: Bool { voiceOver || switchControl }
    private var holdOpen: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: TentPoseCapture.holdControlsKey)
        #else
        false
        #endif
    }

    private var showsControls: Bool {
        touchedRecently || TentControlsPolicy.showsControls(lastTouch: nil, now: Date(),
                                                            assistiveTechnology: assistive, holdOpen: holdOpen)
    }

    private var heroTrack: TrackInfo? {
        if case .track(let track) = content { return track }
        return nil
    }

    var body: some View {
        GeometryReader { geo in
            let layout = TentPoseLayout.make(containerWidth: Double(geo.size.width),
                                             containerHeight: Double(geo.size.height),
                                             accessibilityText: typeSize.isAccessibilitySize)
            VStack(spacing: 0) {
                face(layout)
                    .frame(width: geo.size.width, height: CGFloat(layout.faceHeight))
                    .clipped()
                Color.black
                    .frame(height: CGFloat(layout.foldBand))
                    .overlay(alignment: .center) {
                        Rectangle().fill(Color.white.opacity(0.10)).frame(height: 1)
                    }
                    .accessibilityHidden(true)
                    .accessibilityIdentifier("tent.fold")
                lowerHalf(layout)
                    .frame(width: geo.size.width, height: CGFloat(layout.lowerHeight))
            }
        }
        .background(TentStyle.lowerBase.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
        .environment(\.onSlab, true)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("layout.tent")
        .onDisappear { hideTask?.cancel() }
    }

    // MARK: Face

    private func face(_ layout: TentPoseLayout) -> some View {
        ZStack(alignment: .bottom) {
            faceBackdrop
                .accessibilityHidden(true)
            Group {
                if layout.usesColumns {
                    faceColumns(layout)
                } else {
                    // At accessibility text sizes, controls live in this scroll so
                    // growing chips are not clipped by the fixed face height.
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(alignment: .leading, spacing: 16) {
                            faceStacked(layout)
                            if typeSize.isAccessibilitySize && controlsOnFace(layout) && showsControls {
                                controls
                                    .transition(controlsTransition)
                            }
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
            }
            .opacity(controlsOnFace(layout) && showsControls && !typeSize.isAccessibilitySize ? 0.35 : 1)
            .contentShape(Rectangle())
            .onTapGesture { touch() }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("tent.face")

            if controlsOnFace(layout) && showsControls && !typeSize.isAccessibilitySize {
                controls
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
                    .transition(controlsTransition)
            }
        }
        .animation(reduceMotion ? .linear(duration: TentControlsPolicy.revealSeconds)
                   : .easeOut(duration: TentControlsPolicy.revealSeconds), value: showsControls)
    }

    private func controlsOnFace(_ layout: TentPoseLayout) -> Bool { layout.controlsPlacement == .onFace }

    private var controlsTransition: AnyTransition {
        switch TentControlsPolicy.transition(reduceMotion: reduceMotion) {
        case .crossfade: .opacity
        case .fadeUp: .opacity.combined(with: .offset(y: 12))
        }
    }

    /// Two still glows: red behind the hero, the station tint on the right. Reduce
    /// Transparency drops them for the plain base.
    @ViewBuilder
    private var faceBackdrop: some View {
        if reduceTransparency {
            TentStyle.faceBase
        } else {
            ZStack {
                TentStyle.faceBase
                RadialGradient(colors: [TentStyle.tallyGlow.opacity(dj.state.isOnAir ? 0.36 : 0.14), .clear],
                               center: UnitPoint(x: 0.14, y: 0.55), startRadius: 0, endRadius: 300)
                RadialGradient(colors: [TentStyle.teal.opacity(0.30), .clear],
                               center: UnitPoint(x: 0.88, y: 0.40), startRadius: 0, endRadius: 300)
            }
        }
    }

    private func faceColumns(_ layout: TentPoseLayout) -> some View {
        HStack(alignment: .top, spacing: 0) {
            heroColumn(layout)
                .frame(width: CGFloat(layout.heroSide) + 40)
                .padding(.top, 70)
            Spacer(minLength: 24)
            clockBlock(layout)
                .padding(.top, 52)
            Spacer(minLength: 24)
            stationColumn(layout)
                .frame(width: CGFloat(layout.stationColumnWidth), alignment: .leading)
                .padding(.top, 64)
        }
        .padding(.leading, CGFloat(layout.leadingInset))
        .padding(.trailing, CGFloat(layout.trailingInset))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Accessibility text sizes or a narrow face: one column that scrolls.
    private func faceStacked(_ layout: TentPoseLayout) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                heroColumn(layout)
                clockBlock(layout)
            }
            stationColumn(layout)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func heroColumn(_ layout: TentPoseLayout) -> some View {
        let side = CGFloat(layout.heroSide)
        return VStack(spacing: 30) {
            hero(side: side)
                .frame(width: side, height: side)
                .accessibilityHidden(true)
                .overlay(alignment: .topLeading) { captureHeroMarker }
            if let label = TentFace.onAirLabel(dj.state) {
                TentTally(label: label)
            }
        }
    }

    /// Debug capture only: the hero is decorative and hidden from VoiceOver, so UI tests read
    /// which one is drawn from this 1 pt marker. Never in Release or outside the capture.
    @ViewBuilder
    private var captureHeroMarker: some View {
        #if DEBUG
        if UserDefaults.standard.bool(forKey: StudioCapture.defaultsKey) {
            let kind = TentFace.hero(state: dj.state, reduceMotion: reduceMotion, hasTrack: heroTrack != nil)
            Text(verbatim: kind.rawValue)
                .font(.system(size: 1))
                .frame(width: 2, height: 2)
                .opacity(0.02)
                .allowsHitTesting(false)
                .accessibilityElement()
                .accessibilityLabel(kind.rawValue)
                .accessibilityIdentifier("tent.hero")
        }
        #endif
    }

    @ViewBuilder
    private func hero(side: CGFloat) -> some View {
        switch TentFace.hero(state: dj.state, reduceMotion: reduceMotion, hasTrack: heroTrack != nil) {
        case .liveOrb:
            DJLavaOrb(track: heroTrack, station: station, levels: speechLevel)
                .accessibilityIdentifier("tent.visualizer")
        case .stillOrb:
            TentStillOrb()
                .accessibilityIdentifier("tent.visualizer.still")
        case .artwork:
            BleedArtwork(track: heroTrack, station: station)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .accessibilityIdentifier("tent.artwork")
        case .stationArt:
            StationArtwork(style: .station(heading.opened), size: side)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .accessibilityIdentifier("tent.artwork")
        }
    }

    private func clockBlock(_ layout: TentPoseLayout) -> some View {
        TimelineView(.everyMinute) { context in
            let now = TentClock.now(context.date)
            let time = now.formatted(.dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
            let date = "\(now.formatted(.dateTime.weekday(.wide))) · \(now.formatted(.dateTime.day().month(.wide)))"
            VStack(alignment: .leading, spacing: 12) {
                Text(verbatim: time)
                    .font(.system(size: CGFloat(layout.clockPointSize), weight: .heavy))
                    .monospacedDigit()
                    .tracking(-0.06 * CGFloat(layout.clockPointSize))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .foregroundStyle(TentStyle.ink)
                Text(verbatim: date)
                    .font(.headline)
                    .foregroundStyle(TentStyle.secondaryInk)
                    .lineLimit(2)
                    .padding(.leading, 8)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(TentFace.accessibilitySummary(
                time: time, station: heading.opened.name, state: dj.state,
                next: snapshot.upNext.first.map { (title: $0.title, artist: $0.artistName) }))
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("tent.clock")
        }
    }

    private func stationColumn(_ layout: TentPoseLayout) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                TentLabel(text: "Station", color: TentStyle.teal)
                Text(heading.opened.name)
                    .font(.system(.largeTitle, weight: .heavy))
                    .tracking(-1)
                    .foregroundStyle(TentStyle.ink)
                    .lineLimit(3)
                    .minimumScaleFactor(0.7)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
                if let next = snapshot.upNext.first {
                    TentLabel(text: TentFace.nextCaption(state: dj.state), color: TentStyle.secondaryInk)
                        .padding(.top, 16)
                    Text(next.title)
                        .font(.headline.weight(.heavy))
                        .foregroundStyle(TentStyle.ink)
                        .lineLimit(2)
                        .padding(.top, 5)
                    Text(next.artistName)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(TentStyle.secondaryInk)
                        .lineLimit(2)
                        .padding(.top, 2)
                }
            }
            .accessibilityHidden(true)
            if !showsControls {
                Button(action: touch) {
                    Text("Tap to show controls")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(Color.white.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .frame(minHeight: CGFloat(TentControlsPolicy.hitTargetFloor))
                        .fixedSize(horizontal: false, vertical: true)
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.28), lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
                .accessibilityIdentifier("tent.showControls")
            }
        }
        // The clock's summary already reads the station and the next song.
        // Hide this copy so VoiceOver does not hear them twice; keep the
        // show-controls button in the tree.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tent.station")
    }

    // MARK: Lower half

    @ViewBuilder
    private func lowerHalf(_ layout: TentPoseLayout) -> some View {
        if layout.controlsPlacement == .lowerHalf && showsControls {
            controls
                .padding(24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(TentStyle.lowerBase)
                .transition(controlsTransition)
        } else {
            // Faces away: dark, nothing drawn, no touch.
            TentStyle.lowerBase
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .accessibilityIdentifier("tent.lowerHalf")
        }
    }

    // MARK: Controls

    private var breakChip: String? { TentFace.breakChip(state: dj.state, headline: dj.headline) }

    private var controls: some View {
        ViewThatFits(in: .horizontal) {
            controlsRow
            controlsTwoRows
        }
        .padding(12)
        .aeroGlass(RoundedRectangle(cornerRadius: 30, style: .continuous), role: .surface,
                   fallback: AnyShapeStyle(Color.white.opacity(0.08)), hairline: Color.white.opacity(0.18),
                   opaqueFill: TentStyle.opaqueGlass)
        // Any touch on the panel keeps it up for another 5 s.
        .simultaneousGesture(TapGesture().onEnded { touch() })
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tent.controls")
    }

    private var controlsRow: some View {
        HStack(spacing: 12) {
            transport
            dial
            if let breakChip { TentBreakChip(text: breakChip) }
            Spacer(minLength: 0)
            chrome
        }
    }

    private var controlsTwoRows: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                transport
                Spacer(minLength: 0)
                chrome
            }
            HStack(spacing: 12) {
                dial
                if let breakChip { TentBreakChip(text: breakChip) }
            }
        }
    }

    @ViewBuilder
    private var transport: some View {
        if content.showsTransport {
            TentTransport(transport: snapshot.transport, startTimedOut: snapshot.startTimedOut, actions: actions)
        }
    }

    @ViewBuilder
    private var dial: some View {
        if stationStops.count > 1, let onOpenStation {
            TentStationDial(stops: stationStops, openedID: heading.opened.id, onOpen: onOpenStation)
        }
    }

    private var chrome: some View {
        HStack(spacing: 8) {
            TentChromeButton(systemImage: "list.bullet", label: "Queue", hint: "Opens the queue",
                             identifier: "tent.queue", action: onQueue)
            TentChromeButton(systemImage: "slider.horizontal.3", label: "Tune station",
                             hint: "Opens the tuner. Music continues.", identifier: "tent.tune", action: onTune)
            TentChromeButton(systemImage: "chevron.backward", label: "Back", hint: "Returns to your stations",
                             identifier: "tent.back", action: { dismiss() })
        }
    }

    /// A touch on the face or the panel: show the controls and restart the 5 s timer.
    private func touch() {
        let now = Date()
        lastTouch = now
        touchedRecently = TentControlsPolicy.showsControls(lastTouch: now, now: now,
                                                           assistiveTechnology: assistive, holdOpen: holdOpen)
        hideTask?.cancel()
        guard TentControlsPolicy.autoHides(assistiveTechnology: assistive, holdOpen: holdOpen) else { return }
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(TentControlsPolicy.autoHideSeconds))
            guard !Task.isCancelled else { return }
            touchedRecently = TentControlsPolicy.showsControls(lastTouch: lastTouch, now: Date(),
                                                               assistiveTechnology: assistive, holdOpen: holdOpen)
            hideTask = nil
        }
    }
}

// MARK: - Pieces

private struct TentLabel: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.weight(.heavy))
            .tracking(1.6)
            .textCase(.uppercase)
            .foregroundStyle(color)
    }
}

/// The On Air tally. Drawn only when `DJStudioState.onAirLabel` is non-nil; the label is
/// that string, never a constant of its own.
private struct TentTally: View {
    let label: String
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(.white).frame(width: 8, height: 8).accessibilityHidden(true)
            Text(label)
                .font(.caption.weight(.heavy))
                .tracking(2)
                .textCase(.uppercase)
                .foregroundStyle(.white)
        }
        .padding(.leading, 10)
        .padding(.trailing, 12)
        .frame(minHeight: 28)
        .background(Capsule().fill(TentStyle.tally))
        .shadow(color: reduceTransparency ? .clear : TentStyle.tallyGlow.opacity(0.75), radius: 11)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityIdentifier("tent.onAir")
        // The clock summary already speaks On Air from DJStudioState.onAirLabel.
        .accessibilityHidden(true)
    }
}

/// Reduce Motion while on air: the orb's colours, standing still. No timeline, no animation.
private struct TentStillOrb: View {
    var body: some View {
        Circle()
            .fill(RadialGradient(colors: [Color(red: 1, green: 0.95, blue: 0.86),
                                          Color(red: 1, green: 0.71, blue: 0.43),
                                          Color(red: 1, green: 0.35, blue: 0.2),
                                          Color(red: 0.78, green: 0.08, blue: 0.12)],
                                 center: UnitPoint(x: 0.38, y: 0.32), startRadius: 0, endRadius: 90))
    }
}

/// Big Play/Pause and Skip. Same `TransportTapPolicy` as the shared `TransportRow`, so a
/// second tap during a start still does nothing until its deadline.
private struct TentTransport: View {
    let transport: TransportState
    let startTimedOut: Bool
    let actions: PlaybackActions
    @State private var taps = 0

    private var face: TransportButtonFace {
        TransportTapPolicy.face(transport: transport, startTimedOut: startTimedOut)
    }

    var body: some View {
        HStack(spacing: 12) {
            Button {
                switch TransportTapPolicy.decide(transport: transport, startTimedOut: startTimedOut) {
                case .ignore: break
                case .cancelStart: taps += 1; actions.cancelStart()
                case .pause: taps += 1; actions.pause()
                case .play: taps += 1; Task { await actions.resume() }
                }
            } label: {
                Group {
                    if let systemImage = face.systemImage {
                        Image(systemName: systemImage)
                    } else {
                        ProgressView().tint(AeroDJPalette.onMediaInk)
                    }
                }
                .font(.system(size: 38, weight: .bold))
                .foregroundStyle(AeroDJPalette.onMediaInk)
                .frame(width: CGFloat(TentControlsPolicy.playSide), height: CGFloat(TentControlsPolicy.playSide))
                .background(Circle().fill(AeroDJPalette.onMediaLight))
                .contentShape(Circle())
            }
            .accessibilityLabel(face.accessibilityLabel)
            .accessibilityRemoveTraits(face.isActionable ? [] : .isButton)
            .accessibilityIdentifier("tent.playPause")

            Button {
                taps += 1
                Task { await actions.skip() }
            } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: CGFloat(TentControlsPolicy.skipSide), height: CGFloat(TentControlsPolicy.skipSide))
                    .aeroGlass(Circle(), role: .control, fallback: AnyShapeStyle(Color.white.opacity(0.08)),
                               hairline: Color.white.opacity(0.10), opaqueFill: TentStyle.opaqueGlass)
                    .contentShape(Circle())
            }
            .accessibilityLabel("Skip")
            .accessibilityIdentifier("tent.skip")
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.impact(weight: .light), trigger: taps)
    }
}

/// Station stops as large capsules. A tap opens through the caller's open action
/// (`DuoStationSwitch` decides: the playing station is not reopened, a newer tap wins).
private struct TentStationDial: View {
    let stops: [DuoStationSwitch.Stop]
    let openedID: String
    let onOpen: (String) async -> Void

    @State private var flight = DuoStationSwitch.Flight(highlightID: "")
    @State private var openTask: Task<Void, Never>?
    @State private var highlighted: String?

    private var highlightedID: String { highlighted ?? openedID }
    private var highlightedName: String { stops.first { $0.id == highlightedID }?.name ?? "" }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(stops) { stop in
                    let selected = stop.id == highlightedID
                    Button { open(stop.id) } label: {
                        Text(stop.name)
                            .font(.headline)
                            .lineLimit(1)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 8)
                            .frame(minWidth: 60, minHeight: CGFloat(TentControlsPolicy.targetMinSide))
                            .fixedSize(horizontal: true, vertical: true)
                            .foregroundStyle(.white.opacity(selected ? 1 : 0.72))
                            .aeroGlass(Capsule(), role: .control, fallback: AnyShapeStyle(Color.white.opacity(selected ? 0.18 : 0.08)),
                                       hairline: Color.white.opacity(0.10), opaqueFill: TentStyle.opaqueGlass)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(stop.name)
                    .accessibilityHint("Plays the station now.")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                    .accessibilityIdentifier("tent.station.\(stop.id)")
                }
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .fixedSize(horizontal: false, vertical: true)
        .frame(minHeight: CGFloat(TentControlsPolicy.targetMinSide))
        .frame(maxWidth: 320)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("tent.stationDial")
        .accessibilityLabel("Stations")
        .accessibilityValue(highlightedName)
        .onAppear { flight = DuoStationSwitch.Flight(highlightID: openedID) }
        .onChange(of: openedID) { _, _ in highlighted = nil }
    }

    private func open(_ id: String) {
        highlighted = id
        guard let token = flight.receive(.tap(id), playingID: openedID) else { return }
        openTask?.cancel()
        openTask = Task {
            guard flight.accepts(token), !Task.isCancelled else { return }
            await onOpen(id)
        }
    }
}

/// Ready break, read only. Not a button: it says what is coming, nothing more.
private struct TentBreakChip: View {
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock").accessibilityHidden(true)
            Text(text).lineLimit(2)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(Color.white.opacity(0.85))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(minHeight: CGFloat(TentControlsPolicy.hitTargetFloor))
        .fixedSize(horizontal: false, vertical: true)
        .aeroGlass(Capsule(), role: .surface, fallback: AnyShapeStyle(Color.white.opacity(0.08)),
                   hairline: Color.white.opacity(0.10), opaqueFill: TentStyle.opaqueGlass)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
        .accessibilityIdentifier("tent.breakChip")
    }
}

private struct TentChromeButton: View {
    let systemImage: String
    let label: String
    let hint: String
    let identifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: CGFloat(TentControlsPolicy.targetMinSide), height: CGFloat(TentControlsPolicy.targetMinSide))
                .aeroGlass(Circle(), role: .control, fallback: AnyShapeStyle(Color.white.opacity(0.08)),
                           hairline: Color.white.opacity(0.10), opaqueFill: TentStyle.opaqueGlass)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityHint(hint)
        .accessibilityIdentifier(identifier)
    }
}

// MARK: - Clock and capture hooks

/// The face clock. Debug only: the `duoTent` capture freezes it at the mockup's 9:41 so the
/// PNG is the same every run.
@MainActor
private enum TentClock {
    static func now(_ date: Date) -> Date {
        #if DEBUG
        if let frozen = TentPoseCapture.frozenDate { return frozen }
        #endif
        return date
    }
}

#if DEBUG
/// What the `duoTent` capture forces. Nil everywhere else, so no other run is affected.
@MainActor
enum TentPoseCapture {
    /// A partially open hinge at 100°, fed to the real `DuoPoseDecision`.
    static var forcedHinge: DuoHingeSample?
    /// Thursday 12 November 2026, 9:41 local, as in the mockup.
    static var frozenDate: Date?
    /// `-AeroDJTentHoldControls YES`: no auto-hide, so a UI test can measure the controls.
    static let holdControlsKey = "AeroDJTentHoldControls"

    static let capturedHinge = DuoHingeSample(status: .partiallyOpen, angleDegrees: 100)
    static var capturedDate: Date {
        DateComponents(calendar: .current, year: 2026, month: 11, day: 12, hour: 9, minute: 41).date ?? Date()
    }
}

#Preview("Tent (DJ speaking)", traits: .fixedLayout(width: 820, height: 640)) {
    TentPosePlayer(station: PlaybackFixtures.station,
                   heading: StationHeading(opened: PlaybackFixtures.station, playing: PlaybackFixtures.station),
                   content: .track(PlaybackFixtures.songs[1]),
                   snapshot: PlaybackFixtures.djSpeaking, actions: .preview,
                   dj: .init(state: .speaking(includesBriefing: false)),
                   onQueue: {}, onTune: {})
}
#endif
