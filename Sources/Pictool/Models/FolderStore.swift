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
    /// 直接跳到某个百分比(1.0 = 实际大小,与状态栏读数同一套语义)
    case scale(CGFloat)
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
    /// 当前显示位图已被用户旋转(纯显示态,切图即丢、不写回文件)
    var isDisplayRotated = false

    var showInspector = false
    /// 只看图:窗口内隐藏顶栏/侧栏/状态栏/信息面板
    var isImmersive = false
    /// 当前是否有模态面板(裁切 sheet / 打印面板)打开。
    /// 裸键快捷键(I/C/F/0/1/←/→)此时必须失效,否则会在面板背后改动浏览状态。
    var isModalPresented = false
    /// 侧栏是否可见(普通模式;纯净模式下强制隐藏,退出后恢复)
    var sidebarVisible = true
    private var sidebarBeforeImmersive = true

    /// 切图到首尾后是否循环(偏好设置)
    var wrapNavigation: Bool = {
        guard UserDefaults.standard.object(forKey: WrapNavigation.storageKey) != nil else {
            return WrapNavigation.defaultValue
        }
        return UserDefaults.standard.bool(forKey: WrapNavigation.storageKey)
    }()
    /// 当前列表排序(偏好设置;列表变更时沿用)
    private(set) var sortPreference = ImageSortPreference.load()

    /// 单张/少量打开模式：默认不加载同目录所有图片，侧边提示按需加载
    private(set) var isSingleImageMode = false
    private(set) var singleImageSourceFolder: URL?
    /// 文件夹图片总数缓存,避免 pendingOtherCount 每次扫盘
    private var folderImageCountCache: [URL: Int] = [:]
    private var sortGeneration = 0

    /// 同目录还有多少张未加载。只读缓存,绝不在此触发扫盘——
    /// 这个属性被 body 直接求值,走主线程,上千文件的目录会卡住渲染。
    var pendingOtherCount: Int {
        guard isSingleImageMode, let folder = singleImageSourceFolder else { return 0 }
        guard let all = folderImageCountCache[standardized(folder)] else { return 0 }
        let hidden = hiddenByFolder[standardized(folder)]?.count ?? 0
        return max(0, all - hidden - images.count)
    }

    /// 当前文件夹被隐藏的张数(用于侧栏的「恢复」入口)
    var hiddenCountInCurrentFolder: Int {
        guard let folder = selectedFolder?.url else { return 0 }
        return hiddenByFolder[standardized(folder)]?.count ?? 0
    }

    /// 恢复当前文件夹所有被隐藏的图片(隐藏仅作用于本次浏览)
    func unhideAllInCurrentFolder() {
        guard let node = selectedFolder else { return }
        let key = standardized(node.url)
        guard hiddenByFolder[key] != nil else { return }
        hiddenByFolder.removeValue(forKey: key)
        hiddenByFolderOrder.removeAll { $0 == key }
        selectFolder(node)
    }

    private func rememberFolderCount(_ folder: URL, _ count: Int) {
        folderImageCountCache[standardized(folder)] = count
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
    /// 当前图累计显示旋转次数(每格 90°;显示层状态,不写回文件)。
    /// 传次数而不是递增 token:纯净模式/普通模式是两个画布实例,切换时新画布
    /// 按「次数 - 已应用次数」补齐差值,才能重放完整角度(token 只能重放一刀)。
    private(set) var rotationCount = 0
    /// 最近一次选图的步进方向:+1 向后,-1 向前,0 点选/无变化
    private(set) var lastStepDirection = 0

    func requestRotate() {
        guard currentImage != nil else { return }
        rotationCount += 1
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
        let unique = ImageDiscovery.sorted(
            Array(Set(imageURLs)),
            by: ImageSortPreference(key: .name, direction: sortPreference.direction)
        )
        // 是否同目录
        let firstFolder = unique[0].deletingLastPathComponent().standardizedFileURL
        let sameFolder = unique.allSatisfy { $0.deletingLastPathComponent().standardizedFileURL == firstFolder }

        // 同路径已打开时的增量/跳转逻辑。
        // 全量扫盘(目录枚举 + 并行类型判定)不能在主线程做——双击单图/拖入同目录图
        // 都会走到这里,大文件夹会让 UI 卡住;扫描在后台完成后回主线程执行分支。
        if sameFolder {
            let pref = sortPreference
            Task { @MainActor in
                let allImages = await Task.detached(priority: .userInitiated) {
                    ImageDiscovery.images(in: firstFolder, sortedBy: pref)
                }.value
                self.applySameFolderReveal(unique: unique, firstFolder: firstFolder, allImages: allImages)
            }
            return
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
            if let first = images.first?.id { setSelectedImage(first) }
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

    /// 同目录外部打开的三个分支:增量合并 / 已全量直接跳转 / 首次进入单图模式。
    /// 只做状态修改;扫盘由调用方在后台完成后传入 allImages。
    private func applySameFolderReveal(unique: [URL], firstFolder: URL, allImages: [ImageFile]) {
        rememberFolderCount(firstFolder, allImages.count)
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
            let combined = ImageDiscovery.sorted(Array(combinedSet), by: sortPreference).map { ImageFile(id: $0) }
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
                setSelectedImage(target)
                lastStepDirection = 0
                selectionMemory[standardized(firstFolder)] = target
            } else if let first = combined.first?.id {
                setSelectedImage(first)
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
            if let first = images.first?.id { setSelectedImage(first) }
            if let sel = selectedImageID { selectionMemory[standardized(firstFolder)] = sel }
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
        let urls = ImageDiscovery.imageURLs(in: node.url)
        rememberFolderCount(node.url, urls.count)
        applySortedURLs(
            urls.filter { !hidden.contains(standardized($0)) },
            remembered: selectionMemory[key]
        )
    }

        /// 直选图片的所有路径统一走这里:切到不同图时丢弃当前图的旋转显示态
    func setSelectedImage(_ id: ImageFile.ID) {
        if selectedImageID != id {
            rotationCount = 0
            isDisplayRotated = false
        }
        selectedImageID = id
    }

    func selectImage(_ id: ImageFile.ID, direction: Int = 0) {
        guard images.contains(where: { $0.id == id }) else { return }
        setSelectedImage(id)
        lastStepDirection = direction
        if let folder = selectedFolder?.url {
            selectionMemory[standardized(folder)] = standardized(id)
        }
        prefetchNeighbors()
    }

    /// 步进切换;循环由 wrapNavigation 控制
    func step(_ delta: Int) {
        guard !images.isEmpty else { return }
        if currentIndex < 0 {
            selectImage(images[0].id, direction: delta)
            return
        }
        guard let idx = ImageNavigation.nextIndex(
            current: currentIndex, count: images.count, delta: delta, wrap: wrapNavigation
        ), idx != currentIndex else { return }
        lastStepDirection = delta > 0 ? 1 : (delta < 0 ? -1 : 0)
        selectImage(images[idx].id, direction: lastStepDirection)
    }

    func canStep(_ delta: Int) -> Bool {
        guard let idx = ImageNavigation.nextIndex(
            current: currentIndex, count: images.count, delta: delta, wrap: wrapNavigation
        ) else { return false }
        return idx != currentIndex
    }

    func applySortPreference(_ preference: ImageSortPreference) {
        guard preference != sortPreference else { return }
        sortPreference = preference
        guard !images.isEmpty else { return }
        applySortedURLs(images.map(\.url), remembered: selectedImageID)
    }

    /// 同步排出即时序(文件名/时间/大小);拍摄时间先按文件名显示,后台读 EXIF 再重排。
    private func applySortedURLs(_ urls: [URL], remembered: URL?) {
        sortGeneration += 1
        let gen = sortGeneration
        let pref = sortPreference

        func finish(_ files: [ImageFile]) {
            images = files
            if let remembered, images.contains(where: { standardized($0.id) == standardized(remembered) }) {
                setSelectedImage(remembered)
            } else if selectedImageID == nil || !images.contains(where: { $0.id == selectedImageID }) {
                if let first = images.first?.id { setSelectedImage(first) }
            }
            if let sel = selectedImageID, let folder = selectedFolder?.url {
                selectionMemory[standardized(folder)] = standardized(sel)
            }
            prefetchNeighbors()
        }

        if pref.key == .captured {
            let namePref = ImageSortPreference(key: .name, direction: pref.direction)
            finish(ImageDiscovery.sorted(urls, by: namePref).map { ImageFile(id: $0) })
            Task { [weak self] in
                let sorted = await Task.detached(priority: .utility) {
                    ImageDiscovery.sorted(urls, by: pref)
                }.value
                await MainActor.run {
                    guard let self, self.sortGeneration == gen else { return }
                    finish(sorted.map { ImageFile(id: $0) })
                }
            }
        } else {
            finish(ImageDiscovery.sorted(urls, by: pref).map { ImageFile(id: $0) })
        }
    }

    /// 一期手动刷新当前文件夹(不做实时监听)。
    /// 顺带清掉该文件夹的隐藏集合——否则隐藏在本次会话里无法撤销,只能重启 App。
    func refreshCurrentFolder() {
        guard let node = selectedFolder else { return }
        let key = standardized(node.url)
        folderImageCountCache.removeValue(forKey: key)
        hiddenByFolder.removeValue(forKey: key)
        hiddenByFolderOrder.removeAll { $0 == key }
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
        // 右键菜单里的破坏性操作,先确认,避免误触
        let confirm = NSAlert()
        confirm.messageText = "要把“\(id.lastPathComponent)”移到废纸篓吗?"
        confirm.informativeText = "可以从废纸篓恢复。"
        confirm.alertStyle = .warning
        confirm.addButton(withTitle: "移到废纸篓")
        confirm.addButton(withTitle: "取消")
        guard confirm.runModal() == .alertFirstButtonReturn else { return }
        do {
            try FileManager.default.trashItem(at: id, resultingItemURL: nil)
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法将“\(id.lastPathComponent)”移到废纸篓"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            return
        }
        if let folder = selectedFolder?.url {
            let key = standardized(folder)
            if let count = folderImageCountCache[key] {
                folderImageCountCache[key] = max(0, count - 1)
            }
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
