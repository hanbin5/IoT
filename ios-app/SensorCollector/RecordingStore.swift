import Foundation

/// 폰에 저장한 녹화 목록. 지우기, 라벨 고치기, 서버로 보내기를 맡는다.
@MainActor
final class RecordingStore: ObservableObject {
    @Published private(set) var recordings: [LocalRecording] = []
    @Published private(set) var progress: [String: Double] = [:]  // 보내는 중인 녹화의 진행률 (0~1)
    @Published var error: String?
    /// 지금 녹화 중인 녹화. 요약이 아직 없어도 끊긴 녹화로 보지 않는다
    var active: String?
    private var repairs: [String: Task<Void, Never>] = [:]  // 끊긴 녹화의 요약 만들기. 녹화마다 한 번만 한다

    func reload() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: LocalRecording.directory,
                                                                    includingPropertiesForKeys: nil)) ?? []
        recordings = folders.compactMap(LocalRecording.load).sorted { $0.startedAt > $1.startedAt }
        for recording in recordings where recording.items == nil && recording.id != active {
            _ = repair(recording.id)
        }
    }

    /// 폰에서 지운다. 서버에 보낸 데이터는 서버에 남는다
    func delete(_ ids: Set<String>) {
        for recording in recordings where ids.contains(recording.id) {
            try? FileManager.default.removeItem(at: recording.folderURL)
        }
        reload()
    }

    /// 녹화들을 하나씩 차례로 서버에 보낸다
    func upload(_ ids: [String], serverURL: String) async {
        error = nil  // 지난 오류는 다시 시도하면 지운다
        for id in ids {
            guard progress[id] == nil, recordings.contains(where: { $0.id == id }) else { continue }
            progress[id] = 0
            do {
                await repair(id).value  // 끊긴 녹화면 라벨 구간부터 만든다
                guard let recording = LocalRecording.load(id: id) else { throw CocoaError(.fileNoSuchFile) }
                let folder = try await Uploader.send(recording, serverURL: serverURL) { fraction in
                    Task { @MainActor in
                        if self.progress[id] != nil { self.progress[id] = fraction }
                    }
                }
                let latest = try update(id) {
                    $0.serverFolder = folder
                    $0.uploadedAt = Date()
                }
                // 보내는 동안 라벨이나 휴대 위치를 고쳤으면 그것도 보낸다
                if latest.segments != recording.segments {
                    try await Uploader.setLabels(folder, latest.segments ?? [], serverURL: serverURL)
                }
                if latest.placement != recording.placement {
                    try await Uploader.setMeta(folder, ["placement": latest.placement.map { $0 as Any } ?? NSNull()],
                                               serverURL: serverURL)
                }
            } catch {
                _ = try? update(id) { $0.uploadedAt = nil }  // 서버에 일부만 갔을 수 있다
                self.error = "보내지 못했습니다: \(error.localizedDescription)"
            }
            progress[id] = nil
            reload()
        }
    }

    /// 라벨(동작 구간)을 바꾼다. 서버에 보낸 녹화면 서버의 label.csv도 바꾼다
    func setSegments(_ segments: [LocalRecording.Segment], for id: String, serverURL: String) async throws {
        try await edit(id, "라벨을", change: { $0.segments = segments }) { folder in
            try await Uploader.setLabels(folder, segments, serverURL: serverURL)
        }
    }

    /// 휴대 위치를 바꾼다. 서버에 보낸 녹화면 서버의 meta.json도 바꾼다
    func setPlacement(_ placement: String, for id: String, serverURL: String) async {
        do {
            try await edit(id, "휴대 위치를", change: { $0.placement = placement }) { folder in
                try await Uploader.setMeta(folder, ["placement": placement], serverURL: serverURL)
            }
        } catch {
            self.error = "휴대 위치를 저장하지 못했습니다: \(error.localizedDescription)"
        }
    }

    /// 녹화 하나를 고친다: 폰에 먼저 저장하고, 서버에 보낸 녹화면 sync로 서버에도 반영한다.
    /// 서버에 반영하지 못하면 서버와 다르다고 표시한다 (다시 보내면 고친 것도 같이 간다).
    /// 보내는 중이면 다 보낸 뒤 upload가 고친 것을 보낸다.
    private func edit(_ id: String, _ what: String, change: (inout LocalRecording) -> Void,
                      sync: (String) async throws -> Void) async throws {
        error = nil
        let recording = try update(id, change)
        reload()
        guard recording.uploadedAt != nil, let folder = recording.serverFolder, progress[id] == nil else { return }
        do {
            try await sync(folder)
        } catch {
            _ = try? update(id) { $0.uploadedAt = nil }
            reload()
            self.error = "\(what) 폰에는 저장했지만 서버에는 반영하지 못했습니다 (\(error.localizedDescription)). 연결되면 다시 보내세요."
        }
    }

    /// meta.json을 디스크에서 다시 읽어 고쳐 저장한다. 보내기, 라벨 고치기, 요약 만들기가 겹쳐도 서로의 변경을 덮어쓰지 않는다
    @discardableResult
    private func update(_ id: String, _ change: (inout LocalRecording) -> Void) throws -> LocalRecording {
        guard var recording = LocalRecording.load(id: id) else { throw CocoaError(.fileNoSuchFile) }
        change(&recording)
        try recording.save()
        return recording
    }

    /// 중간에 끊긴 녹화(앱이 꺼지는 등으로 마무리하지 못한 녹화)의 요약을 items.jsonl을 다시 읽어 만든다
    private func repair(_ id: String) -> Task<Void, Never> {
        if let task = repairs[id] { return task }
        let task = Task {
            guard let recording = LocalRecording.load(id: id), recording.items == nil else { return }
            let url = recording.itemsURL
            let summary = await Task.detached(priority: .utility) { await RecordingSummary.scan(url) }.value
            _ = try? self.update(id) { if $0.items == nil { summary.apply(to: &$0) } }
            self.reload()
        }
        repairs[id] = task
        return task
    }
}

/// 서버(web-sensor/server.py)와 주고받기
enum Uploader {
    /// 폰에 저장한 녹화를 /app으로 2000개씩 보내고, 라벨을 /recordings/labels로 보낸 뒤 서버 폴더 이름을 돌려준다.
    /// 첫 묶음에 replace를 실어 서버에 있던 같은 녹화의 값을 지우고 처음부터 쓰므로, 여러 번 보내도 겹치지 않는다.
    /// 이때 서버의 meta.json도 첫 묶음의 meta(휴대 위치 포함)로 바뀐다.
    /// items.jsonl의 label 값(녹화 중 누른 동작)은 보내지 않는다. 녹화 뒤에 고친 것까지 담긴 meta.json의 구간을 보낸다.
    static func send(_ recording: LocalRecording, serverURL: String,
                     progress: @escaping (Double) -> Void) async throws -> String {
        guard let url = URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ServerError("서버 주소가 올바르지 않습니다")
        }
        let total = Double(max(recording.items ?? 1, 1))
        var batch: [[String: Any]] = []
        var count = 0
        var folder: String?
        func sendBatch() async throws {
            var body: [String: Any] = ["sessionId": recording.sessionId, "deviceId": recording.deviceId, "payload": batch]
            if count == 0 {
                body["meta"] = recording.serverMeta
                body["replace"] = true
            }
            let reply = try await post(body, to: url)
            folder = reply["session"] as? String ?? folder
            count += batch.count
            batch.removeAll()
            progress(min(Double(count) / total, 1))
        }
        for try await line in recording.itemsURL.lines {
            // 앱이 꺼지며 잘린 줄은 건너뛴다
            guard let item = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  item["name"] as? String != "label" else { continue }
            batch.append(item)
            if batch.count == 2000 {
                try await sendBatch()
            }
        }
        if !batch.isEmpty {
            try await sendBatch()
        }
        guard let name = folder else { throw ServerError("보낼 값이 없습니다") }
        try await setLabels(name, recording.segments ?? [], serverURL: serverURL)
        return name
    }

    /// 서버 녹화의 라벨(label.csv)을 이 구간들로 통째로 바꾸고, 서버가 돌려준 새 요약을 돌려준다
    @discardableResult
    static func setLabels(_ folder: String, _ segments: [LocalRecording.Segment],
                          serverURL: String) async throws -> [String: Any] {
        guard let url = endpoint(serverURL, "recordings/labels") else { throw ServerError("서버 주소가 올바르지 않습니다") }
        return try await post(labelsBody(folder, segments), to: url)
    }

    /// 서버 녹화의 meta.json에서 앱이 고칠 수 있는 값(휴대 위치)을 바꾼다. 값이 NSNull이면 지운다
    @discardableResult
    static func setMeta(_ folder: String, _ meta: [String: Any], serverURL: String) async throws -> [String: Any] {
        guard let url = endpoint(serverURL, "recordings/meta") else { throw ServerError("서버 주소가 올바르지 않습니다") }
        return try await post(["name": folder, "meta": meta], to: url)
    }

    /// POST /recordings/labels의 본문. 구간은 다음 구간의 시작(마지막은 녹화 끝)까지라 시작만 보낸다
    static func labelsBody(_ folder: String, _ segments: [LocalRecording.Segment]) -> [String: Any] {
        ["name": folder, "segments": segments.map { ["label": $0.label, "start": $0.start] as [String: Any] }]
    }

    /// 서버 주소(…/app)와 같은 서버의 다른 경로
    static func endpoint(_ serverURL: String, _ path: String) -> URL? {
        URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines))?
            .deletingLastPathComponent()
            .appendingPathComponent(path)
    }

    /// JSON을 POST하고 응답 JSON을 돌려준다. 서버가 거절하면 응답의 error 문구를 오류로 던진다
    private static func post(_ body: [String: Any], to url: URL) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw ServerError(reply["error"] as? String ?? "HTTP \(http.statusCode)")
        }
        return reply
    }
}

struct ServerError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}
