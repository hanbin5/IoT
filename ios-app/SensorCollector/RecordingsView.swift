import SwiftUI

/// 서버(web-sensor/server.py)에 있는 녹화 목록 ('서버의 녹화' 화면). 다른 기기에서 보낸 녹화도 여기 나온다.
/// 녹화를 누르면 펼쳐지고 라벨을 고치거나 지운다. 지우면 서버의 data/.trash로 옮겨져 되살릴 수 있다.
///
/// 라벨은 서버의 label.csv에 있다. 폰에 있는 녹화를 다시 보내면 폰의 라벨로 바뀐다.
struct RecordingsView: View {
    let serverURL: String

    @State private var recordings: [Recording] = []
    @State private var loaded = false
    @State private var error: String?
    @State private var expanded: Recording.ID?
    @State private var editing: LabelTarget?
    @State private var deleting: Recording?

    var body: some View {
        List {
            if let error {
                Text(error)
                    .foregroundStyle(.red)
            }
            Section {
                ForEach(recordings) { recording in
                    RecordingRow(recording: recording, expanded: expanded == recording.id,
                                 edit: { editing = recording.labelTarget },
                                 delete: { deleting = recording })
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.snappy) {
                                expanded = expanded == recording.id ? nil : recording.id
                            }
                        }
                        .swipeActions(edge: .trailing) {
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
            } header: {
                if recordings.contains(where: { !$0.parts.isEmpty }) {
                    SegmentLegend()
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if loaded, recordings.isEmpty, error == nil {
                ContentUnavailableView("서버에 녹화 없음", systemImage: "server.rack",
                                       description: Text("폰의 녹화를 보내면 여기에 나옵니다."))
            }
        }
        .task(id: serverURL) { await load() }
        .refreshable { await load() }
        .sheet(item: $editing) { target in
            LabelEditor(target: target) { segments in
                try await setLabels(target.id, segments)
            }
        }
        .confirmationDialog("서버에서 이 녹화를 지울까요?",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { recording in
            Button("지우기", role: .destructive) {
                Task { await delete(recording) }
            }
        } message: { recording in
            Text("\(recording.name) 폴더를 서버의 data/.trash로 옮깁니다. 그 폴더에서 꺼내면 되살릴 수 있습니다.")
        }
    }

    private func load() async {
        do {
            guard let url = Uploader.endpoint(serverURL, "recordings") else { throw ServerError("서버 주소가 올바르지 않습니다") }
            recordings = try await send(URLRequest(url: url, timeoutInterval: 10), as: RecordingList.self).recordings
            error = nil
        } catch {
            self.error = "목록을 불러오지 못했습니다: \(error.localizedDescription)"
        }
        loaded = true
    }

    private func setLabels(_ name: String, _ segments: [LocalRecording.Segment]) async throws {
        let updated = try await post("recordings/labels", Uploader.labelsBody(name, segments),
                                     as: RecordingReply.self).recording
        if let i = recordings.firstIndex(where: { $0.id == name }) {
            recordings[i] = updated
        }
    }

    private func delete(_ recording: Recording) async {
        do {
            _ = try await post("recordings/delete", ["name": recording.name], as: DeleteReply.self)
            recordings.removeAll { $0.id == recording.id }
            error = nil
        } catch {
            self.error = "지우지 못했습니다: \(error.localizedDescription)"
        }
    }

    private func post<T: Decodable>(_ path: String, _ body: [String: Any], as type: T.Type) async throws -> T {
        guard let url = Uploader.endpoint(serverURL, path) else { throw ServerError("서버 주소가 올바르지 않습니다") }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request, as: type)
    }

    /// 요청을 보내고 JSON 응답을 읽는다. 서버가 거절하면 응답의 error 문구를 오류로 던진다.
    private func send<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let reply = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            throw ServerError(reply?["error"] as? String ?? "HTTP \(http.statusCode)")
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: data)
    }
}

/// GET /recordings가 돌려주는 녹화 하나
struct Recording: Decodable, Identifiable {
    let name: String
    let source: String
    let started: Double?  // epoch 초
    let durationS: Double?
    let altChangeM: Double?
    let altRangeM: Double?
    let segments: [Segment]?  // 라벨: 동작 구간들 (label.csv)
    let placement: String?  // 휴대 위치 (meta.json)
    let active: Bool  // 아직 데이터가 들어오는 중

    /// 라벨 구간 하나. 시각은 녹화 시작 기준 초다
    struct Segment: Decodable, Hashable {
        let label: String
        let startS: Double
        let endS: Double
    }

    /// 구간 막대의 조각 하나. 라벨이 없으면 첫 라벨을 누르기 전의 시간이다
    struct Part: Hashable {
        let label: String?
        let start: Double
        let end: Double

        var title: String { label.map { Activity.named($0)?.title ?? $0 } ?? "라벨 없음" }
        var color: Color { label.map { Activity.named($0)?.color ?? Activity.Palette.idle } ?? Activity.Palette.unlabeled }

        /// 구간 라벨들로 막대 조각을 만든다. 첫 라벨 전의 시간은 '라벨 없음' 조각이 된다
        static func parts(_ segments: [(label: String, start: Double, end: Double)]) -> [Part] {
            guard let first = segments.first else { return [] }
            let lead = first.start >= 0.5 ? [Part(label: nil, start: 0, end: first.start)] : []
            return lead + segments.map { Part(label: $0.label, start: $0.start, end: $0.end) }
        }
    }

    var id: String { name }

    /// 목록에 쓰는 이름: 라벨의 동작들 (예: 걷기 → 계단 ↑ → 걷기). 라벨이 없으면 nil
    var title: String? { Activity.title(of: (segments ?? []).map(\.label)) }

    /// 구간 막대에 그릴 조각들: 첫 라벨 전의 라벨 없는 시간과 라벨 구간. 라벨이 없으면 비어 있다
    var parts: [Part] {
        Part.parts((segments ?? []).map { ($0.label, $0.startS, $0.endS) })
    }

    var labelTarget: LabelTarget {
        LabelTarget(id: id, duration: durationS,
                    segments: (segments ?? []).map { LocalRecording.Segment(label: $0.label, start: $0.startS, end: $0.endS) },
                    note: "폰에 남아 있는 녹화면 폰의 목록에서 고치세요. 폰에서 다시 보내면 서버의 라벨이 폰의 라벨로 바뀝니다.")
    }
}

private struct RecordingList: Decodable {
    let recordings: [Recording]
}

private struct RecordingReply: Decodable {
    let recording: Recording
}

private struct DeleteReply: Decodable {
    let trashed: String
}

/// 서버 녹화 한 줄: 라벨, 날짜, 길이, 구간 막대. 펼치면 고도 변화, 폴더 이름, 라벨·지우기 버튼이 나온다.
private struct RecordingRow: View {
    let recording: Recording
    let expanded: Bool
    let edit: () -> Void
    let delete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(recording.title ?? "라벨 없는 녹화")
                    .font(.headline)
                    .foregroundStyle(recording.title == nil ? .secondary : .primary)
                    .lineLimit(1)
                if recording.active {
                    Text("수집 중")
                        .font(.caption.bold())
                        .foregroundStyle(.red)
                }
            }
            HStack {
                Text([recording.started.map { dayText(Date(timeIntervalSince1970: $0)) }, Placement.title(of: recording.placement)]
                    .compactMap { $0 }.joined(separator: " · "))
                    .lineLimit(1)
                Spacer()
                if let duration = recording.durationS {
                    Text(timeText(duration))
                        .monospacedDigit()
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            if let duration = recording.durationS, !recording.parts.isEmpty {
                SegmentBar(parts: recording.parts, duration: duration)
                    .padding(.top, 2)
            }
            if expanded {
                VStack(alignment: .leading, spacing: 8) {
                    if !details.isEmpty {
                        Text(details)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text(recording.name)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                    HStack {
                        Button(action: edit) {
                            Label("라벨", systemImage: "tag")
                        }
                        Spacer()
                        Button(role: .destructive, action: delete) {
                            Label("지우기", systemImage: "trash")
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.top, 4)
            }
        }
        .padding(.vertical, 4)
    }

    private var details: String {
        var items: [String] = []
        if let change = recording.altChangeM {
            items.append(altitudeText(change, range: recording.altRangeM))
        }
        if recording.source == "web" {
            items.append("웹 페이지")
        }
        return items.joined(separator: " · ")
    }
}

/// 녹화 시간 축 위에 구간 라벨을 색 막대로 그린다 (얇은 막대: 높이 8, 양 끝 둥글게, 조각 사이 2pt 틈).
struct SegmentBar: View {
    let parts: [Recording.Part]
    let duration: Double

    var body: some View {
        GeometryReader { proxy in
            let scale = proxy.size.width / CGFloat(max(duration, parts.last?.end ?? 0, 0.001))
            ZStack(alignment: .leading) {
                ForEach(Array(parts.enumerated()), id: \.offset) { i, part in
                    let gap: CGFloat = i < parts.count - 1 ? 2 : 0  // 틈은 바탕색이 보이게 비워 둔다
                    let width = CGFloat(part.end - part.start) * scale - gap
                    if width >= 1 {
                        Rectangle()
                            .fill(part.color)
                            .frame(width: width)
                            .offset(x: CGFloat(part.start) * scale)
                    }
                }
            }
        }
        .frame(height: 8)
        .clipShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("구간 라벨: " + parts.map { "\($0.title) \(timeText($0.start))부터 \(timeText($0.end))까지" }
            .joined(separator: ", "))
    }
}

/// 구간 막대 색의 범례
struct SegmentLegend: View {
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), alignment: .leading)], alignment: .leading, spacing: 4) {
            ForEach(Activity.legend, id: \.self) { item in
                HStack(spacing: 6) {
                    Capsule()
                        .fill(item.color)
                        .frame(width: 14, height: 8)
                    Text(item.title)
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .textCase(nil)
        .padding(.bottom, 4)
    }
}

/// 녹화 시작 기준 초를 m:ss로
func timeText(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    return String(format: "%d:%02d", s / 60, s % 60)
}

/// 오늘이면 시각만, 어제면 '어제', 그 전이면 날짜 (음성 메모처럼)
func dayText(_ date: Date) -> String {
    if Calendar.current.isDateInToday(date) {
        return date.formatted(date: .omitted, time: .shortened)
    }
    if Calendar.current.isDateInYesterday(date) {
        return "어제"
    }
    return date.formatted(date: .abbreviated, time: .omitted)
}

/// 상대 고도의 처음과 끝 차이. 올라갔다 내려온 녹화면 최대 폭도 붙인다
func altitudeText(_ change: Double, range: Double?) -> String {
    var text = String(format: "고도 %+.1f m", change)
    if let range, range > abs(change) + 1 {
        text += String(format: " (최대 폭 %.1f m)", range)
    }
    return text
}

/// 라벨을 고칠 녹화. 폰의 녹화와 서버의 녹화가 같이 쓴다
struct LabelTarget: Identifiable {
    let id: String
    let duration: Double?  // 모르면 녹화 전체를 한 동작으로 정할 수 없다
    let segments: [LocalRecording.Segment]
    var note: String?  // 라벨 화면 아래에 덧붙일 안내
}

/// 녹화의 라벨을 고치는 화면. 라벨은 동작 구간들이다: 녹화하면서 동작 버튼을 누르면 생기고,
/// 여기서 구간의 동작을 바꾸거나, 구간을 지우거나, 녹화 전체를 한 동작으로 정한다.
struct LabelEditor: View {
    static let activities = Activity.all + [.idle]

    let target: LabelTarget
    let save: ([LocalRecording.Segment]) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var rows: [Row]
    @State private var saving = false
    @State private var error: String?

    /// 고치는 중인 구간 하나. 지우거나 합쳐도 줄이 섞이지 않게 id를 붙인다
    private struct Row: Identifiable {
        let id = UUID()
        var segment: LocalRecording.Segment
    }

    init(target: LabelTarget, save: @escaping ([LocalRecording.Segment]) async throws -> Void) {
        self.target = target
        self.save = save
        _rows = State(initialValue: target.segments.map { Row(segment: $0) })
    }

    private var segments: [LocalRecording.Segment] { rows.map(\.segment) }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let duration = target.duration {
                        timeline(duration)
                    }
                    if rows.isEmpty {
                        Text("라벨 없음")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(rows) { row in
                        Picker(selection: Binding(get: { row.segment.label }, set: { relabel(row.id, to: $0) })) {
                            ForEach(options(row.segment.label), id: \.self) { token in
                                Text(Activity.named(token)?.title ?? token).tag(token)
                            }
                        } label: {
                            HStack(spacing: 8) {
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(Activity.named(row.segment.label)?.color ?? Activity.Palette.idle)
                                    .frame(width: 12, height: 12)
                                Text("\(clockText(row.segment.start))–\(clockText(row.segment.end))")
                                    .monospacedDigit()
                            }
                        }
                    }
                    .onDelete(perform: delete)
                } header: {
                    Text("구간")
                } footer: {
                    Text("동작을 눌러 바꾸고, 밀어서 지웁니다. 구간을 지우면 앞 구간이 그 시간까지 이어집니다 (첫 구간이면 라벨 없음이 됩니다).")
                }
                Section {
                    Menu("전체를 한 동작으로") {
                        ForEach(Self.activities, id: \.self) { activity in
                            Button(activity.title) { setWhole(activity.token) }
                        }
                    }
                    .disabled(target.duration == nil)
                    if !rows.isEmpty {
                        Button("라벨 모두 지우기", role: .destructive) {
                            rows.removeAll()
                        }
                    }
                } footer: {
                    Text([target.duration == nil
                          ? "길이를 모르는 녹화라 전체를 한 동작으로 정할 수 없습니다."
                          : "녹화하면서 동작 버튼을 누르지 않았으면 전체를 한 동작으로 정하세요.",
                          target.note].compactMap { $0 }.joined(separator: "\n\n"))
                }
                if let error {
                    Section {
                        Text(error)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("라벨")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") {
                        Task { await submit() }
                    }
                    .disabled(saving || segments == target.segments)
                }
            }
        }
    }

    /// 녹화 전체 길이 위의 구간 막대와 시간 축. 라벨이 없으면 막대 전체가 '라벨 없음'이다
    private func timeline(_ duration: Double) -> some View {
        let parts = rows.isEmpty
            ? [Recording.Part(label: nil, start: 0, end: duration)]
            : Recording.Part.parts(segments.map { ($0.label, $0.start, $0.end) })
        return VStack(spacing: 6) {
            SegmentBar(parts: parts, duration: duration)
            HStack {
                Text(timeText(0))
                Spacer()
                Text(timeText(duration))
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    /// 고를 수 있는 동작의 token. 모르는 token(다른 기기나 예전 앱이 쓴 라벨)이면 그것도 넣는다
    private func options(_ current: String) -> [String] {
        let tokens = Self.activities.map(\.token)
        return tokens.contains(current) ? tokens : tokens + [current]
    }

    private func relabel(_ id: Row.ID, to label: String) {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        rows[i].segment.label = label
        mergeSame()
    }

    /// 구간을 지우면 앞 구간이 그 시간까지 이어진다. 첫 구간이면 그 시간은 라벨 없음이 된다
    private func delete(_ offsets: IndexSet) {
        for i in offsets.sorted(by: >) {
            if i > 0 {
                rows[i - 1].segment.end = rows[i].segment.end
            }
            rows.remove(at: i)
        }
        mergeSame()
    }

    private func setWhole(_ label: String) {
        guard let duration = target.duration else { return }
        rows = [Row(segment: LocalRecording.Segment(label: label, start: 0, end: duration))]
    }

    /// 이어진 같은 동작 구간을 앞 줄 하나로 합친다 (LocalRecording.Segment.normalized와 같은 규칙)
    private func mergeSame() {
        var merged: [Row] = []
        for row in rows {
            if let last = merged.last, last.segment.label == row.segment.label,
               row.segment.start - last.segment.end < 0.01 {
                merged[merged.count - 1].segment.end = row.segment.end
            } else {
                merged.append(row)
            }
        }
        rows = merged
    }

    private func submit() async {
        saving = true
        defer { saving = false }
        do {
            try await save(segments)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
