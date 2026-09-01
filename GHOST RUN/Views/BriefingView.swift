import CoreLocation
import SwiftUI
import UIKit

struct BriefingView: View {
    @ObservedObject var engine: GameEngine
    @ObservedObject var locationService: LocationService
    @Environment(\.openURL) private var openURL
    @AppStorage("safetyAcknowledged") private var safetyAcknowledged = false
    @AppStorage("hapticsEnabled") private var hapticsEnabled = true
    @AppStorage("soundEnabled") private var soundEnabled = false
    @State private var presentedSheet: BriefingSheet?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                topBar
                titleBlock
                if engine.completedRuns > 0 {
                    personalBestCard
                }
                safetyCard
                howToPlayCard
                modeCard
                permissionCard
                startArea
            }
            .padding(.horizontal, 20)
            .padding(.top, 30)
            .padding(.bottom, 40)
            .frame(maxWidth: 680)
            .frame(maxWidth: .infinity)
        }
        .background {
            LinearGradient(
                colors: [GhostRunTheme.canvas, GhostRunTheme.elevated.opacity(0.7)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
        .sheet(item: $presentedSheet) { sheet in
            switch sheet {
            case .guide:
                GameGuideView()
            case .privacy:
                PrivacyInfoView()
            }
        }
    }

    private var topBar: some View {
        HStack {
            Label("GHOST RUN", systemImage: "moon.circle.fill")
                .font(.caption.weight(.black))
                .foregroundStyle(GhostRunTheme.signal)

            Spacer()

            Button {
                presentedSheet = .guide
            } label: {
                Image(systemName: "questionmark.circle")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("게임 방법")

            Button {
                presentedSheet = .privacy
            } label: {
                Image(systemName: "info.circle")
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("앱 정보와 개인정보")
        }
        .foregroundStyle(.white)
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("현실 러닝 서바이벌", systemImage: "figure.run")
                .font(.caption.weight(.bold))
                .foregroundStyle(GhostRunTheme.signal)

            Text("GHOST RUN")
                .font(.system(size: 46, weight: .black, design: .rounded))
                .tracking(-2)
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.72)

            Text("유령이 나를 쫓아옵니다. 캐릭터가 아니라 내가 직접 움직여야 합니다. \(engine.countdownDuration)초 동안 준비하고, 달려서 유령과 거리를 벌리세요.")
                .font(.body)
                .foregroundStyle(GhostRunTheme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var personalBestCard: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Label("내 기록", systemImage: "trophy.fill")
                    .font(.headline)
                Spacer()
                Text("GPS 러닝 \(engine.completedRuns)회")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(GhostRunTheme.secondaryText)
            }

            HStack(spacing: 8) {
                recordMetric("최고 점수", engine.bestScore.formatted())
                recordMetric("최장 거리", distanceText(engine.bestDistance))
                recordMetric("최장 생존", durationText(engine.longestSurvival))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nightPanel()
    }

    private func recordMetric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(GhostRunTheme.secondaryText)
            Text(value)
                .font(.subheadline.bold().monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GhostRunTheme.surface.opacity(0.85), in: RoundedRectangle(cornerRadius: 12))
    }

    private var safetyCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("먼저, 안전", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(GhostRunTheme.supply)
            Text("교통법규를 지키고 익숙한 야외 공간에서만 플레이하세요. 달리는 동안 화면을 오래 보지 말고, 차도·계단·사유지로 이동하지 마세요.")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.84))

            Toggle("안전 수칙을 확인했습니다", isOn: $safetyAcknowledged)
                .font(.subheadline.weight(.semibold))
                .tint(GhostRunTheme.supply)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GhostRunTheme.supply.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(GhostRunTheme.supply.opacity(0.35), lineWidth: 1)
        }
    }

    private var howToPlayCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("게임 방법", systemImage: "map.fill")
                    .font(.headline)
                Spacer()
                Button("자세히") { presentedSheet = .guide }
                    .font(.caption.bold())
                    .foregroundStyle(GhostRunTheme.signal)
            }

            guideRow("figure.walk", "내 속도로 이동", "걷기로 출발하세요. 추격과 숨 고르기 구간이 번갈아 옵니다.")
            guideRow("scope", "비상 사격 · \(engine.configuration.startingAmmo)발", "큰 사격 버튼으로 가까운 유령을 자동 조준합니다. 처치 점수는 없습니다.")
            guideRow("shippingbox.fill", "이동해서 보급", "보급 상자에 실제로 도달하면 탄약과 잠깐의 보호를 얻습니다.")
            guideRow("wave.3.right", "이동 충전 파동", "\(Int(engine.configuration.pulseChargeDistance))m마다 완충. \(engine.configuration.pulseDuration)초간 추격을 멈춥니다. 걷기도 충전됩니다.")
            Text("빈 공간에서는 유령이 바로 접근하고, 지도에 등록된 건물은 돌아갑니다. 주변 지도 영역은 건물 데이터 서버로, 회복 지점의 경로 요청 좌표는 Apple로 전달됩니다. 인터넷이 필요하며 지도 누락·위치 오차가 있을 수 있습니다. 실제 교통·출입 제한을 우선하세요.")
                .font(.footnote)
                .foregroundStyle(GhostRunTheme.secondaryText)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nightPanel()
    }

    private func guideRow(_ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(GhostRunTheme.signal)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(GhostRunTheme.secondaryText)
            }
        }
    }

    private var modeCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("러닝 설정", systemImage: "figure.run")
                .font(.headline)

            Toggle(isOn: $hapticsEnabled) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("진동 피드백")
                    Text("유령 위험 단계와 목표 도달을 진동으로 알려줍니다.")
                        .font(.caption)
                        .foregroundStyle(GhostRunTheme.secondaryText)
                }
            }
            .tint(GhostRunTheme.signal)

            Toggle("위기 음성 안내", isOn: $soundEnabled)
                .tint(GhostRunTheme.signal)

#if DEBUG
            Divider().overlay(Color.white.opacity(0.12))

            Toggle(isOn: simulationBinding) {
                VStack(alignment: .leading, spacing: 3) {
                    Label("Debug 가상 이동", systemImage: "location.viewfinder")
                    Text("실내에서 권한 없이 가상 좌표와 속도로 테스트합니다.")
                        .font(.caption)
                        .foregroundStyle(GhostRunTheme.secondaryText)
                }
            }
            .tint(GhostRunTheme.debug)

            if locationService.isSimulationEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("가상 속도")
                        Spacer()
                        Text(locationService.simulatedSpeed.formatted(.number.precision(.fractionLength(1))) + " m/s")
                            .monospacedDigit()
                            .foregroundStyle(GhostRunTheme.debug)
                    }
                    Slider(value: $locationService.simulatedSpeed, in: 0...5, step: 0.1)
                        .tint(GhostRunTheme.debug)
                }
                .font(.subheadline)
            }
#endif
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nightPanel()
    }

    private var permissionCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("위치 권한", systemImage: authorizationSymbol)
                    .font(.headline)
                Spacer()
                Text(authorizationLabel)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(authorizationColor)
            }

            Text("현재 위치는 기기 안에서 거리·속도와 게임 오브젝트를 계산하는 데만 사용합니다. 경로를 서버로 전송하거나 저장하지 않습니다.")
                .font(.caption)
                .foregroundStyle(GhostRunTheme.secondaryText)

            if let error = locationService.lastErrorMessage {
                Label(error, systemImage: "exclamationmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(GhostRunTheme.hazard)
            }

            if !locationService.isSimulationEnabled {
                permissionAction

                if locationService.accuracyAuthorization == .reducedAccuracy,
                   locationService.isAuthorized {
                    Button("이번 러닝에 정확한 위치 허용") {
                        locationService.requestTemporaryPrecision()
                    }
                    .buttonStyle(.bordered)
                    .tint(GhostRunTheme.signal)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nightPanel()
    }

    @ViewBuilder
    private var permissionAction: some View {
        switch locationService.authorizationStatus {
        case .notDetermined:
            Button("앱 사용 중 위치 허용") {
                locationService.requestWhenInUseAuthorization()
            }
            .buttonStyle(.borderedProminent)
            .tint(GhostRunTheme.signal)
            .foregroundStyle(GhostRunTheme.canvas)
        case .denied, .restricted:
            Button("설정에서 위치 권한 열기") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    openURL(url)
                }
            }
            .buttonStyle(.bordered)
            .tint(GhostRunTheme.hazard)
        case .authorizedAlways, .authorizedWhenInUse:
            Label(
                locationService.accuracyAuthorization == .fullAccuracy ? "정확한 위치 사용 가능" : "대략적인 위치만 허용됨",
                systemImage: "checkmark.circle.fill"
            )
            .font(.subheadline)
            .foregroundStyle(locationService.accuracyAuthorization == .fullAccuracy ? GhostRunTheme.signal : GhostRunTheme.supply)
        @unknown default:
            EmptyView()
        }
    }

    private var startArea: some View {
        VStack(spacing: 10) {
            Button(action: engine.beginSession) {
                HStack {
                    Image(systemName: "timer")
                    Text("\(engine.countdownDuration)초 준비 시작")
                    Spacer()
                    Image(systemName: "arrow.right")
                }
                .font(.headline)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, minHeight: 62)
            }
            .buttonStyle(.plain)
            .foregroundStyle(GhostRunTheme.canvas)
            .background(
                canBegin ? GhostRunTheme.signal : Color.gray,
                in: RoundedRectangle(cornerRadius: 18)
            )
            .disabled(!canBegin)

            Text(startHint)
                .font(.caption)
                .foregroundStyle(GhostRunTheme.secondaryText)
                .multilineTextAlignment(.center)
        }
    }

    private var canBegin: Bool {
        engine.canStart && safetyAcknowledged
    }

    private var startHint: String {
        if !safetyAcknowledged {
            return "안전 수칙을 확인한 뒤 시작할 수 있습니다."
        }
        if !engine.canStart {
            return "실제 플레이에는 정확한 위치 권한이 필요합니다."
        }
        return "준비시간 동안 GPS를 안정화합니다. 거리와 점수는 준비가 끝난 뒤부터 계산됩니다."
    }

#if DEBUG
    private var simulationBinding: Binding<Bool> {
        Binding(
            get: { locationService.isSimulationEnabled },
            set: { locationService.setSimulationEnabled($0) }
        )
    }
#endif

    private var authorizationLabel: String {
        if locationService.isSimulationEnabled { return "SIMULATION" }
        switch locationService.authorizationStatus {
        case .notDetermined: return "필요"
        case .denied: return "거부됨"
        case .restricted: return "제한됨"
        case .authorizedAlways: return "항상 허용"
        case .authorizedWhenInUse: return "사용 중 허용"
        @unknown default: return "확인 필요"
        }
    }

    private var authorizationSymbol: String {
        locationService.isSimulationEnabled ? "location.viewfinder" : "location.fill"
    }

    private var authorizationColor: Color {
        if locationService.isSimulationEnabled { return GhostRunTheme.debug }
        return locationService.isAuthorized ? GhostRunTheme.signal : GhostRunTheme.hazard
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

private enum BriefingSheet: String, Identifiable {
    case guide
    case privacy

    var id: String { rawValue }
}
