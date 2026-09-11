# Android 傳輸 V2 0.6.7 — MTP 共存與舊 Android File Transfer Agent

## 這一版修正的誤判

0.6.6 把舊 Google Android File Transfer 的可見主程式 `com.google.android.mtpviewer` 與背景 `com.google.android.mtpagent` 都當成 MTP session owner。這太保守，而且會造成一個實際 bug：使用者已用 Command+Q 關掉舊主程式後，背景 Agent 仍正常常駐，Android 傳輸 V2 卻一直拒絕連線。

重新靜態檢查使用者提供的舊 Android File Transfer binary 後，可以把兩者角色分清楚：

- `Android File Transfer Agent` 內可見 `LIBMTP_Init`、`LIBMTP_Detect_Raw_Devices`、IOKit hot-plug 與 `launchApplication:`。
- Agent binary 沒有 `LIBMTP_Open_Raw_Device_Uncached` / `LIBMTP_Open_Raw_Device` 的呼叫。
- 可見的 `Android File Transfer` 主程式則明確包含 `LIBMTP_Open_Raw_Device_Uncached`、`LIBMTP_Get_Storage`、`LIBMTP_Get_Files_And_Folders` 等真正 session / file-operation API。

因此背景 Agent 是「插入偵測與啟動器」，可見 viewer 才是持續持有 MTP session 的程式。

## 0.6.7 的新仲裁規則

1. `com.google.android.mtpviewer` 正在執行：視為硬衝突，Android 傳輸 V2 暫不 open MTP。
2. 只有 `com.google.android.mtpagent` 正在執行：**不再阻擋 MTP**。
3. 「暫時關閉舊 Android File Transfer」只關閉可見 viewer，不再嘗試終止背景 Agent。
4. 使用者自己 Command+Q 關閉舊 viewer 後，即使 Agent 還在，Android 傳輸 V2 也會在 conflict monitor 下一輪自動重新連線。
5. Android 從 charge-only 切換成 MTP 後仍保留 650 ms settling window，讓舊 Agent 有時間啟動 viewer；如果 viewer 真正出現，就先等待它退出，避免兩個主程式同時 open session。
6. 專案內 libmtp 的 macOS no-USB-reset safety patch 繼續保留。

## 為什麼不直接殺掉舊 Agent？

舊 Agent 是另一套軟體的背景登入項目。它可能由系統維持，也可能在終止後再次出現；而且它本身並不是持續的 MTP session owner。要求使用者到活動監視器結束它既麻煩，也沒有必要。

如果舊 Agent 在下一次插手機時把舊 viewer 再次叫起來，Android 傳輸 V2 會只把**新出現的 viewer**視為衝突。關閉舊 viewer 後，本程式就會恢復連線。

## 建議實機測試

- 保留舊 Android File Transfer Agent 在背景。
- Command+Q 關閉舊 Android File Transfer 主程式。
- 手機切到「檔案傳輸」。
- Android 傳輸 V2 應能連線，不應再要求結束 Agent。
- 下一次重新插入時，如果舊 Agent 又打開舊 viewer，關掉舊 viewer 後 Android 傳輸 V2 應自動接手。
