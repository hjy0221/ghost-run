import SwiftUI

struct GameGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("살아남는 법")
                        .font(.system(size: 34, weight: .black, design: .rounded))

                    guideCard(
                        number: "1",
                        title: "\(GameConfiguration.standard.preparationDuration)초 동안 준비",
                        detail: "GPS 신호와 주변 안전을 확인하세요. 준비 중에는 기록이 시작되지 않습니다.",
                        symbol: "timer"
                    )
                    guideCard(
                        number: "2",
                        title: "화면보다 현실 우선",
                        detail: "익숙하고 열린 보행 공간에서 달리세요. 지도 표시를 따라 차도나 사유지로 들어가지 마세요.",
                        symbol: "eye.fill"
                    )
                    guideCard(
                        number: "3",
                        title: "유령과 거리 유지",
                        detail: "실제로 움직여 유령과 거리를 벌리세요. 100m 이동할 때마다 +50점이며, 가까워진 유령을 따돌리면 탈출 보너스를 얻습니다. 위험한 상황에서는 달리는 대신 일시 정지하세요.",
                        symbol: "figure.run"
                    )
                    guideCard(
                        number: "4",
                        title: "이동해서 탄약 보급",
                        detail: "사격은 \(GameConfiguration.standard.startingAmmo)발의 비상 수단입니다. 큰 버튼을 누르면 시야 안 가까운 유령을 자동 조준하고, 탄환이 도착하면 사라집니다. 보급 상자에 실제로 도달하면 탄약과 잠깐의 보호를 얻습니다. 통행이 불가능한 목표는 일시 정지에서 건너뛰세요.",
                        symbol: "shippingbox.fill"
                    )

                    guideCard(
                        number: "5",
                        title: "내 속도로 충전하고 회복",
                        detail: "파동은 걷거나 달린 거리로만 충전됩니다. \(Int(GameConfiguration.standard.pulseChargeDistance))m 이동으로 완충되면 \(GameConfiguration.standard.pulseDuration)초간 추격을 멈춥니다. 보호막은 별도의 짧은 비상 수단입니다. 추격 중에도 회복 구간에서는 유령이 느려집니다. 게임 신호 때문에 무리하게 속도를 높이지 말고, 피곤하거나 주변이 위험하면 바로 일시정지하세요.",
                        symbol: "wave.3.right"
                    )

                    Label(
                        "앱을 잠그거나 다른 앱으로 이동하면 게임과 위치 추적이 자동으로 일시 정지됩니다.",
                        systemImage: "lock.iphone"
                    )
                    .font(.footnote)
                    .foregroundStyle(GhostRunTheme.secondaryText)
                    .padding(16)
                    .nightPanel()
                }
                .padding(20)
            }
            .background(GhostRunTheme.canvas.ignoresSafeArea())
            .navigationTitle("게임 방법")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func guideCard(number: String, title: String, detail: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(GhostRunTheme.signal.opacity(0.14))
                Image(systemName: symbol)
                    .foregroundStyle(GhostRunTheme.signal)
            }
            .frame(width: 48, height: 48)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text("STEP \(number) · \(title)")
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(GhostRunTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nightPanel()
    }
}

struct PrivacyInfoView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    infoSection(
                        "위치정보",
                        symbol: "location.fill",
                        text: "현재 위치·거리·속도는 기기에서 계산합니다. 건물 지도 조회를 위해 현재 위치를 포함한 주변 지도 영역을 데이터 서버로 전달합니다. 개발용은 overpass-api.de를 사용하며 상대 서버는 요청과 IP 주소를 받을 수 있습니다. Safe Light 보행 경로 좌표는 Apple로 전달됩니다. 앱은 이동 경로를 저장/분석 서버에 보내지 않고 세션 종료 시 메모리의 지도와 경로를 정리합니다."
                    )
                    infoSection(
                        "백그라운드",
                        symbol: "pause.circle.fill",
                        text: "화면을 잠그거나 다른 앱으로 이동하면 게임과 위치 추적을 중지합니다. 앱으로 돌아온 뒤 사용자가 직접 재개해야 합니다."
                    )
                    infoSection(
                        "기록",
                        symbol: "trophy.fill",
                        text: "최고 점수, 최장 거리, 생존 시간과 러닝 횟수만 이 기기에 저장합니다. Debug 가상 이동 기록은 개인 기록에 포함하지 않습니다."
                    )
                    infoSection(
                        "건강 및 안전",
                        symbol: "heart.text.square.fill",
                        text: "이 앱은 게임이며 건강 측정, 응급 구조 또는 경로 안내 서비스가 아닙니다. 항상 실제 주변 환경과 교통 규칙을 우선하세요."
                    )

                    Link("건물 지도 © OpenStreetMap contributors · ODbL", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                        .font(.footnote)
                    Text("지도 데이터 누락·오차와 공사·출입 제한을 완벽히 판별하지 않습니다. Release 빌드는 별도 건물 지도 서버 설정이 필요합니다.")
                        .font(.caption)
                        .foregroundStyle(GhostRunTheme.secondaryText)
                    Text("GHOST RUN · Version 1.0")
                        .font(.caption)
                        .foregroundStyle(GhostRunTheme.secondaryText)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                }
                .padding(20)
            }
            .background(GhostRunTheme.canvas.ignoresSafeArea())
            .navigationTitle("앱 정보와 개인정보")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func infoSection(_ title: String, symbol: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: symbol)
                .font(.headline)
                .foregroundStyle(GhostRunTheme.signal)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.84))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nightPanel()
    }
}
