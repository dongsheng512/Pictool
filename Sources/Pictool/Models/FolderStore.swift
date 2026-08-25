import Foundation
import Observation
import AppKit

@Observable
final class FolderNode: Identifiable {
    let id = UUID()
    let url: URL
    let depth: Int
    var children: [FolderNode] = []
    var childrenLoaded = false

    init(url: URL, depth: Int) {
        self.url = url
        self.depth = depth
    }
    var name: String { url.lastPathComponent }
}

enum ZoomAction: Equatable {
    case fit, actualSize, zoomIn, zoomOut
}

/// 当前图片的基本显示信息(状态栏/信息面板头部用)
struct DisplayImageInfo: Equatable {
    var pixelWidth = 0
    var pixelHeight = 0
    var frameCount = 1
    var formatName = ""
    var isAnimated: Bool { frameCount > 1 }
}

@MainActor
@Observable
final class FolderStore {

    private(set) var roots: [FolderNode] = []
    var selectedFolderID: FolderNode.ID?

    private(set) var images: [ImageFile] = []
    var selectedImageID: ImageFile.ID?

    var imageLoading = false
    var displayScale: CGFloat = 1
    var displayInfo = DisplayImageInfo()

    var showInspector = false
    /// 只看图:窗口内隐藏顶栏/侧栏/状态栏/信息面板
    var isImmersive = false
    /// 侧栏是否可见(普通模式;纯净模式下强制隐藏,退出后恢复)
    var sidebarVisible = true
    private var sidebarBeforeImmersive = true

    /// 单张/少量打开模式：默认不加载同目录所有图片，侧边提示按需加载
    private(set) var isSingleImageMode = false
    private(set) var singleImageSourceFolder: URL?
    var pendingOtherCount: Int {
        guard isSingleImageMode, let folder = singleImageSourceFolder else { return 0 }
        let all = ImageDiscovery.images(in: folder).count
        let hidden = hiddenByFolder[standardized(folder)]?.count ?? 0
        return max(0, all - hidden - images.count)
    }

    func toggleImmersive() {
        if !isImmersive, currentImage == nil { return }
        isImmersive.toggle()
        if isImmersive {
            showInspector = false
            sidebarBeforeImmersive = sidebarVisible
            sidebarVisible = false
        } else {
            sidebarVisible = sidebarBeforeImmersive
        }
    }

    func toggleSidebar() {
        guard !isImmersive else { return }
        sidebarVisible.toggle()
    }
    private(set) var printRequestToken = 0
    private(set) var cropRequestToken = 0
    /// 旋转指令通道(token 递增表示新指令;旋转是显示层状态,不写回文件)
    private(set) var rotateRequestToken = 0
    /// 最近一次选图的步进方向:+1 向后,-1 向前,0 点选/无变化
    private(set) var lastStepDirection = 0

    func requestRotate() {
        guard currentImage != nil else { return }
        rotateRequestToken += 1
    }

    /// 缩放指令通道(token 递增表示新指令)
    private(set) var zoomRequest: (action: ZoomAction, token: Int)?
    private var zoomToken = 0

    /// folder -> 上次选中的图片,切回文件夹时恢复（key 已 standardized）
    private var selectionMemory: [URL: URL] = [:]
    /// folder -> 被隐藏的图片(会话级,不写盘;刷新/重开 app 后恢复，最多 100 文件夹 LRU)
    private var hiddenByFolder: [URL: Set<URL>] = [:]
    private var hiddenByFolderOrder: [URL] = []

    private func standardized(_ url: URL) -> URL { url.standardizedFileURL }
    private func rememberHidden(folder: URL, id: URL) {
        let key = standardized(folder)
        if hiddenByFolder[key] == nil { hiddenByFolderOrder.append(key) }
        hiddenByFolder[key, default: []].insert(standardized(id))
        if hiddenByFolderOrder.count > 100, let oldest = hiddenByFolderOrder.first {
            hiddenByFolderOrder.removeFirst()
            hiddenByFolder.removeValue(forKey: oldest)
        }
    }

    var currentImage: ImageFile? {
        guard let id = selectedImageID else { return nil }
        return images.first { $0.id == id }
    }

    /// 当前图前后各 1 张,供主视图预解码
    var neighborURLs: [URL] {
        guard selectedImageID != nil, !images.isEmpty, currentIndex >= 0 else { return [] }
        return [-1, 1].compactMap { offset in
            let idx = currentIndex + offset
            guard images.indices.contains(idx) else { return nil }
            return images[idx].url
        }
    }

    var currentIndex: Int {
        guard let id = selectedImageID else { return -1 }
        return images.firstIndex { $0.id == id } ?? -1
    }

    var selectedFolder: FolderNode? { node(id: selectedFolderID) }

    // MARK: - 打开 / 选择

    func openFolderPanel() {
        let panel = NSOpenPanel()
        panel.title = L10n.openFolderTitle
        panel.message = L10n.openFolderMessage
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openFolder(url)
    }

    func openFolder(_ url: URL) {
        isSingleImageMode = false
        singleImageSourceFolder = nil
        selectFolder(ensureRoot(url))
    }

    /// 打开外部图片文件（单张/少量）：默认仅加载所选图，侧边提示按需加载同目录其余图片
    func revealExternalImage(_ url: URL) {
        revealExternalImages([url])
    }

    func revealExternalImages(_ urls: [URL]) {
        let imageURLs = urls.filter { ImageDiscovery.isImageFile($0) }
            .map { $0.standardizedFileURL }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true }
        guard !imageURLs.isEmpty else { return }
        // 统一用 standardized，便于去重与比较
        let unique = Array(Set(imageURLs)).sorted { ImageDiscovery.naturalLess($0.lastPathComponent, $1.lastPathComponent) }
        // 是否同目录
        let firstFolder = unique[0].deletingLastPathComponent().standardizedFileURL
        let sameFolder = unique.allSatisfy { $0.deletingLastPathComponent().standardizedFileURL == firstFolder }

        // 同路径已打开时的增量/跳转逻辑
        if sameFolder {
            let allImages = ImageDiscovery.images(in: firstFolder)
            let hidden = hiddenByFolder[standardized(firstFolder)] ?? []
            let filteredAll = allImages.filter { !hidden.contains(standardized($0.url)) }
            let filteredSet = Set(filteredAll.map { $0.id })
            let currentSet = Set(images.map { $0.id })
            let isSameFolderAlreadyOpen = selectedFolder?.url.standardizedFileURL == firstFolder || roots.contains(where: { $0.url.standardizedFileURL == firstFolder })

            // 情况1：已在单图模式且同目录 -> 合并保留已打开的，新增本次选择
            if isSingleImageMode, let src = singleImageSourceFolder, src.standardizedFileURL == firstFolder {
                var combinedSet = currentSet
                for u in unique { combinedSet.insert(u) }
                // 若合并后已全量，且原本就是该目录的单图模式，则直接展示新图（保留已打开的）
                if combinedSet == filteredSet {
                    // 已全量：退出单图模式并全量展示，直接跳转
                    isSingleImageMode = false
                    singleImageSourceFolder = nil
                    let node = ensureRoot(firstFolder)
                    selectedFolderID = node.id
                    ThumbnailProvider.shared.cancelAll()
                    DisplayImageCache.shared.cancelAll()
                    images = filteredAll
                    if let target = unique.first(where: { filteredSet.contains($0) }) {
                        selectImage(target)
                    } else if let first = unique.first {
                        selectImage(first)
                    }
                    return
                }
                // 未全量：合并后仍保持单图模式，保留之前已打开的
                let combined = combinedSet.sorted { ImageDiscovery.naturalLess($0.lastPathComponent, $1.lastPathComponent) }.map { ImageFile(id: $0) }
                let node = ensureRoot(firstFolder)
                selectedFolderID = node.id
                // 保持单图模式
                isSingleImageMode = true
                singleImageSourceFolder = firstFolder
                ThumbnailProvider.shared.cancelAll()
                DisplayImageCache.shared.cancelAll()
                images = combined
                // 跳转到本次新打开的首张（若已在列表则选中它）
                if let target = unique.first, combinedSet.contains(target) {
                    selectedImageID = target
                    lastStepDirection = 0
                    selectionMemory[standardized(firstFolder)] = target
                } else {
                    selectedImageID = combined.first?.id
                }
                prefetchNeighbors()
                return
            }

            // 情况2：已在全量模式且同目录已全量展示 -> 直接跳转
            if !isSingleImageMode, isSameFolderAlreadyOpen, currentSet == filteredSet, let target = unique.first, filteredSet.contains(target) {
                // 确保选中该文件夹
                if let node = roots.first(where: { $0.url.standardizedFileURL == firstFolder }) {
                    selectedFolderID = node.id
                } else {
                    let node = ensureRoot(firstFolder)
                    selectedFolderID = node.id
                }
                // 直接选中目标图
                if images.contains(where: { $0.id == target }) {
                    selectImage(target)
                } else {
                    // 理论上已全量不应走到这里，兜底全量后选中
                    isSingleImageMode = false
                    singleImageSourceFolder = nil
                    let node = ensureRoot(firstFolder)
                    selectedFolderID = node.id
                    images = filteredAll
                    selectImage(target)
                }
                return
            }

            // 情况3：同目录但尚未全量，且本次非增量单图模式 -> 首次进入单图模式
            if filteredAll.count > unique.count {
                let node = ensureRoot(firstFolder)
                selectedFolderID = node.id
                isSingleImageMode = true
                singleImageSourceFolder = firstFolder
                ThumbnailProvider.shared.cancelAll()
                DisplayImageCache.shared.cancelAll()
                images = unique.map { ImageFile(id: $0) }
                selectedImageID = images.first?.id
                if let sel = selectedImageID { selectionMemory[standardized(firstFolder)] = sel }
                prefetchNeighbors()
                return
            }
        }
        // 非同目录多选：作为临时虚拟相册（不关联文件夹，仅展示所选）
        if unique.count > 1 && !sameFolder {
            // 仍需一个根用于侧栏展示，选首图所在目录为关联目录但不自动加载
            let node = ensureRoot(firstFolder)
            selectedFolderID = node.id
            isSingleImageMode = true
            singleImageSourceFolder = nil
            ThumbnailProvider.shared.cancelAll()
            DisplayImageCache.shared.cancelAll()
            images = unique.map { ImageFile(id: $0) }
            selectedImageID = images.first?.id
            prefetchNeighbors()
            return
        }
        // 回退：同目录且已全选 / 单张且目录仅一张 → 直接走文件夹全量
        isSingleImageMode = false
        singleImageSourceFolder = nil
        openFolder(firstFolder)
        if let first = unique.first, images.contains(where: { $0.id == first }) {
            selectImage(first)
        }
    }

    /// 单图模式下，按需加载同目录所有图片
    func loadAllFromCurrentFolder() {
        guard isSingleImageMode, let folder = singleImageSourceFolder else { return }
        let current = selectedImageID
        isSingleImageMode = false
        singleImageSourceFolder = nil
        let node = ensureRoot(folder)
        // selectFolder 会重算 images 并 cancel 队列
        selectFolder(node)
        if let cur = current, images.contains(where: { $0.id == cur }) {
            selectImage(cur)
        }
    }

    func selectFolder(_ node: FolderNode) {
        selectedFolderID = node.id
        // 显式选文件夹即退出单图模式
        isSingleImageMode = false
        singleImageSourceFolder = nil
        let key = standardized(node.url)
        let hidden = hiddenByFolder[key] ?? []
        // 取消旧缩略图队列，避免 1000 张切盘时积压
        ThumbnailProvider.shared.cancelAll()
        DisplayImageCache.shared.cancelAll()
        images = ImageDiscovery.images(in: node.url).filter { !hidden.contains(standardized($0.url)) }
        if let remembered = selectionMemory[key],
           images.contains(where: { standardized($0.id) == remembered }) {
            selectedImageID = remembered
        } else {
            selectedImageID = images.first?.id
        }
        if let sel = selectedImageID { selectionMemory[key] = standardized(sel) }
        prefetchNeighbors()
    }

        func selectImage(_ id: ImageFile.ID, direction: Int = 0) {
        guard images.contains(where: { $0.id == id }) else { return }
        selectedImageID = id
        lastStepDirection = direction
        if let folder = selectedFolder?.url {
            selectionMemory[standardized(folder)] = standardized(id)
        }
        prefetchNeighbors()
    }

    /// 步进切换(首尾循环)
    func step(_ delta: Int) {
        guard !images.isEmpty, currentIndex >= 0 else {
            if !images.isEmpty { selectImage(images[0].id, direction: delta) }
            return
        }
        let count = images.count
        let idx = ((currentIndex + delta) % count + count) % count
        lastStepDirection = delta > 0 ? 1 : (delta < 0 ? -1 : 0)
        selectImage(images[idx].id, direction: lastStepDirection)
    }

    /// 一期手动刷新当前文件夹(不做实时监听)
    func refreshCurrentFolder() {
        guard let node = selectedFolder else { return }
        selectFolder(node)
    }

    // MARK: - 文件夹树

    func ensureChildren(of node: FolderNode) {
        guard !node.childrenLoaded else { return }
        node.childrenLoaded = true
        node.children = ImageDiscovery.subfolders(in: node.url)
            .map { FolderNode(url: $0, depth: node.depth + 1) }
    }

    func removeRoot(id: FolderNode.ID) {
        roots.removeAll { $0.id == id }
        guard selectedFolderID == id else { return }
        selectedFolderID = nil
        images = []
        selectedImageID = nil
        if let first = roots.first { selectFolder(first) }
    }

    func node(id: FolderNode.ID?) -> FolderNode? {
        guard let id else { return nil }
        return findNode(in: roots, id: id)
    }

    private func findNode(in nodes: [FolderNode], id: FolderNode.ID) -> FolderNode? {
        for n in nodes {
            if n.id == id { return n }
            if let found = findNode(in: n.children, id: id) { return found }
        }
        return nil
    }

    // MARK: - 画布交互指令

    func requestZoom(_ action: ZoomAction) {
        zoomToken += 1
        zoomRequest = (action, zoomToken)
    }

    func requestPrint() {
        guard currentImage != nil else { return }
        printRequestToken += 1
    }

    func requestCrop() {
        guard currentImage != nil else { return }
        cropRequestToken += 1
    }

    // MARK: - 缩略图右键操作(复制 / 隐藏 / 删除)

    /// 复制图片:同时写入文件引用与图像数据
    /// (Finder 粘贴得到文件拷贝,富文本/聊天应用粘贴得到图像)
    func copyImageToPasteboard(_ id: ImageFile.ID) {
        let pasteboard = NSPasteboard.general
        pasteboard.declareTypes([.fileURL, .tiff], owner: nil)
        (id as NSURL).write(to: pasteboard)
        guard let image = NSImage(contentsOf: id),
              let tiff = image.tiffRepresentation else { return }
        pasteboard.setData(tiff, forType: .tiff)
    }

    /// 隐藏图片:仅从当前浏览列表移除,文件保留在磁盘
    func hideImage(_ id: ImageFile.ID) {
        guard let folder = selectedFolder?.url,
              images.contains(where: { $0.id == id }) else { return }
        rememberHidden(folder: folder, id: id)
        removeFromImages(id)
    }

    /// 删除图片:移到废纸篓(可从 Finder 恢复);失败时弹窗说明并保留在列表
    func deleteImage(_ id: ImageFile.ID) {
        guard images.contains(where: { $0.id == id }) else { return }
        do {
            try FileManager.default.trashItem(at: id, resultingItemURL: nil)
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法将“\(id.lastPathComponent)”移到废纸篓"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return
        }
        removeFromImages(id)
    }

    /// 从浏览列表移除一张图;若被移除的是当前图,选中同位置的后继项
    private func removeFromImages(_ id: ImageFile.ID) {
        guard let index = images.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = selectedImageID == id
        images.remove(at: index)
        guard wasSelected else { return }
        if images.isEmpty {
            selectedImageID = nil
        } else {
            selectImage(images[min(index, images.count - 1)].id)
        }
        if let folder = selectedFolder?.url {
            let key = standardized(folder)
            if let sel = selectedImageID { selectionMemory[key] = standardized(sel) }
            else { selectionMemory.removeValue(forKey: key) }
        }
    }

    // MARK: - 私有

    private func ensureRoot(_ url: URL) -> FolderNode {
        let std = url.standardizedFileURL
        if let existing = roots.first(where: { $0.url.standardizedFileURL == std }) {
            return existing
        }
        let node = FolderNode(url: url, depth: 0)
        roots.append(node)
        return node
    }

    /// 预取相邻图片缩略图,切换零等待
    private func prefetchNeighbors() {
        let around: [URL] = [-2, -1, 1, 2].compactMap { offset in
            let idx = currentIndex + offset
            guard images.indices.contains(idx) else { return nil }
            return images[idx].url
        }
        guard !around.isEmpty else { return }
        Task.detached(priority: .utility) {
            for url in around {
                _ = await ThumbnailProvider.shared.asyncThumbnail(for: url, maxPixel: 180)
            }
        }
    }
}
