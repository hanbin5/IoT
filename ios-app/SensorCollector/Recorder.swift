import CoreLocation
import CoreMotion
import Foundation
import UIKit

/// 동작 센서(100 Hz)와 기압계(약 1 Hz)를 기록해 1초마다 서버(web-sensor/server.py의 /app)로 보낸다.
///
/// 보내는 형식은 Sensor Logger HTTP Push와 같다:
/// {"sessionId", "deviceId", "meta", "payload": [{"name", "time"(epoch ns), "values": {...}}]}
/// - motion: acc_*(중력을 뺀 가속도, m/s²), grav_*(중력, m/s²), gyro_*(rad/s), quat_*(자세),
///           mag_*(보정된 자기장, µT), mag_accuracy(-1 보정 안 됨 ~ 2 높음)
/// - barometer: pressure_hpa, rel_alt_m(수집 시작 기준 상대 고도)
/// 축과 부호는 Core Motion 그대로다 (화면을 위로 놓으면 grav_z ≈ -9.8).
///
/// 화면이 꺼져도 앱이 멈추지 않도록 백그라운드 위치 업데이트를 켜 둔다 (위치 값은 쓰지 않는다).
final class Recorder: NSObject, ObservableObject, CLLocationManagerDelegate {
    enum Phase { case idle, recording, draining }

    @Published private(set) var phase = Phase.idle
    @Published private(set) var status = "대기 중"
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var motionHz = 0.0
    @Published private(set) var pressure: Double?
    @Published private(set) var altitude: Double?
    @Published private(set) var sent = 0
    @Published private(set) var queued = 0
    @Published private(set) var lastError: String?
    @Published private(set) var folder: String?

    private let motion = CMMotionManager()
    private let altimeter = CMAltimeter()
    private let location = CLLocationManager()
    private let sensorQueue = OperationQueue()

    // 아래 값들은 queue에서만 읽고 쓴다
    private let queue = DispatchQueue(label: "Recorder")
    private var buffer: [[String: Any]] = []
    private var inflight = false
    private var stopping = false
    private var failures = 0
    private var sentCount = 0
    private var motionCount = 0
    private var lastTick = Date()
    private var startDate = Date()
    private var timer: DispatchSourceTimer?
    private var url: URL?
    private var sessionId = ""
    private var deviceId = ""
    private var meta: [String: Any]?

    #if targetEnvironment(simulator)
    private var fakeTimer: DispatchSourceTimer?
    #endif

    func start(serverURL: String) {
        guard phase == .idle else { return }
        guard let url = URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme == "https" || url.scheme == "http" else {
            status = "서버 주소가 올바르지 않습니다"
            return
        }
        let now = Date()
        let meta: [String: Any] = [
            "model": Self.modelIdentifier(),
            "system": "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
            "startedAt": ISO8601DateFormatter().string(from: now),
        ]
        let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? "unknown"
        queue.sync {
            self.url = url
            self.sessionId = UUID().uuidString
            self.deviceId = deviceId
            self.meta = meta
            self.buffer.removeAll()
            self.stopping = false
            self.failures = 0
            self.sentCount = 0
            self.motionCount = 0
            self.lastTick = now
            self.startDate = now
        }
        phase = .recording
        status = "수집 중"
        elapsed = 0
        motionHz = 0
        pressure = nil
        altitude = nil
        sent = 0
        queued = 0
        lastError = nil
        folder = nil
        startLocation()
        startSensors()
        startTimer()
    }

    func stop() {
        guard phase == .recording else { return }
        phase = .draining
        status = "남은 데이터를 보내는 중…"
        motionHz = 0
        motion.stopDeviceMotionUpdates()
        altimeter.stopRelativeAltitudeUpdates()
        #if targetEnvironment(simulator)
        fakeTimer?.cancel()
        fakeTimer = nil
        #endif
        // 대기열이 비면 tick()이 마무리한다. 위치 업데이트는 그때까지 켜 둬야 백그라운드에서도 마저 보낸다
        queue.async {
            self.stopping = true
            self.failures = 0
        }
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

    /// Core Motion 시각(부팅 후 초)을 epoch ns로 바꿔 버퍼에 넣는다.
    private func record(_ name: String, at timestamp: TimeInterval, _ values: [String: Any]) {
        let age = ProcessInfo.processInfo.systemUptime - timestamp
        let time = Int64((Date().timeIntervalSince1970 - age) * 1e9)
        let clean = values.mapValues { value -> Any in
            if let d = value as? Double, !d.isFinite { return NSNull() }  // JSON에는 NaN을 넣을 수 없다
            return value
        }
        queue.async {
            self.buffer.append(["name": name, "time": time, "values": clean])
            if name == "motion" { self.motionCount += 1 }
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

    // MARK: - 전송

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

    /// 1초마다 queue에서 돈다: 전송하고, 화면 값을 갱신하고, 중지 뒤 대기열이 비면 마무리한다.
    private func tick() {
        let now = Date()
        let hz = Double(motionCount) / now.timeIntervalSince(lastTick)
        motionCount = 0
        lastTick = now
        flush()
        let finished = stopping && buffer.isEmpty && !inflight
        let gaveUp = stopping && !finished && failures >= 10
        if finished || gaveUp {
            timer?.cancel()
            timer = nil
        }
        let sent = sentCount, queued = buffer.count, elapsed = now.timeIntervalSince(startDate)
        DispatchQueue.main.async {
            self.sent = sent
            self.queued = queued
            if self.phase == .recording {
                self.motionHz = hz
                self.elapsed = elapsed
            }
            if finished || gaveUp {
                self.location.stopUpdatingLocation()
                self.phase = .idle
                self.status = finished ? "저장 완료" : "전송 실패: \(queued)개를 보내지 못했습니다"
            }
        }
    }

    /// 버퍼 앞쪽을 한 묶음 보낸다. 실패한 묶음은 버퍼 앞에 되돌려 다음 tick에 다시 보낸다.
    private func flush() {
        guard !inflight, !buffer.isEmpty, let url else { return }
        let batch = Array(buffer.prefix(2000))  // 밀린 데이터가 많아도 요청 하나는 1 MB 안팎으로
        buffer.removeFirst(batch.count)
        var body: [String: Any] = ["sessionId": sessionId, "deviceId": deviceId, "payload": batch]
        if let meta { body["meta"] = meta }
        guard JSONSerialization.isValidJSONObject(body),
              let json = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else {
            return  // 만들 수 없는 묶음은 버린다
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
            self.queue.async {
                self.inflight = false
                if ok {
                    self.sentCount += batch.count
                    self.meta = nil  // meta는 첫 묶음에만 싣는다
                    self.failures = 0
                } else {
                    self.buffer.insert(contentsOf: batch, at: 0)
                    self.failures += 1
                    if self.buffer.count > 120_000 {  // 20분 분량을 넘으면 오래된 것부터 버린다
                        self.buffer.removeFirst(self.buffer.count - 120_000)
                    }
                }
            }
            let message = ok ? nil : (error?.localizedDescription ?? "HTTP \(code)")
            DispatchQueue.main.async {
                self.lastError = message
                if let folder = reply?["session"] as? String { self.folder = folder }
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
