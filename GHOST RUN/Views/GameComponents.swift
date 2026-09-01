import SwiftUI

struct RunStatsCapsule: View {
    @ObservedObject var engine: GameEngine

    var body: some View {
        HStack(spacing: 0) {
            metric("시간", durationText(engine.elapsedSeconds), "timer")
            divider
            metric("거리", distanceText(engine.distanceMeters), "figure.run")
            divider
            metric("유령과 거리", threatText, "moon.fill")
        }
        .padding(.vertical, 12)
        .nightPanel(cornerRadius: 20)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "생존 시간 \(durationText(engine.elapsedSeconds)), 이동 거리 \(distanceText(engine.distanceMeters)), 가장 가까운 위협 \(threatText)"
        )
    }

    private func metric(_ label: String, _ value: String, _ symbol: String) -> some View {
        VStack(spacing: 3) {
            Label(label, systemImage: symbol)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(GhostRunTheme.secondaryText)
                .labelStyle(.titleAndIcon)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 26, weight: .black, design: .rounded))
                .monospacedDigit()
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(width: 1, height: 36)
    }

    private var threatText: String {
        guard let distance = engine.nearestThreatDistance else { return "경로 대기" }
        return "\(Int(distance)) m"
    }

    private func durationText(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func distanceText(_ meters: Double) -> String {
        meters >= 1_000
            ? String(format: "%.1f km", meters / 1_000)
            : "\(Int(meters)) m"
    }
}

struct ThreatPressureRibbon: View {
    @ObservedObject var engine: GameEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(engine.isRecoveringLocation ? "위치 연결 회복 중" : engine.dangerLevel.rawValue,
                      systemImage: engine.isRecoveringLocation ? "location.slash" : "waveform.path")
                    .font(.title3.weight(.black))
                Spacer()
                if !engine.isRecoveringLocation {
                    Text("유령 \(engine.ghostCount)")
                        .font(.subheadline.bold().monospacedDigit())
                }
                if engine.catchSeconds > 0 {
                    Text("접근 경고 · \(engine.configuration.catchGraceDuration - engine.catchSeconds)초")
                        .font(.subheadline.bold())
                }
            }
            Text(engine.isRecoveringLocation ? "추격·기록 보호 중 · 연결되면 자동 재개"
                 : engine.isRoutingSuspended ? engine.routingStatus : (engine.isProtected ? "\(engine.protectionSeconds)초 보호 · 숨을 고르세요" : engine.runRhythm.title))
                .font(.caption)
        }
        .foregroundStyle(color)
        .padding(10)
        .nightPanel(cornerRadius: 16)
        .accessibilityElement(children: .combine)
    }

    private var color: Color {
        if engine.isRecoveringLocation { return GhostRunTheme.secondaryText }
        return switch engine.dangerLevel {
        case .critical, .caught: GhostRunTheme.hazard
        case .danger, .watch: GhostRunTheme.supply
        case .safe: GhostRunTheme.signal
        case .unknown: GhostRunTheme.secondaryText
        }
    }
}

struct EventToastView: View {
    let event: GameEvent

    var body: some View {
        Label(event.message, systemImage: symbol)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .background(color.opacity(0.9), in: Capsule())
            .overlay { Capsule().stroke(Color.white.opacity(0.25), lineWidth: 1) }
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .accessibilityAddTraits(.isStaticText)
    }

    private var symbol: String {
        switch event.tone {
        case .signal: return "dot.radiowaves.left.and.right"
        case .warning: return "exclamationmark.triangle.fill"
        case .supply: return "shippingbox.fill"
        case .neutral: return "info.circle.fill"
        }
    }

    private var color: Color {
        switch event.tone {
        case .signal: return GhostRunTheme.signal.opacity(0.8)
        case .warning: return GhostRunTheme.hazard.opacity(0.8)
        case .supply: return GhostRunTheme.supply.opacity(0.8)
        case .neutral: return GhostRunTheme.elevated
        }
    }

    private var foregroundColor: Color {
        switch event.tone {
        case .signal, .supply:
            return GhostRunTheme.canvas
        case .warning, .neutral:
            return .white
        }
    }
}

struct RunnerBeaconMarker: View {
    let heading: Double

    var body: some View {
        ZStack {
            Circle()
                .fill(GhostRunTheme.signal.opacity(0.2))
                .frame(width: 48, height: 48)
            Circle()
                .stroke(GhostRunTheme.signal.opacity(0.55), lineWidth: 2)
                .frame(width: 36, height: 36)
            Image(systemName: "location.north.fill")
                .font(.system(size: 18, weight: .black))
                .foregroundStyle(GhostRunTheme.signal)
                .rotationEffect(.degrees(heading))
        }
        .shadow(color: GhostRunTheme.signal.opacity(0.55), radius: 8)
        .accessibilityLabel("내 위치")
    }
}

struct GhostSilhouette: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + rect.width * 0.12, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.15, y: rect.minY + rect.height * 0.43))
        path.addQuadCurve(to: CGPoint(x: rect.midX, y: rect.minY), control: CGPoint(x: rect.minX + rect.width * 0.1, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + rect.width * 0.85, y: rect.minY + rect.height * 0.43), control: CGPoint(x: rect.maxX - rect.width * 0.1, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.12, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.width * 0.62 + rect.minX, y: rect.maxY - rect.height * 0.16))
        path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.width * 0.38 + rect.minX, y: rect.maxY - rect.height * 0.16))
        path.closeSubpath()
        return path
    }
}

struct GhostMarker: View {
    let isCritical: Bool
    var isTargeted = false
    var body: some View {
        ZStack {
            Circle().fill(Color.black.opacity(0.85)).frame(width: 48, height: 48)
            GhostSilhouette()
                .fill(LinearGradient(colors: [.white.opacity(0.95), .purple.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                .frame(width: 30, height: 34)
            HStack(spacing: 5) {
                Capsule().frame(width: 4, height: 7)
                Capsule().frame(width: 4, height: 7)
            }
            .foregroundStyle(.black)
            .offset(y: -3)
            Circle().stroke(isCritical ? GhostRunTheme.hazard : Color.purple.opacity(0.8), lineWidth: isCritical ? 3 : 1)
                .frame(width: 50, height: 50)
        }
        .shadow(color: isCritical ? GhostRunTheme.hazard.opacity(0.7) : .purple.opacity(0.4), radius: isCritical ? 9 : 4)
        .overlay {
            if isTargeted {
                Image(systemName: "scope")
                    .font(.system(size: 58, weight: .ultraLight))
                    .foregroundStyle(GhostRunTheme.supply)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel(isCritical ? "유령이 가까이 다가왔습니다" : "나를 쫓아오는 유령")
    }
}

struct SafeLightMarker: View {
    var body: some View {
        Image(systemName: "shippingbox.fill")
            .font(.system(size: 23, weight: .bold))
            .foregroundStyle(GhostRunTheme.supply)
            .padding(10)
            .background(.black.opacity(0.8), in: Circle())
            .overlay(Circle().stroke(GhostRunTheme.supply.opacity(0.8), lineWidth: 2))
            .accessibilityLabel("탄약 보급과 회복 지점")
    }
}

struct CountdownOverlay: View {
    let seconds: Int
    let totalSeconds: Int
    let waitingForGPS: Bool
    let accuracyText: String
    let routingStatus: String
    let onCancel: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.48).ignoresSafeArea()
            VStack(spacing: 24) {
                if seconds == 0 {
                    Image(systemName: "location.magnifyingglass")
                        .font(.system(size: 44, weight: .bold))
                        .foregroundStyle(GhostRunTheme.supply)
                    Text(waitingForGPS ? "위치 신호 대기" : "추격 준비")
                        .font(.system(size: 30, weight: .black, design: .rounded))
                    Text(waitingForGPS ? "정확한 위치가 잡히면 주변 지도를 확인합니다." : routingStatus + "\n건물 지도가 없으면 추격을 시작하지 않습니다.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(GhostRunTheme.secondaryText)
                } else {
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.12), lineWidth: 12)
                        Circle()
                            .trim(
                                from: 0,
                                to: min(
                                    1,
                                    max(0, CGFloat(totalSeconds - seconds) / CGFloat(max(1, totalSeconds)))
                                )
                            )
                            .stroke(
                                GhostRunTheme.signal,
                                style: StrokeStyle(lineWidth: 12, lineCap: .round)
                            )
                            .rotationEffect(.degrees(-90))
                        Text("\(seconds)")
                            .font(.system(size: 58, weight: .black, design: .rounded))
                            .monospacedDigit()
                    }
                    .frame(width: 180, height: 180)

                    Text("러닝 준비")
                        .font(.headline.weight(.black))
                    Text("몸을 풀고 주변 안전을 확인하세요.\n아직 거리와 점수는 계산되지 않습니다.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(GhostRunTheme.secondaryText)
                }

                Label(accuracyText, systemImage: "location.fill")
                    .font(.subheadline.bold())
                    .foregroundStyle(GhostRunTheme.signal)

                Button("준비 취소", action: onCancel)
                    .buttonStyle(.bordered)
                    .tint(.white)
            }
            .padding(28)
            .frame(maxWidth: 360)
            .nightPanel(cornerRadius: 28)
            .padding(20)
        }
        .accessibilityLabel(
            waitingForGPS
                ? "GPS 신호를 기다리는 중"
                : "준비 시간 \(seconds)초 남음"
        )
    }
}

struct PauseOverlay: View {
    let reason: PauseReason
    let canResume: Bool
    let onResume: () -> Void
    let canSkipSupply: Bool
    let onSkipSupply: () -> Void
    let onEnd: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.65).ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: reason == .gpsSignalLost ? "location.slash.fill" : "pause.circle.fill")
                    .font(.system(size: 44, weight: .bold))
                    .foregroundStyle(reason == .gpsSignalLost ? GhostRunTheme.supply : GhostRunTheme.signal)
                Text(reason.title)
                    .font(.title2.bold())
                Text(reason.message)
                    .foregroundStyle(GhostRunTheme.secondaryText)
                    .multilineTextAlignment(.center)

                Button("안전 확인 후 재개", action: onResume)
                    .buttonStyle(.borderedProminent)
                    .tint(GhostRunTheme.signal)
                    .foregroundStyle(GhostRunTheme.canvas)
                    .disabled(!canResume)

                Button("접근 어려운 Safe Light 건너뛰기", action: onSkipSupply)
                    .buttonStyle(.bordered)
                    .tint(GhostRunTheme.supply)
                    .disabled(!canSkipSupply)
                Text("위험한 목표는 무시하세요. 건너뛰기는 플레이 시간 20초마다 가능합니다.")
                    .font(.caption)
                    .foregroundStyle(GhostRunTheme.secondaryText)

                Button("러닝 종료", action: onEnd)
                    .buttonStyle(.bordered)
                    .tint(GhostRunTheme.hazard)
            }
            .padding(26)
            .frame(maxWidth: 350)
            .nightPanel(cornerRadius: 26)
            .padding(20)
        }
    }
}

#if DEBUG
struct DebugSimulationControls: View {
    @ObservedObject var locationService: LocationService
    @ObservedObject var engine: GameEngine
    @State private var expanded = false

    var body: some View {
        VStack(spacing: 9) {
            HStack {
                Button { expanded.toggle() } label: {
                    Label("가상 이동", systemImage: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption.bold())
                        .frame(minHeight: 44)
                }
                Spacer()
                Text("\(locationService.simulatedSpeed, specifier: "%.1f") m/s")
                    .font(.caption.monospacedDigit())
                Menu {
                    Toggle("추격 경로 표시", isOn: $engine.showsDebugRoutes)
                    Toggle("건물·장애물 경계 표시", isOn: $engine.showsDebugObstacles)
                    Button("유령 생성 · 경로 확인") { engine.debugSpawn(.ghost) }
                    Button("보급 상자 생성") { engine.debugSpawn(.safeLight) }
                    Button("강제 경로 재탐색") { engine.debugForceReroute() }
                    Button("유령 경로상 30m 전진") { engine.debugMoveGhostAlongRoute() }
                    Button("유령 속도 +0.3m/s") { engine.debugGhostSpeed = min(4, (engine.debugGhostSpeed ?? engine.configuration.baseGhostSpeed) + 0.3) }
                    Button("유령 속도 -0.3m/s") { engine.debugGhostSpeed = max(0, (engine.debugGhostSpeed ?? engine.configuration.baseGhostSpeed) - 0.3) }
                    Button("CRITICAL 표시 테스트") { engine.debugDangerOverride = .critical }
                    Button("기본 속도/위험 표시 복귀") { engine.debugGhostSpeed = nil; engine.debugDangerOverride = nil }
                    Button("파동 충전 (테스트)") { engine.debugChargePulse() }
                    Button("보급 테스트 (유령 정지)") {
                        if let path = engine.nearestSupply?.safePath {
                            engine.debugGhostSpeed = 0
                            locationService.followSimulationPath(path)
                            locationService.simulatedSpeed = 3
                        }
                    }
                    .disabled(engine.nearestSupply == nil)
                    Button("강제 게임 오버", role: .destructive) { engine.debugGameOver() }

                } label: {
                    Image(systemName: "wrench.and.screwdriver")
                        .frame(width: 44, height: 44)
                }
                .disabled(engine.phase != .running)
                .accessibilityLabel("가상 이동 테스트 도구")
            }

            if expanded { HStack(spacing: 14) {
                Button { locationService.rotateSimulation(by: -22.5) } label: {
                    Image(systemName: "arrow.turn.up.left")
                        .frame(width: 44, height: 44)
                }
                Slider(value: $locationService.simulatedSpeed, in: 0...5, step: 0.1)
                    .accessibilityLabel("가상 이동 속도")
                    .accessibilityValue("\(locationService.simulatedSpeed, specifier: "%.1f") 미터 매초")
                Button { locationService.rotateSimulation(by: 22.5) } label: {
                    Image(systemName: "arrow.turn.up.right")
                        .frame(width: 44, height: 44)
                }
            } }
        }
        .foregroundStyle(GhostRunTheme.debug)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(GhostRunTheme.debug.opacity(0.13), in: RoundedRectangle(cornerRadius: 15))
        .overlay {
            RoundedRectangle(cornerRadius: 15)
                .stroke(GhostRunTheme.debug.opacity(0.5), lineWidth: 1)
        }
    }
}
#endif
