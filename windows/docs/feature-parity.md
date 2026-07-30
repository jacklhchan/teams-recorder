# 實作狀態更新（2026-07-29）

本文件是原始 parity／驗收規格，表中的 Phase 1 目標不應視為已交付宣告。最新已實作範圍、端對端缺口和實機發行驗證請見 [audio-first MVP 範圍與發行驗證](audio-first-mvp.md)。特別是，MVP 不聲稱 Teams-only process recording、已驗證的 Teams API、視訊、虛擬麥克風、轉寫、安裝程式或 Start Menu 安裝；實體麥克風的成功錄製仍需在發行前驗證。Teams mute sync 與 global hotkey/mute 有預覽程式及測試，仍受 Teams 租戶配對或實體裝置／driver 前置條件限制。

# Windows Migration：功能對等與 Phase 0/1 驗收規格

**狀態：** 實作前規格
**範圍：** 新 Windows 原生應用程式；不修改既有 macOS Swift Package。
**依據：** `README.md`、`Sources/RecorderApp/**`、`Tests/RecorderAppTests/**` 與既有 Teams／錄影規格。

目前 Phase 0 的首輪實機結果記錄於
[`2026-07-28-wasapi-probe-results.md`](2026-07-28-wasapi-probe-results.md)：
system loopback、WAV publish及process-loopback activation已通過短 probe；
physical mic及process-only隔離仍未通過 gate。

## 成功定義

Windows 不是把 SwiftUI 或 ScreenCaptureKit 逐字移植。Phase 1 的完成條件是：使用者可在 Windows 上選擇全系統音訊或指定應用程式、選擇麥克風、看到即時健康資訊、可靠地完成本機音訊錄音、在程式內播放及管理 session，並在故障時保留可播放的音訊。所有跨平台 session 檔案均須能被兩端安全讀取；未驗證的 Windows 能力不得出現在產品承諾中。

## 來源功能矩陣

| 來源行為（目前 macOS） | 來源證據 | Windows 對應／決策 | 優先級 | 目標階段與驗收 gate |
| --- | --- | --- | --- | --- |
| 全系統音訊錄製 | README；`ScreenCaptureSource.swift` | WASAPI loopback capture adapter；以實機 loopback 測試為先決 | P0 | P0 probe：連續 30 分鐘、48 kHz stereo、無未處理例外；P1：錄製可播放並有訊號健康結果 |
| 指定 app 音訊 | README；`CaptureSelectionResolver`、`ScreenCaptureSource` | **待驗證** Windows process loopback capture；不得以混入全系統音訊冒充 app-only | P0 | P0：目標 app 有聲、另一 app 有聲時輸出只含目標；失敗即以明確 unavailable 狀態降級，不能進 P1 承諾 |
| 選擇實體麥克風 | README；`AudioDevice.swift` | WASAPI capture device enumeration + capture adapter | P0 | P1：列舉、儲存 endpoint ID、實機 10 秒錄音有 mic 訊號 |
| 48 kHz 時戳混音 | `TimestampedAudioMixer.swift` | 平台無關核心的 frame/sample-clock mixer；輸入須正規化為 48 kHz stereo float PCM | P0 | P1：單元測試覆蓋亂序、缺口、靜音、麥克風 mute、來源斷線；輸出 PTS 單調 |
| 一個 session 一個完成媒體檔 | README；`MixedAudioWriter.swift` | Media Foundation sink writer 產出 `recording.m4a`（AAC），先以 audio-only 為可靠基線 | P0 | P1：開始／停止／重複停止均只完成一次，檔案可由 Windows Media Foundation 重新開啟 |
| 10 秒測試錄音、立即播放與健康摘要 | README；`AudioHealthAdvisor` | 相同工作流程；Windows 播放 adapter | P0 | P1：system/mic 訊號、clipping、dropped buffer 及失敗訊息可見；測試自行停止後可播放 |
| session library、標題、標籤、最愛、開啟資料夾、移至資源回收筒 | `RecordingSession.swift`、`RecordingLibrary.swift` | 採用同一 session folder 與 JSON contract；Windows Shell recycle-bin adapter | P1 | P1：掃描只接受白名單 session folder 與 regular file；metadata 壞欄位不破壞其他欄位 |
| 已完成音訊播放與 seek | README；`PlaybackCoordinator.swift` | Media Foundation playback adapter | P1 | P1：對 m4a session 可播放、暫停、seek、停止；不要求跨平台精確 frame seek |
| 儲存空間政策 | `RecordingStoragePolicy.swift` | 以目標 volume 可用空間實作同一門檻：warn 5 GiB、video 不足 1 GiB 則 audio-only、audio 少於 256 MiB 停止 | P0 | P1：邊界值單測；無法查詢容量時阻擋開始並明示原因 |
| 中斷後音訊復原 | `IncompleteSessionRecovery.swift` | 啟動時僅嘗試提升已驗證、同資料夾的 audio backup；不得覆寫現有 final | P1 | P1：crash fixture 能復原；目的檔存在、backup 無效、路徑重解析失敗均不覆寫 |
| 手動匯入音訊轉寫 | `ManualTranscriptionImporter` | 先保留檔案匯入與 session shell；轉寫執行器後置 | P2 | Deferred（見下） |
| 本機 Qwen/oMLX 檔案型轉寫 | README；`TranscriptionProcess.swift` | Windows model/runtime、FFmpeg 散布與憑證策略皆未定，不複製 macOS shell script | P2 | Deferred；先維持既有 transcript/read state JSON 相容 |
| Teams Third-party App API mute sync | README；`TeamsThirdPartyAPI.swift`、`TeamsMuteSyncClient.swift` | Windows 已有 local WebSocket、DPAPI token、pairing 與絕對 mute/fail-closed 預覽層；仍必須在可用 Teams tenant/client 完成 pairing 核准與會議實測 | P2 | Preview，非 MVP release gate；不得以 UI 開關宣稱已支援 Teams API 或 Teams mute 控制 |
| Teams 自動錄製 | `TeamsAutoMeetingCoordinator` 與其設計規格 | 依賴上一項 authoritative meeting state，且不屬錄音核心 | P2 | Deferred |
| Teams 視窗錄影與 runtime 切換 | `ScreenCaptureSource.swift`、`RecordingMediaCoordinator.swift`、viability gate | Windows.Graphics.Capture + Media Foundation 的可行性須獨立驗證；此主機的 WGC probe 已失敗，Phase 1 不交付 | P2 | Deferred；目前僅有失敗的可行性證據，不能標記 feature complete 或泛化到其他主機 |
| 虛擬麥克風與硬體 mute | README；`VirtualMic/**`、`MicrophoneMuteCoordinator.swift` | app 可偵測受信任 endpoint identity，但需要簽署並已安裝的 Windows audio driver / virtual endpoint，且與 app 進程分離 | P3 | Deferred；driver 供應、安裝、音訊路由與硬體 mute 實測皆為必要前置條件 |
| 全域 hotkey | README；`GlobalHotKeyManager.swift` | Windows `RegisterHotKey` 的 `Ctrl+Alt+M` registrar 與獨立 local/input mute 狀態已有程式和測試 | P3 | Preview；尚未作為硬體 mute、Teams sync 或虛擬麥克風可用性的證據 |

P0 表示「無此能力不能聲稱 Windows MVP 可錄音」；P1 表示第一個可交付的 Windows MVP；P2/P3 不是拒絕，而是有明確前置條件後的後續工作。

## Phase 0：可行性與骨架（必須先完成）

Phase 0 只產出探針程式、測試、決策紀錄及空的可替換 adapter；不把未證實的媒體路徑接入產品 UI。

1. 建立 Windows solution：UI、Application、Domain、Infrastructure、Tests 五個專案或等價分層；Domain 不得參考 WinRT、COM、Media Foundation 或 UI assemblies。
2. 以每個 adapter 可替換的 interface 建立 fake，先移植純邏輯測試：capture lifecycle、storage decision、session metadata 寬容解碼、recovery 的 no-replace 行為、audio timeline/mixer。
3. 完成受控實機 probe：WASAPI loopback、選取麥克風、process loopback（若系統版本支援）。每次 probe 記錄 Windows edition/build、音訊 endpoint、sample rate、目標程式、持續時間、輸入是否非靜音、丟失／斷線／HRESULT 與產物雜湊；資料不得含錄音內容或 token。
4. 選擇 Media Foundation 寫檔路徑，驗證 m4a 可重新開啟；同時故意中斷 writer，證明 audio backup 不會覆寫既有 final。
5. 寫入 ADR：process loopback 是否可靠可用、是否需要最低 Windows build、無法支援時的 UI 文案與 release scope。沒有通過 app-only 隔離 probe，即從 Phase 1 產品要求移除「Selected App」。

### Phase 0 exit gate

- 所有純邏輯單元測試通過，且至少包含 stale lifecycle completion、時間倒退／重複 PTS、空間三門檻、metadata malformed field、現存 final 不覆寫。
- 全系統 loopback、麥克風、m4a 重新開啟與 crash recovery probe 各至少一次成功；失敗有可重現證據與明確結論。
- process loopback 有通過隔離證據，或已正式降級為 Phase 1 不提供的選項。
- 不得在此階段引入 Teams、螢幕影像、虛擬麥克風或模型下載。

## Phase 1：audio-first Windows MVP

交付範圍：裝置與來源選擇、permissions/readiness、開始／停止、音量／波形與健康摘要、10 秒測試、m4a session 寫入、library／metadata、播放／seek、容量政策與復原。選定 app 音訊只在 Phase 0 gate 已通過時顯示；否則只提供全系統音訊並說明限制。

### Phase 1 產品驗收

1. 新使用者拒絕 microphone 或 capture 相關存取時，開始按鈕不會半開 session，畫面提供可操作的修正說明；手動開始才可觸發權限流程。
2. 使用全系統音訊和選定麥克風的 10 秒測試，完成後生成一個可播放 `recording.m4a`、顯示 system/mic 訊號與健康 counters，且不遺留 partial 當作完成品。
3. 連續 60 分鐘 audio-only 錄音後，停止可在既定 timeout 內完成；輸出可重新開啟、音訊 PTS 單調、沒有未處理例外。效能數字與目標硬體須記錄在 release evidence，不把單一機器結果泛化。
4. 在 writer 失敗、來源斷線或強制程序終止 fixture 中，既有完成檔不會消失；若 backup 可驗證，下一次啟動產出 `recording.m4a` 並標示 `recoveredAfterInterruption`。
5. library 不跟隨 symlink/reparse point、不把 `recording.partial.*` 或 backup 視為 session；刪除只針對使用者選中的 session folder。
6. 若 app-only 已納入：目標與干擾 app 同時發聲時，驗收錄音只能量到目標 app；目標程序離開後 UI 顯示需 reconnect／不可用，不得靜默改錄全系統。

## 明確 deferred（不屬 Phase 0/1）

- Teams pairing／tenant 核准與實機 mute sync、meeting-state auto recording。現有 Teams mute UI 是受限預覽，不可當作已驗證的整合。
- Teams / 任意視窗影像錄製、影像與音訊 mux、動態 capture filter、screen interval metadata 的產生。
- Windows 虛擬麥克風 driver、裝置 mute 手勢同步與安裝器權限提升；driver 已簽署／安裝及 endpoint 可用是任何整合的必要前置條件。
- **刻意 deferred：** Qwen ASR、本機／遠端模型散布、FFmpeg packaging、串流轉寫、speaker diarization。
- 全域 hotkey 的產品化／實機驗證、企業部署／簽章／自動更新、跨裝置同步或雲端上傳。

Deferred 功能可讀取既有相容 metadata，但不會在 Phase 1 產生其宣稱的資料。例如 audio-only session 必須寫 `mediaKind: "audio"`、空 `screenIntervals`，且沒有 `capturedTeamsWindow`。
