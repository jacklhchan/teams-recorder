# Selected App 音訊隔離：人工驗收紀錄

**狀態：** PR Draft；未驗證，非 GA。
**適用範圍：** Windows process-loopback 的 Selected App 音訊隔離。
**不適用：** Teams-only 宣稱、全系統錄音 fallback、視窗錄影、Teams API 或任何自動化認證流程。

## 通過條件

必須在兩個不同程序同時播放可區分 tone 的情況下完成：

1. 在產品中選取目標程序後，錄音與量表只能反映目標 tone；干擾者 tone 不得出現。
2. 終止目標程序後，產品須顯示 reconnect 或 unavailable，並停止／拒絕 Selected App capture。
3. 終止目標後不得靜默改錄全系統音訊。任何 fallback 必須是明確、使用者可見且未開始錄製的 unavailable 狀態。

任何一項未達成、音訊無法判讀或證據不足，即記錄為 **未通過**。不要以 process-loopback activation 成功、聲音存在或 Teams 的個別結果推論已隔離或可 GA。

## 執行程序

1. 使用兩個不共用 process image 的 tone emitter，準備不同頻率／節奏且足以重疊的 tone。不要把帳號、token 或真實錄音內容加入測試。
2. 以受控機器執行 [`Test-SelectedAppAudioIsolation.ps1`](../scripts/Test-SelectedAppAudioIsolation.ps1)，以參數提供兩個 emitter 及可辨識的 `TargetToneLabel`／`DistractorToneLabel`（例如兩個已驗證但不含敏感資料的頻率標籤）。腳本先維持兩者重疊，再只終止它所建立的 target process，讓 distractor 繼續播放以觀察 no-fallback；它不保存 executable path 或參數，也不產生判定。
3. 在產品 UI 選取目標 emitter，於兩者重疊時開始所需的測試錄製，觀察選取狀態、量表與健康資訊。
4. 結束目標 emitter，在不停止干擾 emitter 的情況下觀察 UI、量表、健康／錯誤資訊與錄音結果。
5. 把下列最小紀錄寫入核准的人工 evidence 系統。不得記錄憑證、檔案路徑、完整命令列、音訊內容或任何個人資料。

## Evidence checklist

| 欄位 | 必填內容 |
| --- | --- |
| 環境 | UTC 時間、Windows edition/build、產品 build/revision、音訊 endpoint 與 sample rate |
| 刺激 | 目標／干擾的匿名角色、可區分方式、重疊秒數；不記路徑或命令列 |
| 隔離觀察 | Selected App 選取狀態、量表／健康訊號、錄音重開結果，以及「只觀察到目標」或「未通過」 |
| 目標結束 | 目標結束後的 UI、健康／錯誤和錄音行為，以及「無全系統 fallback」或「未通過」 |
| 異常 | HRESULT、dropped buffer、斷線、例外及重現步驟（移除敏感資料） |
| 結論 | Pass / Fail / Inconclusive；只有全部通過條件與證據完整時才可填 Pass |

此紀錄是人工判讀，腳本輸出或 emitter 的結束碼均不是 isolation pass 的替代品。
