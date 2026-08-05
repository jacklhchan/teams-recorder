# Windows 功能對等狀態矩陣

此表是 Windows 發行判斷的唯一 live status matrix；「已實作」只表示程式及自動化證據存在，**不**表示硬體驗收、一般可用或 Teams-only 隔離已通過。macOS 行為的來源是根目錄 `README.md` 與 `Sources/RecorderApp/**`。

| 能力 | macOS 行為 | Windows 實作狀態 | 自動化證據 | 人工證據 | 發行 gate | 目前 PR |
| --- | --- | --- | --- | --- | --- | --- |
| 全系統音訊 | ScreenCaptureKit system audio capture | 已實作 WASAPI system loopback 與可選 render endpoint；仍待實體硬體 smoke | native Debug/Release CTest、managed lifecycle tests | 實機開始、停止、可播放 M4A、實際錄音長度 | 實機 duration 成功，沒有未處理例外 | PR #1 基礎；本 branch 沿用 |
| 實體麥克風及混音 | 可選 physical microphone 與錄音同一 capture session | 已實作 endpoint 選取、optional microphone、48 kHz mix；仍待實體麥克風 smoke | managed request/coordinator tests、native timeline tests | 選取實體 microphone，與 system/selected-app 同時錄製 | 可辨識 mic 訊號、可播放輸出及健康計數 | PR #1 基礎；本 branch 沿用 |
| 指定應用程式音訊 | 選取 app 的系統音訊 capture | **Draft 實作**：root PID 加完整 process tree、optional microphone、M4A；程序失效時 fail-closed，絕不轉成全系統 loopback | C ABI contract/smoke、process-loopback、timeline、selected-session facade、managed no-fallback/stale-PID/test-stop tests | [dual-tone isolation script](selected-app-audio-isolation-acceptance.md) | 目標 tone 存在、干擾 tone 不存在；目標退出後為 unavailable/停止且無 fallback | [Draft PR #3](https://github.com/jacklhchan/teams-recorder/pull/3) (`codex/windows-selected-app-audio`) |
| canonical 48 kHz timeline | Timestamped mixer 保持時序 | 已實作 QPC/device-position mapping、silence gaps、mic mute、late/overflow/disconnect counters | deterministic long/silence timeline tests | 長時錄音比對 duration、silence 與健康摘要 | PTS 單調、沒有壓縮 loopback silence | PR #1 基礎；本 branch 延伸 selected source |
| M4A session、library、播放與復原 | MP4 primary，必要時 M4A audio fallback；library/playback | 已實作 AAC/M4A、library、播放、bounded recovery、partial retention | M4A writer fault/recovery tests、storage/recovery tests | 可重開啟播放、來源/寫檔失敗後重啟復原 | 實機 playback 與 fault-recovery smoke 記錄 | PR #1 基礎；本 branch 使用同一 publication path |
| recording-session metadata | 共享 root session contract | 已使用 root Draft 2020-12 contract；selected capture 只寫 `audioSource`、安全 `processName`、`includedProcessTree`，不寫 PID、路徑、命令列、token | schema validation、cross-platform fixture 與 privacy round-trip tests | 檢查產生的 session metadata 不含敏感欄位 | 真實錄製 metadata 通過 schema 且 privacy review | PR #1 contract；本 branch 加 selected metadata |
| 手動／10 秒測試／本機自動擁有權 | manual 不被 auto stop；自動有 countdown/debounce | manual、test、local-automatic 皆進 application lifecycle；10 秒 selected test 可取消且只 stop 一次 | coordinator/lifecycle/local detector state-machine tests | 手動開始、10 秒取消、joined debounce、Teams process 缺失三次才 stop | 記錄 ownership 與取消 smoke；render session 缺失不可自停；heuristic 不可作為 Teams-only isolation 證據 | PR #1 基礎；本 branch 追加 local path |
| 本機 WASAPI heuristic／Recorder mic mute | macOS Third-party App API 功能 | app/CLI 不使用 Teams API pairing；使用者 opt-in 後以本機 Teams playback session 的 joined debounce 提出自動開始。錄音後 render session 缺失視為安靜會議，只有 Teams process 連續缺失三次才自停；一般離會由 floating overlay 手動 stop。mute 只控制 Recorder 的 optional microphone contribution | detector、auto-controller、input-mute tests | 長時間 Teams/non-meeting activity、短暫 silence/rejoin、process exit、mic mute | false positive/negative 可見且 fail-safe；不得讀寫 Teams mute 或宣稱 Teams API 支援 | 本 branch Draft |
| Teams 視窗 WGC + MP4 companion | macOS 視窗影像／影音 session | **Draft implemented，非 GA**：只枚舉 exact `ms-teams` 的安全 top-level HWND，並以 process start time + HWND fail-closed 重驗；WGC BGRA frame 經 bounded queue 寫 H.264/AAC MP4，失敗保留 M4A audio。主視窗與 floating overlay 可在錄音中切換，accepted PTS 產生動態 screen intervals | window-policy、A/V timeline、MP4 writer、metadata/privacy tests | 受控兩帳號 Teams call、window close、resize、DPI/多螢幕、最少一小時錄影、on/off/re-on | MP4 可重開、影音 timestamp/區段正確、video failure 不傷 audio；所有人工 gate 完成前不可稱 GA | 本 branch Draft |
| 虛擬麥克風、signed distribution | macOS 有較完整的對應功能 | Deferred／非目標 | 各自既有 probe 或 feature gate | 不適用 | 不可標示 feature complete | 不在本 branch |

## Selected App 的範圍與隱私界線

- 「指定程序」意指啟動時驗證的 root PID 加其完整 process tree；PID 與 start time 在 application 層再確認一次，以拒絕 PID reuse。
- process loopback 不可用、程序在開始前消失或錄製中退出時，錄製必須停止／fault 並保留可復原的已累積媒體；不得改錄 system loopback。
- process catalog 是 process picker：可選無頂層視窗的有效程序，但有視窗的項目優先顯示；只短暫顯示 app name、process name、PID、可選 window title 及 availability。選取只在 PID 與 start time 均相同時保留；不持久化 executable path 或 command line。
- completed session 的 Windows extension 僅可包含 `audioSource`、`processName`、`includedProcessTree`（舊有 system fixture 的 `endpointId` 仍可讀取）。

## Selected App 人工隔離驗收

執行 [Test-SelectedAppAudioIsolation.ps1](../scripts/Test-SelectedAppAudioIsolation.ps1) 時，使用兩個不同程序產生可區分的 tone。選取目標程序後，錄音必須只含目標 tone（及使用者明確選取的麥克風）；在干擾程序繼續播放時終止目標程序，確認 UI/health 進入 unavailable 或停止，並證明沒有切換成全系統 loopback。

完整步驟、最小 evidence checklist 和失敗判定見 [selected-app-audio-isolation-acceptance.md](selected-app-audio-isolation-acceptance.md)。腳本不讀取產品、不分析錄音、不保存路徑或命令列，也不會產生 isolation pass verdict。

## 明確非目標

本 Draft 不包含一般可用的 Teams 視窗錄影、virtual microphone driver、signed distribution，或任何「一般可用 Teams-only isolation」主張。Teams-window WGC/MP4 僅為 Draft implemented，尚待兩帳號、resize/DPI、長時間與 dynamic on/off/re-on 實機 gate。Windows app/CLI 不提供 Teams Third-party App API pairing 或 Teams mute sync；本機 WASAPI heuristic 必須由使用者 opt-in，並以 joined debounce 限制開始。錄音後 render session 缺失不會自停，只有 Teams process 連續缺失三次才可自停；一般離會應以 floating overlay Stop 完成，且 heuristic 不能作為 Teams mute 或會議真實性的證據。
