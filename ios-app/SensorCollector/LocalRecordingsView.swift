import SwiftUI

/// 첫 화면의 녹화 목록: 폰에 저장한 녹화. 누르면 펼쳐지고, 밀거나 '선택'으로 골라 서버로 보내거나 지운다.
struct LocalRecordingsView: View {
    @ObservedObject var store: RecordingStore
    @ObservedObject var recorder: Recorder
    let serverURL: String
    let selecting: Bool
    @Binding var selection: Set<String>

    @State private var expanded: String?
    @State private var editing: LabelTarget?
    @State private var deleting: LocalRecording?

    var body: some View {
        List {
            if let error = store.error {
                Text(error)
                    .foregroundStyle(.red)
                    .onTapGesture { store.error = nil }  // 눌러서 닫는다
            }
            Section {
                ForEach(store.recordings) { recording in
                    let recordingNow = recording.id == recorder.currentID
                    LocalRecordingRow(recording: recording,
                                      recordingNow: recordingNow,
                                      expanded: expanded == recording.id && !selecting,
                                      selected: selecting ? selection.contains(recording.id) : nil,
                                      progress: store.progress[recording.id],
                                      edit: { editing = recording.labelTarget },
                                      setPlacement: { placement in
                                          Task { await store.setPlacement(placement, for: recording.id, serverURL: serverURL) }
                                      },
                                      upload: { upload(recording) },
                                      delete: { deleting = recording })
                        .contentShape(Rectangle())
                        .onTapGesture { tap(recording) }
                        .swipeActions(edge: .trailing) {
                            if !recordingNow {
                                // 밀어서 연 버튼이 닫히는 동안에는 확인 창이 뜨지 않아, 닫힌 뒤에 띄운다
                                Button {
                                    Task {
                                        try? await Task.sleep(for: .milliseconds(400))
                                        deleting = recording
                                    }
                                } label: {
                                    Label("지우기", systemImage: "trash")
                                }
                                .tint(.red)
                            }
                        }
                        .swipeActions(edge: .leading) {
                            if !recordingNow {
                                Button {
                                    upload(recording)
                                } label: {
                                    Label("보내기", systemImage: "arrow.up.circle")
                                }
                                .tint(Color.accentColor)
                            }
                        }
                }
            } header: {
                if store.recordings.contains(where: { !$0.parts.isEmpty }) {
                    SegmentLegend()
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if store.recordings.isEmpty {
                ContentUnavailableView("녹화 없음", systemImage: "waveform",
                                       description: Text("아래 빨간 버튼으로 녹화를 시작하세요. 녹화는 폰에 저장되고, 골라서 서버로 보냅니다."))
            }
        }
        .refreshable { store.reload() }
        .sheet(item: $editing) { target in
            LabelEditor(target: target) { segments in
                try await store.setSegments(segments, for: target.id, serverURL: serverURL)
            }
        }
        .confirmationDialog("이 녹화를 폰에서 지울까요?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { recording in
            Button("지우기", role: .destructive) {
                store.delete([recording.id])
            }
        } message: { recording in
            Text(recording.uploadedAt == nil
                 ? "아직 서버에 보내지 않은 녹화라 지우면 되살릴 수 없습니다."
                 : "서버에 보낸 데이터는 서버에 남습니다.")
        }
    }

    private func tap(_ recording: LocalRecording) {
        if selecting {
            guard recording.id != recorder.currentID else { return }
            if selection.contains(recording.id) {
                selection.remove(recording.id)
            } else {
                selection.insert(recording.id)
            }
        } else {
            withAnimation(.snappy) {
                expanded = expanded == recording.id ? nil : recording.id
            }
        }
    }

    private func upload(_ recording: LocalRecording) {
        Task { await store.upload([recording.id], serverURL: serverURL) }
    }
}

/// 폰의 녹화 한 줄: 라벨의 동작들, 날짜와 휴대 위치, 길이, 보냈는지, 구간 막대. 펼치면 요약과 버튼이 나온다.
private struct LocalRecordingRow: View {
    let recording: LocalRecording
    let recordingNow: Bool
    let expanded: Bool
    let selected: Bool?  // 고르는 중이 아니면 nil
    let progress: Double?  // 보내는 중이면 진행률
    let edit: () -> Void
    let setPlacement: (String) -> Void
    let upload: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let selected {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(recording.title ?? "라벨 없는 녹화")
                        .font(.headline)
                        .foregroundStyle(recording.title == nil ? .secondary : .primary)
                        .lineLimit(1)
                    if recordingNow {
                        Text("녹화 중")
                            .font(.caption.bold())
                            .foregroundStyle(.red)
                    }
                    Spacer()
                    uploadState
                }
                HStack {
                    Text([dayText(recording.startedAt), Placement.title(of: recording.placement)]
                        .compactMap { $0 }.joined(separator: " · "))
                        .lineLimit(1)
                    Spacer()
                    if let duration = recording.duration {
                        Text(timeText(duration))
                            .monospacedDigit()
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                if let progress {
                    ProgressView(value: progress)
                }
                if let duration = recording.duration, !recording.parts.isEmpty {
                    SegmentBar(parts: recording.parts, duration: duration)
                        .padding(.top, 2)
                }
                if expanded {
                    details
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityAddTraits(selected == true ? .isSelected : [])
    }

    /// 서버에 보냈으면 체크, 아직이면 보내기 버튼
    @ViewBuilder private var uploadState: some View {
        if progress != nil {
            ProgressView()
        } else if recording.uploadedAt != nil {
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.secondary)
                .accessibilityLabel("서버에 보냄")
        } else if !recordingNow && selected == nil {
            Button(action: upload) {
                Image(systemName: "arrow.up.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("서버로 보내기")
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if !summary.isEmpty {
                    Text(summary)
                }
                Text(uploadText)
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            Menu {
                Picker("휴대 위치", selection: Binding(get: { recording.placement ?? "" }, set: setPlacement)) {
                    ForEach(Placement.all) { item in
                        Text(item.title).tag(item.token)
                    }
                }
            } label: {
                Label("휴대 위치: \(Placement.title(of: recording.placement) ?? "모름")", systemImage: "iphone")
                    .font(.footnote)
            }
            .disabled(recordingNow || progress != nil)  // 보내는 중에는 고치지 않는다
            HStack {
                Button(action: edit) {
                    Label("라벨", systemImage: "tag")
                }
                .disabled(progress != nil)  // 보내는 중에는 고치지 않는다
                Button(action: upload) {
                    Label(recording.serverFolder == nil ? "보내기" : "다시 보내기", systemImage: "arrow.up.circle")
                }
                .disabled(progress != nil)
                Spacer()
                Button(role: .destructive, action: delete) {
                    Label("지우기", systemImage: "trash")
                }
            }
            .buttonStyle(.bordered)
            .disabled(recordingNow)
        }
        .padding(.top, 4)
    }

    private var summary: String {
        var items: [String] = []
        if let change = recording.altChange {
            items.append(altitudeText(change, range: recording.altRange))
        }
        if recording.items == nil && !recordingNow {
            items.append("중간에 끊긴 녹화, 요약을 만드는 중")  // 앱이 꺼지는 등으로 마무리하지 못했다. RecordingStore가 다시 읽는다
        }
        return items.joined(separator: " · ")
    }

    private var uploadText: String {
        switch (recording.uploadedAt, recording.serverFolder) {
        case (nil, nil): "아직 서버에 보내지 않음"
        case (nil, let folder?): "서버(\(folder))에 반영하지 못한 변경이 있습니다. 다시 보내세요"
        case (_, let folder): "서버에 보냄" + (folder.map { ": \($0)" } ?? "")
        }
    }
}
