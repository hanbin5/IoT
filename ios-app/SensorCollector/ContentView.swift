import SwiftUI

/// 첫 화면: 폰에 저장한 녹화 목록과 아래쪽 녹화 패널 (iOS 음성 메모처럼).
/// 녹화는 언제나 폰에 먼저 저장되고, 목록에서 골라 서버로 보낸다.
struct ContentView: View {
    @StateObject private var recorder = Recorder()
    @StateObject private var store = RecordingStore()
    @AppStorage("serverURL") private var serverURL = "https://mac.tail2f6d0f.ts.net/app"
    @AppStorage("liveUpload") private var liveUpload = false
    @AppStorage("placement") private var placement = Placement.standard.token  // 마지막에 고른 휴대 위치
    @AppStorage("startActivity") private var startActivity = ""  // 마지막에 고른 시작 동작 ("" = 고르지 않음)
    @State private var showSettings = false
    @State private var selecting = false
    @State private var selection = Set<String>()
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            LocalRecordingsView(store: store, recorder: recorder, serverURL: serverURL,
                                selecting: selecting, selection: $selection)
                .navigationTitle("녹화")
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        NavigationLink {
                            RecordingsView(serverURL: serverURL)
                                .navigationTitle("서버의 녹화")
                        } label: {
                            Label("서버의 녹화", systemImage: "server.rack")
                        }
                    }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button(selecting ? "완료" : "선택") {
                            selecting.toggle()
                            selection.removeAll()
                        }
                        .disabled(!selecting && (recorder.phase != .idle || store.recordings.isEmpty))
                        Button {
                            showSettings = true
                        } label: {
                            Label("설정", systemImage: "gearshape")
                        }
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if selecting {
                        selectionBar
                    } else {
                        RecorderPanel(recorder: recorder, serverURL: serverURL, live: liveUpload,
                                      placement: $placement, activity: $startActivity)
                    }
                }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(serverURL: $serverURL, liveUpload: $liveUpload, editable: recorder.phase == .idle)
        }
        .confirmationDialog("녹화 \(selection.count)개를 폰에서 지울까요?", isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("지우기", role: .destructive) {
                store.delete(selection)
                selection.removeAll()
                selecting = false
            }
        } message: {
            Text(deleteMessage)
        }
        .onAppear { store.reload() }
        .onChange(of: recorder.currentID) {  // 녹화를 시작하거나 마치면 목록에 바로 나온다
            store.active = recorder.currentID
            store.reload()
        }
    }

    /// 고르는 동안 녹화 패널 자리에 나오는 막대
    private var selectionBar: some View {
        HStack {
            Button("보내기") {
                let ids = store.recordings.map(\.id).filter(selection.contains)  // 목록 순서대로
                selection.removeAll()
                selecting = false
                Task { await store.upload(ids, serverURL: serverURL) }
            }
            .disabled(selection.isEmpty)
            Spacer()
            Text(selection.isEmpty ? "녹화를 고르세요" : "\(selection.count)개 선택")
                .foregroundStyle(.secondary)
            Spacer()
            Button("지우기", role: .destructive) {
                confirmDelete = true
            }
            .disabled(selection.isEmpty)
        }
        .padding()
        .background(.bar)
    }

    private var deleteMessage: String {
        let notSent = store.recordings.filter { selection.contains($0.id) && $0.uploadedAt == nil }.count
        return notSent == 0 ? "서버에 보낸 데이터는 서버에 남습니다." : "그중 \(notSent)개는 아직 서버에 보내지 않아 지우면 되살릴 수 없습니다."
    }
}

/// 서버 주소, 실시간 전송, 수집 안내
private struct SettingsView: View {
    @Binding var serverURL: String
    @Binding var liveUpload: Bool
    let editable: Bool  // 녹화 중에는 바꾸지 않는다

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("주소", text: $serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("서버")
                } footer: {
                    Text("녹화를 보내는 곳입니다. '서버의 녹화' 목록도 여기서 불러옵니다.")
                }
                .disabled(!editable)
                Section {
                    Toggle("녹화하면서 서버로 보내기", isOn: $liveUpload)
                } footer: {
                    Text("켜면 녹화하는 동안 1초마다 서버로도 보냅니다. 서버에서 실시간으로 분석할 때 켜세요. 끄면 폰에만 저장하고, 목록에서 골라 보냅니다. 어느 쪽이든 녹화는 폰에 남습니다.")
                }
                .disabled(!editable)
                Section {
                    Text("화면을 꺼도 계속 수집합니다. 위치 권한은 화면이 꺼진 동안 앱이 멈추지 않게 하는 데만 쓰고, 위치 값은 저장하지 않습니다.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                }
            }
        }
    }
}
