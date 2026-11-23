import SwiftUI

/// 화면 아래의 녹화 패널 (iOS 음성 메모처럼). 쉴 때는 휴대 위치, 시작 동작, 빨간 녹화 버튼이 있고,
/// 녹화 중에는 시계, 움직임 파형, 동작 버튼, 중지 버튼이 나온다.
struct RecorderPanel: View {
    @ObservedObject var recorder: Recorder
    let serverURL: String
    let live: Bool  // 녹화하면서 서버로도 보낼지 (설정)
    @Binding var placement: String  // 휴대 위치. 녹화 전에 고르고, 다음 녹화에도 그대로 쓴다
    @Binding var activity: String  // 시작 동작 (Activity의 token). 비어 있으면 라벨 없이 시작한다. 다음 녹화에도 그대로 쓴다

    private static let placements = Placement.all.map { Choice(title: $0.title, token: $0.token) }
    private static let activities = [Choice(title: "고르지 않음", token: "")]
        + (Activity.all + [.idle]).map { Choice(title: $0.title, token: $0.token, color: $0.color) }

    var body: some View {
        VStack(spacing: 14) {
            if recorder.phase == .idle {
                if recorder.status != "대기 중" {
                    Text(recorder.status)  // 저장 완료, 주소 오류 등
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 10) {
                    ChoiceMenu(name: "휴대 위치", icon: "iphone", choices: Self.placements, selection: $placement)
                    ChoiceMenu(name: "시작 동작", icon: "figure.walk", choices: Self.activities, selection: $activity)
                }
            } else {
                header
                Waveform(levels: recorder.levels)
                ActivityPad(recorder: recorder)
            }
            RecordButton(recording: recorder.phase != .idle) {
                if recorder.phase == .recording {
                    recorder.stop()
                } else {
                    recorder.start(serverURL: serverURL, live: live, placement: placement,
                                   activity: Activity.named(activity)?.token)
                }
            }
            .disabled(recorder.phase == .draining)
        }
        .padding(.horizontal)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(.bar)
        .animation(.snappy, value: recorder.phase)
    }

    /// 녹화 이름과 휴대 위치, 경과 시간, 센서 상태
    private var header: some View {
        VStack(spacing: 4) {
            Text([recorder.live ? recorder.folder ?? "새 녹화" : "새 녹화", Placement.title(of: placement)]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.headline)
            if recorder.phase == .draining {
                Text(recorder.live ? "남은 데이터를 보내는 중…" : "저장하는 중…")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            } else if let startedAt = recorder.startedAt {
                TimelineView(.periodic(from: startedAt, by: 0.1)) { context in
                    Text(clockText(context.date.timeIntervalSince(startedAt)))
                        .font(.system(size: 40, weight: .light).monospacedDigit())
                }
            }
            Text(statusLine)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if recorder.live, let error = recorder.lastError {
                Text("실시간 전송 오류: \(error) (폰에는 저장 중)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var statusLine: String {
        var items = [String(format: "%.0f Hz", recorder.motionHz)]
        if let pressure = recorder.pressure {
            items.append(String(format: "%.2f hPa", pressure))
        }
        if let altitude = recorder.altitude {
            items.append(String(format: "고도 %+.2f m", altitude))
        }
        items.append("폰 \(recorder.saved)")
        if recorder.live {
            items.append("서버 \(recorder.sent)")
            if recorder.queued > 0 {
                items.append("대기 \(recorder.queued)")
            }
        }
        return items.joined(separator: " · ")
    }
}

/// 녹화 전에 고르는 값 하나(휴대 위치, 시작 동작)의 메뉴. 같은 크기의 카드 두 개가 나란히 놓인다:
/// 위에 작은 이름, 아래에 고른 값. 동작은 구간 막대와 같은 색 점을 붙인다
private struct ChoiceMenu: View {
    let name: String
    let icon: String  // 이름 앞의 SF Symbol
    let choices: [Choice]
    @Binding var selection: String

    private var current: Choice? { choices.first { $0.token == selection } }

    var body: some View {
        Menu {
            Picker(name, selection: $selection) {
                ForEach(choices) { choice in
                    Text(choice.title).tag(choice.token)
                }
            }
        } label: {
            // 메뉴 라벨은 강조색으로 물들어서, 글자 색을 직접 정한다
            VStack(alignment: .leading, spacing: 3) {
                Label(name, systemImage: icon)
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                HStack(spacing: 6) {
                    if let color = current?.color {
                        Circle()
                            .fill(color)
                            .frame(width: 8, height: 8)
                    }
                    Text(current?.title ?? "고르세요")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.primary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .accessibilityLabel("\(name): \(current?.title ?? "고르지 않음")")
    }
}

/// 메뉴의 선택지: 보이는 이름, 저장하는 token, (동작이면) 구간 막대의 색
private struct Choice: Identifiable {
    let title: String
    let token: String
    var color: Color? = nil
    var id: String { token }
}

/// 분:초.0.1초 (예: 00:12.3). 녹화 중 시계와 라벨 화면의 구간 시각이 같이 쓴다
func clockText(_ seconds: TimeInterval) -> String {
    let tenths = Int(max(seconds, 0) * 10)
    return String(format: "%02d:%02d.%d", tenths / 600, tenths / 10 % 60, tenths % 10)
}

/// 최근 6초의 움직임 크기를 막대로 그린다. 새 값이 오른쪽에 붙고 왼쪽으로 밀려난다.
private struct Waveform: View {
    let levels: [Double]

    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 4  // 막대 2pt + 틈 2pt
            let recent = levels.suffix(Int(size.width / step))
            for (i, level) in recent.enumerated() {
                let height = max(2, CGFloat(min(level / 6, 1)) * size.height)  // 6 m/s²에서 꽉 찬다
                let x = size.width - CGFloat(recent.count - i) * step
                let bar = CGRect(x: x, y: (size.height - height) / 2, width: 2, height: height)
                context.fill(Path(roundedRect: bar, cornerRadius: 1), with: .color(.red))
            }
        }
        .frame(height: 56)
        .accessibilityHidden(true)
    }
}

/// 녹화 중에 지금 하는 동작을 고르는 버튼들. 누른 때부터 다음에 누를 때까지가 그 동작 구간이 된다 (서버의 label.csv).
private struct ActivityPad: View {
    @ObservedObject var recorder: Recorder

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("지금 하는 동작")
                Spacer()
                if let segment = recorder.segment {
                    // 파형이 1초에 20번 바뀌어 이 값도 함께 다시 그려진다
                    Text("\(Activity.named(segment.label)?.title ?? segment.label) · \(Int(Date().timeIntervalSince(segment.since)))초째")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(Activity.all + [.idle], id: \.self) { activity in
                    ActivityButton(activity: activity, selected: recorder.segment?.label == activity.token) {
                        recorder.mark(activity.token)
                    }
                }
            }
        }
        .disabled(recorder.phase != .recording)
        .sensoryFeedback(.selection, trigger: recorder.segment?.since)
    }
}

private struct ActivityButton: View {
    let activity: Activity
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Circle()
                    .fill(activity.color)
                    .frame(width: 8, height: 8)
                Text(activity.short)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .font(.subheadline.weight(selected ? .semibold : .regular))
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(selected ? activity.color.opacity(0.18) : Color(.secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                if selected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(activity.color, lineWidth: 2)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 녹화 버튼. 쉴 때는 빨간 원, 녹화 중에는 빨간 네모(중지)
private struct RecordButton: View {
    let recording: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .strokeBorder(Color(.systemGray3), lineWidth: 4)
                RoundedRectangle(cornerRadius: recording ? 6 : 27)
                    .fill(.red)
                    .padding(recording ? 22 : 9)
            }
            .frame(width: 72, height: 72)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(recording ? "녹화 중지" : "녹화 시작")
    }
}
