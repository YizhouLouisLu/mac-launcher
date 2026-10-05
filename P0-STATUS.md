# P0 状态（2026-10-05）

Alfred 风格的极简启动器：呼出面板 → 搜索 → 启动/退出 App 与文件。
自用、多台 Mac、每台从源码构建。技术栈 Swift + AppKit，直接 `swiftc` 构建。

---

## 1. 已验证通过（客观证据）

| 项 | 结果 |
| --- | --- |
| 构建 | `./build.sh` → `build/MacLauncher.app`（swiftc + 手工组装 bundle + ad-hoc 签名） |
| 启动 | LaunchServices 启动 **< 1 秒**完成（此前会永久卡死，原因见 §3.3） |
| App 索引 | 159–160 个 App（含 18 个运行中），33 ms |
| App 搜索 | 纯内存，**0 ms**：`saf`→Safari、`term`→Terminal、`q `→12 个运行中 App |
| 文件搜索 | Spotlight（`mdfind`）：`saf` 31 命中/306 ms，`christoffel` 11 命中/260 ms，`readme` 36 命中/408 ms |
| 合并排序 | App 与文件在同一评分尺度上竞争：`saf` → Safari 置顶，其后才是文件；`q term` 只返回运行中的 App |
| 退出模式 | `q <名称>` / `quit <名称>` 前缀把候选限制为运行中的 App |
| 符号链接 App | `/Applications/Safari.app` 是指向 cryptex 的符号链接，`FileManager.enumerator` 会**静默漏掉**；已自写递归遍历修复 |
| 本地化名 | 同时索引 bundle 文件名与本地化显示名：`finder` 与「访达」都能命中 |
| 配置 | 本地即时加载（首次自动生成）；iCloud 副本后台读取、有差异才采纳 |
| 热键注册 | Carbon `RegisterEventHotKey option+space -> OK`（Alfred 5 同时在运行也不冲突） |

## 2. 验收状态

### 2.1 已由人工按键验证（2026-10-05）

- 按 Option+Space 出现灰色无边框输入框 → **热键 + 面板 + 键盘焦点成立**，且 Alfred 未抢走该键；
- 输入 `saf` 再按 `Enter` → **Safari 启动**，即「搜索 → 排序 → 启动」链路成立。

（我的合成按键通道在本会话后半段失效，见 §4，所以这几项只能由人验证。）

### 2.2 待验证

1. 输入 `christoffel` 应补上 `.nb` 文件结果（Spotlight 路径）；
2. `↑`/`↓` 切换选中项；`Esc` 关闭并回到原 App；
3. 先打开「计算器」，输入 `q 计算器` 按 Enter 应退出该 App（退出路径）；
4. 菜单栏 ⌘ 状态项的菜单项是否可用（Show palette / Reload / Open config / Reveal log）。

全部通过（2026-10-05）：↑↓ 切换正常；`q 计算器` 能退出；面板启动的 App 出现在前台；
文件结果随输入补齐；Dock 图标为蓝底白放大镜；菜单栏状态项因刘海遮挡不可见（见 §8），
改由 Dock 图标 + 热键作为入口。

### 2.3 安装形态（打磨完成）

- `./install.sh`：构建 → 装到 `~/Applications/MacLauncher.app` → 注册 LaunchAgent
  （`~/Library/LaunchAgents/com.luyizhou.maclauncher.plist`，`RunAtLoad`、`ProcessType=Interactive`、
  `LimitLoadToSessionType=Aqua`）并立即启动；`./install.sh --uninstall` 卸载。
- 登录启动路径用 `launchctl kickstart -k gui/$UID/com.luyizhou.maclauncher` 验证过（进程被 launchd 重启并完整初始化）。
- 图标由代码生成（`tools/make-icon.swift` → `build/AppIcon.iconset` → `iconutil -c icns`），仓库里不放二进制。
- 主菜单（App + Edit）已安装，使 Dock 模式下的面板输入支持 Cmd+V 等编辑键。
- 搜索目录最终定为 `~/Documents`、`~/Downloads`、`~/Library/Mathematica`
  （去掉 Desktop 的旧备份噪音；补上 xAct 笔记本位置。实测 `saf` 从 12 行噪音降到 3 行）。


## 3. 环境硬约束

### 3.1 SDK 必须显式指定
`xcrun` 把默认 SDK 解析为 `MacOSX27.0.sdk`（由 Swift 6.4 构建），被本机 Swift 6.3.3 拒绝。
`build.sh` 固定用 `-sdk $(xcode-select -p)/SDKs/MacOSX.sdk`（→ 26.5）。

### 3.2 SwiftPM 不可用
`swift-package` 与自带 `BuildServerProtocol.framework` dyld 符号不匹配
（`SourceKitInitializeA12ResponseDataV14encodeToLSPAny`）。已改为直接 `swiftc`，不依赖 SwiftPM。

### 3.3 启动路径禁止同步 iCloud I/O 与目录遍历（已按此重构）
`sample` 抓到的阻塞点：
- `Config.mirrorToShared` → `Data.write(to:)` → `open()`，卡在 `~/Library/Mobile Documents/...`；同路径的读取同样卡死，LaunchServices 启动时**永久不返回**；
- `Indexer.buildFiles` → `DirEnumRead` → `open()`，枚举 `~/Desktop`、`~/Documents`、`~/Downloads` 时挂住；而 CLI 上下文（继承 shell 的 TCC 授权）只要 820 ms。

因此：配置改为**本地权威 + 后台采纳 iCloud 副本**；文件搜索**整体改为 Spotlight**，
不再有任何目录遍历。`mdfind` 子进程带看门狗（deadline 到点即 kill），
索引卡死只会退化成「没有文件结果」，不会冻结面板。

遗留提示：iCloud Drive 在本机的 fileprovider 交互本身不可靠（后台那次读取数十分钟未返回），
跨机同步建议改用 git 仓库或显式导入导出，不要依赖同步 iCloud 文件访问。

## 4. 当前会话的测试通道失效

会话前半段可用合成按键（`CGEventPost`）驱动 GUI 验证（ObjC spike 的 Option+Space 与打字均成功）；
后半段该通道整体失效，连最稳的「打字进 Sink 文本框」也不再生效。
`AXIsProcessTrusted=true`、tccd 显示 `kTCCServicePostEvent` 查询正常、无显式拒绝、无崩溃报告。

因此 §2 必须人工验收。可先检查：系统设置 → 隐私与安全性 → 辅助功能 中 DeepSeek Harness 是否仍被勾选。

## 5. 结构

```
app/Sources/
  Support.swift     路径与日志（AppPaths 不做 iCloud 存在性检查，避免启动阻塞）
  Config.swift      本地权威配置 + 后台采纳 iCloud 副本
  Item.swift        一行结果（预计算小写标题、首字母、多别名）
  Ranking.swift     精确 > 前缀 > 首字母 > 词首 > 子串 > 路径
  Indexer.swift     App 索引（自写递归遍历，处理符号链接）+ 合并排序；不碰文件系统
  Spotlight.swift   mdfind 子进程 + 看门狗，回调跑在自身队列
  HotKey.swift      Carbon 全局热键
  Palette.swift     面板、结果表、键盘操作、启动/激活/退出
  AppDelegate.swift 状态项、启动流程、配置采纳
  main.swift        CLI：--selftest / --query / --apps
```

## 6. 复现

```
cd mac-launcher/app
./build.sh
./build/MacLauncher --selftest            # 索引、热键、Spotlight 计时与合并结果
./build/MacLauncher --query christoffel   # 文件搜索
./build/MacLauncher --query saf           # App 搜索
open -n build/MacLauncher.app             # 运行（菜单栏 ⌘ / Dock 图标）
~/Library/Application Support/MacLauncher/launcher.log
```

CLI：
```
--selftest            索引、热键、Spotlight 计时与合并结果
--query <text>        单次查询（App + 文件合并排序）
--apps                列出全部索引到的 App
--quit <name>         退出某个正在运行的 App（与面板同一解析逻辑）
```

## 7. 下一步

**P0 已封板**：呼出 → 搜索 App/文件 → 启动/退出 → 安装与登录自启动，全部经人工或客观验证。

1. **P1：snippets 直接粘贴插入前台 App**（最初列的三个功能里最核心的一个）。配方已在 spike 验证：
   记录原前台 App → 隐藏面板 → 重新激活目标 → 等 400–500 ms → `CGEventPost` 发 Cmd+V → 还原剪贴板；
   目标 App 需有主菜单才响应 Cmd+V，因此要保留「Unicode 逐字输入」作为后备。
   需要引导用户授予 Accessibility 权限；配合钥匙串自签名证书，避免每次重编译后授权失效。
2. P2：引擎前缀网络搜索（`engines` 字段已预留；`g 关键词`、`gh 关键词` 等）。
3. 多机部署：`./install.sh` 已可用；配置同步**不要**依赖同步 iCloud 文件访问（实测会无限期阻塞），
   建议改用 git 仓库或显式导入导出。


## 8. P0 期间发现并修掉的 bug（供后续参考）

| bug | 症状 | 修法 |
| --- | --- | --- |
| 运行状态是启动时快照 | 启动器启动后新开的 App 永远标为「未运行」，`q` 无法退出、也无法切到前台（用户实测发现） | 拆成「一次性目录扫描」+「每次呼出面板重叠加实时运行状态」，均为纯内存 |
| 启动时同步读 iCloud 配置 | LaunchServices 启动时**永久卡死**在 `open()` | 本地配置为启动权威，iCloud 副本后台按修改时间双向收敛 |
| iCloud 副本覆盖本地改动 | 同步逻辑「字节不同就采纳远端」，静默回滚了本地配置 | 改为比较 modificationDate，新的覆盖旧的 |
| `FileManager.enumerator` 漏符号链接 | `/Applications/Safari.app`（→ cryptex 的符号链接）被静默跳过 | 自写递归遍历，用 `contentsOfDirectory` 并解析符号链接 |
| 只索引本地化显示名 | 中文系统下 `finder` 搜不到「访达」 | 同时索引 bundle 文件名与本地化显示名，两者都可命中 |
| Spotlight 回调派发到 main queue | CLI 下 main run loop 不存在，查询永远超时 | 回调跑在 searcher 自身队列，UI 侧自行跳主线程 |
| `readabilityHandler` 死锁 | 回调被派发到正在阻塞等待的串行队列 | 改为阻塞读到 EOF + 独立看门狗 kill |
| 空查询时 merge 返回 0 行 | `q ` 模式列出 12 个 App，合并后变 0 行 | 空查询直接返回 App 结果 |
| 启动的 App 不到前台 | 面板刚激活过，新 App 落在后面（用户提问暴露） | `openApplication(configuration.activates = true)` + 完成后显式激活 + 0.25s 重试 |
| Dock 图标是系统通用图标 | bundle 无 `.icns`（用户实测发现） | 运行时把 SF Symbol 渲染成 Dock 图标；正式 `.icns` 留到 P1 |
| 状态项被刘海遮挡 | 菜单栏 18 个状态项，我们的项被排到刘海死区（x 771–956） | macOS 行为，代码无法控制；提供 `showInDock` 兜底入口 + Dock 图标点击开面板 |

