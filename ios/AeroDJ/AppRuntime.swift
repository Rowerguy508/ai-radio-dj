import AeroDJCore

/// The one composition root for the phone window and the CarPlay scene.
///
/// `AeroDJApp` and `CarPlaySceneDelegate` both read `dependencies`. `startIfNeeded`
/// runs the studio, the DJ session, and `PlaybackSessionBinder` once per process,
/// whichever scene asks first. Previews keep calling `AppDependencies.make()` and
/// do not enter this cache.
@MainActor
enum AppRuntime {
    private static var stored: AppDependencies?
    private static var startup: Task<Void, Never>?

    static var dependencies: AppDependencies {
        if let stored { return stored }
        let created = AppDependencies.make()
        stored = created
        return created
    }

    static func startIfNeeded() async {
        if let startup {
            await startup.value
            return
        }
        let task = Task { @MainActor in
            await dependencies.start()
            await PlaybackSessionBinder.bind(dependencies)
            // #465 item 7: widget and Live Activity feed. Observes only; does nothing until
            // the widget extension is embedded, and never sits on the playback path.
            NowPlayingSurfaces.shared.start(dependencies)
        }
        startup = task
        await task.value
    }
}
