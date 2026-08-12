# Windows 功能對等狀態矩陣

## PR #11 integration update

- Teams Third-party App API pairing, token consumption, and product commands
  are retired. The Windows runtime uses only an explicit local WASAPI
  render-session heuristic for automatic-recording candidates.
- The local heuristic requires three healthy active observations to propose a
  start. Render silence and probe failure never stop capture; only three
  healthy observations with no Teams process can propose a stop.
- Recorder microphone mute remains recorder-owned. An explicit Preview opt-in
  may read the exact Teams `microphone-button` and gate the physical-microphone
  contribution; it never invokes or changes a Teams control.
- Exact Teams-window WGC uses one crash-safe fragmented MP4. The floating
  overlay can enable/disable pixels while audio continues; disabled, missing,
  and transition intervals are privacy-black and never fall back to another
  window or the desktop.
- System loopback includes linear headroom, explicit-discontinuity smoothing,
  conservative isolated-impulse repair, and device-confirmed QPC jitter
  handling. Real Teams call/noise and physical-microphone evidence remain
  manual release gates.

此表是 Windows 發行判斷的唯一 live status matrix；「已實作」只表示程式及自動化證據存在，**不**表示硬體驗收、一般可用或 Teams-only 隔離已通過。macOS 行為的來源是根目錄 `README.md` 與 `Sources/RecorderApp/**`。

| 能力 | macOS 行為 | Windows 實作狀態 | 自動化證據 | 人工證據 | 發行 gate | 目前 PR |
| --- | --- | --- | --- | --- | --- | --- |
| 全系統音訊 | ScreenCaptureKit system audio capture | 已實作 WASAPI system loopback 與可選 render endpoint；仍待實體硬體 smoke | native Debug/Release CTest、managed lifecycle tests | 實機開始、停止、可播放 M4A、實際錄音長度 | 實機 duration 成功，沒有未處理例外 | PR #1 基礎；本 branch 沿用 |
| 實體麥克風及混音 | 可選 physical microphone 與錄音同一 capture session | 已實作 endpoint 選取、optional microphone、48 kHz mix；仍待實體麥克風 smoke | managed request/coordinator tests、native timeline tests | 選取實體 microphone，與 system/selected-app 同時錄製 | 可辨識 mic 訊號、可播放輸出及健康計數 | PR #1 基礎；本 branch 沿用 |
| 指定應用程式音訊 | 選取 app 的系統音訊 capture | **Draft 實作**：root PID 加完整 process tree、optional microphone、M4A；程序失效時 fail-closed，絕不轉成全系統 loopback | C ABI contract/smoke、process-loopback、timeline、selected-session facade、managed no-fallback/stale-PID/test-stop tests | [dual-tone isolation script](selected-app-audio-isolation-acceptance.md) | 目標 tone 存在、干擾 tone 不存在；目標退出後為 unavailable/停止且無 fallback | [Draft PR #3](https://github.com/jacklhchan/teams-recorder/pull/3) (`codex/windows-selected-app-audio`) |
| canonical 48 kHz timeline | Timestamped mixer 保持時序 | 已實作 QPC/device-position mapping、silence gaps、mic mute、late/overflow/disconnect counters | deterministic long/silence timeline tests | 長時錄音比對 duration、silence 與健康摘要 | PTS 單調、沒有壓縮 loopback silence | PR #1 基礎；本 branch 延伸 selected source |
| M4A session、library、播放與復原 | MP4 primary，必要時 M4A audio fallback；library/playback | 已實作 AAC/M4A、library、播放、bounded recovery、partial retention | M4A writer fault/recovery tests、storage/recovery tests | 可重開啟播放、來源/寫檔失敗後重啟復原 | 實機 playback 與 fault-recovery smoke 記錄 | PR #1 基礎；本 branch 使用同一 publication path |
| recording-session metadata | 共享 root session contract | 已使用 root Draft 2020-12 contract；selected capture 只寫 `audioSource`、安全 `processName`、`includedProcessTree`，不寫 PID、路徑、命令列、token | schema validation、cross-platform fixture 與 privacy round-trip tests | 檢查產生的 session metadata 不含敏感欄位 | 真實錄製 metadata 通過 schema 且 privacy review | PR #1 contract；本 branch 加 selected metadata |
| 手動／10 秒測試／Teams 自動擁有權 | manual 不被 auto stop；Teams 自動有 countdown/debounce | manual、test、Teams-automatic 皆進 application lifecycle；自動模式使用明確 opt-in 的本機 WASAPI heuristic，無 Teams API | coordinator/lifecycle/heuristic tests：3 次 active start、silence/probe fault 不 stop、Teams process 3 次不存在才 stop | 真實 Teams 會議開始、沉默、離開與手動停止 smoke | heuristic 不得聲稱 authoritative meeting state；升級後需重新同意 | Draft PR #11 |
| Teams API／mute | macOS 曾使用 Third-party App API | Windows 產品路徑已退役 pairing/token/WebSocket；另有明確 opt-in 的唯讀 Preview，以 exact `microphone-button` 將 Teams mute 加入 Recorder mic gate；不按下／改變 Teams 控制，未知狀態且 Teams audio session active 時 fail-closed | C ABI、exact-label、ambiguous/stale、independent mute causes、settings fresh-consent tests | 1.2.9 Meet now 錄音中驗證 `Unmute mic`→Recorder yes、`Mute mic`→no、再次靜音→yes；離會→no | Teams UI 更新／非英文 action label 會 fail-closed；不得宣稱控制 Teams mute 或使用 API | Draft PR #11 |
| Teams 視窗 WGC／動態畫面 | macOS 有 ScreenCaptureKit 視窗 capture | exact HWND/PID/start-time WGC；同一 crash-safe fMP4 可從浮動窗開關，關閉／失去 target 時寫 privacy-black，音訊不中斷且不 fallback | dynamic route、stale callback、delayed-first-frame、off-on-off-on single-writer tests | 真實 Teams 分享畫面、toggle、target close、crash recovery | 可播放單一 MP4、黑畫面隱私間隙、音訊連續 | Draft PR #11 |

## Selected App 的範圍與隱私界線

- 「指定程序」意指啟動時驗證的 root PID 加其完整 process tree；PID 與 start time 在 application 層再確認一次，以拒絕 PID reuse。
- process loopback 不可用、程序在開始前消失或錄製中退出時，錄製必須停止／fault 並保留可復原的已累積媒體；不得改錄 system loopback。
- process catalog 是 process picker：可選無頂層視窗的有效程序，但有視窗的項目優先顯示；只短暫顯示 app name、process name、PID、可選 window title 及 availability。選取只在 PID 與 start time 均相同時保留；不持久化 executable path 或 command line。
- completed session 的 Windows extension 僅可包含 `audioSource`、`processName`、`includedProcessTree`（舊有 system fixture 的 `endpointId` 仍可讀取）。

## Selected App 人工隔離驗收

執行 [Test-SelectedAppAudioIsolation.ps1](../scripts/Test-SelectedAppAudioIsolation.ps1) 時，使用兩個不同程序產生可區分的 tone。選取目標程序後，錄音必須只含目標 tone（及使用者明確選取的麥克風）；在干擾程序繼續播放時終止目標程序，確認 UI/health 進入 unavailable 或停止，並證明沒有切換成全系統 loopback。

完整步驟、最小 evidence checklist 和失敗判定見 [selected-app-audio-isolation-acceptance.md](selected-app-audio-isolation-acceptance.md)。腳本不讀取產品、不分析錄音、不保存路徑或命令列，也不會產生 isolation pass verdict。

## 明確非目標

本 Draft 不宣稱一般可用 Teams-only isolation、可靠的 Teams meeting-state API，亦不宣稱可寫入或控制 Teams mute。唯讀 mute-follow 仍是 Preview，WGC、ASR 與 virtual-microphone preview 各自保留獨立 release gate；signed distribution 仍未完成。
