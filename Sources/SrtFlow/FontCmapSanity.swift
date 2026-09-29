import CoreText
import Foundation

// MARK: - 字幕字体的 cmap 体检：FreeType（libass）会挑错字形的字体不进清单
//
// 管什么：一个字体的 cmap 表（字符 → 字形号）能不能放心交给 libass。Core Text 和 FreeType 挑子表的路子不一样：
// 圆体（Yuanti.ttc，2026-09-29 婚礼工程 BUG-04）的 (3,10) format 12 子表声明的长度和分组数对不上（458 对 16 + 12 × 34 = 424），
// 里面的映射也错位（'I' 映到 'f' 的字形号）；Core Text 不用它，预览是对的，FreeType 优先用 UCS-4 这张，烧出来英文全是
// 别的字形、中文碰巧没事。这里只做两件便宜的事：① format 4 / 12 的 Unicode 子表长度自洽；② 几张 Unicode 子表对 ASCII
// 字母的说法一致。任一条不成立就当 libass 用不了（docs/bugfixes/2026-09-29-yuanti-cmap-breaks-libass-latin.md）。
// 不管什么：字体扫描本身（FontCatalog）、烧录时点名回退字体（SubtitleFallbackFont）。

enum FontCmapSanity {
    /// 这个字体的 cmap 能不能放心交给 FreeType。读不到 cmap 表当不能。
    static func isSafeForFreeType(_ font: CTFont) -> Bool {
        guard let data = CTFontCopyTable(font, CTFontTableTag(kCTFontTableCmap), []) as Data? else { return false }
        return isSafeForFreeType(cmap: data)
    }

    /// 纯值：整张 cmap 表的字节。
    static func isSafeForFreeType(cmap: Data) -> Bool {
        let bytes = [UInt8](cmap)
        guard bytes.count >= 4 else { return false }
        let count = Int(be16(bytes, 2))
        var mappings: [[UInt32: UInt32]] = []
        for index in 0..<count {
            let record = 4 + index * 8
            guard record + 8 <= bytes.count else { return false }
            let platform = be16(bytes, record)
            let encoding = be16(bytes, record + 2)
            let offset = Int(be32(bytes, record + 4))
            guard offset + 4 <= bytes.count else { return false }
            guard platform == 0 || (platform == 3 && (encoding == 1 || encoding == 10)) else { continue }
            switch be16(bytes, offset) {
            case 4:
                let length = Int(be16(bytes, offset + 2))
                guard length >= 16, offset + length <= bytes.count, let map = asciiLetters(format4: bytes, at: offset) else { return false }
                mappings.append(map)
            case 12:
                guard offset + 16 <= bytes.count else { return false }
                let length = Int(be32(bytes, offset + 4))
                let groups = Int(be32(bytes, offset + 12))
                guard length == 16 + 12 * groups, offset + length <= bytes.count else { return false }
                mappings.append(asciiLetters(format12: bytes, at: offset, groups: groups))
            default:
                continue
            }
        }
        guard let first = mappings.first else { return false }
        for other in mappings.dropFirst() {
            for (code, glyph) in first {
                if let theirs = other[code], theirs != glyph { return false }
            }
        }
        return true
    }

    private static let letters: [UInt32] = Array(0x41...0x5A) + Array(0x61...0x7A)

    /// format 4：分段的 BMP 表。越界就是坏表，返回 nil。
    private static func asciiLetters(format4 bytes: [UInt8], at offset: Int) -> [UInt32: UInt32]? {
        guard offset + 14 <= bytes.count else { return nil }
        let segmentsX2 = Int(be16(bytes, offset + 6))
        let ends = offset + 14
        let starts = ends + segmentsX2 + 2
        let deltas = starts + segmentsX2
        let rangeOffsets = deltas + segmentsX2
        guard segmentsX2 >= 2, rangeOffsets + segmentsX2 <= bytes.count else { return nil }
        var map: [UInt32: UInt32] = [:]
        for code in letters {
            for segment in stride(from: 0, to: segmentsX2, by: 2) {
                let end = UInt32(be16(bytes, ends + segment))
                let start = UInt32(be16(bytes, starts + segment))
                guard start <= code, code <= end else { continue }
                let delta = UInt32(be16(bytes, deltas + segment))
                let rangeOffset = Int(be16(bytes, rangeOffsets + segment))
                if rangeOffset == 0 {
                    map[code] = (code &+ delta) & 0xFFFF
                } else {
                    let address = rangeOffsets + segment + rangeOffset + 2 * Int(code - start)
                    guard address + 2 <= bytes.count else { return nil }
                    let glyph = UInt32(be16(bytes, address))
                    map[code] = glyph == 0 ? 0 : (glyph &+ delta) & 0xFFFF
                }
                break
            }
        }
        return map
    }

    /// format 12：按组的 UCS-4 表（长度已经核过）。
    private static func asciiLetters(format12 bytes: [UInt8], at offset: Int, groups: Int) -> [UInt32: UInt32] {
        var map: [UInt32: UInt32] = [:]
        for group in 0..<groups {
            let record = offset + 16 + group * 12
            let start = be32(bytes, record), end = be32(bytes, record + 4), glyph = be32(bytes, record + 8)
            for code in letters where start <= code && code <= end { map[code] = glyph &+ (code - start) }
        }
        return map
    }

    private static func be16(_ bytes: [UInt8], _ at: Int) -> UInt16 { UInt16(bytes[at]) << 8 | UInt16(bytes[at + 1]) }
    private static func be32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) << 24 | UInt32(bytes[at + 1]) << 16 | UInt32(bytes[at + 2]) << 8 | UInt32(bytes[at + 3])
    }
}
