import Foundation

/// 녹화하는 동안 폰을 몸의 어디에 두었는지 (휴대 위치). 같은 동작이라도 위치에 따라 센서 값이 크게 달라서 녹화마다 남긴다.
/// 한 녹화 안에서는 위치를 바꾸지 않는다고 보고, 녹화 전에 고른다. token이 meta.json의 placement로 서버에 간다.
struct Placement: Hashable, Identifiable {
    let title: String
    let token: String

    var id: String { token }

    static let all = [
        Placement(title: "손 (화면을 보며)", token: "hand_front"),
        Placement(title: "손 (팔을 흔들며)", token: "hand_swing"),
        Placement(title: "바지 앞주머니", token: "pocket_front"),
        Placement(title: "바지 뒷주머니", token: "pocket_back"),
        Placement(title: "상의 주머니", token: "jacket_pocket"),
        Placement(title: "가방", token: "bag"),
        Placement(title: "통화 (귀에 대고)", token: "ear"),
    ]

    /// 처음 녹화할 때의 휴대 위치. 그 뒤로는 마지막에 고른 것을 쓴다
    static let standard = all[0]

    /// meta.json에 적힌 token의 이름. 모르는 token이면 token 그대로, 없으면 nil
    static func title(of token: String?) -> String? {
        guard let token, !token.isEmpty else { return nil }
        return all.first { $0.token == token }?.title ?? token
    }
}
