import AppKit

// Command line surface (used for objective testing and for scripting):
//   MacLauncher --selftest          index apps, exercise Spotlight search, exit
//   MacLauncher --query "saf"       print ranked rows for a query, exit
//   MacLauncher --apps              print every indexed application, exit
//   MacLauncher                     run the launcher

let arguments = CommandLine.arguments

if arguments.contains("--apps") {
    runAppList()
    exit(0)
}

if let index = arguments.firstIndex(of: "--quit"), index + 1 < arguments.count {
    runQuit(arguments[index + 1])
    exit(0)
}

if arguments.contains("--scopes") {
    let config = Config.load()
    print("# searchHomeFolder=\(config.searchHomeFolder) configured=\(config.searchFolders)")
    for folder in config.effectiveSearchFolders {
        let exists = FileManager.default.fileExists(atPath: folder) ? "ok" : "MISSING"
        print("\(folder)\t\(exists)")
    }
    exit(0)
}

if arguments.contains("--reconcile-test") {
    let config = Config.load()
    print("# local before: snippets=\(config.snippets.count) hotKey=\(config.hotKey) showInDock=\(config.showInDock)")
    let semaphore = DispatchSemaphore(value: 0)
    Config.reconcileShared(local: config) { _ in semaphore.signal() }
    _ = semaphore.wait(timeout: .now() + 6)
    let after = Config.load()
    print("# local after : snippets=\(after.snippets.count) hotKey=\(after.hotKey) showInDock=\(after.showInDock)")
    let sharedURL = AppPaths.sharedConfigURL
    if let data = try? Data(contentsOf: sharedURL),
       let decoded = try? JSONDecoder().decode(Config.self, from: data) {
        print("# shared      : snippets=\(decoded.snippets.count) hotKey=\(decoded.hotKey)")
    } else {
        print("# shared      : (none)")
    }
    exit(0)
}

if let index = arguments.firstIndex(of: "--screenshot-capture") {
    let path = (index + 1 < arguments.count) ? arguments[index + 1] : "/tmp/shot.png"
    let region = (index + 2 < arguments.count) ? arguments[index + 2] : nil
    let permitted = ScreenCapture.isPermitted
    print("# 屏幕录制权限: \(permitted)")
    let screen = NSScreen.main ?? NSScreen.screens[0]
    let rect: CGRect
    if let region = region {
        let parts = region.split(separator: ",").compactMap { Double($0) }
        rect = parts.count == 4 ? CGRect(x: parts[0], y: parts[1], width: parts[2], height: parts[3])
                                : ScreenGeometry.cgRect(fromAppKit: screen.frame)
    } else {
        rect = ScreenGeometry.cgRect(fromAppKit: screen.frame)
    }
    guard let image = ScreenCapture.image(of: rect) else {
        print("  捕获失败（返回 nil）")
        exit(1)
    }
    let rep = NSBitmapImageRep(cgImage: image)
    if let data = rep.representation(using: .png, properties: [:]) {
        try? data.write(to: URL(fileURLWithPath: path))
        print("# 已写入 \(path)  图像 \(image.width)x\(image.height) 像素, 请求区域 \(Int(rect.width))x\(Int(rect.height)) pt")
    }
    exit(0)
}

if arguments.contains("--screenshot-windows") {
    let screen = NSScreen.main ?? NSScreen.screens[0]
    let targets = SnapTargets.forScreen(screen, includeWindows: true)
    print("# 主屏 \(Int(screen.frame.width))x\(Int(screen.frame.height)) pt")
    print("# 竖直候选线 \(targets.verticals.count) 条: \(targets.verticals.sorted().prefix(8).map { Int($0) })")
    print("# 水平候选线 \(targets.horizontals.count) 条: \(targets.horizontals.sorted().prefix(8).map { Int($0) })")
    print("# 仅屏幕(无窗口)时: 竖直 \(SnapTargets.forScreen(screen, includeWindows: false).verticals.count) 条")
    exit(0)
}

if arguments.contains("--stable-order-test") {
    func item(_ title: String, _ kind: ItemKind, _ path: String = "") -> Item {
        Item(title: title, subtitle: "", path: path, kind: kind)
    }
    var failures = 0
    func check(_ name: String, _ ok: Bool, _ detail: String) {
        print("  \(ok ? "PASSED" : "FAILED")  \(name)  \(detail)")
        if !ok { failures += 1 }
    }

    // 屏上已有 [应用A, 应用B]；异步到达 [应用A, 文件X(排名更高), 应用B, 文件Y]
    let existing = [item("Alpha", .application), item("Beta", .application)]
    let incoming = [item("Alpha", .application), item("Xfile", .file, "/tmp/x"), item("Beta", .application),
                    item("Yfile", .file, "/tmp/y")]
    let stable = Indexer.stableResults(existing: existing, incoming: incoming, limit: 12)
    check("已显示的行索引不变",
          stable.count >= 2 && stable[0].title == "Alpha" && stable[1].title == "Beta",
          "-> \(stable.map { $0.title })")
    check("新到的文件行只追加在后面",
          stable.count == 4 && stable[2].title == "Xfile" && stable[3].title == "Yfile",
          "-> \(stable.map { $0.title })")

    // 重复到达不应产生重复行
    let again = Indexer.stableResults(existing: stable, incoming: incoming, limit: 12)
    check("重复合并不产生重复行", again.count == stable.count, "-> \(again.count) 行")

    // 不再匹配的文件行消失，但应用行保留原位
    let shrunk = Indexer.stableResults(existing: stable,
                                       incoming: [item("Alpha", .application), item("Beta", .application)],
                                       limit: 12)
    check("失效的文件行移除、应用行原位保留",
          shrunk.map { $0.title } == ["Alpha", "Beta"], "-> \(shrunk.map { $0.title })")

    // 上限生效
    let many = (0..<20).map { item("F\($0)", .file, "/tmp/\($0)") }
    let capped = Indexer.stableResults(existing: existing, incoming: many, limit: 5)
    check("结果上限生效", capped.count == 5, "-> \(capped.count) 行")

    // 股票行原地替换：位置不变
    let withStocks = [item("用 Google 搜索", .webSearch), item("贵州茅台", .stock, "stock://sh600519"),
                      item("Xfile", .file, "/tmp/x")]
    let refreshed = Indexer.replacingStockRows(in: withStocks,
                                              with: [item("贵州茅台", .stock, "stock://sh600519"),
                                                     item("腾讯控股", .stock, "stock://hk00700")],
                                              limit: 12)
    check("股票行原地刷新不移动其他行",
          refreshed.map { $0.title } == ["用 Google 搜索", "贵州茅台", "腾讯控股", "Xfile"],
          "-> \(refreshed.map { $0.title })")

    // 即时绘制预留槽位后的契约：既有 8 行 + 到达的 8 应用/4 文件 → 恰好 12 行且文件可见
    let painted = (0..<8).map { item("App\($0)", .application) }
    let arrivals = (0..<8).map { item("App\($0)", .application) } + (0..<4).map { item("F\($0)", .file, "/tmp/\($0)") }
    let merged = Indexer.stableResults(existing: painted, incoming: arrivals, limit: 12)
    check("预留槽位后文件行仍可见",
          merged.count == 12 && merged.suffix(4).allSatisfy { $0.kind == .file },
          "-> \(merged.count) 行，末尾 4 行均为文件: \(merged.suffix(4).allSatisfy { $0.kind == .file })")

    // 即时绘制的行数（这条以前只能靠读代码，现在可断言）
    check("预留 4 槽：12 上限 -> 即时 8 行",
          Indexer.instantPaintCount(maxResults: 12, reserve: 4) == 8,
          "-> \(Indexer.instantPaintCount(maxResults: 12, reserve: 4))")
    check("空查询不预留 -> 12 行",
          Indexer.instantPaintCount(maxResults: 12, reserve: 0) == 12,
          "-> \(Indexer.instantPaintCount(maxResults: 12, reserve: 0))")
    check("预留大于上限时至少 1 行",
          Indexer.instantPaintCount(maxResults: 3, reserve: 4) == 1,
          "-> \(Indexer.instantPaintCount(maxResults: 3, reserve: 4))")

    // 裸关键词网页行：回车应进入输入状态
    let bareRow = Item(title: "用 Google 搜索…", subtitle: "", path: "", kind: .webSearch,
                       alternateTitles: ["g"], url: "https://www.google.com/search")
    check("裸关键词行 → 回车进入输入状态",
          PaletteController.webPromptKeyword(for: bareRow, fieldText: "g") == "g",
          "-> \(PaletteController.webPromptKeyword(for: bareRow, fieldText: "g") ?? "nil")")
    check("关键词已带内容 → 回车照常打开",
          PaletteController.webPromptKeyword(for: bareRow, fieldText: "g test") == nil,
          "-> nil 表示照常打开")
    check("默认引擎行（普通查询）不进入输入状态",
          PaletteController.webPromptKeyword(for: bareRow, fieldText: "holography") == nil,
          "-> nil")
    check("回车提示按行类型区分",
          PaletteController.returnHint(for: .webSearch) == "↵ 输入搜索内容"
            && PaletteController.returnHint(for: .application) == "↵ 打开",
          "-> \(PaletteController.returnHint(for: .webSearch)) / \(PaletteController.returnHint(for: .application))")

    // ⌘↩ 的提示随选中类型变化
    check("文件行提示为访达显示",
          PaletteController.commandHint(for: .file) == "⌘↩ 在访达中显示",
          "-> \(PaletteController.commandHint(for: .file))")
    check("文件夹行提示为访达显示",
          PaletteController.commandHint(for: .folder) == "⌘↩ 在访达中显示",
          "-> \(PaletteController.commandHint(for: .folder))")
    check("应用行提示为强制退出",
          PaletteController.commandHint(for: .application) == "⌘↩ 强制退出",
          "-> \(PaletteController.commandHint(for: .application))")

    print("# 结果: \(failures == 0 ? "全部通过" : "\(failures) 项失败")")
    exit(failures == 0 ? 0 : 1)
}

if arguments.contains("--screenshot-drag-test") {
    // Regression test for "dragging the region teleports it": the grab point must be recorded
    // on every mouse down, so a move translates the box by the cursor delta.
    let screen = NSScreen.main ?? NSScreen.screens[0]
    let view = ScreenshotOverlayView(screen: screen, frozen: nil)
    view.frame = NSRect(origin: .zero, size: screen.frame.size)
    view.setSelection(NSRect(x: 400, y: 400, width: 300, height: 200))

    func mouse(_ type: NSEvent.EventType, _ point: NSPoint) -> NSEvent? {
        NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                           timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: 0, context: nil, eventNumber: 0,
                           clickCount: 1, pressure: 1)
    }
    var failures = 0
    func check(_ name: String, _ ok: Bool, _ detail: String) {
        print("  \(ok ? "PASSED" : "FAILED")  \(name)  \(detail)")
        if !ok { failures += 1 }
    }

    // 抓取选区内部 (500,500) 拖动到 (520,530)：应平移 (20,30)，而不是把左上角对到光标
    view.mouseDown(with: mouse(.leftMouseDown, NSPoint(x: 500, y: 500))!)
    view.mouseDragged(with: mouse(.leftMouseDragged, NSPoint(x: 520, y: 530))!)
    var rect = view.debugSelection
    check("内部拖动=平移光标增量",
          abs(rect.minX - 420) < 0.001 && abs(rect.minY - 430) < 0.001,
          "-> 原点 \(Int(rect.minX)),\(Int(rect.minY))（期望 420,430）")
    view.mouseUp(with: mouse(.leftMouseUp, NSPoint(x: 520, y: 530))!)

    // 第二次抓取：再次拖动应继续平移（旧实现会因陈旧 dragOrigin 瞬移）
    view.mouseDown(with: mouse(.leftMouseDown, NSPoint(x: 500, y: 500))!)
    view.mouseDragged(with: mouse(.leftMouseDragged, NSPoint(x: 510, y: 510))!)
    rect = view.debugSelection
    check("第二次拖动同样只平移",
          abs(rect.minX - 430) < 0.001 && abs(rect.minY - 440) < 0.001,
          "-> 原点 \(Int(rect.minX)),\(Int(rect.minY))（期望 430,440）")
    view.mouseUp(with: mouse(.leftMouseUp, NSPoint(x: 510, y: 510))!)

    // 首次画框：锚点(按下点)绝不能动，即使自由角吸附到候选线
    let fresh = ScreenshotOverlayView(screen: screen, frozen: nil)
    fresh.frame = NSRect(origin: .zero, size: screen.frame.size)
    let anchor = NSPoint(x: 300, y: 300)
    fresh.mouseDown(with: mouse(.leftMouseDown, anchor)!)
    let targets = SnapTargets.forScreen(screen, includeWindows: false)
    let nearTarget = targets.verticals.first { $0 > 320 } ?? 640      // 让自由角落在吸附范围内
    fresh.mouseDragged(with: mouse(.leftMouseDragged, NSPoint(x: nearTarget + 3, y: 500))!)
    var freshRect = fresh.debugSelection
    check("首次画框锚点不动",
          abs(freshRect.minX - anchor.x) < 0.001 && abs(freshRect.minY - anchor.y) < 0.001,
          "-> 锚点 \(Int(freshRect.minX)),\(Int(freshRect.minY))（期望 \(Int(anchor.x)),\(Int(anchor.y))）")
    check("自由角吸附到候选线",
          abs(freshRect.maxX - nearTarget) < 0.001,
          "-> 右边缘 \(Int(freshRect.maxX))（期望 \(Int(nearTarget))）")
    fresh.mouseUp(with: mouse(.leftMouseUp, NSPoint(x: nearTarget + 3, y: 500))!)

    // 滞回：已在候选线上时，略微离开不应立刻跳回。
    // 这里必须用合成候选线——真实屏幕的候选线是 [0, 中点, 宽]，并不存在 x=100，
    // 我第一版拿真实候选线去断言 x=100，得到的是假失败。
    let synthetic = SnapTargets(verticals: [100], horizontals: [200])
    let sticky = SnapEngine.snapPoint(NSPoint(x: 103, y: 500), targets: synthetic)
    let stickyKept = SnapEngine.snapPoint(NSPoint(x: 112, y: 500), targets: synthetic,
                                          stickyVertical: sticky.verticalGuide,
                                          stickyHorizontal: sticky.horizontalGuide)
    check("滞回：小幅离开仍保持在线上",
          sticky.verticalGuide == 100 && stickyKept.verticalGuide == 100,
          "-> 首帧 \(sticky.verticalGuide.map { Int($0) } ?? -1), 离开后 \(stickyKept.verticalGuide.map { Int($0) } ?? -1)（均应为 100）")
    check("滞回：超出两倍阈值后放开",
          SnapEngine.snapPoint(NSPoint(x: 130, y: 500), targets: synthetic,
                               stickyVertical: 100).verticalGuide == nil,
          "-> \(SnapEngine.snapPoint(NSPoint(x: 130, y: 500), targets: synthetic, stickyVertical: 100).verticalGuide.map { Int($0) } ?? -1)")

    // 拖右边缘：只改宽度
    view.mouseDown(with: mouse(.leftMouseDown, NSPoint(x: rect.maxX, y: rect.midY))!)
    view.mouseDragged(with: mouse(.leftMouseDragged, NSPoint(x: rect.maxX + 30, y: rect.midY))!)
    let resized = view.debugSelection
    check("拖右边缘只改宽度",
          abs(resized.minX - rect.minX) < 0.001 && abs(resized.width - (rect.width + 30)) < 0.001,
          "-> x=\(Int(resized.minX)) 宽=\(Int(resized.width))（期望 \(Int(rect.minX)),\(Int(rect.width + 30))）")
    view.mouseUp(with: mouse(.leftMouseUp, NSPoint(x: resized.maxX, y: resized.midY))!)

    print("# 结果: \(failures == 0 ? "全部通过" : "\(failures) 项失败")")
    exit(failures == 0 ? 0 : 1)
}

if arguments.contains("--snap-test") {
    // 纯函数测试：不涉及 GUI
    let targets = SnapTargets(verticals: [0, 100, 640], horizontals: [0, 200, 480])
    var failures = 0
    func check(_ name: String, _ condition: Bool, _ detail: String) {
        print("  \(condition ? "PASSED" : "FAILED")  \(name)  \(detail)")
        if !condition { failures += 1 }
    }
    // 1) 左边缘距 100 仅 3px -> 吸附
    let near = SnapEngine.snap(NSRect(x: 97, y: 197, width: 200, height: 100), targets: targets)
    check("左/上边缘吸附", near.rect.minX == 100 && near.rect.minY == 200,
          "-> x=\(Int(near.rect.minX)) y=\(Int(near.rect.minY)) 参考线=\(near.verticalGuide.map { Int($0) } ?? -1)/\(near.horizontalGuide.map { Int($0) } ?? -1)")
    // 2) 距离 20px -> 不吸附
    let far = SnapEngine.snap(NSRect(x: 120, y: 150, width: 200, height: 40), targets: targets)
    check("超出阈值不吸附", far.rect.minX == 120 && far.verticalGuide == nil, "-> x=\(Int(far.rect.minX))")
    // 3) 右边缘吸附：右边缘 641 -> 640
    let right = SnapEngine.snap(NSRect(x: 441, y: 10, width: 200, height: 40), targets: targets)
    check("右边缘吸附", abs(right.rect.maxX - 640) < 0.001, "-> maxX=\(Int(right.rect.maxX))")
    // 4) 缩放时只动被拖的那条边
    let sized = SnapEngine.snapResizing(NSRect(x: 97, y: 0, width: 300, height: 100),
                                        handle: .left, targets: targets)
    check("缩放仅动左边缘", sized.rect.minX == 100 && abs(sized.rect.maxX - 397) < 0.001,
          "-> x=\(Int(sized.rect.minX)) maxX=\(Int(sized.rect.maxX))")
    // 5) 命中判定
    // AppKit coordinates grow upward, so the rect's minY edge is the one drawn at the bottom
    // of the screen: (100, 200) is the bottom-left corner. The first version of this test
    // expected .topLeft and reported a false failure.
    let handle = SelectionHandle.at(point: NSPoint(x: 100, y: 200), in: NSRect(x: 100, y: 200, width: 300, height: 150))
    check("左下角命中", handle == .bottomLeft, "-> \(handle)")
    let move = SelectionHandle.at(point: NSPoint(x: 250, y: 275), in: NSRect(x: 100, y: 200, width: 300, height: 150))
    check("内部=移动", move == .move, "-> \(move)")
    print("# 结果: \(failures == 0 ? "全部通过" : "\(failures) 项失败")")
    exit(failures == 0 ? 0 : 1)
}

if arguments.contains("--clipboard-test") {
    // 1) 类型与多项保真：用自定义剪贴板，完全不碰用户的真实剪贴板
    let board = NSPasteboard(name: NSPasteboard.Name("MacLauncherClipboardTest"))
    let tiff = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
                                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                isPlanar: false, colorSpaceName: .deviceRGB,
                                bytesPerRow: 0, bitsPerPixel: 0)?
        .representation(using: .tiff, properties: [:]) ?? Data()
    let first = NSPasteboardItem()
    first.setString("原始文本", forType: .string)
    first.setData(tiff, forType: .tiff)
    let second = NSPasteboardItem()
    second.setString("第二项", forType: .string)
    board.clearContents()
    board.writeObjects([first, second])

    let snapshot = PasteboardSnapshot.capture(board)
    let beforeItems = snapshot.itemCount, beforeTypes = snapshot.typeCount
    print("# 原剪贴板: \(snapshot.summary)")

    board.clearContents()
    board.setString("snippet 文本", forType: .string)
    let ownership = board.changeCount
    _ = snapshot.restore(to: board, ifUnchangedSince: ownership)

    let restored = board.pasteboardItems ?? []
    let restoredText = board.string(forType: .string) ?? "无"
    let restoredImage = restored.first?.data(forType: .tiff) != nil
    print("# 还原后: \(restored.count) 项, 文本=\(restoredText), 图片=\(restoredImage ? "在" : "丢了")")
    // `string(forType:)` joins the items of a multi-item pasteboard with newlines, so compare
    // by containment rather than equality (the first version of this test asserted equality and
    // reported a false failure).
    let textOK = restoredText.contains("原始文本") && restoredText.contains("第二项")
    print("# 保真判定: \(restored.count == beforeItems && textOK && restoredImage ? "PASSED" : "FAILED")")

    // 2) 归属守卫：借用期间别人写了新内容，还原必须让位
    board.clearContents()
    board.setString("snippet", forType: .string)
    let ownership2 = board.changeCount
    board.clearContents()
    board.setString("用户期间新复制的内容", forType: .string)
    _ = snapshot.restore(to: board, ifUnchangedSince: ownership2)
    let kept = board.string(forType: .string) == "用户期间新复制的内容"
    print("# 归属守卫（新内容不被覆盖）: \(kept ? "PASSED" : "FAILED")")

    // 3) 真实剪贴板往返：净效果为还原，不改变用户现有内容
    let general = NSPasteboard.general
    let real = PasteboardSnapshot.capture(general)
    general.clearContents()
    general.setString("MacLauncher 临时占用", forType: .string)
    let ownership3 = general.changeCount
    let ok = real.restore(to: general, ifUnchangedSince: ownership3)
    let after = PasteboardSnapshot.capture(general)
    print("# 真实剪贴板往返: 还原=\(ok), 类型数 \(real.typeCount) -> \(after.typeCount), 一致=\(real.typeCount == after.typeCount ? "PASSED" : "FAILED")")
    exit(0)
}

if let index = arguments.firstIndex(of: "--engine-set"), index + 3 < arguments.count {
    let engines = Config.setEngine(keyword: arguments[index + 1],
                                   name: arguments[index + 2],
                                   urlTemplate: arguments[index + 3])
    print("# 引擎 \"" + arguments[index + 1] + "\" -> " + arguments[index + 3])
    print("# 现有引擎: " + engines.map { $0.keyword }.joined(separator: ", "))
    exit(0)
}

if let index = arguments.firstIndex(of: "--stock-watch"), index + 1 < arguments.count {
    // Each invocation is its own process, which is the strongest test that the on-disk
    // read-modify-write accumulates instead of dropping what was there before.
    for symbol in arguments[index + 1].split(separator: ",").map(String.init) {
        if symbol.hasPrefix("-") {
            print("# 移除 \(symbol.dropFirst()) -> \(Config.setWatched(String(symbol.dropFirst()), watched: false))")
        } else {
            print("# 加入 \(symbol) -> \(Config.setWatched(symbol, watched: true))")
        }
    }
    exit(0)
}

if arguments.contains("--stock-watch-list") {
    print("# 自选: \(Config.watchlist())")
    exit(0)
}

if let index = arguments.firstIndex(of: "--stock-search"), index + 1 < arguments.count {
    let query = arguments[index + 1]
    let started = Date()
    let hits = StockSearch.suggest(query)
    print("# 联想「\(query)」 \(Int(Date().timeIntervalSince(started) * 1000))ms，\(hits.count) 条")
    for hit in hits { print("  \(hit.market.rawValue)\t\(hit.code)\t\(hit.name)") }
    if !hits.isEmpty {
        let quotes = StockQuotes.fetch(hits.map { $0.code })
        print("# 行情（一次批量请求）")
        for hit in hits {
            guard let quote = quotes[hit.code] else { print("  \(hit.code)\t(无行情)"); continue }
            print("  \(quote.name)\t\(quote.priceText)\t\(quote.changeText)\t\(quote.updated)")
        }
    }
    exit(0)
}

if let index = arguments.firstIndex(of: "--stock-quote"), index + 1 < arguments.count {
    let symbols = arguments[index + 1].split(separator: ",").map(String.init)
    let started = Date()
    let quotes = StockQuotes.fetch(symbols)
    print("# 行情 \(symbols.count) 只 \(Int(Date().timeIntervalSince(started) * 1000))ms")
    for symbol in symbols {
        guard let quote = quotes[symbol] else { print("  \(symbol)\t(无数据)"); continue }
        print("  \(symbol)\t\(quote.name)\t现价 \(quote.priceText)\t昨收 \(quote.previousClose)\t\(quote.changeText)\t\(quote.updated)")
    }
    exit(0)
}

if let index = arguments.firstIndex(of: "--stock-trend"), index + 1 < arguments.count {
    let symbol = arguments[index + 1]
    let started = Date()
    guard let trend = StockTrends.fetch(symbol) else { print("# \(symbol) 分时无数据"); exit(0) }
    print("# \(symbol) 分时 \(Int(Date().timeIntervalSince(started) * 1000))ms  日期 \(trend.date)  昨收 \(trend.previousClose)  根数 \(trend.points.count)")
    if let first = trend.points.first, let last = trend.points.last {
        print("  首根 \(first.minute / 60):\(String(format: "%02d", first.minute % 60)) \(first.price)   末根 \(last.minute / 60):\(String(format: "%02d", last.minute % 60)) \(last.price)")
    }
    exit(0)
}

if let index = arguments.firstIndex(of: "--stock-kline"), index + 1 < arguments.count {
    let symbol = arguments[index + 1]
    let started = Date()
    let bars = StockKLine.fetch(symbol)
    print("# \(symbol) 日K \(Int(Date().timeIntervalSince(started) * 1000))ms  根数 \(bars.count)")
    for bar in bars.suffix(3) {
        print("  \(bar.date)  开\(bar.open) 收\(bar.close) 高\(bar.high) 低\(bar.low)")
    }
    exit(0)
}

if arguments.contains("--history-test") {

    let history = QueryHistory.shared
    history.clear()
    for query in ["设置", "g holography", "entanglement", "设置"] { history.record(query) }
    print("# 记录 4 次（其中「设置」重复）后，最新在前: \(history.entries)")
    var back: [String] = []
    while let entry = history.stepBack() { back.append(entry) }
    print("# 连按 ↑ 依次得到: \(back)")
    var forward: [String] = []
    for _ in 0..<5 { forward.append(history.stepForward()) }
    print("# 连按 ↓ 依次得到: \(forward.map { $0.isEmpty ? "「空」" : $0 })")
    history.clear()
    for index in 1...60 { history.record("q\(index)") }
    print("# 记录 60 条后保留 \(history.entries.count) 条，最旧的是 \(history.entries.last ?? "-")")
    print("# 持久化文件存在: \(FileManager.default.fileExists(atPath: AppPaths.historyURL.path))")
    exit(0)
}

if let index = arguments.firstIndex(of: "--define"), index + 1 < arguments.count {
    let word = arguments[index + 1]
    print("# define \"\(word)\"  candidate=\(Dictionary.isCandidate(word))")
    if let entry = Dictionary.lookUp(word) {
        print("headword : \(entry.headword)")
        print("phonetics: \(entry.phonetics)")
        print("brief    : \(entry.brief)")
        print("---- formatted ----")
        print(Dictionary.format(entry.body))
    } else {
        print("(无词条 —— 可能是拼音撞车或词典未收录)")
    }
    exit(0)
}

if arguments.contains("--hotkey-test") {
    let samples = ["option+space", "ctrl+option+space", "cmd+shift+k", "ctrl+space", "cmd+space",
                   "f5", "shift+f5", "cmd+shift+p", "a", "cmd+spacebar", "ctrl+alt+delete",
                   "cmd+shift+3", "option+`", "ctrl+shift+left"]
    for spec in samples {
        if let parsed = HotKey.parse(spec: spec) {
            let canonical = HotKey.describe(keyCode: parsed.keyCode, modifiers: parsed.modifiers)
            let warning = HotKey.conflictWarning(spec: spec).map { "  ⚠️ \($0)" } ?? ""
            print("\(spec.padding(toLength: 22, withPad: " ", startingAt: 0)) ok  key=\(parsed.keyCode)\tdisplay=\(HotKey.display(spec: spec))\tcanonical=\(canonical)\(warning)")
        } else {
            print("\(spec.padding(toLength: 22, withPad: " ", startingAt: 0)) REJECTED (needs a modifier and a known key)")
        }
    }
    exit(0)
}

if let index = arguments.firstIndex(of: "--expand-test"), index + 1 < arguments.count {
    runExpandTest(arguments[index + 1])
    exit(0)
}

if let index = arguments.firstIndex(of: "--type-test"), index + 1 < arguments.count {
    runTypeTest(arguments[index + 1])
    exit(0)
}

/// Measures the two ways of injecting text into the frontmost application, because event
/// posting turned out to cost ~10 ms per call and the count of calls dominates latency.
func runTypeTest(_ sample: String) {
    guard Paster.isTrusted else {
        print("Accessibility permission is not granted")
        exit(3)
    }
    print("sample=\"\(sample)\" utf16=\(sample.utf16.count)")

    var started = Date()
    Paster.typeTextInPlace(sample)
    print("per-character: \(Int(Date().timeIntervalSince(started) * 1000))ms (\(sample.utf16.count * 2) posts)")

    usleep(400_000)
    started = Date()
    Paster.postWholeString(sample)
    print("whole-string : \(Int(Date().timeIntervalSince(started) * 1000))ms (2 posts)")
}

if let index = arguments.firstIndex(of: "--caret-test"), index + 1 < arguments.count {
    let delay = (index + 2 < arguments.count) ? Double(arguments[index + 2]) ?? 120 : 120
    let arrows = !arguments.contains("--no-arrows")
    runCaretTest(arguments[index + 1], delayMs: delay, arrows: arrows)
    exit(0)
}

if arguments.contains("--selftest") {
    runSelfTest()
    exit(0)
}

if let index = arguments.firstIndex(of: "--query"), index + 1 < arguments.count {
    runQuery(arguments[index + 1])
    exit(0)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.accessory)
application.run()

// MARK: - command line helpers

func makeAppIndex(config: Config) -> Indexer {
    let indexer = Indexer()
    indexer.buildApps()
    indexer.updateSnippets(config.snippets)
    return indexer
}

/// Exercises exactly the same resolution path the palette uses in quit mode, so the
/// quit behaviour can be verified without driving the GUI.
func runQuit(_ query: String) {
    let config = Config.load()
    let indexer = makeAppIndex(config: Config.load())
    let candidates = indexer.searchApps(rawQuery: "q \(query)", config: config)
    guard let item = candidates.first, let app = item.running else {
        print("no running application matches \"\(query)\"")
        exit(2)
    }
    print("quitting \(item.title) [\(item.bundleIdentifier ?? "?")] pid=\(app.processIdentifier)")
    if !app.terminate() {
        print("terminate() was refused (the app may have unsaved changes)")
        exit(3)
    }
    // `NSRunningApplication.isTerminated` lags behind reality, so probe the process.
    let pid = app.processIdentifier
    for _ in 0..<30 {
        if !isProcessAlive(pid) { break }
        usleep(100_000)
    }
    let gone = !isProcessAlive(pid)
    print(gone ? "terminated" : "still running after 3s")
    exit(gone ? 0 : 4)
}

/// Feeds a sample string through the same matching rule the live expander uses, so the
/// expansion logic can be verified without typing into a real application.
func runExpandTest(_ sample: String) {
    let config = Config.load()
    let expandable = SnippetExpander.expandable(config.snippets)
    print("# \(config.snippets.count) snippets, \(expandable.count) auto-expandable")
    for snippet in config.snippets {
        let auto = expandable.contains { $0.keyword == snippet.keyword }
        print("  \(snippet.keyword)  [\(auto ? "auto-expand" : "palette-only")]  \(snippet.name)")
    }
    var buffer = ""
    var hits: [String] = []
    for character in sample {
        if character == "\n" {
            buffer = ""
            continue
        }
        buffer.append(character)
        if let match = SnippetExpander.match(snippets: config.snippets, buffer: buffer) {
            let (text, backoff) = Snippet.cursorSplit(match.content)
            let rendered = text.replacingOccurrences(of: "\n", with: "\\n")
            let caret = backoff > 0 ? " + 光标回退 \(backoff)" : ""
            hits.append("\(buffer) => \(match.keyword) [\(rendered)]\(caret)")
            buffer = ""
        }
    }
    print("# fed \"\(sample)\" -> \(hits.isEmpty ? "no expansion" : hits.joined(separator: ", "))")
}

/// Runs only the injection half of an expansion against the frontmost application.
/// The keystroke monitor cannot be driven by synthetic input, so this is how the caret
/// placement gets measured against a target that reports its own insertion point.
func runCaretTest(_ keyword: String, delayMs: Double, arrows: Bool) {
    let config = Config.load()
    guard let snippet = config.snippets.first(where: { $0.keyword == keyword }) else {
        print("no snippet with keyword \"\(keyword)\"")
        exit(2)
    }
    guard Paster.isTrusted else {
        print("Accessibility permission is not granted")
        exit(3)
    }
    let (text, backoff) = Snippet.cursorSplit(snippet.content)
    print("keyword=\(keyword) delete=\(snippet.keyword.count) paste=\"\(text)\" backoff=\(backoff) delay=\(Int(delayMs))ms arrows=\(arrows)")

    Paster.postBackspaces(count: snippet.keyword.count)
    usleep(60_000)
    Paster.pasteInPlace(text)
    if arrows, backoff > 0 {
        usleep(useconds_t(delayMs * 1000))
        Paster.postLeftArrows(count: backoff)
    }
    usleep(300_000)
    print("done")
}

func isProcessAlive(_ pid: pid_t) -> Bool {
    if kill(pid, 0) == 0 { return true }
    return errno == EPERM
}

/// Blocking Spotlight search, for the command line tools only.
func spotlightPaths(query: String, config: Config, deadline: TimeInterval = 8) -> (paths: [String], ms: Int) {
    let trimmed = Indexer.parse(query).query
    guard !trimmed.isEmpty else { return ([], 0) }
    let started = Date()
    let semaphore = DispatchSemaphore(value: 0)
    var paths: [String] = []
    SpotlightSearcher().search(query: trimmed,
                               folders: config.effectiveSearchFolders,
                               limit: Indexer.fileCandidateLimit,
                               deadline: deadline) { result in
        paths = result
        semaphore.signal()
    }
    _ = semaphore.wait(timeout: .now() + deadline + 2)
    return (paths, Int(Date().timeIntervalSince(started) * 1000))
}

func runAppList() {
    let indexer = makeAppIndex(config: Config.load())
    print("# \(indexer.apps.count) apps")
    for item in indexer.apps {
        print("\(item.running != nil ? "R" : "-")\t\(item.title)\t\(item.path)")
    }
}

func runQuery(_ query: String) {
    let config = Config.load()
    let indexer = makeAppIndex(config: Config.load())
    let apps = indexer.searchApps(rawQuery: query, config: config)
    let spotlight = spotlightPaths(query: query, config: config)
    let merged = indexer.merge(rawQuery: query,
                               apps: apps,
                               filePaths: spotlight.paths,
                               config: config)
    print("# query \"\(query)\" -> \(merged.count) rows  (apps indexed=\(indexer.apps.count), app hits=\(apps.count), spotlight hits=\(spotlight.paths.count) in \(spotlight.ms)ms)")
    for result in merged {
        print("\(result.kind.rawValue)\t\(result.title)\t\(result.path)")
    }
}

func runSelfTest() {
    let config = Config.load()
    Log.write("--- selftest ---")
    Log.write("local config: \(AppPaths.localConfigURL.path)")
    Log.write("shared config: \(AppPaths.sharedConfigURL.path)")
    Log.write("search folders: \(config.searchFolders.joined(separator: ", "))")

    if let parsed = HotKey.parse(spec: config.hotKey) {
        Log.write("hotkey spec: \(config.hotKey) -> keyCode=\(parsed.keyCode) modifiers=\(parsed.modifiers) [\(HotKey.describe(keyCode: parsed.keyCode, modifiers: parsed.modifiers))]")
    } else {
        Log.write("hotkey spec not understood: \(config.hotKey)")
    }
    let registered = HotKeyManager.shared.register(spec: config.hotKey) {}
    Log.write("hotkey registration from selftest: \(registered ? "OK" : "FAILED")")

    let indexer = makeAppIndex(config: Config.load())
    Log.write("apps indexed: \(indexer.apps.count)")

    for query in ["saf", "term", "xcode", "christoffel", "readme", "q ", "q term"] {
        let started = Date()
        let apps = indexer.searchApps(rawQuery: query, config: config)
        let appMs = Int(Date().timeIntervalSince(started) * 1000)
        let spotlight = spotlightPaths(query: query, config: config)
        let merged = indexer.merge(rawQuery: query,
                                   apps: apps,
                                   filePaths: spotlight.paths,
                                   config: config)
        let summary = merged.prefix(5).map { "\($0.title)[\($0.kind.rawValue)]" }.joined(separator: " | ")
        Log.write("query \"\(query)\": appHits=\(apps.count) in \(appMs)ms, spotlightHits=\(spotlight.paths.count) in \(spotlight.ms)ms -> \(merged.count) rows :: \(summary)")
    }
    Log.write("--- selftest done ---")
}
