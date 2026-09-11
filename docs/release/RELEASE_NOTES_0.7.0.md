# Mac Android Transfer V2 0.7.0 — device-launch-r1

本版主要修正插入手機時背景偵測器可能因舊 App 路徑失效而顯示「找不到檔案」的問題。

## 主要變更

- 解除舊 ServiceManagement helper 註冊，避免殘留 helper 指向已刪除的父 App。
- 新 helper bundle identifier 使用 `io.github.mtpbridge.DeviceInsertionAgentV2`。
- 註冊 token 綁定 build、package identity 與主 App 精確 bundle path。
- 啟動前驗證 App bundle、可執行檔與 bundle identifier。
- 父 App 不存在時，改由 Launch Services 尋找目前有效的 Android 傳輸 V2。
- 禁用 running-application substitution，避免開啟另一份舊副本。
- 安裝流程先啟動主 App 完成 helper migration，再視需要啟動目前內嵌 helper。
- 新增候選 App 選擇與舊路徑回歸測試。
- 保留 0.6.11 的手機 ↔ Finder 雙向檔案／資料夾傳輸與既有 UI 功能。

## 平台

- Apple Silicon
- macOS 14+

詳細內容請參閱 repository 中的 `CHANGELOG.md`、`docs/history/DEVICE_LAUNCH_FIX_0.7.0.md`、`docs/ARCHITECTURE.md` 與 `SECURITY.md`。
