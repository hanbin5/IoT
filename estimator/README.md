# 동작 및 층 추정

오프라인 센서 기록용 초기 규칙 기반 모델. motion.csv와 barometer.csv가 든 폴더를 입력한다. 다섯 동작은 stationary, walking, stairs_up, stairs_down, elevator다. elevator_direction은 up/down이다. 판정은 매 0.5초 출력한다. uncertain 대신 low_margin을 보조 표시한다. 이는 확률적 신뢰도가 아니며 5종 강제 판정에는 오분류가 포함될 수 있다.

## 실행

    py -m pip install -r requirements.txt
    py analyze.py analyze "C:\경로\층별측정\stair_up" --start-floor 1 --out results/my_stairs
    py analyze.py analyze "C:\경로\층별측정\ev_up" --start-floor 1 --out results/my_elevator

building.json은 제공된 stair_up과 ev_up이 각각 1층에서 6층까지 순차 방문했다는 정답을 이용해 보정한 건물 모델이다. 다른 건물에는 그대로 적용하지 않는다. 시작 층은 반드시 지정한다. 측정 첫 5초는 지정한 시작 층에 머물러 있어야 한다. 이동 중 잘라낸 파일은 기준 보정이 틀릴 수 있다. 아래 명령은 두 파일을 다시 보정할 때 사용한다.

    py analyze.py calibrate "C:\경로\층별측정\stair_up" "C:\경로\층별측정\ev_up" --model building.json

## 출력

- timeline.csv: time_s, activity, floor, nearest_floor, vertical_state, height_m, height_slope_m_s, acceleration_std, low_margin, elevator_direction.
- floor_events.csv: 층 출력이 바뀌는 시각.
- activities.csv: 연속된 동작 구간.
- overview.png: 고도, 층, 동작 그래프.
- summary.json: 기준 시각 및 시작/종료 층.

floor는 고도가 해당 층 기준에서 0.75m 이내로 약 2초 유지되면 갱신하는 히스테리시스 추정이다. 이동 중에는 마지막 확인한 층을 유지한다. nearest_floor는 현재 고도에 가장 가까운 층이다. vertical_state가 moving_vertical이면 층 사이 이동으로 해석한다. floor 갱신이 정확한 도착 시각을 의미하지 않는다.

기압 고도는 1초 범위 중앙값 필터, 약 6초 범위 강건 기울기를 사용한다. IMU는 중력 방향 가속도의 0.5–8Hz 성분을 사용한다. 센서별 시각을 정렬하고 보간하며 행 번호로 대응시키지 않는다.
3초 미만 수직 이동 후보를 억제한 다음, 같은 방향 계단 동작 사이의 6초 이하 걷기·정지 구간을 계단참으로 통합한다. 6초보다 짧게 실제 층을 걸으면 통합될 수 있고, 계단참에서 오래 머물면 분리될 수 있다. 이 기준은 정답 라벨로 조정해야 한다.

정지 중인 엘리베이터 안과 다른 장소의 정지는 센서만으로 구분하지 않으므로 stationary로 표시한다. 네트워크 실시간 입력 기능은 없고 중앙 창과 후처리에 미래 데이터가 필요하다. 0.5초 출력 간격은 인식 지연을 의미하지 않는다. 1–6층 범위 전용 모델이며 범위 밖 층은 판정할 수 없다. 기압 드리프트와 문 개폐, 초기 휴대전화 조작으로 오차가 생길 수 있다. 장시간 기록의 자동 기압 드리프트 보정은 포함하지 않는다.

## 검증 범위

첨부 결과는 보정에 사용한 두 상승 기록의 재적용 결과다. 두 기록 모두 1→2→3→4→5→6층으로 출력됨을 확인했다. 독립 데이터에 대한 정확도 검증은 아니다. 하강의 시작 층은 사용자 확인이 없어 결과를 첨부하지 않았다. 프로그램은 하강과 여러 층 엘리베이터 이동도 처리하도록 작성됐지만 별도 정답 기록으로 평가해야 한다.
