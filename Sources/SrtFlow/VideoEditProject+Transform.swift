import CoreGraphics
import Foundation
import SrtFlowCore

// MARK: - Transform 面板与摆放的写入入口
//
// 从 VideoEditProject.swift 拆出（单文件 ~800 行警戒线）。每个属性一组：
// `setXxx`（离散，一次一步撤销）+ `liveSetXxx`（拖调，走 liveApply，松手由
// 调用方 endLiveEdit 结账）+ 私有 `xxxMutation`（两者共用的夹紧/归一化/
// 关键帧规则，保证 discrete 和 live 永不分叉）。合同见
// docs/architecture/inspector-scrub-number-field.md。

extension VideoEditProject {
    /// 预览里拖缩放框（连续手势）：每 tick 从快照重放，松手才结一步撤销。
    /// 位置/缩放行有关键帧时改为在播放头处落帧（连续拖动反复写同一帧=替换）。
    func livePlace(_ id: UUID, placement: ClipPlacement) {
        let clamped = placement.clamped
        if let write = keyframedPlacementWriter(id, clamped) {
            liveApply { state in state.update(id) { write(&$0) } }
        } else {
            liveApply { state in
                state.update(id) { $0.placement = clamped }
            }
        }
    }

    /// 位置/缩放任一行带关键帧且播放头在段内时，返回「往轨里落帧」的写入闭包；
    /// 否则 nil（走静态摆放）。没动画的行落进静态摆放（动画行的分量会被轨覆盖）。
    private func keyframedPlacementWriter(
        _ id: UUID, _ clamped: ClipPlacement
    ) -> ((inout EditClip) -> Void)? {
        guard let clip = state.clip(with: id) else { return nil }
        let positionAnimated = hasKeyframes(clip, .position)
        let scaleAnimated = hasKeyframes(clip, .scale)
        guard positionAnimated || scaleAnimated, playheadInsideClip(clip) else { return nil }
        let source = clip.sourceTime(atTimeline: clock.time)
        let tol = sourceTolerance(for: clip)
        return { c in
            var animation = c.animation ?? ClipAnimation()
            if positionAnimated {
                animation.centerX.set(clamped.centerX, atSourceTime: source, tolerance: tol)
                animation.centerY.set(clamped.centerY, atSourceTime: source, tolerance: tol)
            }
            if scaleAnimated {
                animation.width.set(clamped.width, atSourceTime: source, tolerance: tol)
                animation.height.set(clamped.height, atSourceTime: source, tolerance: tol)
            }
            c.animation = animation
            if !positionAnimated || !scaleAnimated {
                c.placement = clamped
            }
        }
    }

    /// 回到默认布局（主轨铺满 / 画中画九宫格）。
    func resetPlacement(_ id: UUID) {
        perform { state in
            state.update(id) { $0.placement = nil }
        }
    }

    // MARK: Transform 面板（离散一步撤销；live 版拖调）

    /// 这段在不在画中画轨上（Position/Scale 的默认基准随轨道不同）。
    func isOverlayClip(_ id: UUID) -> Bool {
        if case .overlay = state.location(of: id)?.track { return true }
        return false
    }

    /// 写入摆放并归一：约等于默认布局就存回 nil，检查器和预览都当「没摆过」。
    /// 位置/缩放行有关键帧时改为在播放头处落帧。discrete/live 共用，见
    /// `placementMutation`。
    func setPlacement(_ id: UUID, _ placement: ClipPlacement) {
        guard let write = placementMutation(id, placement) else { return }
        perform(write)
    }

    /// Inspector 数值框横向拖调用：语义和 `setPlacement` 完全一致（含关键帧
    /// 分支、默认布局归一化），只是走 `liveApply`——每个 tick 都从手势起点的
    /// 快照重放，松手由调用方 `endLiveEdit()` 结成一步撤销。
    /// （画布里拖变换框走的是 `livePlace`，那条路径不做默认值归一化，两者
    /// 故意分开，见 preview-free-transform.md。）
    func liveSetPlacement(_ id: UUID, _ placement: ClipPlacement) {
        guard let write = placementMutation(id, placement) else { return }
        liveApply(write)
    }

    /// 摆放写入的核心规则：关键帧优先，否则按默认布局归一化（约等于默认就
    /// 存 nil）。返回 nil 表示这段此刻取不到（已被删除之类）。
    ///
    /// 归一化容差必须是**亚像素**（半个输出像素）：固定 0.001 在 1920 宽画布
    /// 上约等于 1.9px，会把 Inspector 的 ±1px 步进整个吞回默认值，见
    /// preview-free-transform.md。
    private func placementMutation(_ id: UUID, _ placement: ClipPlacement) -> ((inout TimelineState) -> Void)? {
        guard let clip = state.clip(with: id) else { return nil }
        let clamped = placement.clamped
        if let write = keyframedPlacementWriter(id, clamped) {
            return { state in state.update(id) { write(&$0) } }
        }
        let fallback = clip.defaultPlacement(canvas: renderSize, isOverlay: isOverlayClip(id))
        let toleranceX = 0.5 / max(renderSize.width, 1)
        let toleranceY = 0.5 / max(renderSize.height, 1)
        let isDefault = abs(clamped.centerX - fallback.centerX) < toleranceX
            && abs(clamped.centerY - fallback.centerY) < toleranceY
            && abs(clamped.width - fallback.width) < toleranceX
            && abs(clamped.height - fallback.height) < toleranceY
        return { state in
            state.update(id) { $0.placement = isDefault ? nil : clamped }
        }
    }

    func setRotation(_ id: UUID, degrees: Double) {
        guard let write = rotationMutation(id, degrees: degrees) else { return }
        perform(write)
    }

    /// Inspector 数值框横向拖调用：同 `setRotation` 的关键帧规则，走 `liveApply`。
    func liveSetRotation(_ id: UUID, degrees: Double) {
        guard let write = rotationMutation(id, degrees: degrees) else { return }
        liveApply(write)
    }

    private func rotationMutation(_ id: UUID, degrees: Double) -> ((inout TimelineState) -> Void)? {
        guard let clip = state.clip(with: id) else { return nil }
        let clamped = min(max(degrees.isFinite ? degrees : 0, -360), 360)
        let normalized = abs(clamped) < 0.01 ? 0 : clamped
        if hasKeyframes(clip, .rotation), playheadInsideClip(clip) {
            let source = clip.sourceTime(atTimeline: clock.time)
            let tol = sourceTolerance(for: clip)
            return { state in
                state.update(id) { c in
                    var animation = c.animation ?? ClipAnimation()
                    animation.rotation.set(normalized, atSourceTime: source, tolerance: tol)
                    c.animation = animation
                }
            }
        }
        return { state in state.update(id) { $0.rotationDegrees = normalized } }
    }

    func setClipOpacity(_ id: UUID, _ opacity: Double) {
        guard let write = opacityMutation(id, opacity: opacity) else { return }
        perform(write)
    }

    /// Inspector 数值框横向拖调用：同 `setClipOpacity` 的关键帧规则，走 `liveApply`。
    func liveSetClipOpacity(_ id: UUID, _ opacity: Double) {
        guard let write = opacityMutation(id, opacity: opacity) else { return }
        liveApply(write)
    }

    private func opacityMutation(_ id: UUID, opacity: Double) -> ((inout TimelineState) -> Void)? {
        guard let clip = state.clip(with: id) else { return nil }
        let clamped = min(max(opacity.isFinite ? opacity : 1, 0), 1)
        if hasKeyframes(clip, .opacity), playheadInsideClip(clip) {
            let source = clip.sourceTime(atTimeline: clock.time)
            let tol = sourceTolerance(for: clip)
            return { state in
                state.update(id) { c in
                    var animation = c.animation ?? ClipAnimation()
                    animation.opacity.set(clamped, atSourceTime: source, tolerance: tol)
                    c.animation = animation
                }
            }
        }
        return { state in state.update(id) { $0.opacity = clamped } }
    }

    func setFlip(_ id: UUID, horizontal: Bool? = nil, vertical: Bool? = nil) {
        perform { state in
            state.update(id) { clip in
                if let horizontal { clip.flippedHorizontally = horizontal }
                if let vertical { clip.flippedVertically = vertical }
            }
        }
    }

    func setCrop(_ id: UUID, _ crop: ClipCrop?) {
        let normalized = normalizedCrop(crop)
        perform { state in
            state.update(id) { $0.crop = normalized }
        }
    }

    /// Inspector 数值框横向拖调用：Crop 没有关键帧，规则比其它三行简单，
    /// 但仍要走 liveApply——连续拖动只能替换同一份快照，不能一 tick 一记。
    func liveSetCrop(_ id: UUID, _ crop: ClipCrop?) {
        let normalized = normalizedCrop(crop)
        liveApply { state in
            state.update(id) { $0.crop = normalized }
        }
    }

    private func normalizedCrop(_ crop: ClipCrop?) -> ClipCrop? {
        (crop?.isEmpty ?? true) ? nil : crop
    }

    /// 整个 Transform 区归零（含自由摆放和全部关键帧），一步撤销。
    func resetTransform(_ id: UUID) {
        perform { state in
            state.update(id) { clip in
                clip.placement = nil
                clip.rotationDegrees = 0
                clip.opacity = 1
                clip.flippedHorizontally = false
                clip.flippedVertically = false
                clip.crop = nil
                clip.animation = nil
            }
        }
    }
}
