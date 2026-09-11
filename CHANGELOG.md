# Changelog

## 0.7.0 (build 22) — device-launch-r1

- 修正舊背景 helper 對已刪除父 App 路徑執行 open，導致手機插入時出現「找不到檔案」。
- 將新 helper bundle identifier 切換為 `io.github.mtpbridge.DeviceInsertionAgentV2`，並移除舊 helper 註冊。
- 註冊 token 改為 build、package identity 與主 App 精確 bundle path。
- 啟動前驗證 App bundle、可執行檔與 bundle identifier。
- 父 App 不存在時，使用 Launch Services 尋找目前有效 App，優先比對 package identity／build。
- 禁用 running-application substitution，避免啟動另一份舊副本。
- 安裝流程先啟動主 App 完成 helper migration，再視需要啟動目前內嵌 helper。
- 新增 6 個候選 App 選擇與舊路徑回歸測試。
- 保留 0.6.11 的雙向檔案／資料夾傳輸與所有既有 UI 功能。

## 0.6.11 (build 21) — folder-upload-r1

- 修正 Android 儲存空間根目錄的資料夾上傳 parent sentinel。
