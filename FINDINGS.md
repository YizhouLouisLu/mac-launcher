# macOS 启动器 spike 结论

日期：2026-10-05　机器：M4 Max / macOS 26.6.2 / arm64
目的：在做完整实现前，用最小代码验证方案所依赖的三个 API 假设，以及工具链是否可用。

---

## 0. 环境阻塞：本机 Swift 工具链已损坏

三条症状，同源：

| 现象 | 证据 |
| --- | --- |
| `swift build` 失败 | manifest 链接失败：`PackageDescription.Package.__allocating_init(...)` 未定义符号 |
| `swiftc` 失败 | `redefinition of module 'SwiftBridging'`：`.../usr/include/swift/module.modulemap` 与 `.../usr/include/swift/bridging.modulemap` 重复定义同一模块 |
| 任何 `-sdk` 都失败 | 7 个 SDK（26.2 / 26 / 15.4 / 15 / 14.4 / 13.3）全部报 `SDK is not supported by the compiler`，属上一条的下游症状 |

CLT 版本 `com.apple.pkg.CLTools_Executables 26.2.0.0.1.1764812424`，install-time 2026-01-16 → 半更新的损坏安装。

修复（需要 sudo，本次未执行）：

```
sudo rm -rf /Library/Developer/CommandLineTools
sudo xcode-select --install
```

或安装完整 Xcode（约 10 GB）。

`clang`（Objective-C）完全正常，且 `actool`/`ibtool` 均在 CLT 内，因此 spike 改用 Objective-C 完成——被测 API 是 AppKit / Carbon / CoreGraphics，与语言无关。

项目内两份实现：
- `spike-objc/`　**可运行、已验证**（本次结论来源）
- `spike/`　　　　Swift 版本，等 CLT 修好后作为正式实现起点

---

## 1. 三个假设的验证结果：全部通过

| 假设 | 结论 | 决定证据 |
| --- | --- | --- |
| **A1** 无边框面板能拿到键盘焦点 | **通过（但必须激活 App）** | `useRegularPolicy=0`、`NSApp.isActive=1 panel.isKeyWindow=1`、`typedIntoPanel="accessory-input"` |
| **A2** Cmd+V 注入到恢复后的前台 App | **通过（三种方式）** | 靶子日志 `Sink paste: invoked (pasteboard="LaunchSpike-OK ...")` → `sink.txt` 内容一致 |
| **A3** Option+Space 可注册为全局热键 | **通过（Alfred 在运行时也成功）** | `RegisterEventHotKey Option+Space (id=1) -> OK` 且 `>>> hotkey fired id=1` |

### A1 的关键细节（重要）

纯 nonactivating 路径**不成立**：不调用 `activate` 时，面板在 `+0ms` 拿到 key，`+150ms` 就丢失，`NSApp.isActive` 回到 0，输入与 Return 都进不了面板。

```
showPanel activating=0 previousApp=Sink
  +0ms:   NSApp.isActive=1 panel.isKeyWindow=1
  +150ms: NSApp.isActive=0 panel.isKeyWindow=0     ← 焦点丢失，A1 失败
```

正确配方是**保留 `.accessory`（无 Dock 图标、不接管菜单栏）但显式激活 App**：

```
showPanel activating=1 previousApp=Sink
  useRegularPolicy=0
  +150ms: NSApp.isActive=1 panel.isKeyWindow=1 frontmost=LaunchSpike
action Enter: typedIntoPanel="accessory-input"      ← 面板确实收到合成键盘输入
sink.txt = [LaunchSpike-OK 2026-10-05T08:49:35Z]    ← 且注入成功
```

即：不需要临时切 `.regular`，因此不会出现 Dock 图标闪动。

### A2 的关键细节（重要，且最初误判过一次）

第一轮 A2 判定为「失败」，实际是**测试靶子本身没有主菜单**：AppKit 里 Cmd+V 是经主菜单的 key equivalent 路由到 `paste:` 的，无菜单的 App 永远不会粘贴。给靶子补上 Edit 菜单后三种注入方式全部成功：

| 注入方式 | 结果 |
| --- | --- |
| `CGEventPost(kCGHIDEventTap)` + Cmd+V | 成功 |
| `CGEventPostToPid(pid)` + Cmd+V | 成功 |
| Unicode 逐字输入（`CGEventKeyboardSetUnicodeString`） | 成功，且不依赖剪贴板与菜单 |

产品含义：主路径用 Cmd+V，但**保留「逐字输入」作为后备**——它绕开剪贴板（不干扰用户现有内容）也绕开目标 App 的菜单绑定。

延迟要求：恢复目标 App 后需等 **400–500 ms** 再 post；400 ms 与 900 ms 均成功。

### 其他一并验证的行为

- **Esc 关闭**：必须在 `NSTextFieldDelegate` 的 `control:textView:doCommandBySelector:` 里处理 `cancelOperation:`。在 `NSTextField` 子类里 override `keyDown:` **收不到** Esc——编辑期间按键由 field editor（NSTextView）处理。实测 `escape pressed -> hide` 生效。
- **TCC 身份**：从 shell 直接启动时 `AXIsProcessTrusted=1`（继承启动者的授权）；经 LaunchServices（`open`，即真实分发路径）启动时 `AXIsProcessTrusted=0`，需**每台机器手工授权一次**。
- **热键无冲突**：Alfred 5 正在运行（pid 1462）时 Option+Space 仍注册成功并成功触发，因此**不需要停用 Alfred**。

---

## 2. 由此确定的实现配方

```
面板      NSPanel, styleMask [.nonactivatingPanel, .borderless]
          level = .floating, isFloatingPanel, hidesOnDeactivate = NO
          collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
          canBecomeKey → true, canBecomeMain → false
呼出      activationPolicy 保持 .accessory
          [NSApp activateIgnoringOtherApps:YES]
          panel.makeKeyAndOrderFront + makeFirstResponder(textField)
关闭      delegate: control(_:textView:doCommandBySelector:) / cancelOperation:
热键      Carbon RegisterEventHotKey（不需要 Accessibility 权限）
注入      隐藏面板 → 激活记录的 previousApp → 等 400–500 ms → post Cmd+V
          剪贴板保存 → 写入 → post → 还原
          后备：CGEventPostToPid；再后备：Unicode 逐字输入
权限      Accessibility，每台机器手工授权一次
```

---

## 3. 未验证 / 需人工确认

1. **视觉观感**：面板出现时菜单栏与其他 App 窗口的实际观感。我只能读程序状态，看不到屏幕——这一项需要你目视确认。
2. **重建后 ad-hoc 签名的授权是否失效**：推测 cdhash 变化会导致 TCC 授权失效、每次重编译都要重新授权；**未实测**。若成立，用钥匙串自建签名证书可消除。
3. **真实按键**（非合成事件）触发 Option+Space：合成事件已验证，真人按键未测。
4. **中文输入法激活状态下**的 Cmd+V 注入行为。

---

## 4. 对估算的影响

三个高风险假设现已全部落地为确定配方，P2（snippets 注入）不再是「不知道能不能做」，而是「照配方实现」。剩余工作量重估：**14–24 人日、2M–5M token**（原估 16–27 人日、2.5M–6M）。此估算不含修复 CLT 本身（你侧约 10 分钟，或下载 Xcode）。

## 5. 复现方式

```
cd spike-objc
./build.sh                        # 编译 LaunchSpike.app / Sink.app / keydriver
./build/LaunchSpike.app/Contents/MacOS/LaunchSpike &   # 需继承 shell 的 AX 授权才可自动注入
open -n build/Sink.app
./build/keydriver activate:com.luyizhou.sink sleep:700 hotkey-ctrl sleep:900 \
                   text:panel-input sleep:400 return sleep:1500
cat /tmp/sink.txt                 # 期望 = LaunchSpike-OK <时间戳>
cat ~/Library/Application\ Support/LaunchSpike/spike.log
```

`keydriver` 步骤语法：`hotkey` / `hotkey-ctrl` / `text:<s>` / `return` / `esc` / `sleep:<ms>` / `activate:<bundle-id>` / `copy:<s>`
