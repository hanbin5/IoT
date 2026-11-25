#!/usr/bin/env python3
"""서버에 쌓인 녹화(web-sensor/data)에서 실제 데이터만 골라 estimator/measurement/에 정리해 쓴다.

web-sensor/data는 server.py가 받은 그대로라 공개 저장소에 올리지 않는다(.gitignore). 팀원과 나눌 녹화는
이 스크립트로 팀원의 측정 폴더(estimator/measurement/<녹화>/)와 같은 구조로 옮겨 쓰고 커밋한다.
다시 돌리면 새 녹화를 더하고, 라벨을 고친 녹화는 새로 쓴다. 팀원의 녹화 폴더(stair_up 등)는 건드리지 않는다.

- 고르는 녹화: 수집 앱 폴더(<시작 시각>-app) 가운데 DATASET_START 이후이고 시뮬레이터가 아닌 것
- motion.csv, barometer.csv: 열 순서를 팀원 녹화와 같게 고정하고(앱이 보내는 순서는 녹화마다 다르다) 시각 순으로
  정렬한다. 같은 시각의 행은 처음 것만 둔다 (web-sensor/recordings.py의 load()와 같은 규칙)
- label.csv: 그대로 복사한다 (팀원 녹화에는 없는 파일이다. time, label: 그 시각부터 다음 행까지의 동작)
- meta.json: deviceId(기기마다 붙는 ID)를 뺀다

    python3 web-sensor/export_dataset.py
"""

import csv
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "web-sensor" / "data"
TARGET = ROOT / "estimator" / "measurement"
DATASET_START = "20261124"  # 11월 2·3일(Safari)과 11일(짧은 앱 시험) 녹화는 시험용이라 뺀다 (analysis/baseline.py와 같다)
STAMP = re.compile(r"(\d{8})-\d{6}-app")
SIMULATORS = {"arm64", "x86_64"}  # 시뮬레이터에서 녹화하면 meta.json의 model이 이렇게 나온다
DROP_META = {"deviceId"}
COLUMNS = {  # 팀원 녹화(estimator/measurement/stair_up 등)와 같은 순서
    "motion.csv": ["time", "acc_x", "acc_y", "acc_z", "grav_x", "grav_y", "grav_z", "gyro_x", "gyro_y", "gyro_z",
                   "mag_x", "mag_y", "mag_z", "mag_accuracy", "quat_w", "quat_x", "quat_y", "quat_z"],
    "barometer.csv": ["time", "pressure_hpa", "rel_alt_m"],
}


def write_sensor(src, dst, order):
    """열 순서를 고정하고 시각 순으로 정렬해 쓴다. (행 수, 첫 시각, 끝 시각)을 돌려준다."""
    with open(src, newline="") as f:
        reader = csv.reader(f)
        header = next(reader)
        rows = [r for r in reader if len(r) == len(header)]  # 덜 써진 마지막 줄은 버린다
    columns = [c for c in order if c in header] + sorted(set(header) - set(order))
    picks = [header.index(c) for c in columns]
    t = header.index("time")
    rows.sort(key=lambda r: int(r[t]))
    out, last = [], None
    for r in rows:
        if r[t] != last:
            out.append([r[i] for i in picks])
            last = r[t]
    with open(dst, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(columns)
        writer.writerows(out)
    return len(out), int(out[0][0]), int(out[-1][0])


def export(src, dst):
    """녹화 폴더 하나를 옮겨 쓴다."""
    meta = json.loads((src / "meta.json").read_text())
    dst.mkdir(exist_ok=True)
    count, t0, t1 = write_sensor(src / "motion.csv", dst / "motion.csv", COLUMNS["motion.csv"])
    labels = []
    for name in ("barometer.csv", "label.csv"):
        if not (src / name).exists():
            (dst / name).unlink(missing_ok=True)
        elif name == "label.csv":
            text = (src / name).read_text()
            (dst / name).write_text(text)
            for row in csv.DictReader(text.splitlines()):
                if row["label"] not in labels:
                    labels.append(row["label"])
        else:
            write_sensor(src / name, dst / name, COLUMNS[name])
    clean = {k: v for k, v in meta.items() if k not in DROP_META}
    (dst / "meta.json").write_text(json.dumps(clean, ensure_ascii=False, indent=2) + "\n")
    print(f"{src.name}: {(t1 - t0) / 1e9:.1f}초, motion {count}행, 휴대 위치 {meta.get('placement')}, "
          f"라벨 {' '.join(labels) or '없음'}")


def main():
    TARGET.mkdir(parents=True, exist_ok=True)
    names = set()
    for src in sorted(SOURCE.iterdir()):
        match = STAMP.fullmatch(src.name)
        if not match or match.group(1) < DATASET_START or not (src / "motion.csv").exists():
            continue
        if json.loads((src / "meta.json").read_text()).get("model") in SIMULATORS:
            continue
        export(src, TARGET / src.name)
        names.add(src.name)
    stale = sorted(p.name for p in TARGET.iterdir()
                   if p.is_dir() and STAMP.fullmatch(p.name) and p.name not in names)
    if stale:
        print("서버에 없는 녹화 (서버에서 지웠다면 여기서도 지우세요):", ", ".join(stale))
    print(f"녹화 {len(names)}개를 {TARGET.relative_to(ROOT)}/에 썼습니다")


if __name__ == "__main__":
    main()
