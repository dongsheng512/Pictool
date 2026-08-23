import Foundation

/// 缩放锚点数学(纯函数,单元测试覆盖)
///
/// 坐标模型:imageView 的 frame 原点固定在 (0,0),尺寸 = 图像尺寸 × scale,
/// 因此"同一内容点"的文档坐标会随 scale 线性伸缩(× ratio)。
/// 锚点(clip 本地坐标)在缩放前后应指向同一内容点。
enum ZoomMath {

    /// 计算缩放后的 bounds origin,使 anchor 处的内容点保持在原地
    /// - Parameters:
    ///   - oldOrigin: 缩放前 clipView.bounds.origin(文档坐标)
    ///   - anchor: 锚点,clip 视图本地坐标(0..bounds.width)
    ///   - docSize: 缩放前的文档尺寸(imageSize × oldScale)
    ///   - ratio: 新旧缩放比(newScale / oldScale)
    static func anchoredOrigin(oldOrigin: CGPoint,
                               anchor: CGPoint,
                               docSize: CGSize,
                               ratio: CGFloat) -> CGPoint {
        guard ratio > 0, docSize.width > 0, docSize.height > 0 else { return oldOrigin }
        // 锚点内容点在旧文档中的位置(0..docSize)
        let anchorDoc = CGPoint(x: anchor.x + oldOrigin.x, y: anchor.y + oldOrigin.y)
        // 该内容点在新文档中的位置:坐标随内容一起伸缩
        let scaledDoc = CGPoint(x: anchorDoc.x * ratio, y: anchorDoc.y * ratio)
        // 使 scaledDoc 出现在 anchor 本地位置所需的 origin
        return CGPoint(x: scaledDoc.x - anchor.x, y: scaledDoc.y - anchor.y)
    }

    /// 与 clip 的 constrain 一致:文档小于视口则居中,否则夹取到可滚动范围。
    /// applyScale 里先做这一步,避免随后 constrainBoundsRect 再改 origin 造成一次回跳。
    static func constrainedOrigin(proposed: CGPoint, docSize: CGSize, clipSize: CGSize) -> CGPoint {
        var x = proposed.x
        var y = proposed.y
        if docSize.width < clipSize.width {
            x = (docSize.width - clipSize.width) / 2
        } else {
            x = min(max(x, 0), docSize.width - clipSize.width)
        }
        if docSize.height < clipSize.height {
            y = (docSize.height - clipSize.height) / 2
        } else {
            y = min(max(y, 0), docSize.height - clipSize.height)
        }
        return CGPoint(x: x, y: y)
    }

    /// 对齐到物理像素,避免 AppKit 事后把 origin 四舍五入造成 0.5pt 级跳动
    static func snapped(_ value: CGFloat, backing: CGFloat) -> CGFloat {
        guard backing > 0 else { return value }
        return (value * backing).rounded() / backing
    }

    static func snappedPoint(_ point: CGPoint, backing: CGFloat) -> CGPoint {
        CGPoint(x: snapped(point.x, backing: backing), y: snapped(point.y, backing: backing))
    }

    /// 文档尺寸变化时保持视口中心对准同一内容比例(全尺寸替换用)
    static func originKeepingVisibleCenter(
        oldOrigin: CGPoint,
        oldDoc: CGSize,
        newDoc: CGSize,
        clipSize: CGSize
    ) -> CGPoint {
        guard oldDoc.width > 0, oldDoc.height > 0 else { return oldOrigin }
        let proposed = CGPoint(
            x: (oldOrigin.x + clipSize.width / 2) / oldDoc.width * newDoc.width - clipSize.width / 2,
            y: (oldOrigin.y + clipSize.height / 2) / oldDoc.height * newDoc.height - clipSize.height / 2
        )
        return constrainedOrigin(proposed: proposed, docSize: newDoc, clipSize: clipSize)
    }
}
