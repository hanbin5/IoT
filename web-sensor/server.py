#!/usr/bin/env python3
"""스마트폰이 보낸 센서 데이터를 받아 CSV로 저장하는 서버.

세 곳에서 받는다.
- POST /data: 이 폴더의 index.html을 iPhone Safari에서 열어 보내는 가속도·자이로·방향
- POST /app: ios-app/의 수집 앱이 보내는 동작 센서·기압계 (웹에서 못 읽는 기압계 포함).
  앱은 녹화를 폰에 저장했다가 골라서 보낸다. 그때 첫 묶음의 "replace": true로 같은 녹화의 이전 값을 지우고 다시 쓴다
- POST /sensorlogger: Sensor Logger 앱의 HTTP Push (/app과 같은 형식)

녹화 목록과 라벨 (수집 앱이 쓴다)
- GET /recordings: 녹화 폴더마다 시작 시각, 길이, 상대 고도 변화, 라벨 구간(시작·끝 초), 휴대 위치
- POST /recordings/labels {"name", "segments": [{"label", "start"}]}: 녹화의 라벨(label.csv)을 통째로 바꾼다
- POST /recordings/meta {"name", "meta": {"placement"}}: meta.json에서 앱이 고칠 수 있는 값(휴대 위치)을 바꾼다
- POST /recordings/delete {"name"}: 폴더를 data/.trash로 옮긴다 (목록에서 빠지고, 그 폴더에서 되살릴 수 있다)

iPhone Safari는 HTTPS 페이지에서만 모션 센서 권한을 주므로 tailscale serve로 HTTPS를 붙여 쓴다.

    python3 web-sensor/server.py      # http://127.0.0.1:8000
    tailscale serve 8000              # 다른 터미널에서 → https://<기기 이름>.<tailnet>.ts.net

웹 페이지 데이터는 data/<세션>/ 아래 motion.csv, orientation.csv, meta.json으로,
앱 데이터는 data/<시작 시각>-app/ (Sensor Logger는 -sl/) 아래 센서별 CSV와 meta.json으로 쌓인다.
라벨은 label.csv(time, label) 하나뿐이다. 한 행은 그 시각부터 다음 행(마지막은 녹화 끝)까지의 동작이고,
첫 행 전은 라벨이 없다. 녹화하면서 앱의 동작 버튼을 누르면 생기고, 앱에서 고치면 /recordings/labels로 바뀐다.
meta.json의 placement는 녹화하는 동안 폰을 몸의 어디에 두었는지(휴대 위치)다 (hand_front, pocket_front, bag 등).
"""

import argparse
import csv
import json
import math
import re
import threading
import time
import unicodedata
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

EDITABLE_META = {"placement"}  # 녹화 뒤에 앱에서 고칠 수 있는 meta.json 값

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


def read_meta(folder):
    """녹화 폴더의 meta.json. 없거나 깨졌으면 빈 dict."""
    try:
        meta = json.loads((folder / "meta.json").read_text())
    except (OSError, ValueError):
        return {}
    return meta if isinstance(meta, dict) else {}


def write_meta(folder, meta):
    """meta.json을 쓴다. 쓰다가 멈춰도 깨진 파일이 남지 않게 임시 파일을 바꿔 넣는다."""
    temp = folder / ".meta.json.tmp"
    temp.write_text(json.dumps(meta, ensure_ascii=False, indent=2))
    temp.replace(folder / "meta.json")


def batch_session_dir(suffix, session_id, first_ns):
    """녹화 하나를 '<시작 시각>-<suffix>' 폴더 하나에 모은다.

    서버를 재시작해도 meta.json의 sessionId로 같은 폴더를 다시 찾는다.
    같은 초에 시작한 다른 녹화가 있으면 섞이지 않도록 다음 초로 이름을 짓는다.
    """
    key = (suffix, session_id)
    if key not in batch_dirs or not batch_dirs[key].exists():
        found = [m.parent for m in DATA_DIR.glob("*/meta.json")
                 if read_meta(m.parent).get("sessionId") == session_id]
        if found:
            batch_dirs[key] = found[0]
        else:
            taken = {p.name[:15] for p in DATA_DIR.iterdir()} if DATA_DIR.exists() else set()
            t = first_ns / 1e9
            while (stamp := time.strftime("%Y%m%d-%H%M%S", time.localtime(t))) in taken:
                t += 1
            batch_dirs[key] = DATA_DIR / f"{stamp}-{suffix}"
    return batch_dirs[key]


def save_batch(payload, suffix, source):
    """센서 값 묶음을 센서별 CSV에 덧붙이고 (폴더 이름, 센서별 행 수)를 돌려준다.

    Sensor Logger HTTP Push와 같은 형식이다:
    {"sessionId", "deviceId", "meta"(선택), "payload": [{"name", "time"(epoch ns), "values": {...}}, ...]}
    "replace": true가 있으면 그 녹화에 전에 받은 값을 지우고 이 묶음부터 다시 쓰고, meta.json도 이 묶음의 meta로 바꾼다.
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
    replace = payload.get("replace") is True  # 폰에 저장해 둔 녹화를 처음부터 다시 받는다
    if replace:
        for old in folder.glob("*.csv"):
            old.unlink()
    if replace or not (folder / "meta.json").exists():  # 다시 받으면 폰에서 고친 휴대 위치 등도 따라온다
        ids = {k: payload[k] for k in ("sessionId", "deviceId", "userId") if k in payload}
        extra = payload["meta"] if isinstance(payload.get("meta"), dict) else {}
        write_meta(folder, {"source": source, **extra, **ids})
    for sensor, rows in groups.items():
        append_rows(folder / f"{sensor}.csv", rows)
    return folder.name, {sensor: len(rows) for sensor, rows in groups.items()}


def time_span(path):
    """CSV 첫 열(시각)의 처음과 끝을 epoch 초로 돌려준다. 파일 앞뒤만 읽어 녹화가 길어도 빠르다."""
    try:
        with path.open("rb") as f:
            header = f.readline().decode().strip().split(",")
            first = f.readline().decode().split(",")[0]
            f.seek(max(0, f.seek(0, 2) - 4096))
            last = f.read().decode(errors="ignore").splitlines()[-1].split(",")[0]
        scale = {"time": 1e9, "t_ms": 1e3}[header[0]]  # 앱은 epoch ns, 웹 페이지는 epoch ms
        return float(first) / scale, float(last) / scale
    except (OSError, ValueError, KeyError, IndexError):
        return None, None


def first_time_ns(path):
    """앱 CSV(첫 열이 epoch ns인 time)의 첫 시각을 정수 그대로 돌려준다. 없거나 다른 형식이면 None."""
    try:
        with path.open(newline="") as f:
            reader = csv.reader(f)
            if next(reader)[0] != "time":
                return None
            return int(next(reader)[0])
    except (OSError, StopIteration, ValueError, IndexError):
        return None


def read_segments(folder, start, end):
    """label.csv를 구간 목록으로 바꾼다.

    각 라벨은 그 시각부터 다음 라벨(마지막은 녹화 끝)까지이고, 시각은 녹화 시작 기준 초다.
    길이가 없는 구간은 빼고 이어진 같은 라벨은 하나로 합친다 (수집 앱의 LocalRecording.Segment.normalized와 같은 규칙).
    """
    if start is None:
        return []
    try:
        with (folder / "label.csv").open(newline="") as f:
            marks = sorted((int(r["time"]) / 1e9, r["label"]) for r in csv.DictReader(f))
    except (OSError, KeyError, ValueError):
        return []
    ends = [min(t, end) for t, _ in marks[1:]] + [end]  # 녹화가 끝난 뒤의 라벨은 쓰지 않는다
    segments = []
    for (t, label), e in zip(marks, ends):
        if e <= max(t, start):
            continue
        if segments and segments[-1]["label"] == label:
            segments[-1]["end_s"] = round(e - start, 2)
        else:
            segments.append({"label": label, "start_s": round(max(t - start, 0), 2), "end_s": round(e - start, 2)})
    return segments


def recording_info(folder):
    """녹화 폴더 하나를 요약한다: 시작 시각, 길이, 기압계 상대 고도의 변화, 라벨 구간."""
    meta = read_meta(folder)
    start, end = time_span(folder / "motion.csv")
    try:
        with (folder / "barometer.csv").open(newline="") as f:
            alt = [float(r["rel_alt_m"]) for r in csv.DictReader(f)]
    except (OSError, KeyError, ValueError):
        alt = []
    # 라벨만 고친 녹화를 '받는 중'으로 보지 않게 센서 값 파일만 본다
    updated = max((p.stat().st_mtime for p in folder.glob("*.csv") if p.name != "label.csv"), default=0)
    return {
        "name": folder.name,
        "source": meta.get("source", "web"),
        "started": start,
        "duration_s": None if start is None else round(end - start, 2),
        "alt_change_m": round(alt[-1] - alt[0], 2) if alt else None,
        "alt_range_m": round(max(alt) - min(alt), 2) if alt else None,
        "segments": read_segments(folder, start, end),
        "placement": meta.get("placement"),  # 휴대 위치
        "active": time.time() - updated < 5,  # 아직 데이터가 들어오는 중
    }


def list_recordings():
    """녹화 폴더 요약을 최근 것부터 돌려준다."""
    folders = [p for p in DATA_DIR.iterdir() if p.is_dir() and not p.name.startswith(".")] if DATA_DIR.exists() else []
    return sorted((recording_info(p) for p in folders), key=lambda r: r["started"] or 0, reverse=True)


def clean_label(text):
    """라벨을 다듬는다. 공백은 _로 바꾸고 글자(한글 포함)·숫자·_·-만 남긴다."""
    text = re.sub(r"\s+", "_", unicodedata.normalize("NFC", text).strip())
    return re.sub(r"[^\w-]", "", text).strip("_-")[:80]


def find_recording(name):
    """폴더 이름으로 녹화 폴더를 찾는다. data 바로 아래 폴더만 받는다."""
    folder = DATA_DIR / name
    if not name or "/" in name or name.startswith(".") or not folder.is_dir():
        raise LookupError(f"녹화 {name}을(를) 찾을 수 없습니다")
    return folder


def set_labels(name, segments):
    """녹화의 라벨(label.csv)을 통째로 바꾸고 새 요약을 돌려준다.

    segments는 [{"label", "start"(녹화 시작 기준 초)}]이다. 한 구간은 다음 구간의 시작(마지막은 녹화 끝)까지라
    끝은 받지 않는다. 빈 목록이면 라벨을 모두 지운다.
    """
    folder = find_recording(name)
    if not isinstance(segments, list):
        raise ValueError("segments는 목록이어야 합니다")
    start = first_time_ns(folder / "motion.csv")  # 앱이 보낸 시각과 ns까지 같도록 실수로 바꾸지 않는다
    if start is None:
        raise ValueError("motion.csv의 시각을 읽을 수 없어 라벨을 붙일 수 없습니다")
    marks = []
    for segment in segments:
        label = clean_label(str(segment.get("label") or "")) if isinstance(segment, dict) else ""
        try:
            t = float(segment["start"])
        except (TypeError, KeyError, ValueError):
            t = math.nan
        if not label or not math.isfinite(t) or t < 0:
            raise ValueError(f"구간이 올바르지 않습니다: {json.dumps(segment, ensure_ascii=False)[:100]}")
        marks.append((t, label))
    rows = []
    for t, label in sorted(marks):
        if not rows or rows[-1][1] != label:  # 이어진 같은 라벨은 하나로
            rows.append((start + round(t * 1e9), label))
    path = folder / "label.csv"
    if rows:
        temp = folder / ".label.csv.tmp"
        with temp.open("w", newline="") as f:
            writer = csv.writer(f)
            writer.writerow(["time", "label"])
            writer.writerows(rows)
        temp.replace(path)
    else:
        path.unlink(missing_ok=True)
    return recording_info(folder)


def set_meta(name, changes):
    """meta.json에서 앱이 고칠 수 있는 값(EDITABLE_META)을 바꾸고 새 요약을 돌려준다. 값이 null이나 ""이면 지운다."""
    folder = find_recording(name)
    if not isinstance(changes, dict) or not changes:
        raise ValueError("meta는 비어 있지 않은 객체여야 합니다")
    unknown = sorted(set(changes) - EDITABLE_META)
    if unknown:
        raise ValueError(f"고칠 수 없는 값입니다: {', '.join(unknown)}")
    meta = read_meta(folder)
    for key, value in changes.items():
        if value is not None and not isinstance(value, str):
            raise ValueError(f"{key}는 문자열이어야 합니다")
        value = clean_label(value or "")
        if value:
            meta[key] = value
        else:
            meta.pop(key, None)
    write_meta(folder, meta)
    return recording_info(folder)


def delete_recording(name):
    """녹화 폴더를 data/.trash로 옮기고 옮긴 곳(data 기준 경로)을 돌려준다. 그 폴더에서 꺼내면 되살아난다."""
    folder = find_recording(name)
    trash = DATA_DIR / ".trash"
    trash.mkdir(exist_ok=True)
    target = trash / name
    n = 1
    while target.exists():  # 같은 이름을 또 지우면 뒤에 번호를 붙인다
        n += 1
        target = trash / f"{name}-{n}"
    folder.rename(target)
    for key in [k for k, path in batch_dirs.items() if path == folder]:
        del batch_dirs[key]  # 지운 녹화에 묶음이 더 오면 새 폴더로 받는다
    return target.relative_to(DATA_DIR).as_posix()


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
        if path == "/recordings":
            with lock:
                recordings = list_recordings()
            return self.reply(200, {"recordings": recordings})
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
        if handle is None and self.path not in ("/recordings/labels", "/recordings/meta", "/recordings/delete"):
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
        if handle is None:
            return self.manage(payload)
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

    def manage(self, payload):
        """POST /recordings/labels {"name": 폴더 이름, "segments"}, /recordings/meta {"name", "meta"}, /recordings/delete {"name"}"""
        name = str(payload.get("name") or "")
        try:
            with lock:
                if self.path == "/recordings/labels":
                    result = {"recording": set_labels(name, payload.get("segments"))}
                elif self.path == "/recordings/meta":
                    result = {"recording": set_meta(name, payload.get("meta"))}
                else:
                    result = {"trashed": delete_recording(name)}
        except LookupError as e:
            return self.reply(404, {"error": str(e)})
        except ValueError as e:
            return self.reply(400, {"error": str(e)})
        except OSError as e:
            return self.reply(500, {"error": f"처리하지 못했습니다: {e}"})
        if self.path == "/recordings/meta":
            print(f"휴대 위치: {name} → {result['recording']['placement'] or '없음'}", flush=True)
        elif "recording" in result:
            labels = " → ".join(s["label"] for s in result["recording"]["segments"])
            print(f"라벨: {name} → {labels or '없음'}", flush=True)
        else:
            print(f"지움: {name} → {result['trashed']}", flush=True)
        self.reply(200, {"ok": True, **result})

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
    global DATA_DIR
    parser = argparse.ArgumentParser(description="스마트폰 센서 수집 서버")
    parser.add_argument("--port", type=int, default=8000)
    parser.add_argument("--data", type=Path, default=DATA_DIR, help="녹화를 저장할 폴더 (기본: web-sensor/data)")
    args = parser.parse_args()
    DATA_DIR = args.data.resolve()
    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    print(f"수집 서버: http://127.0.0.1:{args.port}  (저장 위치: {DATA_DIR})", flush=True)
    print(f"아이폰에서 열려면 다른 터미널에서: tailscale serve {args.port}", flush=True)
    print("수집 앱은 그 HTTPS 주소 뒤에 /app (Sensor Logger는 /sensorlogger)으로 보낸다", flush=True)
    print("녹화 목록은 GET /recordings, 라벨은 POST /recordings/labels, 휴대 위치는 POST /recordings/meta, "
          "지우기는 POST /recordings/delete",
          flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\n종료", flush=True)


if __name__ == "__main__":
    main()
