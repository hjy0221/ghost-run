import SwiftUI

struct SummaryView: View {
    let result: SessionResult
    let onRestart: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: result.reason == .userEnded ? "flag.checkered" : "waveform.path.ecg")
                    .font(.system(size: 46, weight: .bold))
                    .foregroundStyle(result.reason == .userEnded ? GhostRunTheme.signal : GhostRunTheme.hazard)

                VStack(spacing: 7) {
                    Text(result.reason.title)
                        .font(.system(size: 28, weight: .black, design: .rounded))
                    Text(result.usedSimulation ? "DEBUG 가상 이동 결과" : "러닝 완료")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(result.usedSimulation ? GhostRunTheme.debug : GhostRunTheme.secondaryText)
                }

                if result.isNewHighScore {
                    Label("새로운 최고 기록", systemImage: "trophy.fill")
                        .font(.subheadline.bold())
                        .foregroundStyle(GhostRunTheme.canvas)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(GhostRunTheme.supply, in: Capsule())
                        .accessibilityAddTraits(.isHeader)
                }

                VStack(spacing: 1) {
                    Text(result.score.formatted())
                        .font(.system(size: 54, weight: .black, design: .rounded))
                        .monospacedDigit()
                    Text("생존 점수")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(GhostRunTheme.secondaryText)
                }

                LazyVGrid(columns: [.init(.flexible()), .init(.flexible())], spacing: 12) {
                    resultMetric("생존 시간", durationText(result.survivedSeconds), "timer")
                    resultMetric("이동 거리", distanceText(result.distanceMeters), "figure.run")
                    resultMetric("보급 도착", result.cachesCollected.formatted(), "shippingbox.fill")
                    resultMetric("최고 압박", "\(Int(result.peakPressure))%", "exclamationmark.triangle.fill")
                    resultMetric("기록 모드", result.usedSimulation ? "가상" : "GPS", "location.fill")
                    resultMetric("이동한 시간", durationText(result.movingSeconds), "figure.walk")
                    resultMetric("움직임 보너스", "+\(result.movementBonus)", "star.fill")
                    resultMetric("추격 탈출", "\(result.escapes)회", "figure.run")
                }

                Text("위치 경로는 저장하지 않았습니다. 주변을 확인하고 충분히 회복한 뒤 다시 시작하세요.")
                    .font(.footnote)
                    .foregroundStyle(GhostRunTheme.secondaryText)
                    .multilineTextAlignment(.center)

                VStack(spacing: 12) {
                    ShareLink(item: shareText) {
                        Label("결과 공유", systemImage: "square.and.arrow.up")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 54)
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)

                    Button(action: onRestart) {
                        Label("브리핑으로 돌아가기", systemImage: "arrow.counterclockwise")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 58)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(GhostRunTheme.signal)
                    .foregroundStyle(GhostRunTheme.canvas)
                }
            }
            .padding(22)
            .frame(maxWidth: 620)
            .frame(maxWidth: .infinity)
        }
        .background(GhostRunTheme.canvas.ignoresSafeArea())
    }

    private func resultMetric(_ label: String, _ value: String, _ symbol: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(GhostRunTheme.signal)
            Text(value)
                .font(.title3.bold())
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(GhostRunTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, minHeight: 112)
        .nightPanel()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(value)")
    }

    private func durationText(_ seconds: Int) -> String {
        String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }

    private func distanceText(_ meters: Double) -> String {
        meters >= 1_000
            ? String(format: "%.2f km", meters / 1_000)
            : "\(Int(meters)) m"
    }

    private var shareText: String {
        "GHOST RUN에서 실제로 \(distanceText(result.distanceMeters))를 이동하며 \(durationText(result.survivedSeconds)) 동안 살아남아 \(result.score)점을 기록했습니다."
    }
}
