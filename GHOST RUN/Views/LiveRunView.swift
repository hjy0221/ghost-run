import Combine
import CoreLocation
import MapKit
import SwiftUI
import UIKit

struct LiveRunView: View {
    @ObservedObject var engine: GameEngine
    @ObservedObject var locationService: LocationService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cameraPosition: MapCameraPosition = .automatic
    @State private var followsRunner = true
    @State private var mapHeading = 0.0
    @State private var showEndConfirmation = false

    var body: some View {
        ZStack {
            ZStack {
                runMap
                mapShade
                hud
            }
            .accessibilityHidden(engine.phase == .countdown || engine.phase == .paused)

            if engine.phase == .countdown {
                CountdownOverlay(
                    seconds: engine.countdownSeconds,
                    totalSeconds: engine.countdownDuration,
                    waitingForGPS: engine.isWaitingForGPS,
                    accuracyText: engine.locationAccuracyText,
                    routingStatus: engine.routingStatus,
                    onCancel: engine.returnToBriefing
                )
                .transition(.opacity)
                .accessibilityAddTraits(.isModal)
            }

            if engine.phase == .paused, let reason = engine.pauseReason {
                PauseOverlay(
                    reason: reason,
                    canResume: engine.canResumeSession,
                    onResume: engine.resume,
                    canSkipSupply: engine.canSkipSupply,
                    onSkipSupply: engine.skipInaccessibleSupply,
                    onEnd: { engine.endSession(reason: .userEnded) }
                )
                .transition(.opacity)
                .accessibilityAddTraits(.isModal)
            }
        }
        .onReceive(engine.$playerLocation.compactMap { $0 }) { location in
            guard followsRunner else { return }
            updateCamera(for: location)
        }
        .onChange(of: engine.currentEvent?.id) { _, _ in
            guard let message = engine.currentEvent?.message else { return }
            UIAccessibility.post(notification: .announcement, argument: message)
        }
        .alert("러닝을 종료할까요?", isPresented: $showEndConfirmation) {
            Button("계속 달리기", role: .cancel) {}
            Button("종료", role: .destructive) {
                engine.endSession(reason: .userEnded)
            }
        } message: {
            Text("현재 생존 기록이 결과 화면에 표시됩니다.")
        }
    }

    private var runMap: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: engine.shots.isEmpty)) { context in
        let targetID = engine.aimedGhost?.id
        Map(position: $cameraPosition, interactionModes: [.pan, .zoom, .rotate]) {
            if engine.routeCoordinates.count > 1 {
                MapPolyline(coordinates: engine.routeCoordinates)
                    .stroke(
                        GhostRunTheme.signal.opacity(0.7),
                        style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
                    )
            }

            ForEach(engine.entities.filter { $0.kind == .safeLight }) { entity in
                MapCircle(center: entity.coordinate, radius: entity.radius)
                    .foregroundStyle(GhostRunTheme.supply.opacity(0.12))
                    .stroke(GhostRunTheme.supply.opacity(0.65), lineWidth: 1)
                Annotation("보급", coordinate: entity.coordinate, anchor: .center) {
                    SafeLightMarker()
                }
            }

            ForEach(engine.entities.filter { $0.kind == .ghost }) { entity in
                Annotation("유령", coordinate: entity.coordinate, anchor: .center) {
                    GhostMarker(isCritical: (engine.routeDistance(to: entity) ?? .infinity) < engine.configuration.dangerDistance,
                                isTargeted: targetID == entity.id && engine.ammo > 0)
                }
                .annotationTitles(.hidden)
            }
#if DEBUG
            if engine.showsDebugObstacles,
               let map = engine.entities.compactMap({ $0.navigation?.cursor.path.obstacleMap }).first {
                ForEach(Array(map.obstacles.enumerated()), id: \.offset) { _, obstacle in
                    if obstacle.isArea {
                        MapPolygon(coordinates: obstacle.points.map(map.coordinate))
                            .foregroundStyle(.orange.opacity(0.14))
                            .stroke(.orange.opacity(0.6), lineWidth: 1)
                    } else {
                        MapPolyline(coordinates: obstacle.points.map(map.coordinate))
                            .stroke(.orange, lineWidth: 2)
                    }
                }
            }
            if engine.showsDebugRoutes {
                ForEach(engine.entities) { entity in
                    if let navigation = entity.navigation {
                        MapPolyline(coordinates: navigation.cursor.path.coordinates)
                            .stroke(.purple.opacity(0.8), style: StrokeStyle(lineWidth: 4, dash: [7, 5]))
                    }
                    if let path = entity.safePath {
                        MapPolyline(coordinates: path.coordinates)
                            .stroke(.yellow.opacity(0.7), style: StrokeStyle(lineWidth: 3, dash: [5, 5]))
                    }
                }
            }
#endif

            ForEach(engine.shots) { shot in
                let head = shot.path.coordinate(at: shot.path.length * shot.progress(at: context.date))
                MapPolyline(coordinates: [shot.path.coordinates[0], head])
                    .stroke(GhostRunTheme.supply.opacity(0.8), lineWidth: 3)
                Annotation("빛 탄환", coordinate: head) {
                    Circle().fill(.white).frame(width: 9, height: 9)
                        .overlay(Circle().stroke(GhostRunTheme.supply, lineWidth: 2))
                        .shadow(color: GhostRunTheme.supply, radius: 8)
                        .allowsHitTesting(false)
                }
                .annotationTitles(.hidden)
            }

            if let location = engine.playerLocation {
                Annotation("내 위치", coordinate: location.coordinate, anchor: .center) {
                    RunnerBeaconMarker(heading: displayHeading(for: location))
                }
            }
        }
        .mapStyle(
            .standard(
                elevation: .flat,
                emphasis: .muted,
                pointsOfInterest: .excludingAll,
                showsTraffic: false
            )
        )
        .mapControls {
            MapScaleView()
        }
        .onMapCameraChange(frequency: .continuous) { context in
            mapHeading = normalizedHeading(context.camera.heading)
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 8)
                .onChanged { _ in followsRunner = false }
        )
        .ignoresSafeArea()
        }
    }

    private var mapShade: some View {
        LinearGradient(
            stops: [
                .init(color: GhostRunTheme.canvas.opacity(0.34), location: 0),
                .init(color: .clear, location: 0.28),
                .init(color: .clear, location: 0.62),
                .init(color: GhostRunTheme.canvas.opacity(0.54), location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    private var hud: some View {
        VStack(spacing: 10) {
            HStack(spacing: 9) {
                locationBadge
                Spacer()
                Button(action: engine.activateWard) {
                    VStack(spacing: 1) {
                        Image(systemName: "shield.lefthalf.filled")
                        Text("\(engine.wardCharges)").font(.caption2.bold())
                    }
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.8), in: Circle())
                }
                .foregroundStyle(GhostRunTheme.signal)
                .disabled(engine.phase != .running || engine.isRecoveringLocation || engine.wardCharges == 0 || engine.isProtected)
                .accessibilityLabel("보호막, \(engine.wardCharges)회 남음, \(engine.configuration.wardDuration)초 추격 정지")
                Button {
                    followsRunner = true
                    if let location = engine.playerLocation {
                        updateCamera(for: location)
                    }
                } label: {
                    Image(systemName: followsRunner ? "location.fill" : "location")
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .foregroundStyle(followsRunner ? GhostRunTheme.signal : .white)
                .accessibilityLabel("내 위치 따라가기")

                Button {
                    mapHeading = 0
                    if let location = engine.playerLocation {
                        updateCamera(for: location)
                    }
                } label: {
                    Image(systemName: "location.north.line.fill")
                        .rotationEffect(.degrees(-mapHeading))
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .foregroundStyle(abs(mapHeading) > 1 ? GhostRunTheme.supply : .white)
                .accessibilityLabel("지도를 북쪽으로 정렬")

                Button {
                    engine.pauseByUser()
                } label: {
                    Image(systemName: "pause.fill")
                        .frame(width: 44, height: 44)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .foregroundStyle(.white)
                .accessibilityLabel("러닝 일시정지 또는 종료")
            }

#if DEBUG
            if locationService.isSimulationEnabled {
                DebugSimulationControls(locationService: locationService, engine: engine)
            }
#endif

            RunStatsCapsule(engine: engine)
            movementObjective

            Spacer()

            if let event = engine.currentEvent {
                EventToastView(event: event)
                    .animation(.easeOut(duration: 0.2), value: event.id)
            }

            ThreatPressureRibbon(engine: engine)
            actionDock
            Link("© OpenStreetMap contributors · ODbL", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.8))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.black.opacity(0.7), in: Capsule())
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 16)
    }

    private var locationBadge: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(locationService.isCurrentLocationUsable ? GhostRunTheme.signal : GhostRunTheme.supply)
                .frame(width: 8, height: 8)
            Text(engine.locationAccuracyText)
                .font(.caption.bold().monospacedDigit())
        }
        .padding(.horizontal, 12)
        .frame(height: 44)
        .background(.ultraThinMaterial, in: Capsule())
        .accessibilityLabel("위치 정확도 \(engine.locationAccuracyText)")
    }

    private var movementObjective: some View {
        HStack(spacing: 8) {
            Image(systemName: "shippingbox.fill")
            Text(engine.nearestSupply == nil ? "다음 보급 지점 탐색 중"
                 : engine.safeLightRouteDistance.map { "보급 · \(Int($0))m" } ?? "보급 · 경로 밖")
                .font(.subheadline.bold().monospacedDigit())
            Spacer(minLength: 2)
            Text("탄약 +\(engine.configuration.supplyAmmo) · 보호")
                .font(.caption)
        }
        .foregroundStyle(GhostRunTheme.supply)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    private var actionDock: some View {
        HStack(spacing: 10) {
            Button(action: engine.fireAtNearestGhost) {
                VStack(spacing: 5) {
                    Label("사격 · \(engine.ammo)", systemImage: "scope")
                        .font(.headline.bold())
                    Text(engine.fireHint)
                        .font(.caption2)
                }
                .frame(maxWidth: .infinity, minHeight: 66)
                .background(GhostRunTheme.supply.opacity(engine.canFire ? 1 : 0.25), in: RoundedRectangle(cornerRadius: 16))
            }
            .disabled(!engine.canFire)
            .foregroundStyle(engine.canFire ? GhostRunTheme.canvas : .white)
            .accessibilityLabel("가까운 유령에게 사격, 탄약 \(engine.ammo)발")

            Button(action: engine.activatePulse) {
                VStack(spacing: 4) {
                    Label(engine.canUsePulse ? "파동 준비 완료" : "파동 · \(Int(engine.energy))%", systemImage: "wave.3.right")
                        .font(.headline.bold())
                    Text(engine.energy >= 100 ? "\(engine.configuration.pulseDuration)초 추격 정지" : "\(engine.metersToPulse)m 더 이동")
                        .font(.caption2)
                    ProgressView(value: engine.energy, total: 100)
                        .tint(engine.canUsePulse ? GhostRunTheme.canvas : GhostRunTheme.signal)
                        .padding(.horizontal, 14)
                }
                .frame(maxWidth: .infinity, minHeight: 66)
                .background(GhostRunTheme.signal.opacity(engine.canUsePulse ? 1 : 0.2), in: RoundedRectangle(cornerRadius: 16))
            }
            .disabled(!engine.canUsePulse)
            .foregroundStyle(engine.canUsePulse ? GhostRunTheme.canvas : .white)
            .accessibilityLabel("파동 \(Int(engine.energy))퍼센트 충전, \(engine.metersToPulse)미터 더 이동")
        }
        .buttonStyle(.plain)
    }

    private func displayHeading(for location: CLLocation) -> Double {
        if locationService.isSimulationEnabled {
            return locationService.simulatedHeading
        }
        return location.course >= 0 ? location.course : 0
    }

    private func updateCamera(for location: CLLocation) {
        let camera = MapCamera(
            centerCoordinate: location.coordinate,
            distance: 1_400,
            heading: mapHeading,
            pitch: 0
        )
        if reduceMotion {
            cameraPosition = .camera(camera)
        } else {
            withAnimation(.easeOut(duration: 0.45)) {
                cameraPosition = .camera(camera)
            }
        }
    }

    private func normalizedHeading(_ heading: Double) -> Double {
        let normalized = heading.truncatingRemainder(dividingBy: 360)
        return normalized >= 0 ? normalized : normalized + 360
    }
}
