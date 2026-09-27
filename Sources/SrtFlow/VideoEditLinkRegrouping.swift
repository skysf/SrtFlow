import Foundation

// MARK: - 分割之后理顺链接组
//
// 管什么：一对链接的段（视频 + 分离出来的声音、录屏的画面 + 麦克风）切开之后，应该是**两对**，不是四段连成一串。
// 以前右半段原样抄了组号，同一个组越切越多：链接开着时删掉 / 拖走 / 裁其中一块，整串（所有碎片，画面和声音）
// 都跟着走（docs/bugfixes/2026-09-28-split-links-every-piece-together.md）。现在切完就把这次切到的组按「时间上重叠」
// 重新分：连在一起的一串一个组号 —— 最早那串留原来的号，其余换新号；落单的段不再链接。
// 手动分割（播放头、刀片）、AI 的 split_clip 和 cut_speech 都走这里。
// 不管什么：切一段本身（`TimelineState.split(clipID:at:)`，抄字段）、链接开关（调用方按它决定要不要把伙伴一起切）。
//
// 已知的代价：链接开关关着时，有人把一对拉开到不重叠（「错位链接」），之后再切其中一段，拉开的那一边会落单。

enum LinkRegrouping {
    /// 把这几段在 `time` 切开，再理顺切到的那几个组。返回切出来的右半段。
    @discardableResult
    static func split(_ ids: some Sequence<UUID>, at time: Double, in state: inout TimelineState) -> [UUID] {
        let before = Set(state.allClips.map(\.id))
        var groups: Set<UUID> = []
        for id in ids {
            if let group = state.clip(with: id)?.linkGroup { groups.insert(group) }
            state.split(clipID: id, at: time)
        }
        regroup(groups, in: &state)
        return state.allClips.map(\.id).filter { !before.contains($0) }
    }

    /// 这几个组各自按时间重叠分成几串：第一串留原来的号，其余每串一个新号，落单的段不再链接。
    static func regroup(_ groups: Set<UUID>, in state: inout TimelineState) {
        for group in groups {
            let members = state.allClips.filter { $0.linkGroup == group }
            let chains = components(members.map { (id: $0.id, start: $0.timelineStart, end: $0.timelineEnd) })
            for (index, chain) in chains.enumerated() {
                let label: UUID? = chain.count < 2 ? nil : (index == 0 ? group : UUID())
                guard label != group else { continue }
                for id in chain { state.update(id) { $0.linkGroup = label } }
            }
        }
    }

    /// 纯计算：按时间重叠连成几串（首尾刚好相接不算重叠）。串按最早的开始排，串里按开始排。
    static func components(_ members: [(id: UUID, start: Double, end: Double)]) -> [[UUID]] {
        let sorted = members.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
        var parent = Array(sorted.indices)
        func root(_ index: Int) -> Int {
            var index = index
            while parent[index] != index {
                parent[index] = parent[parent[index]]
                index = parent[index]
            }
            return index
        }
        for a in sorted.indices {
            for b in sorted.indices where b > a && sorted[b].start < sorted[a].end - epsilon {
                if sorted[a].start < sorted[b].end - epsilon { parent[root(b)] = root(a) }
            }
        }
        var chains: [Int: [UUID]] = [:]
        var order: [Int] = []
        for index in sorted.indices {
            let key = root(index)
            if chains[key] == nil { order.append(key) }
            chains[key, default: []].append(sorted[index].id)
        }
        return order.map { chains[$0]! }
    }

    private static let epsilon = 0.000_5
}
