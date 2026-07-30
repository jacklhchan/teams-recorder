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
| 手動／10 秒測試／Teams 自動擁有權 | manual 不被 auto stop；Teams 自動有 countdown/debounce | manual、test、Teams-automatic 皆進 application lifecycle；10 秒 selected test 可取消且只 stop 一次 | coordinator/lifecycle/Teams state-machine tests | 手動開始、10 秒取消、Teams Preview pairing 狀態 | 記錄 ownership 與取消 smoke；Teams 仍不是 Selected App 的隔離證據 | PR #1 基礎；本 branch 追加 selected path |
| Teams API／mute／自動錄製 | macOS Third-party App API 功能 | Windows 僅 Preview，非本 PR 交付或 release 主張 | protocol/transport state tests | per-tenant pairing 與 meeting-state probe | 另立 Teams API gate；不可作為 Teams-only isolation 或 GA 證明 | PR #1 Preview，非本 branch scope |
| 視訊、WGC product capture、虛擬麥克風、轉錄、signed distribution | macOS 有較完整的對應功能 | Deferred／非目標 | 僅有各自的 probe 或 feature gate | 不適用 | 不可標示 feature complete | 不在本 branch |

## Selected App 的範圍與隱私界線

- 「指定程序」意指啟動時驗證的 root PID 加其完整 process tree；PID 與 start time 在 application 層再確認一次，以拒絕 PID reuse。
- process loopback 不可用、程序在開始前消失或錄製中退出時，錄製必須停止／fault 並保留可復原的已累積媒體；不得改錄 system loopback。
- process catalog 只短暫顯示 app name、process name、PID、可選 window title 及 availability。選取只在 PID 與 start time 均相同時保留；不持久化 executable path 或 command line。
- completed session 的 Windows extension 僅可包含 `audioSource`、`processName`、`includedProcessTree`（舊有 system fixture 的 `endpointId` 仍可讀取）。

## Selected App 人工隔離驗收

執行 [Test-SelectedAppAudioIsolation.ps1](../scripts/Test-SelectedAppAudioIsolation.ps1) 時，使用兩個不同程序產生可區分的 tone。選取目標程序後，錄音必須只含目標 tone（及使用者明確選取的麥克風）；在干擾程序繼續播放時終止目標程序，確認 UI/health 進入 unavailable 或停止，並證明沒有切換成全系統 loopback。

完整步驟、最小 evidence checklist 和失敗判定見 [selected-app-audio-isolation-acceptance.md](selected-app-audio-isolation-acceptance.md)。腳本不讀取產品、不分析錄音、不保存路徑或命令列，也不會產生 isolation pass verdict。

## 明確非目標

本 Draft 不包含 waveform UI、ASR/轉錄、video/WGC product capture、virtual microphone driver、signed distribution，或任何「一般可用 Teams-only isolation」主張。Teams pairing、mute sync 與自動錄製仍然是獨立 Preview，不能取代 selected-app dual-tone gate。
