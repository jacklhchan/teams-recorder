# 實作狀態更新（2026-07-29）

本文件原為實作前架構規格，部分 Phase 0/1 文字不代表目前的產品承諾。請先以 [audio-first MVP 範圍與發行驗證](audio-first-mvp.md) 為準：它記錄已完成的 system-loopback／可選麥克風 AAC M4A 路徑，以及已接入 WinUI 的 storage、無覆寫 promotion、library、capacity gate 與保守 recovery 流程；實機 release gate 仍未完成。另有 Draft implemented 的 exact Teams top-level window WGC + H.264/AAC MP4 companion；它不是 GA，仍待兩帳號、resize/DPI 和長時間實機 gate。Third-party API 仍是 optional Preview；本機 heuristic 必須 opt-in，且不提供 Teams mute sync。

# Windows Migration：Phase 0/1 架構規格

**狀態：** 實作前規格
**範圍：** Windows audio-first MVP；另含非 GA 的 Teams exact-window WGC/MP4 Draft。虛擬麥克風和轉寫不在本階段。

## Solution 邊界

建議 solution 保持五個可獨立測試的邊界；名稱可調整，但相依方向不可反轉。

```text
Windows UI (WinUI 3)
        │ commands, observable state
Application ── lifecycle / readiness / session use cases
        │ interfaces only
Domain ────── mixer, timeline, storage policy, metadata, recovery decisions
        │ ports
Infrastructure.Windows ── WASAPI / Media Foundation / WinRT / filesystem / shell
        │
Native interop (narrow, audited P/Invoke or C++/WinRT boundary)
```

- **Domain**：無 Windows 特定型別、沒有檔案 I/O、COM、WinRT 或 UI thread 假設；以單元測試覆蓋。移植的語意來源包括 `TimestampedAudioMixer`、`RecordingTimeline`、`RecordingStoragePolicy`、session metadata 與 `CaptureLifecycleGate`。
- **Application**：持有單一 recording lifecycle gate，將 UI intent 序列化為 `refresh`、`permission`、`start`、`test`、`reconnect`、`stop`。每個 async 結果須帶 generation/token；過期 completion 只能釋放自身資源，不能變更目前 session。
- **Infrastructure.Windows**：只有這層可以使用 WASAPI、Windows App SDK／WinRT、Media Foundation、COM、known folders、Shell recycle bin 及 Windows capability/consent APIs。
- **Native interop**：若 C# 無法安全承接 callback、buffer ownership 或 MF writer 細節，以最小 C++/WinRT bridge 封裝；不可把 app state、JSON 或 UI callback 帶入 bridge。

UI 固定採用 C#／WinUI 3 與 stable Windows App SDK，但不是目前
portable-core slice 的 gate。UI 必須支援非同步、可取消 command、非阻塞
meter 更新及 Windows 11 部署；媒體／domain contract 不得依附 WinUI。

## Media：不跨 managed boundary

音訊 buffer、Media Foundation sample、WASAPI `IAudioCaptureClient` 取得的記憶體、COM pointer 和 GPU/影像 surface **不得**跨 managed boundary。Phase 1 只處理 audio；這條規則先固定，避免日後影像擴充重新設計。

```text
WASAPI callback / capture worker
  → native-owned PCM copy + format normalization (48 kHz stereo float)
  → bounded native queue
  → native mixer + Media Foundation writer
  → immutable managed telemetry only
       { sessionGeneration, rms, peak, counters, PTS, error code }
```

具體限制：

- callback 不得直接呼叫 UI、進行磁碟 I/O、等待 lock、配置無界集合，或等待 writer。
- native queue 必須有上限與明確 overflow policy；丟棄數量累計到 health report，不可悄悄丟失。
- managed 層只能收到 scalar meter/health snapshot、狀態事件、已完成 session URL 和已複製的錯誤字串。若需交給 managed 做 waveform，傳送經固定速率下採樣的數值，而非 PCM buffer。
- PCM 寫檔與 backup writer 使用同一 native session generation。停止時先停止 ingress、等待 bounded drain、只 finalize 一次；若 primary writer 失敗，安全 audio backup 繼續嘗試完成。
- Draft WGC path 已在 native side 使用 `Windows.Graphics.Capture`、D3D11 BGRA copy、bounded queue 與 Media Foundation H.264/AAC MP4 companion；managed 只保留 target identity、scalar telemetry 和安全的 metadata。它只能選 exact `ms-teams` 的安全 top-level HWND，且須在開始前以 process start time + HWND 重新驗證。此路徑尚未通過實機 GA gate。

此決策對應 macOS `RecordingMediaCoordinator` 的核心成果：影音 mux 失敗時要保留音訊，而不是讓 managed callback 或 video 失敗破壞整個 session。

## 時間軸與混音 contract

1. canonical clock 是 48,000 frames/second 的整數 sample frame；不得以 UI wall clock 產生寫檔 PTS。
2. 每一來源在進入 mixer 前正規化成 48 kHz、stereo、float PCM，並帶單調 source frame/PTS。混音輸出 block 的 `startFrame` 是唯一 timeline key。
3. 第一個已接受 audio block 建立 source anchor；寫入 PTS 是 `block.startFrame - anchorFrame`。不能以負數、NaN、倒退或 overflow PTS 寫入。
4. 系統與麥克風同時存在時，mixer 只在兩者已知範圍內輸出；其中一來源斷線後，清掉該來源 pending data，剩餘來源可繼續。mic mute 應輸出靜音而不是改寫時間軸。
5. 任何 block gap 都是 health/timeline discontinuity，不能被呈現為連續錄音時間。晚到 block 計為 late frame；queue overflow、格式轉換失敗與來源 disconnect 均記 counters。
6. 未來 video 的 source PTS 必須映射到相同 anchor；重複、倒退及超出 audio 尾端兩秒的畫面一律 drop。此為既有 `RecordingTimeline`（96,000 frames lead）語意的 Windows 對等要求，非 Phase 1 功能。

## Session compatibility contract

Windows 必須讀寫 macOS 的資料夾型 session contract，並採取向前相容、保守產生方式。

```text
<output root>/
  meeting-YYYY-MM-DD-HHMMSS/   # Phase 1 實際產生
    recording.m4a              # 完成品
    recording.audio-backup.m4a # 僅進行中／復原候選，永不列為完成品
    recording-info.json
    transcription-state.json   # 只在日後轉寫啟用時產生
    transcript.txt             # 只在日後人工編輯／轉寫啟用時產生
```

- 可讀 folder prefix：`meeting-`、`test-`、`manual-`；只接受 direct child、directory 與 regular file。不得跟隨 symbolic link 或 NTFS reparse point。
- 媒體選取順序與現況相同：`recording.mp4`、`recording.m4a`，然後已支援的手動音訊副檔名。Phase 1 只產生 `recording.m4a`，但必須可安全顯示含既有 `recording.mp4` 的 session。
- `recording-info.json` 是寬容 JSON。`title` trim；`tags` 是去除空白後的非空字串；獨立壞欄位回退預設值，不能令其他可讀欄位遺失。未知欄位讀取時忽略，寫回時不得假裝理解它們。

最小 schema：

```json
{
  "title": "Weekly sync",
  "tags": ["sales"],
  "isFavorite": false,
  "mediaKind": "audio",
  "screenIntervals": [],
  "recoveryState": "none"
}
```

`mediaKind` 是 `audio` 或 `video`；`recoveryState` 是 `none`、`videoLostAudioPreserved`、`recoveredAfterInterruption`。只有已驗證的 `recording.mp4` 且有非空 `screenIntervals` 時才向 UI 投影為 video；其他情況一律 audio，並清除 stale screen metadata。Draft WGC 不寫 `capturedTeamsWindow`、window title、路徑、PID 或 Teams token。

finalize 採同一目錄內的 temporary/partial → validate → no-replace promotion。若 final 已存在，復原和完成路徑都必須失敗保留證據，絕不覆寫。啟動復原僅提升可驗證的同目錄 audio backup，成功後才標記 `recoveredAfterInterruption`。

## 錯誤、取消與安全原則

### 生命周期

- Start 先完成 readiness：選擇存在、麥克風可用、必要同意已授權、目標 volume capacity 可讀；任一不成立時不建立完成 session，也不啟動隱藏 capture。
- 只有使用者明確的 Start/Test 可以要求同意。自動化功能（目前 deferred）不可彈 permission prompt。
- Stop 可取消進行中的非 stop operation，但重複 Stop 必須冪等；所有 writer finalization 對一個 generation 最多一次。
- 來源失效會產生可行動狀態，不可靜默切換 capture intent。例如 app loopback 失效不能改為全系統 capture。

### 錯誤呈現與診斷

- UI 顯示穩定的使用者訊息及可選動作；診斷保留 HRESULT/exception 類型、adapter、session generation、輸入 endpoint、timeline counters。診斷不記錄 PCM、螢幕內容、Teams token 或完整使用者路徑。
- 寫檔錯誤的優先順序是保存音訊和 session evidence；primary mux/final failure 可降級為可播放 audio backup，但 metadata 必須反映真實結果。
- 容量政策固定：<256 MiB 停止；256 MiB 至 <1 GiB 只容許 audio；1 GiB 至 <5 GiB 警告；>=5 GiB 正常。Phase 1 沒有 video，仍需實作以保證將來不破壞 contract。

### 安全與隱私

- 錄音預設完全本機；Phase 1 不上傳媒體、telemetry、transcript 或 endpoint inventory。
- 資料夾、檔案開啟、刪除與復原均以 canonical path 驗證在使用者選定 output root 內；拒絕 reparse point、非 regular file 與 path traversal。刪除走 Recycle Bin，且僅針對使用者選取 session。
- 不把 Teams pairing token（目前 macOS 暫存於 UserDefaults 的已知限制）複製到 Windows。日後若啟用 Teams，token 需使用 Windows credential protection 並從 log/redaction 清單排除。
- 虛擬麥克風屬 driver 安全邊界；在有簽章、最小權限、安裝／卸載及音訊隔離設計前，禁止納入應用程式權限或 Phase 1 安裝器。

## Phase 0/1 測試責任

| 層次 | 必測內容 |
| --- | --- |
| Domain unit | mixer/timeline、storage thresholds、metadata 寬容解碼、recovery no-replace、lifecycle generation/stale completion |
| Infrastructure contract | fake WASAPI/MF adapter 下的開始、停止、來源斷線、writer failure、bounded queue counter |
| Windows integration | loopback + mic 10 秒、m4a reopen、60 分鐘 audio-only、權限拒絕、crash recovery、library reparse-point 拒絕 |
| 手動 release gate | 目標 Windows build/driver 資訊、非靜音證據、健康 counters、可播放產物、錯誤 redaction 檢查；若有 app-only，再加雙 app 隔離證據 |
