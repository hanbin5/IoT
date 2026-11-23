import CoreLocation
import CoreMotion
import Foundation
import UIKit

/// 동작 센서(100 Hz)와 기압계(약 1 Hz)를 기록해 폰에 저장한다. 실시간 전송을 켜면 1초마다 서버(/app)로도 보낸다.
///
/// 녹화 하나는 LocalRecording.directory/<sessionId>/에 쌓인다 (RecordingStore가 목록으로 읽는다).
/// - items.jsonl: 한 줄에 값 하나. 서버로 보내는 형식과 같다: {"name", "time"(epoch ns), "values": {...}}
/// - meta.json: 시작 시각, 길이, 고도 변화, 라벨 구간 같은 요약 (LocalRecording). 녹화 뒤에 고친 라벨도 여기 있다
///
/// 값의 종류:
/// - motion: acc_*(중력을 뺀 가속도, m/s²), grav_*(중력, m/s²), gyro_*(rad/s), quat_*(자세),
///           mag_*(보정된 자기장, µT), mag_accuracy(-1 보정 안 됨 ~ 2 높음)
/// - barometer: pressure_hpa, rel_alt_m(수집 시작 기준 상대 고도)
/// - label: label(녹화 중 누른 활동). 그 시각부터 다음 label까지가 그 활동 구간이다 (마칠 때 meta.json의 segments가 된다)
/// 축과 부호는 Core Motion 그대로다 (화면을 위로 놓으면 grav_z ≈ -9.8).
///
/// 화면이 꺼져도 앱이 멈추지 않도록 백그라운드 위치 업데이트를 켜 둔다 (위치 값은 쓰지 않는다).
final class Recorder: NSObject, ObservableObject, CLLocationManagerDelegate {
    enum Phase { case idle, recording, draining }

    struct Segment {
        let label: String
        let since: Date
    }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var status = "대기 중"
    @Published private(set) var motionHz = 0.0
    @Published private(set) var pressure: Double?
    @Published private(set) var altitude: Double?
    @Published private(set) var saved = 0  // 폰에 저장한 값 수
    @Published private(set) var sent = 0  // 실시간 전송으로 서버에 보낸 값 수
    @Published private(set) var queued = 0  // 실시간 전송을 기다리는 값 수
    @Published private(set) var lastError: String?  // 실시간 전송의 마지막 오류
    @Published private(set) var folder: String?  // 실시간 전송 중인 서버 폴더 이름
    @Published private(set) var segment: Segment?  // 지금 구간의 활동 (mark로 바꾼다)
    @Published private(set) var startedAt: Date?  // 화면의 시계용
    @Published private(set) var levels: [Double] = []  // 화면의 움직임 파형: 50 ms마다 가속도 크기의 최댓값(m/s²), 최근 6초
    @Published private(set) var currentID: String?  // 녹화 중인 녹화의 id (목록에서 '녹화 중' 표시)
    @Published private(set) var live = false  // 이번 녹화를 실시간으로도 보내는지

    private let motion = CMMotionManager()
    private let altimeter = CMAltimeter()
    private let location = CLLocationManager()
    private let sensorQueue = OperationQueue()

    // 아래 값들은 queue에서만 읽고 쓴다
    private let queue = DispatchQueue(label: "Recorder")
    private var recording: LocalRecording?  // 지금 녹화 (마칠 때 요약을 meta.json에 쓴다)
    private var writer: FileHandle?  // items.jsonl
    private var unwritten: [[String: Any]] = []  // 아직 파일에 쓰지 않은 값
    private var summary = RecordingSummary()
    private var savedCount = 0
    private var stopping = false
    private var motionCount = 0
    private var lastTick = Date()
    private var levelPeak = 0.0
    private var levelCount = 0
    private var timer: DispatchSourceTimer?
    // 실시간 전송
    private var streaming = false
    private var url: URL?
    private var buffer: [[String: Any]] = []
    private var inflight = false
    private var failures = 0
    private var sentCount = 0
    private var dropped = false  // 실시간 전송에서 빠진 값이 있으면, 서버에는 목록에서 다시 보내야 한다
    private var serverFolder: String?
    private var streamMeta: [String: Any]?

    #if targetEnvironment(simulator)
    private var fakeTimer: DispatchSourceTimer?
    #endif

    /// 녹화를 시작한다. live면 1초마다 serverURL로도 보낸다. placement는 휴대 위치(Placement의 token)다.
    /// activity(Activity의 token)를 주면 처음부터 그 동작 구간으로 표시한다. 녹화 중에 동작 버튼으로 바꿀 수 있다.
    func start(serverURL: String, live: Bool, placement: String?, activity: String? = nil) {
        guard phase == .idle else { return }
        let url = URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines))
        if live, url?.scheme != "https", url?.scheme != "http" {
            status = "서버 주소가 올바르지 않습니다"
            return
        }
        let now = Date()
        var recording = LocalRecording(sessionId: UUID().uuidString,
                                       deviceId: UIDevice.current.identifierForVendor?.uuidString ?? "unknown",
                                       model: Self.modelIdentifier(),
                                       system: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
                                       startedAt: now)
        recording.placement = placement
        let writer: FileHandle
        do {
            try recording.save()
            FileManager.default.createFile(atPath: recording.itemsURL.path, contents: nil)
            writer = try FileHandle(forWritingTo: recording.itemsURL)
        } catch {
            status = "폰에 저장할 수 없습니다: \(error.localizedDescription)"
            return
        }
        queue.sync {
            self.recording = recording
            self.writer = writer
            self.unwritten.removeAll()
            self.summary = RecordingSummary()
            self.savedCount = 0
            self.stopping = false
            self.motionCount = 0
            self.lastTick = now
            self.levelPeak = 0
            self.levelCount = 0
            self.streaming = live
            self.url = url
            self.buffer.removeAll()
            self.failures = 0
            self.sentCount = 0
            self.dropped = false
            self.serverFolder = nil
            self.streamMeta = recording.serverMeta
        }
        phase = .recording
        status = "녹화 중"
        motionHz = 0
        pressure = nil
        altitude = nil
        saved = 0
        sent = 0
        queued = 0
        lastError = nil
        folder = nil
        segment = nil
        startedAt = now
        levels = []
        currentID = recording.id
        self.live = live
        startLocation()
        startSensors()
        startTimer()
        if let activity {
            mark(activity)  // 첫 motion보다 조금 앞서 찍혀, 구간은 녹화의 처음(0초)부터가 된다
        }
    }

    func stop() {
        guard phase == .recording else { return }
        phase = .draining
        status = live ? "남은 데이터를 보내는 중…" : "저장하는 중…"
        motionHz = 0
        segment = nil
        motion.stopDeviceMotionUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        #if targetEnvironment(simulator)
        fakeTimer?.cancel()
        fakeTimer = nil
        #endif
        // 다음 tick이 남은 값을 파일에 쓰고 마무리한다. 위치 업데이트는 그때까지 켜 둬야 백그라운드에서도 마저 한다
        queue.async {
            self.stopping = true
            self.failures = 0
        }
    }

    /// 지금부터 다음 mark()나 중지까지를 activity 구간으로 표시한다. label 값으로 저장된다.
    /// 지금 활동을 또 누르면 아무것도 하지 않는다 (같은 구간이 둘로 나뉘지 않게).
    func mark(_ activity: String) {
        guard phase == .recording, segment?.label != activity else { return }
        record("label", at: ProcessInfo.processInfo.systemUptime, ["label": activity])
        segment = Segment(label: activity, since: Date())
    }

    // MARK: - 센서

    private func startSensors() {
        #if targetEnvironment(simulator)
        startFakeSensors()
        #else
        if motion.isDeviceMotionAvailable {
            motion.deviceMotionUpdateInterval = 1.0 / 100
            motion.startDeviceMotionUpdates(using: .xArbitraryCorrectedZVertical, to: sensorQueue) { [weak self] m, _ in
                guard let self, let m else { return }
                let g = 9.80665
                let a = m.userAcceleration, gr = m.gravity, r = m.rotationRate
                let q = m.attitude.quaternion, f = m.magneticField
                let values: [String: Any] = [
                    "acc_x": a.x * g, "acc_y": a.y * g, "acc_z": a.z * g,
                    "grav_x": gr.x * g, "grav_y": gr.y * g, "grav_z": gr.z * g,
                    "gyro_x": r.x, "gyro_y": r.y, "gyro_z": r.z,
                    "quat_w": q.w, "quat_x": q.x, "quat_y": q.y, "quat_z": q.z,
                    "mag_x": f.field.x, "mag_y": f.field.y, "mag_z": f.field.z,
                    "mag_accuracy": Int(f.accuracy.rawValue),
                ]
                self.record("motion", at: m.timestamp, values)
                self.addLevel((a.x * a.x + a.y * a.y + a.z * a.z).squareRoot() * g)
            }
        } else {
            status = "이 기기는 동작 센서를 지원하지 않습니다"
        }
        if CMAltimeter.isRelativeAltitudeAvailable() {
            altimeter.startRelativeAltitudeUpdates(to: sensorQueue) { [weak self] data, error in
                guard let self else { return }
                guard let data else {
                    let message = error?.localizedDescription ?? "알 수 없는 오류"
                    DispatchQueue.main.async { self.status = "기압계를 쓸 수 없습니다: \(message)" }
                    return
                }
                let hPa = data.pressure.doubleValue * 10  // kPa → hPa
                let alt = data.relativeAltitude.doubleValue
                self.record("barometer", at: data.timestamp, ["pressure_hpa": hPa, "rel_alt_m": alt])
                DispatchQueue.main.async {
                    self.pressure = hPa
                    self.altitude = alt
                }
            }
        } else {
            status = "이 기기는 기압계를 지원하지 않습니다"
        }
        #endif
    }

    /// Core Motion 시각(부팅 후 초)을 epoch ns로 바꿔, 파일에 쓸 값(과 실시간 전송 버퍼)에 넣는다.
    private func record(_ name: String, at timestamp: TimeInterval, _ values: [String: Any]) {
        let age = ProcessInfo.processInfo.systemUptime - timestamp
        let time = Int64((Date().timeIntervalSince1970 - age) * 1e9)
        let clean = values.mapValues { value -> Any in
            if let d = value as? Double, !d.isFinite { return NSNull() }  // JSON에는 NaN을 넣을 수 없다
            return value
        }
        queue.async {
            guard self.writer != nil, !self.stopping else { return }  // 중지한 뒤에 늦게 온 값은 버린다
            let item: [String: Any] = ["name": name, "time": time, "values": clean]
            self.unwritten.append(item)
            self.summary.add(name, time, clean)
            if self.streaming {
                self.buffer.append(item)
            }
            if name == "motion" { self.motionCount += 1 }
        }
    }

    /// 화면의 파형에 쓸 움직임 크기를 모은다. 5개(50 ms)마다 최댓값 하나를 levels에 넣는다.
    private func addLevel(_ magnitude: Double) {
        queue.async {
            self.levelPeak = max(self.levelPeak, magnitude)
            self.levelCount += 1
            guard self.levelCount == 5 else { return }
            let peak = self.levelPeak
            self.levelPeak = 0
            self.levelCount = 0
            DispatchQueue.main.async {
                self.levels.append(peak)
                if self.levels.count > 120 {
                    self.levels.removeFirst(self.levels.count - 120)
                }
            }
        }
    }

    #if targetEnvironment(simulator)
    /// 시뮬레이터에는 센서가 없어서, 전송 경로를 확인할 수 있게 걷는 것처럼 흔들리는 가짜 값을 만든다.
    private func startFakeSensors() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        var n = 0
        timer.schedule(deadline: .now(), repeating: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            n += 1
            let now = ProcessInfo.processInfo.systemUptime
            let bob = 2.5 * sin(Double(n) / 100 * 2 * .pi * 1.8)
            self.record("motion", at: now, ["acc_x": 0.0, "acc_y": bob, "acc_z": 0.0,
                                             "grav_x": 0.0, "grav_y": -9.80665, "grav_z": 0.0])
            self.addLevel(abs(bob))
            if n % 100 == 0 {
                let hPa = 1009.8 - Double(n) / 25_000, alt = Double(n) / 3_000
                self.record("barometer", at: now, ["pressure_hpa": hPa, "rel_alt_m": alt])
                DispatchQueue.main.async {
                    self.pressure = hPa
                    self.altitude = alt
                }
            }
        }
        timer.resume()
        fakeTimer = timer
    }
    #endif

    // MARK: - 저장과 실시간 전송

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 1)
        timer.setEventHandler { [weak self] in self?.tick() }
        queue.async {
            self.timer?.cancel()
            self.timer = timer
            timer.resume()
        }
    }

    /// 1초마다 queue에서 돈다: 파일에 쓰고, 실시간 전송을 하고, 화면 값을 갱신하고, 중지했으면 마무리한다.
    private func tick() {
        let now = Date()
        let hz = Double(motionCount) / now.timeIntervalSince(lastTick)
        motionCount = 0
        lastTick = now
        let writeError = writeUnwritten()
        // 실시간 전송은 중지 뒤 남은 것을 마저 보내 보다가, 연결이 없으면(2번 실패) 그만둔다. 폰에는 모두 저장돼 있다
        let gaveUp = stopping && failures >= 2
        if streaming && !gaveUp {
            flush()
        }
        let finished = stopping && !inflight && (!streaming || buffer.isEmpty || gaveUp)
        let uploaded = finished && streaming && buffer.isEmpty && !dropped
        if finished {
            close(uploaded: uploaded)
        }
        let saved = savedCount, sent = sentCount, queued = buffer.count
        DispatchQueue.main.async {
            self.saved = saved
            self.sent = sent
            self.queued = queued
            if let writeError {
                self.status = "폰에 저장하지 못했습니다: \(writeError)"
            }
            if self.phase == .recording {
                self.motionHz = hz
            }
            if finished {
                self.location.stopUpdatingLocation()
                self.phase = .idle
                self.currentID = nil
                if !self.live {
                    self.status = "폰에 저장했습니다"
                } else {
                    self.status = uploaded ? "폰에 저장하고 서버에도 보냈습니다" : "폰에 저장했습니다. 서버에는 목록에서 보내세요"
                }
            }
        }
    }

    /// 아직 파일에 쓰지 않은 값을 items.jsonl 끝에 덧붙인다. 앱이 꺼져도 그 전까지 쓴 값은 남는다.
    private func writeUnwritten() -> String? {
        guard let writer, !unwritten.isEmpty else { return nil }
        var data = Data()
        for item in unwritten {
            guard let line = try? JSONSerialization.data(withJSONObject: item) else { continue }
            data.append(line)
            data.append(0x0A)  // 줄바꿈
        }
        let count = unwritten.count
        unwritten.removeAll(keepingCapacity: true)
        do {
            try writer.write(contentsOf: data)
            savedCount += count
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// 녹화를 닫는다: 파일을 닫고 meta.json에 요약을 쓴다.
    private func close(uploaded: Bool) {
        try? writer?.close()
        writer = nil
        timer?.cancel()
        timer = nil
        guard var recording else { return }
        summary.apply(to: &recording)
        if uploaded {
            recording.uploadedAt = Date()
            recording.serverFolder = serverFolder
        }
        try? recording.save()
        self.recording = nil
    }

    /// 실시간 전송: 버퍼 앞쪽을 한 묶음 보낸다. 실패한 묶음은 버퍼 앞에 되돌려 다음 tick에 다시 보낸다.
    private func flush() {
        guard !inflight, !buffer.isEmpty, let url, let recording else { return }
        let batch = Array(buffer.prefix(2000))  // 밀린 데이터가 많아도 요청 하나는 1 MB 안팎으로
        buffer.removeFirst(batch.count)
        var body: [String: Any] = ["sessionId": recording.sessionId, "deviceId": recording.deviceId, "payload": batch]
        if let streamMeta { body["meta"] = streamMeta }
        guard JSONSerialization.isValidJSONObject(body),
              let json = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else {
            dropped = true  // 만들 수 없는 묶음은 실시간 전송에서 뺀다 (폰에는 남아 있다)
            return
        }
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = json
        inflight = true
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let ok = (200..<300).contains(code)
            let reply = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            let folder = reply?["session"] as? String
            self.queue.async {
                self.inflight = false
                if ok {
                    self.sentCount += batch.count
                    self.streamMeta = nil  // meta는 첫 묶음에만 싣는다
                    self.failures = 0
                    self.serverFolder = folder ?? self.serverFolder
                } else {
                    self.buffer.insert(contentsOf: batch, at: 0)
                    self.failures += 1
                    if self.buffer.count > 120_000 {  // 20분 분량을 넘으면 실시간 전송에서는 오래된 것부터 뺀다 (폰에는 남아 있다)
                        self.buffer.removeFirst(self.buffer.count - 120_000)
                        self.dropped = true
                    }
                }
            }
            let message = ok ? nil : (error?.localizedDescription ?? "HTTP \(code)")
            DispatchQueue.main.async {
                self.lastError = message
                if let folder { self.folder = folder }
            }
        }.resume()
    }

    // MARK: - 백그라운드 실행

    private func startLocation() {
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyThreeKilometers  // 위치 값은 쓰지 않으니 전력을 아낀다
        location.pausesLocationUpdatesAutomatically = false
        location.allowsBackgroundLocationUpdates = true  // Info.plist의 UIBackgroundModes에 location이 있어야 한다
        location.showsBackgroundLocationIndicator = true
        location.requestWhenInUseAuthorization()
        location.startUpdatingLocation()
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let auth = manager.authorizationStatus
        if phase == .recording, auth == .denied || auth == .restricted {
            status = "위치 권한이 없어 화면을 끄면 수집이 멈춥니다"
        }
    }

    private static func modelIdentifier() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
