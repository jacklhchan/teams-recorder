# Windows Process Loopback Activation Spike

這個資料夾是獨立的 Windows process-loopback activation/capture spike。它不會在失敗時改錄全系統音訊或改用實體 endpoint。它會以 `ActivateAudioInterfaceAsync` 為指定 PID（包含其子程序）取得 `IAudioClient`，並以 shared-mode WASAPI 擷取該 virtual process-loopback endpoint 的 packet。

## 行為與限制

- 只接受非零十進位 `DWORD` PID；不接受空白、正負號、分隔符或超過 `UINT32_MAX` 的值。
- 先檢查 Windows 10 build 20348 以上；不符合時回傳 `HRESULT_FROM_WIN32(ERROR_OLD_WIN_VERSION)`。
- 使用 `VIRTUAL_AUDIO_DEVICE_PROCESS_LOOPBACK`、`AUDIOCLIENT_ACTIVATION_TYPE_PROCESS_LOOPBACK` 與 `PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE`。
- 等待可設定 timeout（預設 10 秒）。Windows activation API 沒有可安全呼叫的取消方法；timeout 後模組釋放 operation，將 shared state 標記為 abandoned。遲到 callback 只釋放它取得的 `IAudioClient`，不會存取 caller stack 或回報成功。
- `ProcessLoopbackCapture` 先嘗試 event-driven shared mode；只有 virtual process endpoint 本身拒絕 event callback 時，才以**同一 PID 的重新 activation**改用有界 polling。這不是全系統 fallback。
- 每個 callback block 擁有自己的 PCM bytes 與完整 `WAVEFORMATEX + cbSize` blob，並帶 frame count、device/QPC positions、silent、discontinuity、event/polling 標記。silent packet 不會虛構零 PCM bytes。
- `Stop` 會在 `IAudioClient::Stop` 前 drain 已排入的 packets。callback 在專屬 MTA capture thread 執行，不可從 callback 同步呼叫 `Stop`。
- `activate` 成功只代表取得 `IAudioClient`；`capture` 有 packet 亦只代表可讀取，兩者都不代表已完成 process-only 音訊隔離驗收。

## 建置需求

- Windows SDK 10.0.26100（`audioclient.h`、`mmdeviceapi.h`）。
- Visual Studio 2022 Build Tools / MSVC，C++17 或更新。
- 連結：`ole32.lib`、`mmdevapi.lib`。`ActivateAudioInterfaceAsync` 不需要自行宣稱其他 fallback library。

在此目錄使用 Developer PowerShell for VS：

```powershell
cl /nologo /std:c++17 /EHsc /W4 /DUNICODE /D_UNICODE process_loopback.cpp process_loopback_probe.cpp /link ole32.lib mmdevapi.lib /out:process_loopback_probe.exe
cl /nologo /std:c++17 /EHsc /W4 /DUNICODE /D_UNICODE process_loopback.cpp process_loopback_tests.cpp /link ole32.lib mmdevapi.lib /out:process_loopback_tests.exe
.\process_loopback_tests.exe
```

## 實機驗證

1. 在有可辨識播放音訊的目標程式（例如 Teams 測試呼叫）執行時取得 PID：`Get-Process ms-teams | Select-Object -First 1 -ExpandProperty Id`。不要使用本 probe 的 PID。
2. 僅驗證 activation：`.\process_loopback_probe.exe activate <PID> 10000`。
3. 讀取 10 秒 packets：`.\process_loopback_probe.exe capture <PID> 10`。輸出會列出 packets、frames、owned bytes、silent/discontinuity count、event/polling mode 與 format blob bytes；零 packet 是失敗，不是 pass。
4. 下一個 capture-validation slice 必須以「目標程式有聲、干擾程式亦有聲」的已儲存音訊證據，證明 process-only 隔離；不可只由本 probe 的 packet count 推論。
5. OS 不支援、PID 已結束／拒絕存取、API activation 失敗、timeout 或 capture error 都是明確失敗，不能回退成全系統 loopback。
