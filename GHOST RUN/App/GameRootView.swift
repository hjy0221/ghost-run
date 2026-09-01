import SwiftUI

struct GameRootView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var locationService: LocationService
    @StateObject private var engine: GameEngine

    init() {
        let locationService = LocationService()
        _locationService = StateObject(wrappedValue: locationService)
        _engine = StateObject(wrappedValue: GameEngine(locationService: locationService))
    }

    var body: some View {
        ZStack {
            GhostRunTheme.canvas.ignoresSafeArea()

            switch engine.phase {
            case .briefing:
                BriefingView(engine: engine, locationService: locationService)
            case .countdown, .running, .paused:
                LiveRunView(engine: engine, locationService: locationService)
            case .summary:
                if let result = engine.result {
                    SummaryView(result: result, onRestart: engine.returnToBriefing)
                }
            }
        }
        .onChange(of: scenePhase) { _, newValue in
            switch newValue {
            case .active:
                engine.appDidBecomeActive()
            case .background:
                engine.appDidEnterBackground()
            case .inactive:
                engine.appDidBecomeInactive()
            @unknown default:
                break
            }
        }
#if DEBUG
        .task {
            if ProcessInfo.processInfo.environment["NIGHT_SIGNAL_AUTO_START"] == "1",
               engine.phase == .briefing {
                engine.beginSession()
            }
        }
#endif
    }
}
