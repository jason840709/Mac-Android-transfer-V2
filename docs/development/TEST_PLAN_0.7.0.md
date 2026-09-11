# 0.7.0 Real-Mac Test Plan

1. 解壓到新的固定資料夾並安裝，確認 Terminal 顯示 package `0.7.0-device-launch-r1`。
2. 測試一個 Finder → 手機檔案、一個資料夾，以及一個手機 → Finder 檔案。
3. Command+Q 關閉主 App，確認背景 `AndroidTransferV2DeviceAgent` 仍存在。
4. 拔除手機，等一秒，再插入並切換為「檔案傳輸」。
5. 確認主 App 自動開啟，不得顯示「找不到檔案」。
6. 再重複一次 Command+Q／拔除／插入。
7. 將舊測試版來源資料夾移到垃圾桶後再重複；新版 helper 必須使用目前有效 App，而不是舊路徑。
8. 若失敗，執行 `診斷手機自動開啟.command`，保存完整報告。
