# 錄影期間即時切換麥克風：可行性 Spike

日期：2026-08-13
範圍：只評估 Local Meeting Recorder 的本機音訊擷取。**不涉及 Teams mute status、Teams 控制或真實會議。**

## 結論

可把「不中斷錄影檔與系統音訊」列為可行的工程目標，但不能把「在既有 `SCStream` 上原地更換 `microphoneCaptureDeviceID`」列為已獲 Apple 契約保證。建議採取**受控的麥克風輸出重新掛接／重新配置**架構，先以同一個 `SCStream` 的 `updateConfiguration` 作可回滾 runtime UAT；若該呼叫失敗、停止 stream、或未在限時內交付新麥克風 frame，保留原裝置，將切換回報失敗。完整擷取重啟會終止目前 source session，故不應作為 live-switch 的 fallback。

本 spike 沒有操作實體麥克風、GUI 或會議；XcodeBuildMCP 的 macOS workflows 在本 session 未暴露，因而沒有執行 build、run 或 test，也沒有使用 raw `xcodebuild`、`xcrun` 或 `simctl`。

## 已觀察到的 API 契約與現有路徑

### ScreenCaptureKit（本機 macOS SDK headers）

- `SCStreamConfiguration.captureMicrophone` 與 `microphoneCaptureDeviceID` 都是 macOS 15.0 起提供；後者的註解指明值是 `AVCaptureDevice.uniqueID`，未指定時取用系統預設麥克風。
- `SCStream` 公開 async `updateConfiguration(_:)`。headers 的說明只說它會更新 content stream 的 configuration，並以 completion error 表示成敗。
- 同一份 headers **沒有**說明 `microphoneCaptureDeviceID` 可在 capture 已開始時安全改變、是否會保留 microphone output、是否會有空洞／新 frame 回呼，或失敗後配置是否保持舊值。因此 API 可呼叫不等於 live device switch 已有文件保證。

### 現有 source／engine 路徑

- `AppModel.selectMicrophone` 只在 `sourceControlsEnabled` 為真時允許選擇；該條件是 `!recorder.isRecording && !isCaptureLifecycleWorking`。所以目前設計明確禁止錄影中選擇。
- 啟動時 `ScreenCaptureSource.start` 以 `AVCaptureDevice.DiscoverySession` 驗證 UID，將同一 UID 放入新的 `SCStreamConfiguration.microphoneCaptureDeviceID`，建立 `SCStream`，並只在啟動前加入 `.audio`、`.microphone` 和 `.screen` outputs。
- 目前 `ScreenCaptureSource` 已把 `SCStream.updateConfiguration` 用於 screen-target/filter 更新，且重建的 configuration 會重帶 `session.selectedMicrophoneUID`；它沒有 microphone-update API，也不會更新該 session 欄位。
- `RecordingEngine.startMonitoring` 對 UID 改變的做法是 `stopActiveSourceSession()` 再 `captureSource.start(...)`。停止會停 capture、停 virtual-mic publisher、清掉 session ID；`resetMonitoringState()` 會新建 mixer。錄影中 `AppModel` 因 UI guard 不會走這條路。
- 音訊回呼以 `RecordingCallbackGate` 的 session ID / recording epoch 過濾陳舊 callback；`ScreenCaptureSource` 另有 stream identity 的 `CaptureSessionToken`。這是可延展為 switch lifecycle token 的既有隔離基礎。

### AVAudio／時間線含意

- `ScreenCaptureStreamOutput` 各自持有 persistent system/microphone resampler。它將 buffer PTS 統一轉為 48 kHz 的整數 `startFrame`，再交給 `TimestampedAudioMixer`；切換裝置時新輸入的 PTS 原點／格式是否連續，沒有 SDK 契約可假定。
- mixer 同時連線時只輸出兩來源都已知的 frame；缺口會重新錨定而計入 `timelineDiscontinuityCount`，太晚的 frame 計入 `lateFrameCount`。斷開麥克風時 `setMicrophoneSourceConnected(false)` 會清除其 pending state，令系統音訊以麥克風靜音繼續。
- 因此 switch 不應 reset mixer、recording epoch、writer 或 system path；應在交接窗保存 mixer，將舊麥克風最後已接受的 frame 作邊界，並以第一個新麥克風 frame 的 PTS 判定是否為無縫、短暫靜音／缺口，或不可接受的 timeline jump。任何 `AVAudioConverter`／resampler 狀態都應按裝置世代重建，不能跨不同 input format 盲目重用。

現有 `TimestampedAudioMixerTests` 已覆蓋來源斷線、重連等待、新時間戳重新錨定、late frame 及有界 pending state；`RecordingEngineStateTests` 已覆蓋 callback barrier、陳舊 session callback 拒收與同一 source 的 screen filter update 不重啟 writer。這些是新行為的適合測試 seams。

## 方案比較

| 方案 | 依據／風險 | 決定 |
| --- | --- | --- |
| 1. 原地 `SCStream.updateConfiguration` | 方法與屬性皆公開，但 headers 沒承諾 running microphone device 的切換語義。 | 僅作具 rollback 的 runtime probe，不可把成功假設編入產品契約。 |
| 2. 受控 microphone-output reattach / reconfigure | 保持同一 `SCStream`、system output、writer、mixer 與 recording epoch；先 quiesce microphone delivery，再發出帶新 UID 的完整 configuration，必要時移除／重加 `.microphone` output（須實測此序列）。 | **推薦最小架構**。若 runtime UAT 顯示 output reattach 非必要，縮成只 reconfigure；若 reattach 引致 stream 終止，立即禁用此變體。 |
| 3. 完整 capture restart | 現有 stop/start 會更換 source session、停止 virtual mic、清除 session state；錄影 writer 的收尾與同一檔案的連續性不受保證。 | 拒絕作 live switch 或 fallback；只可在未錄影監聽模式另行討論。 |

## 推薦的最小架構

在 `CaptureSourceProtocol` 增加明確的 switch operation（而不是重用 `start`）：

```swift
enum MicrophoneSwitchOutcome: Equatable {
    case unchanged
    case switched(previousUID: String?, currentUID: String?, continuity: MicrophoneContinuity)
    case rolledBack(requestedUID: String?, reason: MicrophoneSwitchFailure)
}
```

`MicrophoneContinuity` 應只表達觀測結果，例如 `continuous`、`gap(frameCount:)`、`reanchored`；`MicrophoneSwitchFailure` 至少區分 input UID 無效、configuration error、output reattach error、stream stopped、first-frame timeout、及 superseded。不要把未獲 API 文件保證的「無縫」當成預設。

實作應由 `RecordingEngine` 擁有遞增的 `MicrophoneSwitchLifecycleToken`（包含 source session ID、recording epoch 與 switch generation）。步驟：

1. 在 MainActor 驗證仍為同一 active source／epoch，驗證目標 AVCapture UID；若同 UID 回傳 `.unchanged`。
2. source 以 token 暫停舊 microphone delivery（system/video 仍通過），drain 已入閘 callbacks；不要停 stream 或 reset mixer。
3. 以完整的現有 configuration（保留 sample rate、channel count、screen/frame settings）把新 UID 傳入 `updateConfiguration`；按 runtime UAT 結果才決定是否需要 remove/add `.microphone` output。
4. 等待同 token 的第一個有效新 microphone frame；以 timeout 及 frame timeline 評估 continuity，然後原子地更新 `selectedMicrophoneUID` / `activeMicrophoneUID` 並恢復 delivery。
5. 失敗或被較新的 token supersede 時，嘗試以舊完整 configuration 恢復；若成功，解除暫停並回傳 `.rolledBack`。若 stream 已停止，交由既有 terminal event／recording stop 路徑處理，不能假裝 rollback 成功。

UI 應在切換 pending 時鎖定 source selector，但錄影本身繼續；成功後才持久化選擇。此操作不應觸碰 `micMuted` 的本機 input mute state，也不應讀寫 Teams mute status。

## 必須先做的隔離 runtime UAT

在非會議、可放聲測試的隔離帳戶／環境，以兩個已授權、可辨識的本機輸入進行；不使用 Teams：

1. 開始短錄影，確認 system 與 mic 都有有效 48 kHz frames；記錄 stream identity、recording epoch、writer URL、與切換前後 frame timestamps。
2. 用相同 `SCStream` 呼叫完整 configuration 的 `updateConfiguration`，只改 `microphoneCaptureDeviceID`；確認 completion、stream 未收到 stop delegate、system audio / video 持續，且新 mic frame 在明確 timeout 內到達。
3. 如需要，分別驗證移除／重加 `.microphone` output 的順序；每次只改一個變因，檢查 output 是否仍回呼、是否造成 stream stop 或 duplication。
4. 重複 A→B→A，且在第一個 frame 前提出第二次切換；驗證 lifecycle token 只接受最後請求，舊 callback 不會寫入、writer URL/epoch 不變，時間線只有可量測且產品可接受的 gap／reanchor。
5. 注入或模擬 configuration failure、目標裝置拔除與 first-frame timeout；驗證舊 mic rollback 或清晰 failure，system audio 和檔案收尾仍正確。若任何 case 終止 stream，方案 1/2 不可宣稱支援該 OS/硬體組合。

## 先寫的 focused TDD cases

1. `RecordingEngine` 在錄影中成功 switch 時保持 source session ID、recording epoch、writer instance、system connection 與 mute state；只更新 active microphone UID。
2. switch completion 前的舊 token audio callback，以及被 supersede 的 switch completion，都不可更新 selected UID 或寫入 mixer／virtual mic。
3. configuration error 或 first-frame timeout 會以舊 UID 恢復，回傳 `.rolledBack`，且不呼叫全 capture `stop`/`start`。
4. mixer 測試：在舊 mic 的最後 frame 與新 mic 第一個不同 PTS 之間，斷言輸出單調、late/discontinuity counters 與預期相符，且 system-only path 不被阻塞。

## 未知與判定門檻

- Apple headers 不能回答不同實體裝置、Bluetooth／USB 斷接、樣本率變化或 macOS minor version 的實際行為；必須由上述 UAT 填補。
- 尚未判定 `updateConfiguration` 是否足夠，或是否要求 microphone output reattach；「受控 reattach」是架構選項，不是已驗證 API 序列。
- 若 UAT 無法證明 stream 與 writer 可保持存活並在可接受時限取得新 frame，功能應保持禁用，並繼續採用目前「停止錄影後再換麥克風」的產品行為。
