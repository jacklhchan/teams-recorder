# App Sandbox 可行性評估

日期：2026-08-13
範圍：Local Meeting Recorder 的 App Sandbox 遷移可行性。這是靜態證據評估，不是原型、實作計劃或發行設定變更。

## 結論

以目前產品邊界，**不應直接把現行 app 勾選 App Sandbox 後發行**。螢幕／系統音訊擷取、麥克風、使用者挑選資料夾及 container 內的 pending storage 都有合理的 sandbox 路徑；但目前的終端機控制通道，以及（若保留）虛擬麥克風 HAL driver 安裝與共享記憶體通訊，沒有可由本次靜態查核證實的端到端 sandbox 路徑。若 Teams 偵測改用 Accessibility API，Apple 明確將 assistive-app Accessibility API 列為與 App Sandbox 不相容。

推薦先採用 **選項 1（不 sandbox、集中 capability 與既有 hardening）**，將下列最小驗證項排入獨立 spike；只有在產品接受移除／替換 CLI、虛擬麥克風與任何 AX 依賴後，才重新判斷選項 2 或 3。

### 判讀方式與限制

- **Observed（觀察到）**：本倉庫檔案直接可證明的現況，使用 `repo-relative/path:line` 引用。
- **Inferred（推論）**：由程式與 Apple 官方文件作出的架構判讀，尚未在 sandboxed bundle 實測。
- **Needs spike（需要 spike）**：必須以獨立、不可進入 production entitlement／簽章／release pipeline 的最小 target 在目標 macOS 上驗證。
- 本文的 Apple 依據只使用官方文件。App Sandbox 將檔案、網絡與硬件能力限制在 entitlement 所授予的範圍，並為 sandboxed app 建立可自由讀寫的 container：[Protecting user data with App Sandbox](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)。
- **明確排除**：不建議、沒有設計，也沒有變更 Developer ID、Hardened Runtime 或 notarization。現行 release 腳本本來已要求 Developer ID、runtime option 與 notarization；那是 Observed 現況，不是本評估的變更目標：`scripts/build-release.sh:78-89`, `scripts/build-release.sh:179-190`。
- 未檢查已發行 `.app`、effective entitlements、TCC 授權、實際 HAL driver 或任何 sandboxed prototype；因此「likely」不是「已測通」。

## 現行基線

- **Observed**：主 app 是 SwiftPM executable，連結 ScreenCaptureKit、CoreAudio、Security 等框架：`Package.swift:25-38`。目前 entitlement 檔只含 audio input，沒有 `com.apple.security.app-sandbox`：`Config/LocalMeetingRecorder.entitlements:5-8`。
- **Observed**：錄影預設寫入 `~/Downloads`，pending／診斷資料放在目前使用者的 Application Support 路徑：`Sources/RecorderApp/Setup/AppPaths.swift:7-34`。
- **Observed**：路線圖要求本階段只做 feasibility matrix／spike，並同樣排除 Developer ID、Hardened Runtime 與 notarization：`.superpowers/sdd/remaining-features-inventory.md:183-201`。

## 能力矩陣

| 能力 | 現行證據（Observed） | Sandbox 機制／可確認 entitlement | 判讀 | 最小隔離 spike | fallback architecture |
|---|---|---|---|---|---|
| ScreenCaptureKit 系統音訊與視窗 capture | `SCShareableContent`／`SCContentFilter`／`SCStream`：`Sources/RecorderApp/Capture/ScreenCaptureSource.swift:690-698`, `:1053`, `:1231-1305`；設定 `capturesAudio = true`：`:1308-1316`；以 `CGPreflightScreenCaptureAccess`／`CGRequestScreenCaptureAccess` 取得 TCC 同意：`Sources/RecorderApp/Capture/CapturePermission.swift:270-287`。 | `com.apple.security.app-sandbox=true`；Apple 文件確認 ScreenCaptureKit 可串流 display、app、window 與 audio，並要求首次 Screen Recording 同意；沒有在所查官方資料中發現「ScreenCaptureKit 專用 sandbox entitlement」。見 [Capturing screen content in macOS](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos) 及 [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit)。 | **Likely compatible**；TCC／OS 版本／背景行為仍是 Needs spike。 | 僅含 sandbox + 現有 usage strings 的 app target：列舉單一視窗、capture video + `capturesAudio`，冷啟動後驗證 TCC、停止與重開。 | 保持非 sandbox GUI；或以使用者明確選取的 `SCContentSharingPicker` 取代自建視窗選擇流程（Apple 建議 picker）。 |
| 麥克風 | `captureMicrophone = true` 與 microphone UID：`Sources/RecorderApp/Capture/ScreenCaptureSource.swift:1308-1316`；AVFoundation request：`Sources/RecorderApp/Capture/CapturePermission.swift:275-291`；現有 entitlement：`Config/LocalMeetingRecorder.entitlements:6-7`。 | `com.apple.security.device.audio-input=true` 是 Apple 記載的 audio recording/Core Audio input entitlement；仍須麥克風 TCC 同意：[Audio Input Entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.device.audio-input)。 | **Likely compatible**。 | 在同一 capture spike 確認指定 input device、TCC 拒絕／重授權、與 system audio 同時輸出。 | 維持目前非 sandbox capture process。 |
| 任意使用者選取輸出目的地／重啟後 bookmark | `NSOpenPanel` 選資料夾：`Sources/RecorderApp/AppModel.swift:1515-1525`；優先建 `.withSecurityScope` bookmark、重啟後 resolve 與 `startAccessingSecurityScopedResource()`：`Sources/RecorderApp/Storage/RecordingDestinationStore.swift:52-67`, `:164-204`。 | `com.apple.security.files.user-selected.read-write=true`。官方文件確認標準 Open/Save panel 可擴展 sandbox，security-scoped bookmark 可跨 relaunch 保存存取：[Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)； entitlement 定義見 [user-selected read-write](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.files.user-selected.read-write)。 | **Likely compatible**；現有 `.standard` bookmark fallback 在 sandbox 下不應當作持久存取保證。 | 選任意非 Downloads 資料夾、寫入、結束 app、重啟 resolve/start/stop access，再模擬 stale bookmark。 | 將所有可發布目的地限定為每次 session 的 `NSSavePanel`／`NSOpenPanel` 授權；無法重取權時顯示「重新選擇資料夾」。 |
| Downloads 預設與 App Support pending | 預設是 `~/Downloads`：`Sources/RecorderApp/Setup/AppPaths.swift:12-14`；pending root 以 `0700` 建立、`openat`／`O_NOFOLLOW` 操作：`Sources/RecorderApp/Storage/RecordingPendingStore.swift:35-60`。 | pending 應移到 sandbox container 的 Application Support（container 內不用額外檔案 entitlement）；若仍以 Downloads 作無互動預設，需評估 `com.apple.security.files.downloads.read-write`，或改為首次必選目的地。Apple 指出 sandbox 無完整 home access、標準目錄 API 會回傳 container location。[App Sandbox data locations](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)。 | **Likely compatible，但需資料遷移設計**。現有硬編碼 home／Application Support 會落在 sandbox 外的假設不可保留。 | sandbox app 以 `FileManager` 取 Application Support，跑 pending create/publish/recovery smoke；另測無 Downloads entitlement 的預設路徑失敗是否被明確處理。 | 將 pending 永遠留 container，只在 publish 時透過 security-scoped destination 寫出；首次啟動強制選輸出資料夾。 |
| Keychain API key | generic-password CRUD，未指定 access group：`Sources/RecorderApp/Security/SecureValueStore.swift:48-99`, `:112-159`。 | `com.apple.security.app-sandbox`；使用預設 keychain access group。是否可無縫讀取既有非 sandbox item、及實際 access-group migration，官方資料未足以在本次確認。 | **Likely compatible for new items；existing-item migration unknown**。 | 同一 bundle identifier 的 sandbox debug app 新增／讀寫／刪除 item；以隔離測試 key 測試現有資料遷移策略，絕不讀取真實 API key。 | 首次 sandbox 啟動要求重新輸入 key；完成驗證後才設計一次性、使用者確認的 migration。 |
| 同 UID AF_UNIX `recorderctl` 控制與背景啟動 | socket 在 `/tmp/lmr-<uid>`，目錄 `0700`：`Sources/RecorderControl/RecorderControlEndpoint.swift:7-38`；server 綁定後 socket `0600`：`Sources/RecorderControl/UnixSocketTransport.swift:162-180`；CLI 由 `/usr/bin/open -gj <app> --args --background-control` 啟動 app：`Sources/RecorderControlCLI/RecorderAppLauncher.swift:64-78`。 | Apple 文件只明確說 network client/server entitlement 控制 TCP/UDP 連線，而非 AF_UNIX；本次未找到 Apple 官方文件可證實 sandbox 對 `/tmp` AF_UNIX server、terminal-launched inherited CLI 與 peer check 的組合。 | **Unknown（阻塞 full sandbox 決策）**。 | sandbox app + embedded inherited CLI：測 app bind、終端機 symlink 啟動 CLI、CLI connect、背景 launch、relaunch、socket cleanup；記錄 sandbox denial。 | 移除公開 CLI；改由 GUI／Shortcuts／user-approved URL command。若 CLI 為必要產品能力，保持控制 host 非 sandbox，或另立受限服務且重新設計認證與 IPC。 |
| bundled CLI | helper 被包在 `Contents/Helpers`：`scripts/build-app.sh:117`；由 symlink 安裝至 `/usr/local/bin`：`scripts/install-recorder-cli.sh:5-6`；CLI 以 bundle layout 找主 app：`Sources/RecorderControlCLI/RecorderAppLauncher.swift:33-61`。 | Apple 確認 sandbox app 可嵌入 command-line tool；child tool 應只有 `com.apple.security.app-sandbox` 及 `com.apple.security.inherit`：[Embedding a command-line tool in a sandboxed app](https://developer.apple.com/documentation/xcode/embedding-a-helper-tool-in-a-sandboxed-app)。這只證實「app 內 helper」，不證實目前 `/usr/local/bin` 的外部終端使用情境。 | **Current public-CLI workflow unknown**；app 內 child helper **likely compatible**。 | 驗證 embedded tool 的 codesign entitlements、GUI 呼叫 tool、以及 `/usr/local/bin` symlink 直接呼叫這兩條路徑分別的行為。 | 將 CLI 限為開發／非 sandbox distribution；或以同一 GUI app 的受限 command handler 取代。 |
| Teams 視窗偵測／Accessibility | 現行 pure detector 僅處理 `TeamsWindowResolution`，未在此檔呼叫 AX：`Sources/RecorderApp/Teams/TeamsLocalMeetingDetector.swift:19-115`；capture identity 使用 `CGWindowID`：`Sources/RecorderApp/Capture/TeamsMeetingWindow.swift:1-9`。 | **若功能需要 Accessibility API**，Apple 明確列出「Use of accessibility APIs in assistive apps」為 sandbox 禁止活動，沒有可用 entitlement 補救：[incompatible functionality](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)。 | **Accessibility 路徑 incompatible**；目前 CGWindow／ScreenCaptureKit 路徑是否足夠是 **unknown**。 | 不接 AX：只以 ScreenCaptureKit shareable content + CGWindow identity 完成 Teams 偵測場景；把需要的產品判定與 TCC 狀態記錄下來。 | 移除自動 Teams 偵測，讓使用者選取視窗／手動開始；或保留非 sandbox 偵測 host。 |
| CoreAudio HAL 虛擬麥克風、shared memory、sudo installer | bridge 用 `shm_open`／`mmap`：`Sources/VirtualMicBridge/VirtualMicBridge.cpp:347-359`, `:739-831`；HAL driver：`Driver/LocalRecorderVirtualMic/LocalRecorderVirtualMic.c:3729-4060`；installer 以 sudo 寫 `/Library/Audio/Plug-Ins/HAL`：`scripts/install-virtual-mic.sh:5-9`, `:43-65`。 | App Sandbox 官方限制 Authorization Services，並禁止 kernel extensions；雖然此 repo 是 HAL plug-in 而非 kernel extension，但 sandboxed GUI 無法自行完成此 sudo／系統目錄安裝。對跨 sandbox／AudioServer 的 POSIX shm namespace 也沒有本次可確認 entitlement。 | **End-to-end incompatible if retained in current form**；bridge access 本身 **unknown**。 | 不在 production app：在 disposable test machine 以已安裝 driver 測 sandbox producer 是否可 open/map shm；另測 driver lifecycle。不可把 installer 納入 sandbox target。 | 將 virtual mic 當可選、獨立且非 sandbox 系統元件，由受控 installer／helper 擁有；或移除 virtual mic，保留 app 內錄音。 |
| `NSWorkspace` 開啟／Finder reveal | 開 pending／錄影目的地：`Sources/RecorderApp/AppModel.swift:1551-1558`, `:1594-1600`；Finder selection／URL open：`:1656-1683`。 | 不需在本次確認額外 entitlement；但傳給 Launch Services／Finder 的 URL 必須是 container 內或 app 目前具有 security scope 的使用者選取項目。 | **Likely compatible**，取決於目的地 bookmark 存取仍有效。 | 在 sandbox 下 reveal container pending、已選輸出資料夾、stale bookmark 三種情況，確認不洩漏未授權 path。 | 在 UI 隱藏／disable 沒有有效 scope 的 reveal，改成「重新選取資料夾」。 |
| updater／簽章驗證 | 有 bundle codesign verify、notarization、SHA-256 artifact，但沒有 in-app updater／feed／runtime verifier：`scripts/build-release.sh:179-205`；`.superpowers/sdd/remaining-features-inventory.md:159-181`。 | 純本地簽章／manifest 驗證預期不需 sandbox file entitlement（需後續 API spike）；sandboxed app 不應自行覆寫 app bundle。Apple 對 sandbox container 的規則支持這項推論；本次未確認自更新 API。 | **Verification likely compatible；self-update incompatible/unknown**。 | sandbox test target 對 bundled／user-selected artifact 執行只讀 verification；不要下載、安裝或改動 release pipeline。 | 保持外部 installer／受信任 distribution channel；in-app 僅檢查更新與導向使用者，或採 Store 管理更新。 |
| 對 ASR／LLM 的外連（影響完整路徑） | provider HTTP client 與 legacy process 會上傳資料：`Sources/RecorderApp/Transcription/OpenAICompatibleProviderClient.swift:115-239`; `Sources/RecorderApp/Transcription/TranscriptionProcess.swift:272-315`。 | `com.apple.security.network.client=true` 允許 outgoing network connections：[network client entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.client)。 | **Likely compatible**；legacy `/bin/bash`／外部工具在 sandbox 的完整行為需另驗。 | 只以 loopback TLS fixture 驗證 direct client；獨立驗證 bundled script／ffmpeg resolution，勿傳實際音訊。 | 優先 direct Foundation networking；把 legacy subprocess 留在非 sandbox host 或移除。 |

## 三個實質選項

### 選項 1：不 sandbox；集中 capabilities 與 hardening（建議 baseline）

保留現行 capture、`recorderctl`、HAL driver 與 installer 的產品行為，不增加 App Sandbox entitlement。把現有路徑收斂為明確 capability boundary：輸出一律用目前 bookmark store、pending 一律 owner-only、CLI 維持最小指令集與 same-UID peer check、虛擬麥克風維持顯式 opt-in／獨立安裝。

- **好處**：不會在未驗證前破壞現有錄製、CLI 或虛擬麥克風；與現行 roadmap 的「先 assessment」一致。
- **代價**：沒有 App Sandbox 的 blast-radius 收斂；需持續維護既有 POSIX、installer 和 TCC 防線。
- **Rollout**：先完成下方 spikes，將結果作為下一次架構選擇的 gate；不改 entitlement／release。
- **Rollback**：spike 只在隔離 target／機器，刪除即可；production 無需回退。

### 選項 2：sandbox GUI + out-of-process helper

把 GUI、capture、Keychain、container pending、bookmark publication 放在 sandbox；把 CLI 及 virtual-mic installer／driver bridge 留在明確的 non-sandbox helper 或系統元件。若需持續背景服務，應先以 Apple 的 Service Management 方案重新設計，而非沿用 `/tmp` socket；`SMAppService` 能管理 bundle 內 login item、LaunchAgent 和 LaunchDaemon，且這些服務有使用者核准狀態：[SMAppService](https://developer.apple.com/documentation/servicemanagement/smappservice)。

- **好處**：高風險 GUI／capture／network 路徑獲 sandbox containment，同時保留可選虛擬麥克風。
- **代價**：這是跨程序信任模型重設，不是 entitlement 小改：身份、IPC 授權、資料 ownership、安裝／更新責任都要重做；Apple 對 AX 的限制仍使 AX-based Teams detection 不可留在 sandbox GUI。
- **Rollout gate**：先驗證 capture、bookmark、container pending；再選定 helper lifecycle/IPC，才可設計 production target。任何 spike 失敗時留在選項 1。
- **Rollback**：保留原 non-sandbox distribution 至 sandbox GUI+helper 完整功能／recovery／uninstall UAT 通過；不得混用兩個 writer 管理同一 pending queue。

### 選項 3：full sandbox，移除或改變功能

完整 sandbox app 僅保留 ScreenCaptureKit、麥克風、direct network、container pending、user-selected output bookmarks 與 Finder reveal；移除公開 `recorderctl`／AF_UNIX background-control、移除 virtual microphone driver/installer/shared memory，以及所有 Accessibility-based Teams 偵測。Teams 改為使用者在系統 picker 選視窗或手動錄製。

- **好處**：邊界最清楚，與 Apple App Sandbox 模型最接近。
- **代價**：屬產品縮減，不是透明遷移；既有自動化、CLI workflow、virtual mic 與部分 Teams 自動化會消失或改 UX。
- **Rollout gate**：只有在產品 owner 明確接受功能變更，且 capture/bookmark/recovery/TCC spikes 全數通過後才可進入設計。
- **Rollback**：以 feature flag／平行 non-sandbox build 維持現有客戶工作流，直至行為改變完成公告與遷移；不變更簽章／notarization方案。

## 建議推進順序與可回退檢查點

1. **先做四個 read-only／隔離 spike**：SCK + mic；任意資料夾 bookmark 重啟；container pending publish/recovery；embedded CLI／AF_UNIX。每個 spike 記錄 macOS build、entitlements dump、TCC 初始狀態、成功／失敗 syscall/API 與清理結果。
2. **把 HAL 虛擬麥克風當成獨立架構決策**：它不可以被「sandbox 勾選」隱藏。若此功能是必須，選項 1 是目前可接受 baseline；若可選，才比較選項 2。
3. **禁止 AX creep**：任何 Teams 偵測需求先聲明是否需要 AX；需要 AX 即停止 full-sandbox 路徑並回到選項 1 或改 UX。
4. **只有所有必要 spike 通過才開始設計 production migration**。屆時新增的 code/signing review 必須另開任務；本評估不授權變更 `Config/LocalMeetingRecorder.entitlements`、`Package.swift`、scripts 或 CI/release pipeline。

## 尚未解決的限制

- Apple 官方文件足以確認 user-selected read/write、audio input、network client、container，以及 embedded inherited command-line helper 的一般模型；它**沒有在本次查核中**提供可直接套用於現行 `/tmp` AF_UNIX protocol 或跨 HAL-driver POSIX shared-memory 的保證。
- 現行 `AppPaths` 與可能的 legacy subprocess 對 home／外部執行檔有假設；即使主 capture spike 成功，完整錄製到 transcription、publication、recovery 的行為仍不可假稱已通過。
- 本文不會改變 Developer ID、Hardened Runtime、notarization，也不表示這些既有機制已在 shipped artifact 被重新驗證。
