import Foundation

/// 폰에 저장한 녹화 하나. LocalRecording.directory/<sessionId>/의 meta.json이고,
/// 값은 같은 폴더의 items.jsonl에 한 줄에 하나씩 있다 (서버로 보내는 형식과 같다).
///
/// 라벨은 segments 하나뿐이다: 녹화하면서 누른 동작 버튼으로 생기고, 녹화 뒤에 라벨 화면에서 고친다.
/// 서버로는 items.jsonl의 label 값이 아니라 이 segments를 보낸다.
struct LocalRecording: Codable, Identifiable, Equatable {
    var sessionId: String
    var deviceId: String
    var model: String
    var system: String
    var startedAt: Date
    var duration: Double?  // 첫 motion부터 마지막 motion까지 초
    var items: Int?  // 값의 수. 없으면 아직 녹화 중이거나 중간에 끊겨 요약을 못 만든 녹화다
    var altChange: Double?  // 기압계 상대 고도의 처음과 끝 차이 (m)
    var altRange: Double?
    var segments: [Segment]?  // 라벨: 동작 구간들
    var placement: String?  // 휴대 위치 (Placement의 token)
    var uploadedAt: Date?  // 서버가 폰과 같아진 시각. 그 뒤 서버에 반영하지 못한 변경이 있으면 없앤다
    var serverFolder: String?  // 서버의 폴더 이름 (한 번이라도 보냈으면 있다)

    /// 라벨 구간 하나. 시각은 첫 motion 기준 초이고, 다음 구간의 시작(마지막은 녹화 끝)까지다
    struct Segment: Codable, Hashable {
        var label: String
        var start: Double
        var end: Double

        /// 길이가 없는 구간을 빼고, 이어진 같은 동작 구간을 하나로 합친다 (server.py의 read_segments와 같은 규칙)
        static func normalized(_ segments: [Segment]) -> [Segment] {
            var result: [Segment] = []
            for segment in segments where segment.end > segment.start {
                if let last = result.last, last.label == segment.label, segment.start - last.end < 0.01 {
                    result[result.count - 1].end = segment.end
                } else {
                    result.append(segment)
                }
            }
            return result
        }
    }

    var id: String { sessionId }

    static let directory: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    var folderURL: URL { Self.directory.appendingPathComponent(sessionId, isDirectory: true) }
    var itemsURL: URL { folderURL.appendingPathComponent("items.jsonl") }

    /// 서버로 보낼 때 첫 묶음에 싣는 정보 (server.py가 meta.json에 쓴다)
    var serverMeta: [String: Any] {
        var meta: [String: Any] = ["model": model, "system": system,
                                   "startedAt": ISO8601DateFormatter().string(from: startedAt)]
        meta["placement"] = placement
        return meta
    }

    /// 목록에 쓰는 이름: 라벨의 동작들 (예: 걷기 → 계단 ↑ → 걷기). 라벨이 없으면 nil
    var title: String? { Activity.title(of: (segments ?? []).map(\.label)) }

    /// 구간 막대에 그릴 조각들
    var parts: [Recording.Part] {
        Recording.Part.parts((segments ?? []).map { ($0.label, $0.start, $0.end) })
    }

    var labelTarget: LabelTarget {
        LabelTarget(id: id, duration: duration, segments: segments ?? [])
    }

    /// 폴더를 만들고 meta.json을 쓴다
    func save() throws {
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        try Self.encoder.encode(self).write(to: folderURL.appendingPathComponent("meta.json"), options: .atomic)
    }

    static func load(from folder: URL) -> LocalRecording? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("meta.json")) else { return nil }
        return try? decoder.decode(LocalRecording.self, from: data)
    }

    static func load(id: String) -> LocalRecording? {
        load(from: directory.appendingPathComponent(id, isDirectory: true))
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// 녹화 요약(값의 수, 길이, 고도 변화, 라벨 구간)을 값을 하나씩 받으며 모은다.
/// 녹화하면서 Recorder가 쓰고, 중간에 끊긴 녹화는 RecordingStore가 items.jsonl을 다시 읽어 만든다.
struct RecordingSummary {
    var count = 0
    var firstMotion: Int64?
    var lastMotion: Int64?
    var firstAlt: Double?
    var lastAlt: Double?
    var minAlt = Double.infinity
    var maxAlt = -Double.infinity
    var marks: [(time: Int64, label: String)] = []

    mutating func add(_ name: String, _ time: Int64, _ values: [String: Any]) {
        count += 1
        switch name {
        case "motion":
            if firstMotion == nil { firstMotion = time }
            lastMotion = time
        case "barometer":
            guard let alt = values["rel_alt_m"] as? Double else { break }
            if firstAlt == nil { firstAlt = alt }
            lastAlt = alt
            minAlt = min(minAlt, alt)
            maxAlt = max(maxAlt, alt)
        case "label":
            if let label = values["label"] as? String { marks.append((time, label)) }
        default:
            break
        }
    }

    /// 서버의 recording_info, read_segments와 같은 규칙: 시각은 첫 motion 기준 초, 구간은 다음 라벨(마지막은 녹화 끝)까지
    func apply(to recording: inout LocalRecording) {
        recording.items = count
        guard let start = firstMotion, let end = lastMotion else { return }
        let seconds = { (t: Int64) in Double(t - start) / 1e9 }
        recording.duration = seconds(end)
        if let firstAlt, let lastAlt {
            recording.altChange = lastAlt - firstAlt
            recording.altRange = maxAlt - minAlt
        }
        let ends = marks.dropFirst().map { min($0.time, end) } + [end]
        recording.segments = LocalRecording.Segment.normalized(zip(marks, ends).map { mark, next in
            LocalRecording.Segment(label: mark.label, start: max(seconds(mark.time), 0), end: seconds(next))
        })
    }

    /// items.jsonl을 처음부터 읽어 요약을 만든다. 앱이 꺼지며 잘린 줄은 건너뛴다
    static func scan(_ url: URL) async -> RecordingSummary {
        var summary = RecordingSummary()
        do {
            for try await line in url.lines {
                guard let item = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let name = item["name"] as? String,
                      let time = (item["time"] as? NSNumber)?.int64Value,
                      let values = item["values"] as? [String: Any] else { continue }
                summary.add(name, time, values)
            }
        } catch {
            // 읽은 데까지로 요약한다
        }
        return summary
    }
}
