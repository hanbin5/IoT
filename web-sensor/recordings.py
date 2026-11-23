#!/usr/bin/env python3
"""수집 앱 녹화를 읽고 품질을 점검한다.

녹화 폴더는 data/<시작 시각>-app/이다. 앱은 녹화를 폰에 먼저 저장했다가 고른 것만 보낸다.
지운 녹화는 data/.trash/로 옮겨지고, 여기서는 건너뛴다.
라벨은 label.csv(time, label) 하나뿐이다. 한 행은 그 시각부터 다음 행(마지막은 녹화 끝)까지의 동작이고,
첫 행 전은 라벨이 없다. 녹화 중 누른 동작 버튼으로 생기고, 앱에서 고치면 server.py가 통째로 다시 쓴다.
휴대 위치(폰을 몸의 어디에 두었는지)는 meta.json의 placement다. 녹화 전에 앱에서 고르고, 녹화 뒤에도 고칠 수 있다.
녹화를 보내거나 라벨·휴대 위치를 고칠 때마다 돌려서 다음을 확인한다.
- 길이, 끊김, 중복
- 기압과 고도 변화
- 라벨 구간의 동작이 그 구간의 고도 변화와 맞는지
- 휴대 위치별·라벨별로 모인 시간 (모든 녹화 목록의 끝). 어느 위치의 어느 동작이 모자란지 본다

    web-sensor/.venv/bin/python web-sensor/recordings.py                   # 모든 앱 녹화를 한 줄씩
    web-sensor/.venv/bin/python web-sensor/recordings.py --last            # 가장 최근 녹화를 자세히
    web-sensor/.venv/bin/python web-sensor/recordings.py 20261111-112348   # 지정한 녹화를 자세히 (시작 시각이나 폴더 이름)

분석 코드에서는 load()로 녹화를 numpy 배열로 읽고, label_segments()로 라벨 구간을 읽는다.
numpy는 web-sensor/.venv에 설치한다 (.venv는 git에 올리지 않는다):

    python3 -m venv web-sensor/.venv
    web-sensor/.venv/bin/pip install -r web-sensor/requirements.txt
"""

import argparse
import csv
import json
import re
import time
import unicodedata
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

import numpy as np

DATA_DIR = Path(__file__).resolve().parent / "data"
STAMP = re.compile(r"(\d{8}-\d{6})(?:-.+)?")  # 폴더 이름: <시작 시각>-app (Sensor Logger는 -sl, server.py와 같다)
SOURCES = {"ios-app", "Sensor Logger"}  # meta.json의 source
SIMULATORS = {"arm64", "x86_64"}  # 시뮬레이터에서 녹화하면 meta.json의 model이 이렇게 나온다
# meta.json의 placement(휴대 위치): 수집 앱 Placement.swift의 token과 이름. 예전 녹화에는 없다
PLACEMENTS = {"hand_front": "손 (화면을 보며)", "hand_swing": "손 (팔을 흔들며)", "pocket_front": "바지 앞주머니",
              "pocket_back": "바지 뒷주머니", "jacket_pocket": "상의 주머니", "bag": "가방", "ear": "통화 (귀에 대고)"}
# label.csv의 라벨(수집 앱 Activity.swift의 token)과 그것을 시간축에 그리는 글자. idle은 서 있거나 엘리베이터를 기다리는 구간
SEGMENT_MARKS = {"walk": "-", "stairs_up": "/", "stairs_down": "\\", "elevator_up": "^", "elevator_down": "v", "idle": "."}
ACTIVITIES = tuple(SEGMENT_MARKS)
UP, DOWN = {"stairs_up", "elevator_up"}, {"stairs_down", "elevator_down"}
# 층 이동 표기: 1F-3F, 3F-B1F. 층을 어디에 적을지는 아직 정하지 않았다 (parse_floors, check(floors=…) 참고)
FLOORS = re.compile(r"(?:^|_)(B\d+F?|\d+F)-(B\d+F?|\d+F)(?=_|$)")

MOTION_HZ = 100  # 앱의 Core Motion 수집 주기
GAP_S = 0.1  # motion 간격이 이보다 길면 끊김으로 본다 (정상은 0.01초)
BARO_GAP_S = 3.0  # 기압 간격이 이보다 길면 끊김으로 본다 (정상은 약 1초)
BARO_EDGE_S = 5.0  # 기압 첫 값·마지막 값이 motion과 이보다 많이 어긋나면 알린다 (정상은 약 3초)
MOVING_RMS = 0.5  # 1초 구간의 |가속도| RMS(m/s²)가 이보다 크면 움직인 것으로 본다 (가만히 있으면 0.05 안팎)
ACTIVE_S = 10.0  # CSV가 이 시간 안에 바뀌었으면 아직 데이터를 받는 중(실시간 수집이나 전송)으로 본다
SPARK_WIDTH = 60  # 자세히 보기의 시간축 칸 수 (한 칸은 1초 이상)
BLOCKS = "▁▂▃▄▅▆▇█"


@dataclass
class Recording:
    """녹화 하나.

    sensors[센서 이름][열 이름]은 numpy 배열이다. 센서 이름은 CSV 파일 이름(motion, barometer, label, …)이고,
    "time"은 epoch ns(int64), "t"는 녹화 시작 기준 초다. 녹화 시작은 첫 motion 샘플이다
    (수집 앱, server.py와 같다. motion이 없으면 가장 이른 센서 샘플).
    """

    folder: Path
    meta: dict
    sensors: dict
    t0_ns: int

    @property
    def name(self):
        return self.folder.name

    def get(self, sensor):
        return self.sensors.get(sensor)


def read_meta(folder):
    """녹화 폴더의 meta.json. 없거나 깨졌으면 빈 dict."""
    try:
        meta = json.loads((Path(folder) / "meta.json").read_text())
    except (OSError, ValueError):
        return {}
    return meta if isinstance(meta, dict) else {}


def app_recordings(data_dir=DATA_DIR):
    """수집 앱·Sensor Logger 녹화 폴더를 시작 시각 순으로 돌려준다.

    점으로 시작하는 폴더(지운 녹화를 모아 두는 .trash 등)는 건너뛴다.
    """
    return [p for p in sorted(Path(data_dir).iterdir())
            if p.is_dir() and not p.name.startswith(".") and STAMP.fullmatch(p.name)
            and read_meta(p).get("source") in SOURCES]


def find(name, data_dir=DATA_DIR):
    """녹화 폴더를 찾는다. 경로, 폴더 이름, 시작 시각(20261111-112348처럼 -app을 뺀 것) 모두 된다."""
    name = str(name)
    for path in (Path(name), Path(data_dir) / name):
        if path.is_dir():
            return path
    if re.fullmatch(r"\d{8}-\d{6}", name):  # .trash 안은 찾지 않는다
        matches = [p for p in Path(data_dir).iterdir() if p.is_dir() and p.name.startswith(name + "-")]
        if len(matches) == 1:
            return matches[0]
    raise FileNotFoundError(f"녹화 폴더가 없습니다: {name}")


def parse_floor(text):
    """'3F' → 3, 'B1F'·'B1' → 0, 'B2F' → -1. 층 차이를 바로 뺄 수 있게 지하 1층을 0으로 둔다."""
    digits = int(re.sub(r"\D", "", text))
    return 1 - digits if text.startswith("B") else digits


def floor_name(n):
    return f"{n}F" if n >= 1 else f"B{1 - n}F"


def parse_floors(text):
    """글 속의 층 이동을 (출발 층, 도착 층)으로 읽는다. 없으면 None. 예: '1F-3F' → (1, 3), 'x_3F-B1F' → (3, 0)

    층을 어디에 적을지는 아직 정하지 않았다. 정해지면 거기서 읽어 check(rec, floors=…)에 넘긴다.
    """
    f = FLOORS.search(text or "")
    return (parse_floor(f.group(1)), parse_floor(f.group(2))) if f else None


def read_csv(path):
    """CSV를 {열 이름: numpy 배열}로 읽는다.

    time은 int64, 숫자 열은 float64(빈 칸은 NaN), 숫자가 아닌 열은 문자열 배열이다.
    """
    with Path(path).open(newline="") as f:
        reader = csv.reader(f)
        header = next(reader, None) or []
        rows = [r for r in reader if len(r) == len(header)]  # 수집 중이라 덜 써진 마지막 줄은 버린다
    table = np.array(rows, dtype=str).reshape(len(rows), len(header))
    columns = {}
    for i, name in enumerate(header):
        col = table[:, i]
        if name == "time":
            columns[name] = col.astype(np.int64)
            continue
        try:
            columns[name] = np.where(col == "", "nan", col).astype(np.float64)
        except ValueError:
            columns[name] = col
    return columns


def dedupe(cols):
    """시각 순으로 정렬하고, 시각이 같은 행(앱이 재전송한 묶음)은 처음 것만 남긴다."""
    order = np.argsort(cols["time"], kind="stable")
    first = np.r_[True, np.diff(cols["time"][order]) > 0]
    return {k: v[order[first]] for k, v in cols.items()}


def order_issues(times):
    """시각 열의 중복 행이나 역순(시각이 거꾸로 가는 곳)을 글로 돌려준다. 문제가 없으면 빈 문자열."""
    dups = len(times) - len(np.unique(times))
    if dups:
        return f"시각 중복 {dups}행 (재전송 중복일 수 있음)"
    backwards = int((np.diff(times) < 0).sum())
    return f"시각 역순 {backwards}곳" if backwards else ""


def load(folder, data_dir=DATA_DIR, raw=False):
    """녹화 폴더를 읽어 Recording으로 돌려준다.

    기본으로 센서마다 dedupe()를 거친다. raw=True면 파일에 적힌 순서 그대로 둔다 (점검용).
    label.csv는 센서 값이 아니라 늘 그대로 둔다. 같은 시각의 행은 label_segments()가 server.py와 같은 규칙으로 다룬다.
    """
    folder = find(folder, data_dir)
    sensors = {}
    for path in sorted(folder.glob("*.csv")):
        cols = read_csv(path)
        if "time" not in cols and "t_ms" in cols:  # Safari 페이지(/data) 녹화
            cols["time"] = np.round(cols.pop("t_ms") * 1e6).astype(np.int64)
        if "time" not in cols:
            continue
        sensors[path.stem] = cols if raw or path.stem == "label" else dedupe(cols)
    motion = sensors.get("motion")
    if motion is not None and len(motion["time"]):
        t0 = int(motion["time"].min())  # 녹화 시작은 첫 motion 샘플이다 (수집 앱, server.py와 같다)
    else:
        starts = [c["time"].min() for k, c in sensors.items() if k != "label" and len(c["time"])]
        t0 = int(min(starts)) if starts else 0
    for cols in sensors.values():
        cols["t"] = (cols["time"] - t0) / 1e9
    return Recording(folder, read_meta(folder), sensors, t0)


def acc_magnitude(motion):
    """중력을 뺀 가속도의 크기(m/s²). 폰 방향과 무관하다."""
    return np.sqrt(motion["acc_x"] ** 2 + motion["acc_y"] ** 2 + motion["acc_z"] ** 2)


def bin_stats(t, v, edges):
    """시간 구간 [edges[i], edges[i+1])마다 v의 개수, 평균, 표준편차를 돌려준다. 빈 구간은 NaN."""
    ok = np.isfinite(v)
    idx = np.searchsorted(edges, t[ok], side="right") - 1
    inside = (idx >= 0) & (idx < len(edges) - 1)
    idx, v = idx[inside], v[ok][inside]
    nbins = len(edges) - 1
    n = np.bincount(idx, minlength=nbins)
    s1 = np.bincount(idx, v, minlength=nbins)
    s2 = np.bincount(idx, v * v, minlength=nbins)
    with np.errstate(invalid="ignore", divide="ignore"):
        mean = s1 / n
        std = np.sqrt(np.maximum(s2 / n - mean**2, 0))
    return n, mean, std


def check(rec, floor_height=4.0, floors=None):
    """녹화의 품질 지표를 dict로 돌려준다. 눈여겨볼 점은 "warnings"에 담는다.

    중복·역순을 세려면 load(..., raw=True)로 읽은 녹화를 넘긴다.
    floors는 이 녹화의 층 이동 (출발 층, 도착 층)이다. 주면 고도 변화와 맞는지 보고 층당 고도를 구한다.
    """
    s = {"name": rec.name, "warnings": [], "floor_height": floor_height, "route": floors}
    warn = s["warnings"].append
    m = STAMP.fullmatch(rec.name)
    s["stamp"] = m.group(1) if m else rec.name
    s["start"] = datetime.fromtimestamp(rec.t0_ns / 1e9)
    s["device"] = " · ".join(str(rec.meta[k]) for k in ("model", "system") if rec.meta.get(k))
    s["simulator"] = rec.meta.get("model") in SIMULATORS
    s["placement"] = str(rec.meta.get("placement") or "") or None  # 휴대 위치 token. 없으면 None
    ends =[c["t"].max() for k, c in rec.sensors.items() if k != "label" and len(c["t"])]
    s["duration"] = float(max(ends)) if ends else 0.0
    # 라벨만 고친 녹화를 '받는 중'으로 보지 않게 센서 값 파일만 본다 (server.py와 같다)
    mtimes = [p.stat().st_mtime for p in rec.folder.glob("*.csv") if p.name != "label.csv"]
    s["active"] = bool(mtimes) and -1 < time.time() - max(mtimes) < ACTIVE_S
    moving_bins = alt_curve = None  # 구간 라벨 점검에 다시 쓴다
    if not rec.meta:
        warn("meta.json 없음")
    if s["placement"] and s["placement"] not in PLACEMENTS:
        warn(f"휴대 위치 {s['placement']}: 수집 앱에 없는 값")
    if s["duration"] < 10:
        warn(f"{s['duration']:.1f}초로 짧음")

    motion = rec.get("motion")
    if motion is None or len(motion["time"]) < 2:
        warn("motion 없음")
        motion = None
    else:
        s["motion_order"] = order_issues(motion["time"])
        motion = dedupe(motion)
        t = motion["t"]
        dt = np.diff(t)
        gaps = dt[dt > GAP_S]
        covered = t[-1] - t[0] - gaps.sum()  # 끊긴 구간을 뺀 길이. 샘플링은 끊김과 따로 본다
        s["motion_n"] = len(t)
        s["motion_hz"] = (len(t) - 1 - len(gaps)) / covered if covered > 0 else 0.0
        s["motion_gaps"] = (len(gaps), float(gaps.max(initial=0)), float(gaps.sum()))
        if s["motion_hz"] < 0.95 * MOTION_HZ:
            warn(f"motion {s['motion_hz']:.1f} Hz로 낮음")
        if len(gaps):
            warn(f"motion 끊김 {len(gaps)}회 (최대 {gaps.max():.1f}초, 합계 {gaps.sum():.1f}초)")
        if s["motion_order"]:
            warn(f"motion {s['motion_order']}")
        if {"acc_x", "acc_y", "acc_z"} <= motion.keys():
            edges = np.arange(0, s["duration"] + 1.0)
            n, mean, std = bin_stats(t, acc_magnitude(motion), edges)
            full = n >= 20  # 1초 구간에 샘플이 충분한 것만 센다
            if full.any():
                rms = np.hypot(mean, std)  # = sqrt(구간 평균 |가속도|²)
                s["moving"] = float(np.mean(rms[full] > MOVING_RMS))
                moving_bins = (edges[:-1], np.where(full, rms > MOVING_RMS, np.nan))  # 1초 구간 시작, 움직임 1/0

    baro = rec.get("barometer")
    if baro is None or not len(baro["time"]):
        warn("기압 없음")
    else:
        s["baro_order"] = order_issues(baro["time"])
        baro = dedupe(baro)
        t = baro["t"]
        s["baro_n"] = len(t)
        if len(t) >= 2:
            dt = np.diff(t)
            gaps = dt[dt > BARO_GAP_S]
            s["baro_interval"] = float(np.median(dt))
            if s["baro_interval"] > 1.5:
                warn(f"기압 간격 {s['baro_interval']:.2f}초로 김")
            if len(gaps):
                warn(f"기압 끊김 {len(gaps)}회 (최대 {gaps.max():.1f}초)")
        if s["baro_order"]:
            warn(f"기압 {s['baro_order']}")
        if motion is not None:
            s["baro_lead"] = float(t[0] - motion["t"][0])  # 첫 기압 값이 motion 시작보다 늦은 시간
            s["baro_tail"] = float(motion["t"][-1] - t[-1])  # 마지막 기압 값이 motion 끝보다 이른 시간
            if s["baro_lead"] > BARO_EDGE_S:
                warn(f"기압 첫 값이 {s['baro_lead']:.1f}초 늦음")
            if s["baro_tail"] > BARO_EDGE_S:
                warn(f"기압 마지막 값이 끝보다 {s['baro_tail']:.1f}초 이름")
        p = baro.get("pressure_hpa")
        if p is not None and np.isfinite(p).any():
            s["pressure"] = (p[0], p[-1], np.nanmin(p), np.nanmax(p))
        alt = baro.get("rel_alt_m")
        if alt is not None and np.isfinite(alt).any():
            rel = alt - alt[np.isfinite(alt)][0]
            s["alt"] = (rel[np.isfinite(rel)][-1], np.nanmin(rel), np.nanmax(rel))  # 순변화, 최저, 최고
            s["floors"] = tuple(x / floor_height for x in s["alt"])
            alt_curve = (t[np.isfinite(rel)], rel[np.isfinite(rel)])
    check_floors(s, warn)

    s["segments"] = []
    for i, (label, a, b) in enumerate(label_segments(rec), 1):
        seg = {"label": label, "start": a, "end": b}
        if alt_curve is not None:
            seg["alt"] = float(np.interp(b, *alt_curve) - np.interp(a, *alt_curve))
        if moving_bins is not None:
            starts, flags = moving_bins
            inside = (starts >= a) & (starts + 1 <= b) & np.isfinite(flags)
            if inside.any():
                seg["moving"] = float(np.mean(flags[inside]))
        check_segment(i, seg, warn)
        s["segments"].append(seg)
    if motion is not None:  # 첫 라벨 전처럼 라벨이 없는 시간
        labeled = sum(g["end"] - g["start"] for g in s["segments"])
        s["unlabeled"] = max(float(motion["t"][-1] - motion["t"][0]) - labeled, 0.0)
    s["others"] = {k: len(c["time"]) for k, c in rec.sensors.items()
                   if k not in ("motion", "barometer") and not (k == "label" and s["segments"])}
    return s


def check_floors(s, warn):
    """층 이동(s["route"])이 기압계 고도 변화와 맞는지 본다.

    맞으면 층당 고도(m)를 s["floor_m"]에 담는다. 층 보정에 쓴다.
    """
    floors = s["route"]
    if not floors or "alt" not in s:
        return
    net = s["alt"][0]
    moved = floors[1] - floors[0]
    if moved == 0:
        if abs(net) > 2.0:
            warn(f"같은 층({floor_name(floors[0])})인데 고도 변화가 {net:+.1f} m")
        return
    per_floor = net / moved
    if 2.5 <= per_floor <= 6.0:
        s["floor_m"] = per_floor
    else:
        warn(f"{floor_name(floors[0])}→{floor_name(floors[1])} ({moved:+d}층)인데 고도 변화가 {net:+.1f} m "
             f"(층당 {per_floor:.1f} m)")


def label_segments(rec):
    """label.csv를 [(라벨, 시작 초, 끝 초)]로 바꾼다. 시각은 rec의 "t"와 같은 기준이다.

    수집 앱, server.py의 read_segments와 같은 규칙이다.
    - 녹화는 첫 motion 샘플부터 마지막 motion 샘플까지다
    - 한 행은 그 시각부터 다음 행(마지막은 녹화 끝)까지이고, 첫 행 전은 라벨이 없다
    - 길이가 없는 구간(같은 시각에 찍힌 행, 녹화 끝 뒤의 행)은 빼고, 이어진 같은 라벨은 하나로 합친다
    """
    lab, motion = rec.get("label"), rec.get("motion")
    if lab is None or "label" not in lab or motion is None or not len(motion["t"]):
        return []
    start, end = float(motion["t"].min()), float(motion["t"].max())
    marks = sorted(zip(lab["t"].tolist(), map(str, lab["label"].tolist())))
    ends = [min(t, end) for t, _ in marks[1:]] + [end]
    segments = []
    for (t, label), e in zip(marks, ends):
        if e <= max(t, start):
            continue
        if segments and segments[-1][0] == label:
            segments[-1][2] = e
        else:
            segments.append([label, max(t, start), e])
    return [tuple(g) for g in segments]


def check_segment(i, seg, warn):
    """구간 라벨이 수집 앱의 라벨인지, 그 구간의 고도 변화와 맞는지 본다.

    기압은 1~2초 늦게 따라오므로 짧은 구간은 고도 변화를 따지지 않는다.
    """
    label = seg["label"]
    where = f"구간 {i} {label}({seg['start']:.0f}~{seg['end']:.0f}초)"
    if label not in ACTIVITIES:
        warn(f"{where}: 수집 앱에 없는 라벨")
    if "alt" not in seg:
        return
    alt, dur = seg["alt"], seg["end"] - seg["start"]
    if dur >= 8 and ((label in UP and alt < 0.8) or (label in DOWN and alt > -0.8)):
        warn(f"{where}인데 고도 변화 {alt:+.1f} m")
    if label in ("walk", "idle") and abs(alt) > 2.0:
        warn(f"{where}인데 고도 변화 {alt:+.1f} m (계단·엘리베이터 라벨을 빠뜨렸을 수 있음)")


def sparkline(values, lo, hi):
    """값을 ▁~█ 막대로 그린다. NaN은 빈칸이다."""
    top = len(BLOCKS) - 1
    out = []
    for v in values:
        if not np.isfinite(v):
            out.append(" ")
        else:
            level = round((v - lo) / (hi - lo) * top) if hi > lo else 0
            out.append(BLOCKS[min(max(level, 0), top)])
    return "".join(out)


def timeline(rec, duration, segments=()):
    """구간 라벨, 움직임, 고도를 같은 시간축에 그린 줄들을 돌려준다."""
    width = int(min(SPARK_WIDTH, max(1, np.ceil(duration))))
    edges = np.linspace(0, duration, width + 1)
    edges[-1] += 1e-6  # 마지막 샘플도 넣는다
    lines = []
    if segments:
        marks = []
        for mid in (edges[:-1] + edges[1:]) / 2:  # 칸 가운데 시각의 라벨
            seg = next((g for g in segments if g["start"] <= mid < g["end"]), None)
            marks.append(" " if seg is None else SEGMENT_MARKS.get(seg["label"], "?"))
        legend = "  ".join(f"{mark} {name}" for name, mark in SEGMENT_MARKS.items())
        lines.append(f"  라벨     {''.join(marks)}  {legend}")
    motion = rec.get("motion")
    if motion is not None and {"acc_x", "acc_y", "acc_z"} <= motion.keys():
        _, mean, std = bin_stats(motion["t"], acc_magnitude(motion), edges)
        lines.append(f"  움직임   {sparkline(np.hypot(mean, std), 0, 2.0)}  |가속도| RMS 0~2 m/s²")
    baro = rec.get("barometer")
    if baro is not None and "rel_alt_m" in baro and np.isfinite(baro["rel_alt_m"]).any():
        alt = baro["rel_alt_m"] - baro["rel_alt_m"][np.isfinite(baro["rel_alt_m"])][0]
        _, mean, _ = bin_stats(baro["t"], alt, edges)
        for i in range(1, len(mean)):  # 기압은 약 1초 간격이라 빈 칸은 앞 값으로 채운다
            if not np.isfinite(mean[i]):
                mean[i] = mean[i - 1]
        lo, hi = np.nanmin(alt), np.nanmax(alt)
        if hi - lo < 1.0:  # 잡음이 계단처럼 보이지 않게 최소 1 m 폭으로 그린다
            mid = (hi + lo) / 2
            lo, hi = mid - 0.5, mid + 0.5
        lines.append(f"  고도     {sparkline(mean, lo, hi)}  {lo:+.1f} ~ {hi:+.1f} m")
    if lines:
        right = f"{duration:.0f}초"
        lines.append(f"           0초{right:>{width - 2}}  (한 칸 {duration / width:.1f}초)")
    return lines


def notes(s):
    """경고 앞에 붙는 상태 표시."""
    return (["받는 중"] if s["active"] else []) + (["시뮬레이터"] if s["simulator"] else [])


def label_text(s):
    """라벨 구간들의 동작을 차례로 쓴다 (예: idle→walk→stairs_up). 라벨이 없으면 빈 문자열."""
    return "→".join(g["label"] for g in s["segments"])


def duration_text(seconds):
    """1분 미만은 초로, 그 위는 분으로 쓴다."""
    return f"{seconds:.0f}초" if seconds < 60 else f"{seconds / 60:.1f}분"


def placement_text(token):
    """휴대 위치를 '바지 앞주머니 (pocket_front)'처럼 쓴다."""
    if not token:
        return "모름 (meta.json에 placement 없음)"
    return f"{PLACEMENTS[token]} ({token})" if token in PLACEMENTS else f"{token} (수집 앱에 없는 값)"


def format_line(s):
    """모든 녹화 목록에 쓰는 한 줄 요약. 시작 시각 뒤는 휴대 위치, 라벨 구간의 동작 차례다."""
    parts = [f"{s['stamp']}  {s['placement'] or '-':<13}  {label_text(s) or '-':<24}", f"{s['duration']:6.1f}초"]
    if "motion_hz" in s:
        parts.append(f"motion {s['motion_hz']:5.1f}Hz")
    if "baro_n" in s:
        parts.append(f"기압 {s['baro_n']:4d}개")
    if "alt" in s:
        net, lo, hi = s["alt"]
        parts.append(f"고도 {net:+5.1f}m (범위 {lo:+.1f}~{hi:+.1f}) ≈ {s['floors'][0]:+.1f}층")
    if "moving" in s:
        parts.append(f"움직임 {s['moving']:4.0%}")
    return " | ".join(parts + ["; ".join(notes(s) + s["warnings"]) or "이상 없음"])


def format_detail(s, rec):
    """녹화 하나를 자세히 보여 주는 줄들."""
    head = f"{s['start']:%Y-%m-%d %H:%M:%S} 시작 · {s['duration']:.1f}초"
    lines = [f"{s['stamp']}  {label_text(s) or '라벨 없음'}  ({head}{' · ' + s['device'] if s['device'] else ''})",
             f"  폴더     {rec.folder}",
             f"  폰 위치  {placement_text(s['placement'])}"]
    if s["active"]:
        lines.append("  ※ 아직 데이터를 받는 중입니다 (실시간 수집이나 전송). 다 받은 뒤 다시 점검하세요.")
    if s["simulator"]:
        lines.append("  ※ 시뮬레이터 녹화입니다 (가짜 센서 값). 데이터셋에서 빼세요.")
    if s["route"]:
        a, b = s["route"]
        lines.append(f"  층 이동  {floor_name(a)} → {floor_name(b)} ({b - a:+d}층)")
    if s["segments"]:
        rest = f" · 라벨 없는 시간 {s['unlabeled']:.1f}초" if s.get("unlabeled", 0) >= 0.05 else ""
        lines.append(f"  구간     라벨 {len(s['segments'])}개 (label.csv){rest}")
        for i, seg in enumerate(s["segments"], 1):
            info = [f"{seg['start']:6.1f}~{seg['end']:6.1f}초 ({seg['end'] - seg['start']:5.1f}초)"]
            if "alt" in seg:
                info.append(f"고도 {seg['alt']:+5.1f} m")
            if "moving" in seg:
                info.append(f"움직임 {seg['moving']:4.0%}")
            lines.append(f"           {i:2d}. {seg['label']:<14} " + " · ".join(info))
    if "motion_n" in s:
        n, longest, total = s["motion_gaps"]
        gap = f"끊김 {n}회 (최대 {longest:.1f}초, 합계 {total:.1f}초)" if n else "끊김 없음"
        dup = s["motion_order"] or "중복·역순 없음"
        moving = f" · 움직인 시간 {s['moving']:.0%}" if "moving" in s else ""
        lines.append(f"  motion   {s['motion_n']}개 · {s['motion_hz']:.1f} Hz · {gap} · {dup}{moving}")
    if "baro_n" in s:
        parts = [f"{s['baro_n']}개"]
        if "baro_interval" in s:
            parts.append(f"간격 중앙값 {s['baro_interval']:.2f}초")
        if "baro_lead" in s:
            parts += [f"첫 값 시작 {s['baro_lead']:.1f}초 뒤", f"마지막 값 끝 {s['baro_tail']:.1f}초 전"]
        lines.append("  기압     " + " · ".join(parts))
        if "pressure" in s:
            first, last, lo, hi = s["pressure"]
            lines.append(f"           {first:.3f} → {last:.3f} hPa (최소 {lo:.3f}, 최대 {hi:.3f})")
    if "alt" in s:
        net, lo, hi = s["alt"]
        f_net, f_lo, f_hi = s["floors"]
        lines.append(f"  고도     순변화 {net:+.2f} m · 범위 {lo:+.2f} ~ {hi:+.2f} m")
        per = f" · 층 이동 기준 층당 {s['floor_m']:.2f} m" if "floor_m" in s else ""
        lines.append(f"  층 변화  ≈ {f_net:+.1f}층 (최저 {f_lo:+.1f}, 최고 {f_hi:+.1f} · 층고 {s['floor_height']} m 가정){per}")
    lines += timeline(rec, s["duration"], s["segments"])
    if s["others"]:
        lines.append("  그 밖    " + ", ".join(f"{k}.csv {n}행" for k, n in s["others"].items()))
    lines.append("  점검     " + ("; ".join(s["warnings"]) or "이상 없음"))
    return lines


def text_width(text):
    """터미널에서 차지하는 칸 수. 한글처럼 넓은 글자는 두 칸이다."""
    return sum(2 if unicodedata.east_asian_width(c) in "WF" else 1 for c in text)


def pad(text, cols, right=False):
    """text를 터미널 cols칸에 맞춘다. right면 오른쪽으로 붙인다."""
    gap = " " * max(cols - text_width(text), 0)
    return gap + text if right else text + gap


def time_table(summaries):
    """휴대 위치별·라벨별로 모은 시간 표의 줄들. 시뮬레이터 녹화는 데이터셋에 넣지 않으므로 뺀다.

    수집 앱의 휴대 위치는 시간이 없어도 모두 줄로 넣어 모자란 곳이 드러나게 한다.
    휴대 위치가 없는 예전 녹화는 '모름' 줄에 모은다.
    """
    real = [s for s in summaries if not s["simulator"]]
    table = {p: {} for p in PLACEMENTS}
    for s in real:
        row = table.setdefault(s["placement"] or "모름", {})
        for g in s["segments"]:
            row[g["label"]] = row.get(g["label"], 0.0) + g["end"] - g["start"]
        row["라벨 없음"] = row.get("라벨 없음", 0.0) + s.get("unlabeled", 0.0)
    others = sorted({k for row in table.values() for k in row} - set(ACTIVITIES) - {"라벨 없음"})  # 앱에 없는 라벨
    columns = [*ACTIVITIES, *others, "라벨 없음"]
    names = [*PLACEMENTS, *sorted(set(table) - set(PLACEMENTS) - {"모름"}), *(["모름"] if "모름" in table else [])]
    rows = [[name, *(table[name].get(c, 0.0) for c in columns)] for name in names]
    rows = [r + [sum(r[1:])] for r in rows]  # 줄 합계
    rows.append(["합계", *(sum(col) for col in list(zip(*rows))[1:])])
    cells = [["휴대 위치", *columns, "합계"]]
    cells += [[r[0], *(duration_text(v) if v >= 0.5 else "-" for v in r[1:])] for r in rows]
    widths = [max(text_width(row[i]) for row in cells) for i in range(len(cells[0]))]
    skipped = len(summaries) - len(real)
    lines = ["휴대 위치별 라벨 시간" + (f" (시뮬레이터 녹화 {skipped}개 빼고)" if skipped else "")]
    lines += ["  " + "  ".join(pad(c, w, right=i > 0) for i, (c, w) in enumerate(zip(row, widths))) for row in cells]
    return lines


def main():
    parser = argparse.ArgumentParser(description="수집 앱 녹화 점검")
    parser.add_argument("folders", nargs="*",
                        help="자세히 볼 녹화의 시작 시각(20261111-112348)이나 폴더 이름 (없으면 모든 앱 녹화를 한 줄씩)")
    parser.add_argument("--last", action="store_true", help="가장 최근 앱 녹화를 자세히 본다")
    parser.add_argument("--floor-height", type=float, default=4.0, help="층 수를 어림하는 층고(m), 기본 4.0")
    parser.add_argument("--data-dir", type=Path, default=DATA_DIR, help=f"녹화 폴더들이 있는 곳 (기본 {DATA_DIR})")
    args = parser.parse_args()

    if args.folders or args.last:
        names = list(args.folders)
        if args.last:
            found = app_recordings(args.data_dir)
            if not found:
                raise SystemExit(f"앱 녹화가 없습니다: {args.data_dir}")
            names.append(found[-1])
        failed = False
        for i, name in enumerate(names):
            try:  # 서버가 같은 녹화를 다시 받으며(replace) CSV를 지우고 새로 쓰는 중일 수 있다
                rec = load(name, args.data_dir, raw=True)
                s = check(rec, args.floor_height)
            except (OSError, ValueError) as e:
                print(f"{name}: 읽기 실패 ({e})")
                failed = True
                continue
            print(("\n" if i else "") + "\n".join(format_detail(s, rec)))
        raise SystemExit(1 if failed else 0)

    found = app_recordings(args.data_dir)
    if not found:
        raise SystemExit(f"앱 녹화가 없습니다: {args.data_dir}")
    summaries = []
    for folder in found:
        try:
            s = check(load(folder, args.data_dir, raw=True), args.floor_height)
        except (OSError, ValueError) as e:
            print(f"{folder.name} | 읽기 실패 ({e})")
            continue
        summaries.append(s)
        print(format_line(s))
    total = sum(s["duration"] for s in summaries)
    labeled = sum(1 for s in summaries if s["segments"])
    print(f"앱 녹화 {len(found)}개 (라벨 있는 것 {labeled}개) · 합계 {total / 60:.1f}분 · 자세히: --last 또는 시작 시각")
    print("\n".join(time_table(summaries)))
    per_floor = [s["floor_m"] for s in summaries if "floor_m" in s]
    if per_floor:
        print(f"층 이동 기준 층당 고도: 평균 {np.mean(per_floor):.2f} m "
              f"({len(per_floor)}개 녹화, {min(per_floor):.2f}~{max(per_floor):.2f} m)")


if __name__ == "__main__":
    main()
