# P1 状态：snippets（2026-10-05）

目标：在任意 App 里打关键词 → 自动替换成片段内容（Alfred 式），面板路径同时保留。
状态：**核心已完成并经验证**（用户在 VS Code 实测 `;mail` 自动展开成功）。

---

## 1. 实现结构

| 文件 | 职责 |
| --- | --- |
| `Sources/Snippets.swift` | `Snippet` 模型（keyword / name / content，字段全可选容错）；`Paster`：粘贴与按键注入的底层原语 |
| `Sources/Expander.swift` | 全局按键监听 → 缓冲区 → 关键词匹配 → 删关键词 + 粘贴替换 |
| `Sources/Indexer.swift` | 片段作为 `.snippet` 行参与面板搜索（与 App 在同一评分尺度上竞争） |
| `Sources/Palette.swift` | 面板路径：选中片段 → `Paster.paste` 到呼出前的那个 App |
| `Sources/Config.swift` | `snippets`、`autoExpandSnippets` |

配置示例（`~/Library/Application Support/MacLauncher/config.json`）：

```json
"snippets": [
  { "keyword": ";sig", "name": "邮件签名", "content": "第一行\n第二行" }
],
"autoExpandSnippets": true
```

## 2. 自动展开的安全设计（刻意选择，不要随意放宽）

| 规则 | 原因 |
| --- | --- |
| 全局监听用 `NSEvent.addGlobalMonitorForEvents`（**只读**） | 绝不吞或改写用户的按键；展开是「事后」删关键词 + 粘贴，不会破坏输入流 |
| 只有**以非字母数字开头**的关键词自动展开（`expandable(_:)`） | 纯字母关键词（`sig`）会在正常写作中误触；它仍可在面板里使用 |
| 缓冲区上限 64 字符，遇 Return/Tab/Esc/方向键/组合键清空 | 限定匹配范围，避免跨语句误匹配 |
| 目标 App 中途变化 → 放弃；面板可见 → 不展开 | 防止内容粘到错误位置 |
| 密码框等安全输入框不会触发 | macOS 不把安全输入事件交给全局监听（系统级保证） |
| 展开延迟 60 ms | 等目标 App 处理完刚敲入的字符 |

已知限制：替换走「退格 + Cmd+V」，因此**目标 App 必须响应 Cmd+V**（App 需有 Edit 菜单）；
`Paster.typeText` 已实现逐字 Unicode 注入作为后备原语，但目前未接入展开路径——
若遇到忽略 Cmd+V 的 App，把 `Expander.expand` 里的 `pasteInPlace` 换成 `typeText` 即可。

## 3. 签名证书（关键：让授权在重编译后存活）

ad-hoc 签名的 designated requirement 是 **cdhash**，每次重编译都变 → TCC 授权失效（实测确认）。
改用自签名证书后，要求变成身份型：

```
designated => identifier "com.luyizhou.maclauncher" and certificate root = H"6e48b4be…"
```

创建方式（每台 Mac 各做一次，约 1 分钟）：

```bash
KC="$HOME/Library/Keychains/login.keychain-db"
WORK=$(mktemp -d); cd "$WORK"
cat > cert.conf <<'EOF'
[req]
distinguished_name=dn
x509_extensions=v3
prompt=no
[dn]
CN=MacLauncher Dev
O=MacLauncher
[v3]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
EOF
openssl req -x509 -newkey rsa:2048 -nodes -keyout key.pem -out cert.pem -days 3650 -config cert.conf
# PKCS#12 会被 macOS 拒绝（OpenSSL 3 格式），必须分别导入 PEM
security import key.pem  -k "$KC" -P "" -T /usr/bin/codesign -T /usr/bin/security
security import cert.pem -k "$KC" -T /usr/bin/codesign -T /usr/bin/security
security add-trusted-cert -r trustRoot -k "$KC" cert.pem
security find-identity -v -p codesigning | grep "MacLauncher Dev"
cd /; rm -rf "$WORK"     # 私钥只留在钥匙串里
tccutil reset Accessibility com.luyizhou.maclauncher   # 清掉旧 ad-hoc 记录的重复条目
```

`build.sh` / `install.sh` 都会调 `sign.sh`：有该身份就用它，没有则退回 ad-hoc 并警告。
**注意**：签名前必须 `xattr -cr`，否则 codesign 报
`resource fork, Finder information, or similar detritus not allowed`（已写进 `sign.sh`）。

换到新身份后需要在「隐私与安全性 → 辅助功能」里**授权一次**；之后重编译不再失效（已验证）。

## 4. 验证证据

```
11:08:57  accessibility granted while running
11:08:57  auto-expansion started for 2 keyword(s) of 2
11:09:09  expanding ;mail -> 20 chars in Code      ← 用户在 VS Code 实测
11:09:28  accessibility: granted                    ← 重编译+重装后仍然授权
```

逻辑层的客观验证（不需要 GUI）：

```
MacLauncher --expand-test "hello;mail world"
MacLauncher --expand-test "no keyword here"
MacLauncher --query ";mail"          # 面板路径的搜索与排序
```

## 5. 下一步

- **P1b：图形化片段编辑器**（最初选定的「GUI 设置界面」）：增删改片段、开关自动展开、
  以及「把当前选中的文本存为片段」（后者需要读取选区，用 Accessibility AXAPI）。
- P2：引擎前缀网络搜索（`engines` 字段已预留）。
- 多机部署：每台机器跑一次 `./install.sh` + 上面的证书步骤 + 授权一次。

## 6. Alfred 片段迁移与 `{cursor}`（2026-10-05）

从 `~/Library/Application Support/Alfred/Alfred.alfredpreferences/snippets/Latex/` 迁移 **40 个片段**
（Alfred 5 每个片段一个 JSON：`{"alfredsnippet": {keyword, name, snippet}}`），内容与 `{cursor}` 标记原样保留。

- Alfred 的游标占位符是**单花括号 `{cursor}`**。注意 `{{cursor}}` = 「字面 `{` + 标记」，
  正好对应 `\mathcal{` 后把游标留在括号内——判断占位符时不能用 `\{\{...\}\}` 这种正则，会误判。
- 展开流程：删关键词 → 粘贴去掉标记的文本 → 按标记之后的字符数把光标左移
  （`Snippet.cursorSplit` + `Paster.postLeftArrows`）。已验证：

  | 关键词 | 展开文本 | 光标回退 |
  | --- | --- | --- |
  | `\mcal` | `\mathcal{}` | 1 |
  | `\abs` | `\left\|\right\|` | 7 |
  | `\frac` | `\frac{}{}` | 3 |
  | `\aed` | `\begin{aligned}\n\n\end{aligned}` | 14 |

- 关键词首字符分布：`\`×36、`^`、`_`、`(`、`{` —— 都满足「非字母数字开头」因而自动展开。
  **`{` 与 `(` 是单字符关键词**：打一个 `(` 就会被替换成 `()`，在普通写作里会干扰；是否保留由用户决定。
- 已知风险：多行片段粘贴后若编辑器自动缩进，光标左移的字符数会偏；需在真实编辑器（VS Code）里核对。
- 迁移前已备份配置为 `config.json.bak-*`。
- 按用户决定：删除单字符关键词 `(`（在正文里误触），保留 `{`。片段数 40 → 39。

## 7. 光标定位：根因与验证（2026-10-05）

**现象**：展开后文本正确，但光标跑到行首（`caret=0`），而不是 `{cursor}` 要求的位置。

**根因**：合成 `Cmd+V` 之后，会话状态里 **Cmd 仍被视为按下**，随后发的左箭头被解释成
`Cmd+←`（跳到行首）。同一坑也会影响退格。

**修法**（`Sources/Snippets.swift` + `Sources/Expander.swift`）：
1. 退格与左箭头事件显式 `flags = []`；
2. 光标左移的等待随内容长度自适应：`min(0.6, 0.15 + 0.008 × 字符数)`，
   避免粘贴尚未完成就移动光标（否则长片段会偏字符）。

**验证手段**（重要，可复用）：`spike-objc` 的测试靶子支持自驱动测试——

```
spike-objc/build/Sink.app/Contents/MacOS/Sink --selftest '\mcal'
# -> SELFTEST typed="\mcal" content="\mathcal{}" caret=9 length=10
```

它自己激活、自己把关键词键入自己的文本视图、再读自己的内容与 `selectedRange` 并打印。
跨进程的合成输入有焦点竞争（实测时好时坏，窗口会在过程中失去 key），自驱动测试才可靠。
另注：**展开器的全局监听看不到合成按键**，所以「触发」端只能由真人验证，
而「注入」端（退格/粘贴/光标）可以用这个靶子精确测量。

**结果**：6 个片段 × 3 次 = 18/18 光标位置正确，含 `\aed`（多行 aligned）与 `\lr[`。

CLI 辅助：`--caret-test <关键词> [延迟ms] [--no-arrows]` 可单独跑注入那半边，便于隔离问题。

## 8. 展开速度与「整串注入」的教训（2026-10-05）

用户反馈「有点慢」，随后又报两个 bug：**偶尔丢字符/顺序乱**，以及**打 `\align` 会把前面的内容删掉再粘贴**。

**测量出的真实瓶颈**：每次 `CGEvent.post` 约 2.5ms，按字符注入是 2N 次调用（10 字符 61ms，30 字符约 600ms）。

**第一次修复（错误示范）**：改用 `postWholeString` —— 一个事件对携带整段文本，注入时间降到 ~0ms，
应用内耗时从 346ms 降到 40ms。但这是**拿正确性换速度**：
- Electron（VS Code）对多字符事件的接受度不可靠 → 文本没进去，而后续的光标左移照常执行，
  于是光标在用户**原有正文**里回退，接着的输入插到错误位置，表现为「前面内容被删掉再粘贴」；
- 为提速把匹配延迟压到 40ms，目标 App 还未消化完最后一个按键就退格，会多吃一个字符。

**最终方案（正确性优先）**：
- 默认 `snippetInjection: "type"` = **逐字符注入**（每字符独立事件，Electron 也稳），
  间隔 1ms；应用内耗时实测 `\mcal` 34ms、`\aed` 72ms；
- 匹配延迟放宽到 **90ms**，确保按键已投递到目标 App 才退格（避免误删前面的字符）；
- 保留 `snippetInjection: "whole"`（整串一个事件对，最快但 Electron 可能丢）与
  `"paste"`（剪贴板 + Cmd+V，兼容性最好但慢且会动剪贴板）供按编辑器取舍。

**验证**：`\mcal`、`\align`、`\aed`、`\cases`、`\lr[`、`\mbb` 各 3 次，内容（含多行换行）与光标全部正确。
踩坑提醒：校验多行片段时不能只比较某一行的内容，必须取完整块（我因此误判过两次）。

用户感知延迟 ≈ 匹配延迟 90ms + 应用内 30–70ms ≈ 120–160ms。

### 8.1 换行在 Electron 里会丢（2026-10-05 追加）

用户复测：内容正确但**不换行，光标也不对**。原因：`CGEventKeyboardSetUnicodeString` 发一个
换行码位，**AppKit 文本框会当换行处理，Electron 会忽略**——三行内容被压成一行，按换行数
算出的光标回退自然全错。（我的靶子是 AppKit，所以没暴露这个问题——这是「测试靶子与目标环境不一致」
的典型代价。）

**修法：按内容自适应注入**（`Expander.expand`）：

```
let mode = text.contains("\n") ? "paste" : injectionMode
```

- 单行 → 逐字符注入（快、不碰剪贴板）；
- 含换行 → 剪贴板粘贴（换行原样插入；VS Code 默认不开 Format On Paste，所以不会重排缩进）；
- 配置项 `snippetInjection` 仍可强制 `"paste"` 或 `"whole"`。

验证：`\mcal`/`\abs`（单行，mode type）与 `\align`/`\aed`/`\lr[`（多行，mode paste）
各 3 次 = 15/15 内容（含换行）与光标全对。

代价：多行片段会短暂使用剪贴板（保存→写入→还原），使用剪贴板历史工具时会留下记录。

## 9. P1b：图形化片段编辑器（2026-10-05）

`Sources/SettingsWindow.swift`：左侧片段列表（＋/－增删），右侧编辑表单（关键词 / 名称 / 内容），
以及自动展开开关与「展开预览」（含 `{cursor}` 回退字符数提示）。

- **打开方式（三种）**：面板里输入 `snippets` 回车（内置命令，最方便）；App 菜单 `Snippet settings…`（⌘,）；
  状态菜单同类项（受刘海遮挡影响）。
- **保存即时生效**：保存写 `config.json` → 镜像到 iCloud → 回调 AppDelegate 热更新
  （indexer / palette / expander 三处），**无需重启**。
- **校验**：关键词为空或重复时拒绝保存并提示；关键词不以符号开头时在预览区警告「不会自动展开」。
- **内置命令**（`Indexer.builtinCommands`，与 App/片段同尺度排序）：
  `snippets`（片段设置）、`reload`（重新读取 config.json 并重建索引）。
- 数据层改动：`ItemKind.command` + `Item.command`；`Palette.onCommand` 回调。

未实现（可后续加）：把当前选中文本存为片段——需要 AX 读取选区，而 Electron 的 AX 文本支持参差，
另外这也需要「读选中文本」的独立验证。

## 10. P2：引擎前缀网络搜索（2026-10-05）

`Indexer.webSearchItem`：只认**精确**的引擎关键词，后接空格与查询词，才产生一条动作行
（`ItemKind.webSearch`，URL 存在 `Item.url`）：

| 输入 | 结果 |
| --- | --- |
| `g kodama holography` | 用 Google 搜索「kodama holography」 |
| `gh swift concurrency` | 用 GitHub 搜索 |
| `arxiv entanglement wedge` | 用 arXiv 搜索 |
| `wiki 黑洞信息悖论` | 用 维基百科 搜索 |
| `hello` / `go` / `g` / `arXiv` | **不插入**搜索行（不劫持普通搜索） |

- 动作行固定在结果首位（它是动作，不该被排序压下去）；`merge` 会先剔除 `searchApps` 送来的
  旧动作行再重新插入，避免重复。
- 编码加固：`.urlQueryAllowed` 本身不转义 `& = + ? #`，查询词里带这些字符会**注入额外 URL 参数**，
  因此显式移除后转义（`a&b` → `a%26b`）。
- 默认引擎（写入配置一次）：`g` Google、`gh` GitHub、`arxiv` arXiv、`inspire` INSPIRE-HEP、
  `scholar` Google Scholar、`wiki` 维基百科。

**设置窗口改为两个标签页**：`片段` 与 `搜索引擎`（关键词 / 名称 / URL 模板，含示例 URL 预览与
「URL 里没有 `{query}`」告警）。保存按钮移到窗口底部，一次保存两页；校验引擎关键词与 URL 非空、
关键词不重复。回归测试（`--settings-selftest`，开→关→再开）在新标签页窗口下仍 PASSED。

注意：装了崩溃自愈（`KeepAlive`）后，`pkill` 会被 launchd 立刻拉起，本地测试需先
`launchctl bootout gui/<uid>/com.luyizhou.maclauncher`；用户要停用它应走菜单里的「退出」（干净退出不重启）。

## 11. 面板 UI 美化与离屏渲染自检（2026-10-05）

用户要求美化 Option+Space 面板。改动集中在 `Sources/Palette.swift`：

- **半透明材质**：面板改 `isOpaque = false`、`backgroundColor = .clear`，内容放进
  `NSVisualEffectView(material: .popover, blendingMode: .behindWindow)`；圆角 14pt、1px 发丝边框
  由该视图的 layer 决定。
- **搜索行**：放大镜图标 + 21pt 无边框输入框 + 底部发丝分隔线；占位文案改为「搜索应用、文件、片段、引擎…」。
- **行**：高 46pt、图标 30pt、标题 14.5 medium / 副标题 11.5；**行右侧类型标签**（应用/文件/片段/命令/网页）；
  选中态改为**内缩圆角高亮**（自定义 `NSTableRowView.drawSelection`，配 `tableView.style = .plain`）。
- 副标题不再拼接 `alternateTitles`（原来会把文字挤到类型标签下面，如「lghub」）。
- **底部提示条**：左「N 个结果」、右「↑↓ 选择 ↵ 打开 ⎋ 关闭」；无结果时列表区居中显示「没有匹配的结果」。
- 尺寸：宽 660 → 680；高 = 58（字段）+ 行数×46 + 26（提示条）。
- 修的坑：容器 `content` 的高度此前依赖 autoresizing，面板变高后没跟着变，**提示条与行被裁掉**；
  现在在 `updatePanelSize` 里显式设置其 frame。

**离屏渲染自检工具**：`--render-palette <输出路径> [查询] [--light]`，把面板渲染成 PNG。
本机 shell 没有「屏幕录制」权限（`screencapture` 直接报 `could not create image from display`），
这条路让 UI 评审不依赖任何系统权限。两个必须记住的点：

1. **不能渲染 `panel.contentView`（即 effect view）**：那样会跳过它自己的子视图，搜索框文字与底部提示条
   一律不出现——我据此一度判断「样式没生效」，是错的。必须渲染内层容器 `content`。
2. 材质模糊无法离线复现：渲染时把 `blendingMode` 切成 `.withinWindow`，材质本身不参与评审。

**方法教训**：像素级核对（统计目标区域的颜色种类、亮像素占比）比肉眼可靠得多——
「底部提示条整块只有 1 种颜色」就是「完全没画」的确证，而不是「对比度低」。

预览图：`docs/palette-preview.png`（深色）、`docs/palette-preview-light.png`（浅色，含多行列表）。

## 12. 文件/文件夹搜索修复（2026-10-05）

用户反馈「很多文件搜不到」。诊断出**三个独立缺陷**，前两个是决定性的。

**① 范围太窄**。`searchFolders` 只有 `~/Documents`、`~/Downloads`、`~/Library/Mathematica`，
桌面、家目录根、iCloud、其他项目目录一律不在范围内。实测 `~/Desktop/isinteger.py`
（文件确实存在）：三个目录内命中 **0** 条，`~/Desktop` 1 条，`~` 3 条。用户日志里两次真实查询
（一个中文人名、`密码`）都是 `0 spotlight hits`。

→ 新增 `searchHomeFolder`（默认 true）：范围 = 家目录 + `searchFolders`，并去掉被父目录覆盖的项
（避免对同一棵树重复 `-onlyin`）；`searchFolders` 默认加入 `~/Desktop`。

**② 过滤前截断**。`limit` 加在**未排序**的 mdfind 输出上（`maxResults × 3 = 36`），之后才按目录过滤。
量化：`*pdf*` 全索引 20292 条，三个配置目录内实际 **2162** 条，而「取前 36 条再过滤」只剩 **4** 条。

→ 范围交给索引端（`-onlyin`），本地读取上限 256 KB，**先过滤与排序、后截断**；
候选上限 `Indexer.fileCandidateLimit = 300`；最终按名字质量 + 目录深度排序取前 N。

**③ 噪声与不确定排序**。原始顺序被 `~/Library/...`（OneDrive / Edge / 微信的 `settings.*` 等）淹没；
同分文件的顺序不确定。
→ `SpotlightSearcher.isJunkPath` 过滤缓存、容器、`node_modules`、`.git` 等（**iCloud Drive 保留**）；
`Ranking.fileScore` = 名字匹配阶梯 + 深度加成（浅路径优先）；`Indexer.rank` 增加确定性 tiebreak。

**④ 顺带修好**：Spotlight 找到的 `.app`（例如桌面上的 `Lies of P.app`）现在作为「应用」行出现
——此前它既被垃圾过滤掉，又不在应用索引根目录内，等于搜不到也开不了。

**性能**：复合查询 `(FSName || DisplayName)` 让成本翻倍（家目录 0.42s → 0.91s），而 DisplayName
对文件是冗余的（App 的本地化名由自身索引提供）→ 只用 `kMDItemFSName`。
实测（CLI，含索引端过滤 + 本地排序）：`isinteger` 283ms、`Old_Homebrew` 286ms、`密码` 281ms、
`snippet` 303ms、中文人名 321ms、`pdf`（极常见子串）509ms。

**仍存在的边界**（已告知用户）：外置卷不在范围内（本机只有 Macintosh HD）；只按**文件名**匹配、
不搜内容；`~/Library/Application Support` / 缓存 / 容器按设计被过滤；面板暂无编辑搜索范围的界面。

### 12.1 搜索范围设置界面（同日追加）

设置窗口新增第三个标签页「搜索范围」：

- 开关「搜索整个家目录」= `searchHomeFolder`；
- 额外目录列表，用 `NSOpenPanel`（可多选、只能选目录）添加，而不是手打路径；
- **实际生效范围预览**：把 `~` 缩写成 `~`、标出「已被上级目录覆盖，跳过」、路径不存在时给 ⚠️、
  范围含 `/` 时提示会明显变慢；
- 校验：范围为空且家目录开关关闭时拒绝保存（否则会静默搜不到任何文件）。

新增 CLI 检查 `--scopes`，可打印解析后的生效范围（实测本机 = 仅家目录自身，
因为配置里的四个目录都被家目录覆盖而跳过）。带回第三个标签页的设置窗口回归测试（开→关→再开）仍 PASSED。

## 13. 安装包、自定义热键与多机同步修复（2026-10-05）

### 13.1 安装包（dist/）

`dist/make-dist.sh` → `dist/MacLauncher-<version>.dmg`（0.1.0，580 KB，内含
`MacLauncher.app` + `安装 MacLauncher.command` + `安装说明.txt`）。

- **部署目标（关键）**：build.sh 原先没有 `-target`，二进制的 `minos` 等于 SDK 的 **26.0**
  ——即只能在 macOS 26+ 运行，这是「装到别的 Mac 上打不开」的根因。现为
  `-target arm64-apple-macos13.0`（实测 minos 13.0）。
- **只支持 Apple Silicon**（用户决定不为 Intel 构建）。x86_64 切片实测可以编译通过，
  需要时用 `TARGET_ARCH=x86_64` 编译 + `lipo -create` 合并即可，但未纳入发布，也未做真机验证。
- **不用 .pkg**：没有 Developer ID 的 .pkg 会被 Gatekeeper 直接拒绝。安装器改为
  `.command` 脚本：`ditto` 拷贝到 `~/Applications`（保留签名）→ 清 `com.apple.quarantine`
  → 写 `~/Library/LaunchAgents/com.luyizhou.maclauncher.plist`（路径按本机生成）→ 启动 App
  → 打开辅助功能设置并打印剩余的两个手动步骤。
- **内置默认配置**：`app/default-config.json`（由本机配置导出）被 build.sh 打进
  `Contents/Resources/`；`Config.load()` 在本地配置不存在时用它，而不是空 `Config()`。
  于是新机器开箱即有 40 个片段、7 个引擎、搜索范围与热键。

### 13.2 自定义热键

- `HotKey.swift` 重写：原先 `parse()` **只认 Space 键**。现在有完整按键表（字母/数字/符号/
  方向键/F1–F12/导航键），规格串（`ctrl+shift+k`）与显示符号（`⌃⇧K`）互转，并对已知冲突给提示
  （Spotlight、输入法、截图、Alfred）。
- **硬规则**：必须至少含一个修饰键——裸键全局注册会在所有 App 里吞掉那个键。
- `HotKeyRecorderView`：点击方框后按下组合即可录制（Esc 取消）。录制期间**暂停**已注册的热键，
  因为 Carbon 会在任何视图看到按键之前吞掉已注册组合，否则无法重新录制「当前正在用的」热键。
- 设置窗口新增「通用」标签页：热键录制、恢复默认、Dock 图标开关、面板结果数。
  保存后**当场重新注册**；若组合已被其他 App 占用，设置窗口显示失败原因，而不是静默失效。
- CLI 自检：`--hotkey-test`（覆盖 14 种规格：解析、显示、规范化、冲突提示、裸键拒绝）。

### 13.3 多机同步的数据安全修复（重要）

新机器首次运行会用内置默认创建本地配置，其时间戳最新 —— 原来的「较新者胜」于是会**用默认值
覆盖 iCloud 上用户的真实配置**，把在别的 Mac 上做过的修改丢掉。
修法：`Config.createdFromDefaults` 标记「本次是首次创建」，`reconcileShared` 在这种情况下
**优先采用共享配置**并把共享内容写回本地，而不是镜像本地。

验证（用下面两个新测试开关，零风险、不碰真实 iCloud）：

| 场景 | 期望 | 实测 |
| --- | --- | --- |
| A 新机 + iCloud 有数据 | 采用 iCloud，共享不被覆盖 | local 40→5 片段、热键保留；shared 仍 5 ✓ |
| B 新机 + 无 iCloud | 用本地默认播种共享 | shared 被创建为 40 片段 ✓ |
| C 本地有改动且更新 | 仍以本地覆盖共享（原行为） | shared 变成 3 片段 + 新热键 ✓ |

### 13.4 测试开关与首次运行验证

- `MACLAUNCHER_SUPPORT_DIR=<dir>`：把配置/日志重定向到临时目录（`HOME` 无效——Foundation 通过
  用户记录而非环境变量解析家目录，我一开始就踩了这个坑）。
- `MACLAUNCHER_SHARED_CONFIG=<file>`：把「iCloud 共享配置」指向临时文件。
- `--reconcile-test`：同步跑一次同步逻辑并打印本地/共享三方状态。
- 首次运行实测：空配置目录 + App bundle 内的二进制 → 生成 40 片段 / 7 引擎配置，
  `\align`、`\abs`、`;mail` 均可展开，且用户真实配置分毫未动。

## 14. 设置界面打磨：两个被渲染工具抓到的真 bug（2026-10-05）

### 14.1 离线渲染设置窗口

`--render-settings <路径> [标签页序号] [--light]`，与面板评审同样的思路。两个坑：

1. **必须渲染「标签页内的视图」，不能渲染窗口内容视图**：后者会跳过普通控件（标签、复选框、
   步进器），渲染出来几乎空白——我据此差点以为界面没生效。
2. 背景要自己合成（输出保留透明），否则看什么都像「深色」。

一个可靠的判据：渲染出来先看**图标/按钮是否可见**，不要凭「非白像素比例」下结论
（窗口边框会让这个数字虚高，我因此误判过一次）。

### 14.2 抓到并修掉的两个真 bug

| bug | 现象 | 根因 |
| --- | --- | --- |
| 底部控件被裁 | 片段页的 `＋/－`、搜索范围页的按钮与说明**看不见** | 标签页内容区实测 736×420，而代码按 756×452 排版，底部约 32pt 被裁 |
| 表单覆盖片段 | 打开编辑器后第 1 个片段的关键词/名称/内容**变空** | `select()` 先改 `selectedIndex` 再 `selectRowIndexes`，同步触发选中回调 → `commitFields()` 用空表单写回**新选中**的片段 |

修法：① 新建 `SettingsPane`（`layout()` 里按真实 bounds 排版，底部控件贴底），
`paneSize` 改为实测的 736×420、`formWidth` 384；② 引入 `formIndex`/`engineFormIndex`
记录「表单当前属于哪个片段」，并对程序化选中设 `isProgrammaticSelection` 抑制回调；
筛选后手动同步表单与高亮行。

磁盘配置**没有被写坏**：保存时的校验（关键词为空则拒绝保存）挡住了它——这也说明那道校验
不只是防手误，而是真的拦下了一次静默数据损坏。

### 14.3 同时新增的易用性

- **片段筛选框**：按关键词/名称/内容过滤（40 个片段靠滚动找太累），过滤不视为配置改动。
- **未保存修改的关闭确认**：此前关窗会静默丢弃修改。
- 热键录制、Dock 开关、结果数出现在「通用」页（见 §13.2）。

## 15. 一次「以为没更新」的排查（2026-10-05）

用户反馈「本机没看到变化」。事实与过程：

1. 我先用 `strings <binary> | grep 中文` 判断是否装了新版 → **0 处**。这是**工具用错**：
   `strings` 默认只输出 ASCII 可打印串，中文一律看不到。改用
   `LC_ALL=C grep -ac "<中文>" <binary>` 才可信——实测
   「筛选片段 / 搜索整个家目录 / 全局热键 / 有未保存的修改 / render-settings」各 1 处，
   **安装的确实是最新版**。
2. 真正原因：App **已经不在运行**——`pgrep -x MacLauncher` 为空，`launchctl print` 显示
   `state = not running`、`last exit code = 0`。日志显示用户 22:07 打开过新版权设置窗口
   （`settings window opened (40 snippets, 7 engines)`），随后进程干净退出。
   旧配置 `KeepAlive{SuccessfulExit:false}` 只在**非零退出**时重启，于是「一次误按 ⌘Q」
   = 启动器静默死亡：热键无反应，界面自然无从谈起。

两处修正：

- LaunchAgent 改为 `KeepAlive true`（安装器 payload 同步修改）。实测 `kill -TERM` 后
  **1 秒内自动重启**；
- App 内新增 `applicationShouldTerminate`：⌘Q 先弹确认，确认后**先 `launchctl bootout` 自身
  agent 再退出**，所以「主动退出」仍是干净退出、不会被立刻拉回。

教训：判断「装没装上新版」要查可执行文件里的字符串（**用 `grep`，别用 `strings`**），
并确认**进程是否在运行**；「用户看不到变化」最常见的原因不是编译或安装，而是进程根本不在了。













