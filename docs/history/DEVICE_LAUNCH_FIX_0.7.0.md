# Android 傳輸 V2 0.7.0：手機插入喚醒路徑修正

## 問題

舊版隱藏裝置偵測器位於某一版 App bundle 內。當該來源資料夾被刪除、移動，或 ServiceManagement 仍保留舊 helper 時，背景 helper 可能繼續執行，卻仍以已不存在的父 App 路徑呼叫 `NSWorkspace.openApplication`。macOS 因此顯示「找不到檔案」，而不是開啟目前安裝的 Android 傳輸 V2。

## 0.7.0 修正

- 新 helper bundle identifier：`io.github.mtpbridge.DeviceInsertionAgentV2`，與舊註冊切開。
- 註冊身分綁定 `build + package identity + 主 App 精確路徑`。
- 發現舊路徑、舊 build 或舊 helper process 時，先解除舊註冊並啟動目前 App 內嵌 helper。
- helper 啟動主 App 前會驗證 App bundle、可執行檔和 bundle identifier。
- 包含 helper 的父 App 已不存在時，改向 Launch Services 查詢目前可用的 `io.github.mtpbridge.MTPBridge` App。
- 優先選擇與 helper 相同 build、相同 package identity 的 App。
- 關閉 running-application substitution，避免 macOS 把要求開啟的 App 偷換成另一份舊副本。
- 沒有任何安全候選時只寫診斷紀錄，不再對不存在的路徑發出 open 請求。

## 保留範圍

0.6.11 已通過的雙向檔案／資料夾傳輸、Finder 精確目的位置、MTP 共存、排序、傳輸面板、文字大小、配色與滑鼠導覽均未修改。
