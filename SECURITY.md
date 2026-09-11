# Security

## 資料處理

Android 傳輸 V2 只在 Mac 與使用者直接連接的 Android 手機之間傳輸檔案。0.4.0 不包含網路 API、遙測、廣告 SDK、Keystone、Breakpad 或自動上傳日誌。

## Sandbox 與權限

App 宣告：

- `com.apple.security.app-sandbox`
- `com.apple.security.device.usb`
- `com.apple.security.files.user-selected.read-write`
- `com.apple.security.files.bookmarks.app-scope`

security-scoped bookmark 用於 App 重啟後恢復持久傳輸工作。每次存取在工作生命週期明確 start／stop，不把 scope 無限期留在程序中。

## 本機持久化資料

Application Support 中的傳輸佇列可能包含：

- 本機完整路徑與 security-scoped bookmark data
- 遠端 object／storage identifiers
- 手機 VID／PID、廠牌、型號與完整序號（若有）
- 工作名稱、大小、狀態與錯誤訊息

這些資料不會上傳，但具有隱私敏感性。不要直接公開 `transfers.json`；分享前應刪除私人路徑、bookmark 與序號。

Finder File Promise 使用 ephemeral job，不寫入 persistent queue。拖出暫存內容由 App 的隔離 temporary area 管理；Finder 完成或失敗後釋放 delegate，舊暫存會由啟動清理策略移除。

## 防止傳到錯誤手機

新工作綁定排入佇列時的裝置身分：有序號時精確比對；無序號時退回 VID/PID＋廠牌／型號。identity 缺失或不符合時不開始傳輸。

斷線後 persistent job 回到 queued，只有接回符合 identity 的裝置才可繼續。無序號且同型號的兩支手機仍可能無法區分，因此此情境應一次只連接一支。

## USB presence monitor 的權限邊界

0.4.0 的拔線監控只做短生命週期 libusb enumeration，讀取 bus、address、VID、PID 是否仍存在：

- 不 claim USB interface。
- 不讀取手機檔案或 MTP object。
- 不執行寫入。
- 不把 probe failure 當成拔線。
- 判定拔線後只觸發本機狀態清理與取消 token。

舊 MTP session 的 close 在 UI transition 後異步執行，避免不可信裝置狀態阻塞主畫面。

## 不受信任內容

手機內容與下載檔案均視為不受信任。App 不執行、預覽或自動開啟遠端檔案；「在 Finder 顯示」只定位使用者已下載項目。

遠端檔名先經 `FilenamePolicy` 清理路徑分隔符與不安全名稱。Finder Promise 回傳清理後的完整名稱一次，避免型別推導額外修改名稱。固定長度 partial 側車檔只建立在使用者選定目的資料夾；成功後移除。

## 建立日期 metadata

MTP `DateCreated` 僅用於顯示與排序，不影響下載續傳指紋、上傳覆蓋判定或安全決策。缺失、格式異常或不支援會被視為無值，不會拿修改日期替代，也不會使資料夾載入失敗。

## 安裝器與相依性隔離

雙擊安裝器不要求管理員權限，不執行 Homebrew／MacPorts／系統更新。它在處理依賴前先以現有 macOS SDK type-check 完整 App 原始碼。

既有 arm64 libmtp／libusb 只有通過 header、link、architecture 與 dynamic dependency 稽核後才複製到專案；Mach-O 修改只作用於 project-local copy。缺件時，內附固定版本來源先驗證 SHA-256，再只於 `.local/` 解壓與編譯。安裝器拒絕 root／sudo。

App 執行後，macOS 會建立標準 sandbox container 保存佇列與 bookmarks；這是執行期使用者資料，不是全域安裝套件。專案移除器不跨出目前資料夾刪除 container，避免誤刪未完成工作。

## 依賴與 Release

Release 稽核檢查：

- 主程式與嵌入 dylib 皆為 arm64-only
- 無 Homebrew、暫存目錄、使用者目錄或開發機絕對依賴
- libmtp／libusb 透過 `@rpath` 從 App bundle 載入
- Developer ID Application、Hardened Runtime、secure timestamp、deep／strict codesign
- Sandbox、USB、user-selected 與 bookmark entitlements
- macOS 14 最低版本

正式散布仍需 notarization、stapling 與乾淨機器 Gatekeeper 驗證。

## 回報問題

安全回報應包含版本、macOS／Android 型號、可重現步驟與已去識別化日誌。不要附上 bookmark、私人檔案、完整本機路徑或完整手機序號。
