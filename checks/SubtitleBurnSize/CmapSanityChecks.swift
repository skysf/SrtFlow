import CoreText
import Foundation

// 字幕字体清单的 cmap 体检（Sources/SrtFlow/FontCmapSanity.swift，docs/bugfixes/2026-09-29-yuanti-cmap-breaks-libass-latin.md）：
// 圆体的 (3,10) format 12 子表声明长度比 16 + 12 × 分组数多 34 字节、字母映射和 format 4 那张错位，Core Text 不用它、
// FreeType 优先用它，烧出来英文全是别的字形。这里手造几张 cmap 表：一致的判安全，长度多了、映射错位、format 4 长度
// 超出表、没有 Unicode 子表都判不安全；真字体 Helvetica / Hiragino Sans GB 安全；装了圆体的机器上它不安全、不进清单。

private func be16(_ value: Int) -> [UInt8] { [UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)] }
private func be32(_ value: Int) -> [UInt8] {
    [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
}

/// format 4：A–Z 从字形 36 起、a–z 从 62 起，结尾段 0xFFFF。`shift` 让映射整体错一位。
private func format4(shift: Int = 0, declaredLength: Int? = nil) -> [UInt8] {
    let segments: [(start: Int, end: Int, delta: Int)] = [
        (0x41, 0x5A, 36 - 0x41 + shift), (0x61, 0x7A, 62 - 0x61 + shift), (0xFFFF, 0xFFFF, 1)
    ]
    var body = be16(segments.count * 2) + be16(0) + be16(0) + be16(0)
    body += segments.flatMap { be16($0.end) } + be16(0)
    body += segments.flatMap { be16($0.start) }
    body += segments.flatMap { be16($0.delta & 0xFFFF) }
    body += segments.flatMap { _ in be16(0) }
    return be16(4) + be16(declaredLength ?? (6 + body.count)) + be16(0) + body
}

/// format 12：同样的两组。`extraLength` 往声明长度和表尾各加这么多字节（圆体多了 34）。
private func format12(shift: Int = 0, extraLength: Int = 0) -> [UInt8] {
    let groups: [(Int, Int, Int)] = [(0x41, 0x5A, 36 + shift), (0x61, 0x7A, 62 + shift)]
    var table = be16(12) + be16(0) + be32(16 + 12 * groups.count + extraLength) + be32(0) + be32(groups.count)
    for (start, end, glyph) in groups { table += be32(start) + be32(end) + be32(glyph) }
    return table + [UInt8](repeating: 0, count: extraLength)
}

private func cmap(_ subtables: [(platform: Int, encoding: Int, table: [UInt8])]) -> Data {
    var header = be16(0) + be16(subtables.count)
    var offset = 4 + 8 * subtables.count
    var body: [UInt8] = []
    for sub in subtables {
        header += be16(sub.platform) + be16(sub.encoding) + be32(offset)
        body += sub.table
        offset += sub.table.count
    }
    return Data(header + body)
}

func runCmapSanityChecks() {
    check(FontCmapSanity.isSafeForFreeType(cmap: cmap([(3, 1, format4()), (3, 10, format12())])), "两张一致的 Unicode 子表：安全")
    check(FontCmapSanity.isSafeForFreeType(cmap: cmap([(0, 3, format4())])), "只有一张 format 4：安全")
    check(!FontCmapSanity.isSafeForFreeType(cmap: cmap([(3, 1, format4()), (3, 10, format12(extraLength: 34))])),
          "format 12 声明的长度比 16 + 12 × 分组数多 34 字节（圆体那样）：不安全")
    check(!FontCmapSanity.isSafeForFreeType(cmap: cmap([(3, 1, format4()), (3, 10, format12(shift: 1))])),
          "format 12 的字母映射和 format 4 错一位：不安全")
    check(!FontCmapSanity.isSafeForFreeType(cmap: cmap([(3, 1, format4(declaredLength: 9999))])), "format 4 声明的长度超出表：不安全")
    check(!FontCmapSanity.isSafeForFreeType(cmap: cmap([(1, 0, format4())])), "没有 Unicode 子表：不安全")
    check(!FontCmapSanity.isSafeForFreeType(cmap: Data([0, 0])), "残缺的表：不安全")

    for name in ["Helvetica", "Hiragino Sans GB"] {
        let font = CTFontCreateWithName(name as CFString, 12, nil)
        check(FontCmapSanity.isSafeForFreeType(font), "\(name) 的 cmap 安全（烧录自检就用它）")
    }
    // 用户机器上 ~/Library/Fonts 里那份圆体（23 MB，和系统按需下载的 79 MB 那份不是同一个文件）：Regular / Bold 两个面的
    // (3,10) format 12 子表坏了，Light 只有一张 format 4 是好的；libass 装的是整个 .ttc，所以整个文件不进清单。
    let userCopy = URL(fileURLWithPath: NSString(string: "~/Library/Fonts/Yuanti.ttc").expandingTildeInPath)
    if let descriptors = CTFontManagerCreateFontDescriptorsFromURL(userCopy as CFURL) as? [CTFontDescriptor], !descriptors.isEmpty {
        let verdicts = descriptors.map { descriptor -> (String, Bool) in
            let font = CTFontCreateWithFontDescriptor(descriptor, 24, nil)
            return (CTFontCopyPostScriptName(font) as String, FontCmapSanity.isSafeForFreeType(font))
        }
        check(verdicts.contains { $0.0 == "STYuanti-SC-Regular" && !$0.1 }, "这台 Mac 上那份圆体：Regular 面的 (3,10) format 12 子表坏了，判不安全（\(verdicts)）")
        let listed = FontCatalog.scan()
        check(!listed.contains { $0.fileURL.standardizedFileURL == userCopy.standardizedFileURL }, "那份圆体整个文件不进字幕字体清单（清单里有 \(listed.count) 个字体）")
        check(listed.contains { $0.familyName == "Hiragino Sans GB" }, "冬青黑体照样在清单里")
    } else {
        print("this Mac has no ~/Library/Fonts/Yuanti.ttc; skipping the real-font assertions")
    }
}
