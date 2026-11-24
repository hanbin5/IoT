import SwiftUI

/// 라벨로 쓰는 활동. R1의 네 활동이고, 엘리베이터는 층 추정(R2)을 위해 방향을 나눈다.
/// 녹화의 라벨은 이 활동들의 시간 구간이고, token이 서버의 label.csv에 그대로 저장된다.
struct Activity: Hashable {
    let title: String
    let short: String  // 녹화 중 동작 버튼에 쓰는 짧은 이름
    let token: String
    let color: Color  // 구간 막대의 색. 오르내림은 같은 색이고, 방향은 이름의 화살표로 구별한다

    static let all = [
        Activity(title: "걷기", short: "걷기", token: "walk", color: Palette.walk),
        Activity(title: "계단 오르기", short: "계단 ↑", token: "stairs_up", color: Palette.stairs),
        Activity(title: "계단 내려가기", short: "계단 ↓", token: "stairs_down", color: Palette.stairs),
        Activity(title: "엘리베이터 (올라감)", short: "엘리베이터 ↑", token: "elevator_up", color: Palette.elevator),
        Activity(title: "엘리베이터 (내려감)", short: "엘리베이터 ↓", token: "elevator_down", color: Palette.elevator),
    ]
    /// 서 있거나 엘리베이터를 기다리는 구간
    static let idle = Activity(title: "정지·대기", short: "정지·대기", token: "idle", color: Palette.idle)

    struct Swatch: Hashable {
        let title: String
        let color: Color
    }

    /// 구간 막대의 범례. 색 하나에 이름 하나다
    static let legend = [
        Swatch(title: "걷기", color: Palette.walk),
        Swatch(title: "계단", color: Palette.stairs),
        Swatch(title: "엘리베이터", color: Palette.elevator),
        Swatch(title: "정지·대기", color: Palette.idle),
        Swatch(title: "라벨 없음", color: Palette.unlabeled),
    ]

    /// label.csv에 적힌 token의 활동. 모르는 token이면 nil
    static func named(_ token: String) -> Activity? {
        (all + [idle]).first { $0.token == token }
    }

    /// 녹화 라벨(구간들의 활동)을 한 줄로 쓴다. 하나뿐이면 '계단 오르기', 여럿이면 '걷기 → 계단 ↑ → 걷기'. 라벨이 없으면 nil
    static func title(of labels: [String]) -> String? {
        var sequence: [String] = []
        for label in labels where label != sequence.last {
            sequence.append(label)
        }
        guard let first = sequence.first else { return nil }
        if sequence.count == 1 {
            return named(first)?.title ?? first
        }
        return sequence.map { named($0)?.short ?? $0 }.joined(separator: " → ")
    }

    /// 구간 막대 색. dataviz 기준 팔레트의 앞 세 색은 어느 두 색이 붙어도 구별된다(색각 이상 포함).
    /// 네 색 이상은 그렇지 못해 오르내림은 같은 색으로 묶었고, 회색은 그 세 색과 구별되는 밝기로 골랐다.
    /// 밝은 화면·어두운 화면 값은 각각의 목록 바탕(#ffffff, #1c1c1e)에서 검증했다.
    enum Palette {
        static let walk = Color(light: 0x2a78d6, dark: 0x3987e5)
        static let stairs = Color(light: 0xeb6834, dark: 0xd95926)
        static let elevator = Color(light: 0x1baf7a, dark: 0x199e70)
        static let idle = Color(light: 0x545458, dark: 0xc7c7cc)
        static let unlabeled = Color(light: 0xe5e5ea, dark: 0x3a3a3c)  // 첫 라벨 전의 시간 (막대 바탕)
    }
}

private extension Color {
    /// 밝은 화면과 어두운 화면에서 다른 값을 쓰는 색
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255,
                           blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        })
    }
}
