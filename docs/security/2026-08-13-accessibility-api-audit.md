# Accessibility API 防回歸稽核

`scripts/check-no-accessibility-api.sh` 會掃描 production 的 `Sources/`、`Driver/`、`scripts/`、`Config/` 與 `Package.swift`，拒絕 `ApplicationServices`、`AXUIElement`、`AXIsProcessTrusted`、`AXObserver`、`AXValue` 和 `kAX...` 等 macOS assistive Accessibility API。偵測到時會輸出 repository-relative 檔案及符號，讓新增依賴可被明確的架構審查攔截。

此稽核刻意不掃描 `Tests/`、`docs/`、`build/` 或 `.git/`，並不把 SwiftUI 的 `.accessibilityIdentifier(...)` 視為 assistive API。可直接執行：

```sh
scripts/check-no-accessibility-api.sh
```

它是 sandbox-readiness guard，**不是**本 app 已啟用或符合 App Sandbox 的斷言；sandbox 結論、CLI 與 HAL driver 限制仍見 [App Sandbox 可行性評估](2026-08-13-app-sandbox-feasibility.md)。
