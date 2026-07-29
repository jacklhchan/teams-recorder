# Windows audio-first MVP：目前範圍與發行驗證

**狀態：** 實作中的 MVP；並非已完成硬體發行驗證。

## 已實作的錄音路徑

- 原生 bridge 可錄製 Windows render endpoint 的 WASAPI system loopback；可使用預設輸出或一個明確選取的 render endpoint。
- 可選擇一個 capture endpoint，將其麥克風音訊與 system loopback 混音。未選取麥克風時只錄系統輸出。
- 混音輸出為 AAC M4A，要求副檔名為 `.m4a`；bridge 介面接受 64,000 至 320,000 bit/s 的 AAC 目標位元率。
- WinUI 可開始、停止及執行 10 秒測試錄音，並顯示彙總 peak、packet、silent-packet 與 discontinuity 資訊。
- WinUI 啟動時會先嘗試復原中斷工作階段，再掃描受管的非 reparse-point 直接子資料夾，並以 Windows `MediaPlayer` 播放所選 M4A。

這是系統輸出錄製，並非 Teams-only 或任意單一程序錄製。雖然 repository 有 process-loopback 探針與原生能力，MVP UI 沒有提供程序選取，也不得宣稱 Teams 程序隔離、Teams API、meeting 偵測或自動錄音。

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
- 本執行工作階段無法擷取或控制桌面視窗，因此沒有把這次 M4A 實測宣稱為新的 Teams Test Call 證據；Teams-only 仍不在 MVP 範圍。

## 發行前仍必須完成的實機 gate

1. 在目標 Windows 機器，以實體 USB、耳機或內建麥克風執行 system-only 與 optional-mic-mix 錄製；確認有非靜音訊號、停止成功、M4A 可重新開啟及可播放。
2. 於該機器記錄 endpoint、Windows build、錄音時間、peak、packet、discontinuity、錯誤及產物可播放性；不得把單機結果泛化為所有硬體。
3. 在實機驗證 backup promotion、metadata、library 顯示、容量拒絕與中斷復原不覆寫完成檔。
4. 以實際輸出根目錄驗證 reparse-point 拒絕與錯誤訊息。不要把測試或探針結果描述為 Teams API、視訊、轉寫、虛擬麥克風或已安裝產品的驗證。

相關歷史 probe 證據請見 [WASAPI probe results](2026-07-28-wasapi-probe-results.md)；其中 physical microphone 仍被測試環境阻擋，不能作為實體麥克風支援的發行證明。
