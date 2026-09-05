import CoreGraphics

/// 标记画布缩放视口纯函数(单测覆盖)。
/// 全部使用容器坐标;pan 是「相对居中位置」的偏移量,viewRect 恒为合法矩形:
/// 某边 ≤ 容器 → 该方向居中(偏移 0),> 容器 → 偏移限 ±(缩放边 − 容器边)/2。
enum EditCanvasMath {

    /// 下限 0.25×:允许缩到比适应窗口更小(预览.app 同);上限 8× 供马赛克精修
    static let minZoom: CGFloat = 0.25
    static let maxZoom: CGFloat = 8

    static func clampedZoom(_ zoom: CGFloat) -> CGFloat {
        min(max(zoom, minZoom), maxZoom)
    }

    /// 适配尺寸(zoom=1 时的显示尺寸),与 MarkupCanvas 原 fittedRect 同一准则
    static func fitSize(container: CGSize, imageAspect: CGFloat) -> CGSize {
        guard container.width > 0, container.height > 0, imageAspect > 0 else { return .zero }
        let width = min(container.width, container.height * imageAspect)
        return CGSize(width: width, height: width / imageAspect)
    }

    static func viewRect(container: CGSize, imageAspect: CGFloat,
                         zoom: CGFloat, pan: CGSize) -> CGRect {
        let fit = fitSize(container: container, imageAspect: imageAspect)
        guard fit.width > 0, fit.height > 0 else { return .zero }
        let size = CGSize(width: fit.width * clampedZoom(zoom),
                          height: fit.height * clampedZoom(zoom))
        let offset = clampedPan(pan: pan, scaled: size, container: container)
        return CGRect(x: (container.width - size.width) / 2 + offset.width,
                      y: (container.height - size.height) / 2 + offset.height,
                      width: size.width, height: size.height)
    }

    /// 以 anchor(容器坐标)为锚缩放 factor 倍:锚点下的内容点保持不动。
    static func zoomed(zoom: CGFloat, pan: CGSize, factor: CGFloat, anchor: CGPoint,
                       container: CGSize, imageAspect: CGFloat) -> (zoom: CGFloat, pan: CGSize) {
        let newZoom = clampedZoom(zoom * factor)
        guard newZoom != zoom, container.width > 0, container.height > 0, imageAspect > 0 else {
            return (zoom, pan)
        }
        let oldRect = viewRect(container: container, imageAspect: imageAspect, zoom: zoom, pan: pan)
        guard oldRect.width > 0, oldRect.height > 0 else { return (newZoom, pan) }
        let fit = fitSize(container: container, imageAspect: imageAspect)
        let u = (anchor.x - oldRect.minX) / oldRect.width
        let v = (anchor.y - oldRect.minY) / oldRect.height
        let desiredX = anchor.x - u * fit.width * newZoom
        let desiredY = anchor.y - v * fit.height * newZoom
        let scaled = CGSize(width: fit.width * newZoom, height: fit.height * newZoom)
        return (newZoom, clampedPan(pan: CGSize(width: desiredX - (container.width - scaled.width) / 2,
                                                height: desiredY - (container.height - scaled.height) / 2),
                                    scaled: scaled, container: container))
    }

    /// pan 平移 delta(容器坐标),结果夹回合法范围。
    static func panned(pan: CGSize, delta: CGSize,
                       container: CGSize, imageAspect: CGFloat, zoom: CGFloat) -> CGSize {
        let fit = fitSize(container: container, imageAspect: imageAspect)
        let scaled = CGSize(width: fit.width * clampedZoom(zoom), height: fit.height * clampedZoom(zoom))
        return clampedPan(pan: CGSize(width: pan.width + delta.width, height: pan.height + delta.height),
                          scaled: scaled, container: container)
    }

    /// 新容器尺寸下,让原视口中心处的内容点(u/v 归一化)仍落在容器中心(窗口 resize 时视野稳定)。
    static func panForCenteredContent(u: CGFloat, v: CGFloat, zoom: CGFloat,
                                      container: CGSize, imageAspect: CGFloat) -> CGSize {
        let fit = fitSize(container: container, imageAspect: imageAspect)
        guard fit.width > 0, fit.height > 0 else { return .zero }
        let scaled = CGSize(width: fit.width * clampedZoom(zoom), height: fit.height * clampedZoom(zoom))
        let desiredX = container.width / 2 - u * scaled.width
        let desiredY = container.height / 2 - v * scaled.height
        return clampedPan(pan: CGSize(width: desiredX - (container.width - scaled.width) / 2,
                                      height: desiredY - (container.height - scaled.height) / 2),
                          scaled: scaled, container: container)
    }

    /// 夹取后的合法 pan:某边 ≤ 容器 → 0(居中);> 容器 → ±超出量的一半。
    private static func clampedPan(pan: CGSize, scaled: CGSize, container: CGSize) -> CGSize {
        func clampAxis(_ value: CGFloat, scaledLength: CGFloat, containerLength: CGFloat) -> CGFloat {
            let overflow = (scaledLength - containerLength) / 2
            return overflow > 0 ? min(max(value, -overflow), overflow) : 0
        }
        return CGSize(width: clampAxis(pan.width, scaledLength: scaled.width, containerLength: container.width),
                      height: clampAxis(pan.height, scaledLength: scaled.height, containerLength: container.height))
    }
}
