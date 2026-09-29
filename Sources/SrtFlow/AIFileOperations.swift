import Foundation

// MARK: - 整理文件：移动、改名、建文件夹、删除进废纸篓（给 AI 用）
//
// 管什么：方案第 23、24 条 —— 用户点名的文件夹里「读、新建、整理、移动都行；删除可以，但删之前先问」，
// 删除一律进废纸篓。这里是规则（`plan`：哪些路径能动、目标叫什么、撞没撞名，纯值，自检够得着）和执行（`perform`：
// FileManager）。
// 不管什么：参数怎么读、删除先问（AIFileTools 发确认令牌）、工程里用到的素材挪了之后跟过去（调用方调
// `revalidateMediaLocations`，靠书签找）。
//
// 口径：
// - **只在点名的文件夹里动**（每一层子文件夹都算）；不许动点名的文件夹本身，也不许把东西挪出去。
// - **不覆盖**：目标已经有同名的就报错，让 AI 换个名字（覆盖要问，这里干脆不做）。
// - 改名只给新名字、不带路径；新名字没写后缀就沿用原来的后缀（「开场」→「开场.mp4」）。
// - 这些都不进 ⌘Z：结果里写明做了什么，删掉的在废纸篓里。

enum AIFileOperations {
    enum Action: String, CaseIterable {
        case move, rename, makeFolder = "make_folder", trash
    }

    /// 算好的一步：`source` → `destination`（建文件夹时 source 为 nil；进废纸篓时 destination 为 nil）。
    struct Step: Equatable {
        var source: URL?
        var destination: URL?
    }

    struct Refusal: Error, Equatable {
        let message: String
    }

    /// `url` 在不在这几个文件夹里面（不含文件夹本身）。
    static func isInside(_ url: URL, roots: [URL]) -> Bool {
        let path = url.standardizedFileURL.path
        return roots.contains { path.hasPrefix($0.standardizedFileURL.path + "/") }
    }

    /// 把要做的事算成几步；有一样不许做就整个不做（抛 `Refusal`）。`exists` 替测试换掉真磁盘。
    static func plan(
        _ action: Action, sources: [URL], to target: URL?, newName: String?, roots: [URL], exists: (URL) -> Bool
    ) throws -> [Step] {
        guard !roots.isEmpty else {
            throw Refusal(message: "Open the user's folder with open_folder first; SrtFlow only organises files inside folders the user named.")
        }
        for source in sources {
            guard isInside(source, roots: roots) else {
                throw Refusal(message: "\(source.path) is not inside a folder the user named; SrtFlow does not touch it.")
            }
            guard exists(source) else { throw Refusal(message: "\(source.path) does not exist.") }
        }
        switch action {
        case .trash:
            guard !sources.isEmpty else { throw Refusal(message: "files is required.") }
            return sources.map { Step(source: $0, destination: nil) }
        case .makeFolder:
            guard let target else { throw Refusal(message: "path is required.") }
            guard isInside(target, roots: roots) else {
                throw Refusal(message: "\(target.path) is not inside a folder the user named.")
            }
            guard !exists(target) else { throw Refusal(message: "\(target.lastPathComponent) already exists.") }
            return [Step(source: nil, destination: target)]
        case .rename:
            guard sources.count == 1, let source = sources.first else { throw Refusal(message: "Rename one file at a time.") }
            let name = try validName(newName, keepingExtensionOf: source)
            let destination = source.deletingLastPathComponent().appendingPathComponent(name)
            guard !exists(destination) else {
                throw Refusal(message: "\(name) already exists in that folder; choose another name.")
            }
            return [Step(source: source, destination: destination)]
        case .move:
            guard let target, !sources.isEmpty else { throw Refusal(message: "files and to are required.") }
            guard isInside(target, roots: roots) || roots.contains(where: { $0.standardizedFileURL.path == target.standardizedFileURL.path }) else {
                throw Refusal(message: "\(target.path) is not inside a folder the user named.")
            }
            var steps: [Step] = []
            var taken = Set<String>()
            for source in sources {
                let destination = target.appendingPathComponent(source.lastPathComponent)
                if target.standardizedFileURL.path.hasPrefix(source.standardizedFileURL.path + "/")
                    || target.standardizedFileURL.path == source.standardizedFileURL.path {
                    throw Refusal(message: "Cannot move \(source.lastPathComponent) into itself.")
                }
                if destination.standardizedFileURL.path == source.standardizedFileURL.path { continue }
                guard !exists(destination), taken.insert(destination.standardizedFileURL.path).inserted else {
                    throw Refusal(message: "\(source.lastPathComponent) already exists in \(target.lastPathComponent); rename one of them first.")
                }
                steps.append(Step(source: source, destination: destination))
            }
            return steps
        }
    }

    /// 新名字：不能空、不能带路径；没写后缀就沿用原来的。
    static func validName(_ proposed: String?, keepingExtensionOf source: URL) throws -> String {
        let name = (proposed ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.contains("/"), !name.contains(":"), name != ".", name != ".." else {
            throw Refusal(message: "new_name must be a plain file name (no folders).")
        }
        let original = source.pathExtension
        guard (name as NSString).pathExtension.isEmpty, !original.isEmpty else { return name }
        return name + "." + original
    }

    /// 真去做。废纸篓那一步回放进废纸篓之后的位置。做到一半失败就停，前面做完的照实报。
    static func perform(_ steps: [Step], action: Action) -> (done: [Step], error: String?) {
        let manager = FileManager.default
        var done: [Step] = []
        for step in steps {
            do {
                switch action {
                case .trash:
                    guard let source = step.source else { continue }
                    var trashed: NSURL?
                    try manager.trashItem(at: source, resultingItemURL: &trashed)
                    done.append(Step(source: source, destination: trashed as URL?))
                case .makeFolder:
                    guard let destination = step.destination else { continue }
                    try manager.createDirectory(at: destination, withIntermediateDirectories: true)
                    done.append(step)
                case .move, .rename:
                    guard let source = step.source, let destination = step.destination else { continue }
                    try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try manager.moveItem(at: source, to: destination)
                    done.append(step)
                }
            } catch {
                return (done, "Stopped at \(step.source?.lastPathComponent ?? step.destination?.lastPathComponent ?? "?"): \(error.localizedDescription)")
            }
        }
        return (done, nil)
    }
}
