#!/usr/bin/env python3
"""스마트폰이 보낸 센서 데이터를 받아 CSV로 저장하는 서버.

세 곳에서 받는다.
- POST /data: 이 폴더의 index.html을 iPhone Safari에서 열어 보내는 가속도·자이로·방향
- POST /app: ios-app/의 수집 앱이 보내는 동작 센서·기압계 (웹에서 못 읽는 기압계 포함)
- POST /sensorlogger: Sensor Logger 앱의 HTTP Push (/app과 같은 형식)

iPhone Safari는 HTTPS 페이지에서만 모션 센서 권한을 주므로 tailscale serve로 HTTPS를 붙여 쓴다.

    python3 web-sensor/server.py      # http://127.0.0.1:8000
    tailscale serve 8000              # 다른 터미널에서 → https://<기기 이름>.<tailnet>.ts.net

웹 페이지 데이터는 data/<세션>/ 아래 motion.csv, orientation.csv, meta.json으로,
앱 데이터는 data/<시작 시각>-app/ (Sensor Logger는 -sl/) 아래 센서별 CSV와 meta.json으로 쌓인다.
"""

import argparse
import csv
import json
import re
import threading
import time
from functools import partial
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parent
PAGE = ROOT / "index.html"
DATA_DIR = ROOT / "data"
MAX_BODY = 5 * 1024 * 1024  # 요청 하나의 크기 상한
REPORT_EVERY = 5.0  # 수신 현황을 출력하는 간격(초)

# index.html의 onMotion, onOrientation이 만드는 행과 순서가 같아야 한다
COLUMNS = {
    "motion": ["t_ms", "acc_x", "acc_y", "acc_z", "accg_x", "accg_y", "accg_z",
               "rot_alpha", "rot_beta", "rot_gamma", "interval"],
    "orientation": ["t_ms", "alpha", "beta", "gamma", "heading", "heading_acc"],
}

lock = threading.Lock()
stats = {}
batch_dirs = {}  # (폴더 접미사, sessionId) -> 저장 폴더


def save(payload):
    """한 묶음을 세션 폴더의 CSV에 덧붙이고 (세션 이름, 종류별 행 수)를 돌려준다."""
    name = re.sub(r"[^0-9A-Za-z_-]", "", str(payload.get("session") or ""))[:64] or "unnamed"
    folder = DATA_DIR / name
    folder.mkdir(parents=True, exist_ok=True)
    added = {}
    for kind, header in COLUMNS.items():
        rows = [r for r in payload.get(kind) or [] if isinstance(r, list) and len(r) == len(header)]
        if not rows:
            continue
        path = folder / f"{kind}.csv"
        is_new = not path.exists()
        with path.open("a", newline="") as f:
            writer = csv.writer(f)
            if is_new:
                writer.writerow(header)
            writer.writerows(rows)
        added[kind] = len(rows)
    meta = payload.get("meta")
    if isinstance(meta, dict) and not (folder / "meta.json").exists():
        (folder / "meta.json").write_text(json.dumps(meta, ensure_ascii=False, indent=2))
    return name, added


def append_rows(path, rows):
    """dict 행을 CSV에 덧붙인다. 열은 파일을 처음 만들 때 받은 행의 키로 고정한다."""
    header = None
    if path.exists():
        with path.open(newline="") as f:
            header = next(csv.reader(f), None)
    with path.open("a", newline="") as f:
        writer = csv.DictWriter(f, header or list(rows[0]), restval="", extrasaction="ignore")
        if f.tell() == 0:
            writer.writeheader()
        writer.writerows(rows)


def batch_session_dir(suffix, session_id, first_ns):
    """녹화 하나를 '<시작 시각>-<suffix>' 폴더 하나에 모은다.

    서버를 재시작해도 meta.json의 sessionId로 같은 폴더를 다시 찾는다.
    """
    key = (suffix, session_id)
    if key not in batch_dirs:
        found = [m.parent for m in DATA_DIR.glob(f"*-{suffix}/meta.json")
                 if json.loads(m.read_text()).get("sessionId") == session_id]
        stamp = time.strftime("%Y%m%d-%H%M%S", time.localtime(first_ns / 1e9))
        batch_dirs[key] = found[0] if found else DATA_DIR / f"{stamp}-{suffix}"
    return batch_dirs[key]


def save_batch(payload, suffix, source):
    """센서 값 묶음을 센서별 CSV에 덧붙이고 (폴더 이름, 센서별 행 수)를 돌려준다.

    Sensor Logger HTTP Push와 같은 형식이다:
    {"sessionId", "deviceId", "meta"(선택), "payload": [{"name", "time"(epoch ns), "values": {...}}, ...]}
    """
    groups = {}
    for item in payload.get("payload") or []:
        if not isinstance(item, dict) or not isinstance(item.get("values"), dict):
            continue
        sensor = re.sub(r"[^0-9A-Za-z_-]", "", str(item.get("name") or ""))[:64]
        if not sensor:
            continue
        row = {"time": item.get("time")}
        row.update({k: json.dumps(v) if isinstance(v, (dict, list)) else v for k, v in item["values"].items()})
        if "accuracy" in item:  # Sensor Logger의 Android 일부 센서에만 있다
            row["accuracy"] = item["accuracy"]
        groups.setdefault(sensor, []).append(row)
    if not groups:
        return None, {}  # 연결 테스트처럼 센서 값이 없는 요청
    times = [r["time"] for rows in groups.values() for r in rows if isinstance(r["time"], (int, float))]
    session_id = str(payload.get("sessionId") or "unknown")
    folder = batch_session_dir(suffix, session_id, min(times, default=time.time_ns()))
    folder.mkdir(parents=True, exist_ok=True)
    if not (folder / "meta.json").exists():
        ids = {k: payload[k] for k in ("sessionId", "deviceId", "userId") if k in payload}
        extra = payload["meta"] if isinstance(payload.get("meta"), dict) else {}
        meta = {"source": source, **extra, **ids}
        (folder / "meta.json").write_text(json.dumps(meta, ensure_ascii=False, indent=2))
    for sensor, rows in groups.items():
        append_rows(folder / f"{sensor}.csv", rows)
    return folder.name, {sensor: len(rows) for sensor, rows in groups.items()}


ROUTES = {
    "/data": save,
    "/app": partial(save_batch, suffix="app", source="ios-app"),
    "/sensorlogger": partial(save_batch, suffix="sl", source="Sensor Logger"),
}


def report(name, added):
    """세션마다 REPORT_EVERY초 간격으로 수신 속도와 누적 행 수를 출력한다."""
    s = stats.setdefault(name, {"total": {}, "window": {}, "since": time.monotonic()})
    for kind, n in added.items():
        s["total"][kind] = s["total"].get(kind, 0) + n
        s["window"][kind] = s["window"].get(kind, 0) + n
    elapsed = time.monotonic() - s["since"]
    if elapsed < REPORT_EVERY:
        return
    rates = ", ".join(f"{k} {n / elapsed:.1f}/s" for k, n in s["window"].items())
    totals = ", ".join(f"{k} {n}" for k, n in s["total"].items())
    print(f"[{name}] {rates or '수신 없음'} | 누적 {totals}", flush=True)
    s["window"], s["since"] = {}, time.monotonic()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"  # 0.5초마다 오는 요청이 연결을 재사용하도록

    def do_GET(self):
        path = self.path.split("?")[0]
        if path in ROUTES and path != "/data":  # 앱의 연결 테스트가 GET으로 올 때를 대비
            print(f"연결 확인 (GET {path}): {self.headers.get('User-Agent', '?')}", flush=True)
            return self.reply(200, {"ok": True})
        if path not in ("/", "/index.html"):
            return self.reply(404, {"error": "not found"})
        body = PAGE.read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)
        print(f"페이지 열림: {self.headers.get('User-Agent', '?')}", flush=True)

    def do_POST(self):
        handle = ROUTES.get(self.path)
        if handle is None:
            return self.reply(404, {"error": "not found"})
        body = self.read_body()
        if body is None:
            return self.reply(413, {"error": "bad length"})
        try:
            payload = json.loads(body)
        except ValueError:
            return self.reply(400, {"error": "bad json"})
        if not isinstance(payload, dict):
            return self.reply(400, {"error": "bad json"})
        with lock:
            name, added = handle(payload)
            if added:
                report(name, added)
            elif handle is not save:
                items = payload.get("payload")
                first = items[0] if isinstance(items, list) and items else None
                print(f"{self.path} 요청 받음, 저장할 센서 값 없음 (연결 테스트라면 정상): 키 {sorted(payload)}, "
                      f"항목 {len(items) if isinstance(items, list) else type(items).__name__}, "
                      f"첫 항목 {json.dumps(first, ensure_ascii=False)[:200]}", flush=True)
        self.reply(200, {"ok": True, "session": name, "added": added})

    def read_body(self):
        """요청 본문을 읽는다. tailscale serve를 거치면 Content-Length 없이 chunked로 올 수 있다."""
        try:
            if "chunked" in self.headers.get("Transfer-Encoding", "").lower():
                body = b""
                while len(body) <= MAX_BODY:
                    size = int(self.rfile.readline().split(b";")[0].strip() or b"0", 16)
                    if size == 0:
                        self.rfile.readline()  # 마지막 청크 뒤의 빈 줄
                        return body
                    body += self.rfile.read(size)
                    self.rfile.readline()  # 청크 끝의 CRLF
                return None
            length = int(self.headers.get("Content-Length", ""))
        except ValueError:
            return None
        return self.rfile.read(length) if 0 < length <= MAX_BODY else None

    def reply(self, code, obj):
        if code >= 400:
            print(f"요청 거절 {code} {obj.get('error')}: {self.command} {self.path} "
                  f"({self.headers.get('User-Agent', '?')})", flush=True)
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        if code >= 400:
            self.send_header("Connection", "close")
            self.close_connection = True
        self.end_headers()
        self.wfile.write(body)

    def log_request(self, code="-", size="-"):
        pass  # 0.5초마다 들어오는 요청 로그는 생략한다


def main():
    parser = argparse.ArgumentParser(description="스마트폰 센서 수집 서버")
    parser.add_argument("--port", type=int, default=8000)
    args = parser.parse_args()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"수집 서버: http://127.0.0.1:{args.port}  (저장 위치: {DATA_DIR})", flush=True)
    print(f"아이폰에서 열려면 다른 터미널에서: tailscale serve {args.port}", flush=True)
    print("수집 앱은 그 HTTPS 주소 뒤에 /app (Sensor Logger는 /sensorlogger)으로 보낸다", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n종료", flush=True)


if __name__ == "__main__":
    main()
