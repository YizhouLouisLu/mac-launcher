# MacLauncher

一个极简的 macOS 启动器（Alfred 的替代品），只为三件事而写：**快捷启动/关闭软件与文件**、
**snippets 片段自动展开**、**快捷网络搜索**。

用 Swift + AppKit 直接编译，无 SwiftPM、无 Xcode 工程、无第三方依赖；`build.sh` 里每个非显然的
设计决定都注明了当初实测到的证据（这个项目里几乎每条注释都对应一次踩坑）。

## 环境要求

- Apple Silicon（M 系列）Mac
- macOS 13 或更高（二进制的 `minos` 固定为 13.0）
- 构建需要 Command Line Tools（`xcode-select --install`）

不支持 Intel Mac（只编译 arm64 切片）。

## 安装

从 `dist/` 取 `MacLauncher-<版本>.dmg`：

1. 双击 `安装 MacLauncher.command`（会被装到 `~/Applications`，并注册登录自启）
2. 在系统设置的「辅助功能」里勾选 MacLauncher —— 片段自动展开需要它，**只有这一次**

其它功能（热键、启动应用、文件搜索、网络搜索、设置界面）不需要任何权限。

## 用法

| 操作 | 说明 |
| --- | --- |
| `⌥Space` | 唤出面板（可在 设置 → 通用 里改成任意组合键） |
| 输入名称 | 匹配应用 / 文件 / 文件夹 / 片段 / 命令，回车执行 |
| `q 名称` | 退出正在运行的应用（`⌘↩` 强制退出） |
| `g 关键词` | 用引擎搜索：`g` Google、`bing`、`gh`、`arxiv`、`inspire`、`ia`（INSPIRE 作者检索）、`scholar`、`wiki` |
| 不带关键词输入 | 结果上方出现默认引擎行（`defaultEngineKeyword`，默认 `g`）；若已有精确同名的 App/命令，则该行让到其后，回车仍启动应用 |
| 只输入引擎关键词 | 若该引擎的 URL 里**没有** `{query}`，则直接打开那个网页（直达模式，例如 `mail`）。在 设置 → 搜索引擎 里把 URL 填成目标网址即可新增这类快捷方式 |
| 输入英文单词 | 搜索框下方即时显示音标与中文释义（系统词典，离线 2–3ms），回车开详细小窗 |
| `d 单词` | 强制查词典（该词同时命中很多应用/文件时用） |
| 空搜索框按 `↑` | 调出上一次执行过的查询，继续按 `↑` 往前翻，`↓` 回到空框 |
| `st 关键词` | 股票实时价格（A股/港股/美股；支持代码、中文名、拼音首字母如 `gzmt`） |
| 输入 `st` | 打开自选股票页（实时行情 + 分时图 / 日 K 切换） |
| 输入 `设置` | 打开设置窗口（片段 / 搜索引擎 / 搜索范围 / 通用） |
| 输入 `重载` | 重新读取 config.json 并重建索引 |

**片段自动展开**：在任意 App 里键入以符号开头的关键词即会展开，例如

```
\mcal → \mathcal{|}      \align → 三行 align 环境（光标落在中间行）
\frac → \frac{|}{}       ;mail  → 你的邮箱
```

内容里的 `{cursor}` 表示展开后光标应停在的位置；关键词必须以**非字母数字**开头才会自动展开
（这是安全边界：避免在正常打字时误触发）。

### 引擎的两种模式

| URL 模板 | 模式 | 用法 |
| --- | --- | --- |
| 含 `{query}` | 搜索 | `g 关键词` → 用 Google 搜索 |
| 不含 `{query}` | 直达 | `mail` → 直接打开该网址 |

设置界面里选中一个引擎就会显示它属于哪种模式。直达模式下若关键词后面还跟了文字，
不会静默丢弃那些文字，而是当作普通搜索处理。

## 配置

- 本机配置：`~/Library/Application Support/MacLauncher/config.json`
- 共享配置：iCloud Drive 的 `MacLauncher/config.json`，多台 Mac 按修改时间双向同步；
  **新机器首次运行会优先采用共享配置**，不会用内置默认覆盖你在别的机器上的改动
- 日志：`~/Library/Application Support/MacLauncher/launcher.log`
- 随包自带默认配置（`app/default-config.json`）：新机器开箱即有这些片段与引擎

## 开发

```bash
cd app
./build.sh          # 编译 + 组装 MacLauncher.app（arm64, min macOS 13）
./install.sh        # 装到 ~/Applications 并加载 LaunchAgent
cd .. && ./dist/make-dist.sh   # 生成 dist/MacLauncher-<版本>.dmg
```

源码在 `app/Sources/`：`Palette`（面板）、`Indexer`+`Spotlight`（检索）、`Ranking`（排序）、
`Expander`+`Snippets`（片段展开与注入）、`Config`（配置与同步）、`HotKey`+`HotKeyRecorder`
（全局热键）、`SettingsWindow`（设置界面）、`AppDelegate`（启动装配）。

### 自检入口（不需要 GUI，也不需要屏幕录制权限）

```bash
MacLauncher --query "设置"          # 面板查询与排序
MacLauncher --expand-test '\mcal'   # 片段匹配与展开结果（含光标回退字符数）
MacLauncher --hotkey-test           # 热键规格解析、显示、冲突提示
MacLauncher --scopes                # 解析后的实际搜索范围
MacLauncher --apps                  # 应用索引
# 需要 GUI 进程的两个（注意先用 launchctl bootout 卸下 agent，避免单实例守卫拦下）
MacLauncher --settings-selftest             # 设置窗口开→关→再开（回归）
MacLauncher --render-palette /tmp/p.png     # 把面板渲染成 PNG，用于界面评审
MacLauncher --render-settings /tmp/s.png 0  # 渲染设置窗口的某个标签页
```

测试开关：`MACLAUNCHER_SUPPORT_DIR=<dir>` 把配置/日志重定向到临时目录，
`MACLAUNCHER_SHARED_CONFIG=<file>` 指定「iCloud 共享配置」的位置。

## 更多功能

### 英文单词释义

输入一个英文单词（≥3 字母）时，搜索框正下方即时显示**音标与中文释义**（走 macOS 系统词典，
离线、约 2–3ms、无需权限），回车打开详细小窗：词性胶囊、义项分段、例句缩进，可复制释义或跳转词典 App。
`d 单词` 可强制查询。拼音撞车（如 `ran` 命中中文词典的「蚺 rán」）会被判据挡掉，不会误导。

### 搜索历史

面板刚弹出（搜索框为空）时按 `↑` 依次调出**执行过**的查询；一旦开始打字即退出历史模式，
`↑↓` 恢复为移动结果选中行。历史存 `~/Library/Application Support/MacLauncher/history.json`
（运行状态，独立于配置，可直接删除清空）。

### 股票

`st 关键词` 在下拉里给出实时价与涨跌幅，回车 = **加入自选并跳转自选页**。自选页含列表
（名称/代码/现价/涨跌幅/微型分时）与选中股的**分时图 / 日 K 线**（红涨绿跌），行情 5 秒刷新、
图表 60 秒刷新，休市自动降频。数据来源：腾讯行情/分时/日K（A股、港股）、新浪联想与美股日 K；
免费接口非官方授权，界面内已标注「仅供参考」。

## 已知限制

- 只按**文件名**搜索文件与文件夹，不搜索文件内容
- 外置卷默认不在搜索范围内（设置 → 搜索范围 里可添加）
- 缓存、容器、`node_modules`、`.git` 等噪声路径被自动排除
- Intel Mac 不支持

## 开发记录

`FINDINGS.md`（可行性验证）、`P0-STATUS.md`、`P1-STATUS.md`（按阶段记录每个决定的实测依据、
踩过的坑与仍未解决的部分）。`docs/` 下有面板与设置界面的渲染预览图。
