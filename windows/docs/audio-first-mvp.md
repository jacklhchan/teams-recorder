# Windows audio-first MVP：目前範圍與發行驗證

**狀態：** 實作中的 MVP；並非已完成硬體發行驗證。本文將「已有程式與自動化測試」、「本機實測」和「尚待外部前置條件」分開記錄，避免把其中任一項誤稱為完整產品支援。

## 已實作的錄音路徑

- 原生 bridge 可錄製 Windows render endpoint 的 WASAPI system loopback；可使用預設輸出或一個明確選取的 render endpoint。
- 可選擇一個 capture endpoint，將其麥克風音訊與 system loopback 混音。未選取麥克風時只錄系統輸出；原生核心已加入最多四聲道 float PCM 的 stereo downmix，供多聲道輸入在可初始化時正規化使用。
- 混音輸出為 AAC M4A，要求副檔名為 `.m4a`；bridge 介面接受 64,000 至 320,000 bit/s 的 AAC 目標位元率。
- WinUI 可開始、停止及執行 10 秒測試錄音，並顯示彙總 peak、packet、silent-packet 與 discontinuity 資訊。
- WinUI 啟動時會先嘗試復原中斷工作階段，再掃描受管的非 reparse-point 直接子資料夾，並以 Windows `MediaPlayer` 播放所選 M4A。

這是系統輸出錄製，並非 Teams-only 或任意單一程序錄製。雖然 repository 有 process-loopback 探針與原生能力，MVP UI 沒有提供程序選取，也不得宣稱 Teams 程序隔離。Windows 的 Teams Third-party App API Preview 已在單一實測環境完成配對、收到可信 meeting presence，並以自動流程完成一個 M4A；這不構成一般可用、跨 tenant/client 或 Teams-only 錄製的宣稱。該驗證中，Teams UI 的 mute/unmute 未可靠推送後續 mute-state，故 Teams Mute Sync 仍屬未驗證 Preview，不得宣稱可用、可靠同步或可控制 Teams 靜音；不得以 `query-state` polling 補救缺失的事件更新。

## 工作階段、容量與復原

`SessionStorageService` 的測試覆蓋工作階段資料夾配置與下列安全規則：

```text
<輸出根目錄>\
  meeting-... | test-... | manual-...\
    recording.audio-backup.m4a   # 工作／可復原備份
    recording.m4a                # 完成品；不得覆寫
    recording-info.json
```

- 低於 256 MiB 或無法查詢容量時，服務拒絕開始；256 MiB 至低於 1 GiB 為 audio-only 決策；1 GiB 至低於 5 GiB 為警告；5 GiB 以上為正常。
- 完成時只可將同一工作階段中的非空 backup 無覆寫地提升為 `recording.m4a`，再寫入 audio-only metadata。
- 啟動復原只接受非空、具 ISO-BMFF `ftyp` 標頭、位於受管直接子資料夾且不是 reparse point 的 M4A backup。若 final 已存在或提升失敗，保留原檔而不覆寫。
- library 只接受受管的 `meeting-`、`test-`、`manual-` 資料夾；忽略 reparse point、未完成檔案與不安全項目。

WinUI 已接入此流程：手動錄製與 10 秒測試分別配置 `manual-*`、`test-*` 工作階段，native capture 先寫入 `recording.audio-backup.m4a`；停止後由 UI 無覆寫地發佈為 `recording.m4a` 並寫入 metadata，然後重新掃描資料庫。開始錄製前會套用容量 gate；啟動時則先執行保守的 backup 復原。這些流程已有程式與 managed test 覆蓋，但仍需要實體裝置上的端對端發行驗證。

目前 health 亦只有彙總統計；UI 清楚標示每個來源的統計尚待 bridge 提供，不能視為 source-specific health。

## 已完成的程式／測試工作，與非 MVP 功能的界線

下列項目已有 Windows 實作及相應的 managed、native 或 contract 測試；除非本節另行列出實機證據，這不表示已完成所有目標機器、租戶或裝置的發行驗證。

| 項目 | 目前狀態 | 不應延伸為的宣稱 |
| --- | --- | --- |
| Audio-first 錄製 | WASAPI system loopback、可選 capture endpoint 混音、AAC M4A finalization、最多四聲道輸入的 stereo downmix core，以及 WinUI 開始／停止／10 秒測試均已實作。實機 M4A 結果見下節。 | 不代表每一種實體麥克風或音訊驅動程式皆已驗證；尤其不可把 downmix core 視為目前開發機已成功完成麥克風混音。 |
| Session library 與復原 | 受管資料夾掃描、metadata、容量 gate、backup 的 `ftyp` 驗證與無覆寫 promotion／啟動復原均已接入，並有測試覆蓋。 | 不代表已在所有中斷情境或使用者檔案系統上完成端對端發行驗證。 |
| Teams 靜音整合預覽 | 已有本機 Teams Third-party App API WebSocket client、DPAPI token store、pairing、push-only event 處理與 fail-closed 行為；單一環境已完成配對及 meeting presence 實測。初始「未靜音」快照不會自動開啟本機錄音麥克風。 | Teams UI mute/unmute 未可靠推送後續狀態；不得宣稱 Teams API 已普遍可用、mute sync／控制可用或可靠，亦不得以 `query-state` polling 替代。 |
| 全域熱鍵與本機 mute | `Ctrl+Alt+M` 的 Windows `RegisterHotKey` registrar、獨立 local/input mute 合併，以及對錄音輸入的明確 mute 狀態已有實作與測試。 | 不代表硬體 mute 手勢、Teams mute 或虛擬麥克風輸出已完成整合或驗證。 |
| 視訊／WGC | 僅有非錄製的 Windows Graphics Capture 可行性 probe。此開發主機的 probe 失敗，因此沒有 Windows 視窗／Teams 視訊錄製功能。 | 不得把 probe 或其原始碼視為可用的 WGC、A/V mux 或 QPC 對齊證據；其他主機仍須獨立 probe。 |
| 虛擬麥克風 | app 只會辨識一個已設定 endpoint ID、且名稱符合預期的受信任 virtual-microphone endpoint。 | Windows audio driver 的簽署、安裝、endpoint 供應與實機音訊路由皆是外部必要前置條件；本專案不提供或驗證該 driver。 |
| ASR | **刻意 deferred。** Windows MVP 不包含 Qwen ASR、模型／runtime 取得、FFmpeg packaging、串流轉寫或 diarization。 | 不得因 macOS 相關資產或相容 metadata 而宣稱 Windows 可轉寫。 |

## 本機驗證

在 Developer PowerShell、repository root 執行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\windows\scripts\Verify-Windows.ps1
```

此命令會設定及建置 native Debug/Release 目標、執行 native CTest、建置 .NET solution 和 WinUI x64 Release，並執行 managed 與 contract tests。它是程式與契約驗證，不會產生對實體揚聲器、耳機或麥克風的硬體證據。

可從下列位置直接啟動未安裝的 developer build：

```text
windows\src\Recorder.WinUI\bin\x64\Release\net10.0-windows10.0.22621.0\win-x64\Recorder.WinUI.exe
```

此專案不會安裝 app，也不會建立 Start Menu 項目；未簽署 MSIX 不屬於一般使用者安裝流程。

### 2026-07-29 實機結果（本開發機）

- 已以 Realtek render loopback 寫入非靜音 AAC M4A，bridge 回報 219,840 個輸入／輸出 frame、peak `0.76159`；Windows Shell 可辨識產物為約 4 秒、118 kbps 的 M4A。這驗證 system-only 路徑、AAC finalization 及檔案可被 Windows 重新開啟，但不代表所有音訊裝置都通過。
- 內建 `Microphone Array (Intel® Smart Sound Technology for Digital Microphones)` 回報 4-channel、48 kHz float mix format，卻對四種 shared `IAudioClient::Initialize` 變體、`IAudioClient3` engine-period 以及同 endpoint 的 48 kHz stereo auto-convert 全部回傳 `E_INVALIDARG`。UI 會保留此失敗並要求使用者修正／改選裝置，絕不靜默替換麥克風。
- 原生 4-channel-to-stereo downmix core 與其測試已加入；但它只會在 capture client 成功初始化後處理 PCM，無法繞過上述 Intel 4-channel endpoint 在 WASAPI／Media Foundation RAW 初始化階段的 `E_INVALIDARG`。因此，本機**沒有** optional-mic-mix 成功證據。
- 已在桌面版 Teams 的「Make a test call」啟動 Echo Test Call，並同時以 Release `BridgeProbe mixed` 錄製 45 秒。bridge 回報 2,263 個 render packets、1,086,720 個輸出 frame、0 個 silent packet、peak `0.761594` 與 12 個 discontinuity；產物為 367,453 bytes，Windows Shell 辨識為 22 秒、126 kbps 的 MPEG-4 Audio。這是 Teams Test Call 期間的 system-loopback 與 M4A finalization 實測證據；它不代表 Teams-only process isolation、Teams API、meeting 偵測或自動錄音。
- 2026-07-30：在桌面版 Teams 的僅自己 Meet now 完成 Third-party App API pairing；已配對連線收到 meeting-presence 快照，使用者明確啟用後自動開始並完成一個可播放的 `meeting-*` M4A 工作階段。這是單一環境證據，並非一般 Teams 支援。
- 同一次驗證中，Teams UI 的 mute/unmute 均未可靠推送後續 mute-state；已移除未證實的 `query-state` polling。Recorder 只使用已配對連線的推送事件，且不會依單一「未靜音」快照自動開啟本機錄音麥克風。

## 發行前仍必須完成的實機 gate

1. 在目標 Windows 機器，以實體 USB、耳機或內建麥克風執行 system-only 與 optional-mic-mix 錄製；確認有非靜音訊號、停止成功、M4A 可重新開啟及可播放。
2. 於該機器記錄 endpoint、Windows build、錄音時間、peak、packet、discontinuity、錯誤及產物可播放性；不得把單機結果泛化為所有硬體。
3. 在實機驗證 backup promotion、metadata、library 顯示、容量拒絕與中斷復原不覆寫完成檔。
4. 以實際輸出根目錄驗證 reparse-point 拒絕與錯誤訊息。Teams Preview 另須在不同 tenant/client 重複驗證會議開始／結束及 mute 推送行為；WGC 則須在目標主機重新通過 probe。不要把測試或探針結果描述為一般 Teams API、視訊、轉寫、虛擬麥克風或已安裝產品的驗證。

相關歷史 probe 證據請見 [WASAPI probe results](2026-07-28-wasapi-probe-results.md)；其中 physical microphone 仍被測試環境阻擋，不能作為實體麥克風支援的發行證明。
