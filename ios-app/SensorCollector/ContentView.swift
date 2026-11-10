import SwiftUI

struct ContentView: View {
    @StateObject private var recorder = Recorder()
    @AppStorage("serverURL") private var serverURL = "https://mac.tail2f6d0f.ts.net/app"

    var body: some View {
        NavigationStack {
            Form {
                Section("서버") {
                    TextField("주소", text: $serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(recorder.phase != .idle)
                }
                Section {
                    Button {
                        if recorder.phase == .recording {
                            recorder.stop()
                        } else {
                            recorder.start(serverURL: serverURL)
                        }
                    } label: {
                        Text(buttonTitle)
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }  // 구분선을 행 왼쪽 끝부터
                    }
                    .disabled(recorder.phase == .draining)
                    .tint(recorder.phase == .recording ? Color.red : Color.accentColor)
                    Text(recorder.status)
                        .foregroundStyle(.secondary)
                }
                Section("수집 상태") {
                    LabeledContent("경과 시간", value: "\(Int(recorder.elapsed))초")
                    LabeledContent("동작 센서", value: String(format: "%.1f Hz", recorder.motionHz))
                    LabeledContent("기압", value: recorder.pressure.map { String(format: "%.2f hPa", $0) } ?? "–")
                    LabeledContent("상대 고도", value: recorder.altitude.map { String(format: "%+.2f m", $0) } ?? "–")
                    LabeledContent("서버 저장", value: "\(recorder.sent)개")
                    LabeledContent("전송 대기", value: "\(recorder.queued)개")
                    if let folder = recorder.folder {
                        LabeledContent("저장 폴더", value: folder)
                    }
                    if let error = recorder.lastError {
                        LabeledContent("전송 오류", value: error)
                    }
                }
                Section {
                    Text("화면을 꺼도 계속 수집합니다. 위치 권한은 화면이 꺼진 동안 앱이 멈추지 않게 하는 데만 쓰고, 위치 값은 저장하지 않습니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("센서 수집")
        }
    }

    private var buttonTitle: String {
        switch recorder.phase {
        case .idle: "수집 시작"
        case .recording: "중지"
        case .draining: "보내는 중…"
        }
    }
}
