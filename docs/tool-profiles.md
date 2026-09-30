# Tool profiles

把一台電腦借給 `openab-pty` session 時（reverse attach，`POST /attach {profile}`），
**profile 決定那個 session 裡的 agent 能看到、能呼叫哪些工具**。用 IAM 來類比：profile
就像 managed policy，grant 就是把 policy attach 到一個 principal（session）上，lease
（1–24 小時）則相當於 STS session duration。

- 過濾在**被借出的電腦端**執行（macOS：`ToolProfile.swift`；Linux：`poc/reverse-attach-linux/src/mcp.rs`），
  pod 裡的 session 改不了。
- 不在 profile 裡的工具，`tools/list` 不會列出；硬呼叫 `tools/call` 會得到 *unknown tool*，
  和這個工具根本不存在時的回應一樣。
- 未知的 profile 名稱一律拒絕（HTTP 400；存在磁碟上的 grant 則在重新載入時丟棄），
  不會被當成 `owner` 放寬。

> ⚠️ **只有 `observe` 是安全邊界。** GUI 控制等同 shell：`osascript` 能跑
> `do shell script`，`key` 能在終端機裡打字，`mouse` 能開終端機。所以 `desktop` 雖然拿掉了
> `exec*`，權限上並沒有變小，只是少了一個方便的入口（見
> [#45](https://github.com/openabdev/instance-mcp/issues/45)）。要給完整控制權時，請借一台
> **專用的電腦**，例如 Linux hands node 或拋棄式的機器／VM，不要借你正在用的那台。
> `ProfileBoundaryTests` 會擋下任何宣稱比 shell 窄、卻允許能拿到 shell 的工具的 profile。

## 1. 目前可用的 profiles

| Profile | 舊名 / 別名 | 等同 shell? | macOS 工具數 | Linux 工具數 | 用途 |
|---|---|---|---|---|---|
| `owner` | — | 是（直接） | 42 | 37 | 電腦主人自己的 CLI；全部工具 |
| `desktop` | `sandbox`（仍接受，一律視為 `desktop`） | **是**（透過 GUI） | 20 | 20 | 讓 agent 操作桌面：看、點、打字、AppleScript、瀏覽器互動 |
| `observe` | — | **否** | 2 | 2 | 只能看不能動：系統資訊與截圖 |

工具數包含瀏覽器工具（`browser_*`），前提是那台電腦有設定 Playwright upstream
（`--upstream browser=…`；macmini、rpi1、black 都有）。沒有 upstream 時，`owner` 在 macOS
上是 10 個工具、在 Linux 上是 5 個；`desktop` 在兩邊都是 5 個；`observe` 不受影響。

清單取自 2026-09-30 macmini（instance-mcp，macOS）與 black（Linux hands node）的實際
`tools/list`，再依本 repo 的 profile 規則過濾。

## 2. 各 profile 的完整工具清單

### `owner`

**macOS — 42 個**

| 類別 | 工具 |
|---|---|
| 系統 | `sys_info` |
| Shell | `exec`, `exec_start`, `exec_poll`, `exec_list`, `exec_cancel` |
| 畫面 / 輸入 | `screenshot`, `mouse`, `key`, `osascript` |
| 瀏覽器（32） | `browser_navigate`, `browser_navigate_back`, `browser_snapshot`, `browser_find`, `browser_click`, `browser_type`, `browser_fill_form`, `browser_press_key`, `browser_hover`, `browser_select_option`, `browser_wait_for`, `browser_tabs`, `browser_take_screenshot`, `browser_console_messages`, `browser_resize`, `browser_evaluate`, `browser_run_code_unsafe`, `browser_file_upload`, `browser_drop`, `browser_pdf_save`, `browser_network_requests`, `browser_network_request`, `browser_handle_dialog`, `browser_emulate_media`, `browser_close`, `browser_drag`, `browser_mouse_move_xy`, `browser_mouse_click_xy`, `browser_mouse_drag_xy`, `browser_mouse_down`, `browser_mouse_up`, `browser_mouse_wheel` |

**Linux — 37 個**

| 類別 | 工具 |
|---|---|
| 系統 | `sys_info` |
| Shell | `bash` |
| 畫面 / 輸入 | `screenshot`, `mouse`, `key` |
| 瀏覽器（32） | 與 macOS 相同的 32 個 |

Linux 沒有 `osascript`；`bash` 對應 macOS 的 `exec*`。

### `desktop`（舊名 `sandbox`）

**macOS — 20 個**

| 類別 | 工具 |
|---|---|
| 系統 | `sys_info` |
| 畫面 / 輸入 | `screenshot`, `mouse`, `key`, `osascript` |
| 瀏覽器（15） | `browser_navigate`, `browser_navigate_back`, `browser_snapshot`, `browser_find`, `browser_click`, `browser_type`, `browser_fill_form`, `browser_press_key`, `browser_hover`, `browser_select_option`, `browser_wait_for`, `browser_tabs`, `browser_take_screenshot`, `browser_console_messages`, `browser_resize` |

**Linux — 20 個**

| 類別 | 工具 |
|---|---|
| 系統 | `sys_info` |
| Shell | `bash` |
| 畫面 / 輸入 | `screenshot`, `mouse`, `key` |
| 瀏覽器（15） | 與 macOS `desktop` 相同的 15 個 |

瀏覽器工具的過濾只限制「工具」，不限制瀏覽器本身：瀏覽器用的是那台電腦**持久化的
profile**，帶著已登入網站的 cookie，而且能連到那台電腦能連到的網路，包括 localhost 和
tailnet。

### `observe`（新）

**macOS 與 Linux — 2 個**

| 類別 | 工具 |
|---|---|
| 系統 | `sys_info` |
| 畫面 | `screenshot` |

這是 allowlist：之後新增的任何工具（包括 local 工具與 upstream 瀏覽器工具），在
`observe` 下預設都不給，除非明確加進 `ToolProfile.observeTools`（Linux：`OBSERVE_TOOLS`）。
截圖仍會洩漏螢幕上顯示的內容，但 agent 沒辦法改變任何東西。

## 3. 和上一個 profile 比起來少了什麼

### `owner` → `desktop`

| | macOS | Linux |
|---|---|---|
| 少了 local 工具 | `exec`, `exec_start`, `exec_poll`, `exec_list`, `exec_cancel`（5） | 無（`bash` 保留，理由見下） |
| 少了瀏覽器工具（17） | `browser_evaluate`, `browser_run_code_unsafe`（任意 JavaScript）；`browser_file_upload`, `browser_drop`, `browser_pdf_save`（檔案系統）；`browser_network_requests`, `browser_network_request`（網路監看）；`browser_handle_dialog`, `browser_emulate_media`, `browser_close`；`browser_drag`, `browser_mouse_move_xy`, `browser_mouse_click_xy`, `browser_mouse_drag_xy`, `browser_mouse_down`, `browser_mouse_up`, `browser_mouse_wheel`（以座標操作的原始滑鼠） | 同左 17 個 |
| 總數 | 42 → 20 | 37 → 20 |
| **權限上是否變小** | **否**：`osascript` / `key` / `mouse` 仍能取得桌面使用者的 shell | **否**：`bash` 本身就是 shell |

Linux 的 `desktop` 保留 `bash`，因為 `mouse` 和 `key` 本來就能打開終端機。拿掉它只會讓
agent 比較不方便，不會降低權限，就不假裝它是限制。

### `desktop` → `observe`

| | macOS | Linux |
|---|---|---|
| 少了 local 工具 | `mouse`, `key`, `osascript`（3） | `bash`, `mouse`, `key`（3） |
| 少了瀏覽器工具 | 全部 15 個 | 全部 15 個 |
| 總數 | 20 → 2 | 20 → 2 |
| **權限上是否變小** | **是**：沒有任何能輸入、執行或改變狀態的工具 | **是** |

## 相容性與現況

- **線上值**：`owner`、`desktop`、`observe`。`sandbox` 仍然接受，視為 `desktop`；grant
  一律以新名稱回報。
- **OpenAB Connect / Remote**：目前 UI 只提供 Desktop 與 Owner 兩個選項，送出的值是
  `sandbox`／`owner`，這樣舊版的 instance-mcp 才不會回 400。等所有電腦都更新到支援
  `desktop`／`observe` 的版本後，client 才會改送新名稱，並加上 Observe 選項
  （oablab/oab-pty-mac#76）。
- **降版**：新版存下的 grant 會寫 `desktop` 或 `observe`。舊版 daemon 載入時會把它當成
  未知 profile 丟棄，grant 因此結束，不會被放寬。

## 計畫中（尚未提供）

- **`browser`**：只有 Playwright 工具，每個 grant 使用**用完即丟**的瀏覽器 profile，不含
  `browser_evaluate`。它的邊界來自瀏覽器本身，但仍能連到那台電腦的網路，文件要照實寫。
- **有型別的 App 操作**：用「開啟某個 App」「點某個選單項目」「列出視窗」這類小工具，搭配
  bundle ID 白名單，取代受限層級裡通用的 `osascript`。白名單要排除 Terminal、iTerm、
  Script Editor、系統設定。
- **Custom policy**：grant 時直接帶 allow／deny 清單。它一樣要經過 `ProfileBoundaryTests`
  的提權檢查，只要含有能拿到 shell 的工具，就自動標示為「等同 shell」。
- **VM**：借出拋棄式的 macOS VM，而不是宿主機本身。

以上都在 [#45](https://github.com/openabdev/instance-mcp/issues/45) 追蹤。
