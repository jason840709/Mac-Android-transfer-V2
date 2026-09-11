# Mac Android Transfer V2 Architecture

## 設計目標

1. 原生支援 Apple Silicon，不依賴 Rosetta。
2. 不預掃整支手機，只列舉使用者目前需要的資料夾或所選子樹。
3. 互動行為優先使用 macOS 原生控制項，避免自行模擬 Finder 的選取、排序與拖放。
4. USB 物理拔線不得等待可能卡住的 MTP session；畫面狀態與底層收尾必須解耦。
5. 在 USB 抖動、手機鎖定或 session 中斷時，讓批次可恢復而不是整批重來。
6. 正式檔案只在驗證完成後替換，降低半成品與資料遺失風險。
7. 把不安全的 libmtp 指標、記憶體所有權與 C callback 隔離在小型 ABI。
8. 所有 MTP 操作序列化，避免對狀態式協定做不可靠的平行呼叫。
9. 持久化工作不得在重新連線後誤傳到另一支手機。

## 分層

```text
SwiftUI shell
    │
    ├── RemoteBrowserTable (NSViewRepresentable → NSTableView)
    │       選取、藍色反白、表頭排序、欄寬、雙擊、File Promise
    │
    └── AppModel (@MainActor)
            導航、畫面狀態、建立日期補齊、使用者動作
            │
            ├── USBPresenceMonitor (detached utility task)
            │       獨立 libusb endpoint probe，不等待 MTP actor
            │
            └── TransferCoordinator (@MainActor)
                    持久化佇列、裝置綁定、重試、批次、續傳策略
                    │
                    ▼
             LibMTPClient (actor)
                    Swift 型別 ↔ C ABI、session 所有權、callback lifetime
                    │
                    ▼
             mtp_bridge.c
                    libmtp session、錯誤分類、取消 token、交易式替換
                    │
                    ▼
             libmtp 1.1.23 → libusb 1.0.30 → macOS USB stack
```

`MTPBridgeCore` 不依賴 SwiftUI、AppKit 或 libmtp，因此可在 Linux 驗證模型、檔名、五欄排序、USB removal state machine、partial 指紋、裝置身分、重試、速度與狀態呈現。

## AppKit 原生檔案表格

0.4.0 不再以 SwiftUI `Table` 加上每個儲存格的手勢組合實作瀏覽器。`RemoteBrowserTable` 包裝一個 view-based `NSTableView`，由 AppKit 擁有完整互動生命週期：

- `selectedRowIndexes` 是唯一列選取來源。
- `tableViewSelectionDidChange` 將 object ID 集合回寫 AppModel。
- 外部資料刷新後，coordinator 只依 object ID 將 selection 同步回 row indexes。
- `doubleAction` 只在真正雙擊資料夾時開啟，不與單擊 selection 競爭。
- `sortDescriptorPrototype`、`sortDescriptorsDidChange` 與原生表頭箭頭控制排序方向。
- `NSTableColumn` 管理 min／ideal／max width、拖曳調寬、欄位順序與 autosave。
- table data source 管理 Finder 拖入及 `NSFilePromiseProvider` 拖出。

儲存格只建立圖示與文字 view，不註冊 SwiftUI tap／drag gesture，因此藍色反白與實際選取不會由兩套事件系統分別維護。

## 排序資料流

表頭只負責輸出 `MTPObjectSortKey + ascending`。真正排序由 `MTPObjectSorter` 完成：

- 名稱使用 `localizedStandardCompare`。
- 類型先比較語意分類，再比較副檔名及名稱。
- 大小比較 `UInt64` bytes。
- 建立／修改日期比較 `Date`；未知值固定在底部。
- 資料夾在所有欄位下保持在檔案之前。
- 相同值以名稱與 object ID 作穩定 tie-breaker。

AppModel 的顯示陣列是排序結果；`NSTableView` 不自行改變資料順序，避免 AppKit row indexes 與 Swift object IDs 分離。

## 建立日期補齊

MTP `Get_Files_And_Folders` 回傳的標準 object 結構不保證有可靠建立日期。0.4.0 將初始列表與選用 metadata 分開：

```text
快速列出目前 parent 的 children
    → creationDate = nil
    → 畫面立即顯示，建立日期標記為 pending
    → 背景逐項呼叫 mtp_bridge_get_object_creation_time
    → 查詢 LIBMTP_PROPERTY_DateCreated
    → 每 16 項批次回寫 UI
```

C session 依 file type 快取 `DateCreated` 是否支援。property 不支援、值缺失或格式無法解析時回傳成功＋0，UI 顯示「裝置未提供」，不把 optional metadata 缺失升級成資料夾載入錯誤。

建立日期 task 綁定 navigation generation；換資料夾、斷線或 AppModel 重置時取消。傳輸正在執行時暫停補齊，避免純顯示工作與真正讀寫爭用序列化 MTP actor。

## USB 連線與物理拔線

初次連線：

1. `LIBMTP_Detect_Raw_Devices` 取得候選。
2. 依 bus location 與 device number 選擇候選。
3. 使用 `LIBMTP_Open_Raw_Device_Uncached` 開啟，不建立全裝置檔案快取。
4. 讀取裝置資訊、能力與 storage 清單。
5. UI 只載入目前資料夾。

開啟成功後，`USBPresenceMonitor` 啟動 detached utility task。它使用獨立、短生命週期的 libusb enumeration，只比對 bus、device address、VID 與 PID，不 claim interface、不呼叫 MTP session，也不排入 `LibMTPClient` actor。

判定規則：

```text
present       → miss counter 清零
missing       → miss counter +1
probe failed  → 不視為 missing，也不觸發拔線
連續 2 次 missing → physical disconnect
```

probe 間隔為 250 ms。判定拔線後，MainActor 先執行 `transitionToDisconnected`，立即清除 device／storage／objects／selection／loading，再要求傳輸取消；舊 client 的 `close()` 放到不阻塞 UI 的 task。所有連線與資料夾工作都有 generation guard，舊 task 無法在新狀態上回填資料。

## MTP 序列化與 presence probe 的邊界

MTP session 操作仍經過 `LibMTPClient` actor，確保同一 session 不重入。傳輸、rename、delete、metadata 讀取與列表均遵守序列通道。

只有「裝置是否仍存在」使用獨立 libusb probe，因為它不讀寫 MTP object，也不需要持有 session。這項例外是為了讓物理拔線狀態不被卡住的 MTP request 阻塞；probe 不會與 session 共享 mutable libmtp 狀態。

## 持久化工作與手機綁定

每個新工作保存 `MTPDeviceIdentity`：VID、PID、廠牌、型號與序號。有穩定序號時採 trim 後 canonical Unicode 精確比對；序號缺失時才退回 VID/PID＋廠牌／型號的保守比對。

工作執行前重新讀取目前裝置 identity；不符合時不開始讀寫。斷線時：

- 持久 queue job 取消目前 C token、清除速度／phase、回到 queued，接回同一支手機後才可重跑。
- Finder File Promise 是 ephemeral job，不寫入 queue；斷線時立即以錯誤完成 promise，避免 Finder 永久等待。

無序號且完全相同的兩支手機仍無法由 MTP metadata 唯一區分，這是協定層限制。

## Finder 拖出

`NSTableViewDataSource.tableView(_:pasteboardWriterForRow:)` 保留 0.4.0 的原生 `NSFilePromiseProvider` 實作：

1. `fileNameForType` 回傳 `FilenamePolicy.promisedFileName`，包含原副檔名且只回傳一次。
2. 已知副檔名轉成對應 UTType；未知副檔名使用一般 data。
3. Finder 在 drop 完成後呼叫 `writePromiseTo`，並提供最終項目的完整 URL。
4. AppModel 將該工作標記為 `LocalTransferPlacement.exactItem`。
5. 遠端根項目的 relative components 為空，因此直接映射 Finder URL；只有 promised folder 的 descendants 才附加在其下。
6. exact promise 使用 `allowResume = false` 直接寫入該 URL，不建立目的父資料夾中的 hidden sidecar。
7. 大小與根項目類型驗證完成後，completion handler 才回報成功。
8. 失敗或取消時，移除本次原本不存在、由 promise 建立的 exact root。

這條路徑不使用 later experimental `DragExports` staging、`moveItem` 或 `replaceItemAt`。一般工具列 Download 仍使用 resumable sidecar 與正式檔原子替換，兩種目的位置語意由 `LocalTransferPlacement` 明確分開。

## 本地安裝與依賴隔離

Finder 雙擊入口依序執行：完整 AppKit／SwiftUI type-check、依賴解析、direct Swift/C build、bundle 簽章與稽核。預檢必須在任何 libmtp／libusb 編譯之前完成。

解析器先驗證專案內 staging；其次只讀取系統中相容的 arm64 libmtp/libusb；最後才在 `.local/` 建立固定版本。任何不相容舊版都保留原狀，不執行套件管理器更新。

固定 fallback source archive 隨套件置於 `Vendor/source-archives/`，使用前核對 SHA-256。最終 App 只依賴 `@rpath` 內嵌 dylib 與 macOS 系統 framework。候選 dylib 的 Mach-O 變更只對 project-local copy 進行：架構驗證／必要時 thin → 移除舊簽章 → 修改 load commands → 重新簽章 → strict verify。新 App 在 staging 通過 audit 後才原子替換 `dist/Android 傳輸 V2.app`。

## 為什麼不掛載成 Finder 磁碟

MTP 不是 POSIX 檔案系統：沒有一致的隨機寫入、鎖定、inode 或真正原子 rename。用 FUSE 假裝成磁碟會把 Finder 預讀、metadata 查詢與隱藏檔寫入放大成大量 MTP round trip。0.4.0 採專用檔案管理器，讓每個操作可明確排程、取消、重試與驗證。

## 下載流程

一般 Download-panel 工作：

```text
建立所選遠端子樹 manifest（可取消）
  → 建立目的資料夾
  → 已完成檔（大小＋mtime 相符）跳過
  → 使用固定長度 .mtpbridge-partial-<token>.data
  → 寫入 storage/object/name/size/mtime 指紋
  → 指紋不一致或缺少穩定 mtime：刪除舊 partial
  → 支援 partial read 時分段接續
  → partial API 虛假宣告／失敗：停用該 session partial，清空並完整下載
  → 關閉檔案描述符並檢查 close error
  → 驗證大小
  → 原子移動／替換正式檔
  → 套用遠端修改時間
  → 刪除 sidecar metadata
```

Finder exact promise 工作：

```text
Finder 最終 URL
  → root relative components = []
  → allowResume = false，直接建立／截斷 exact target
  → promised folder descendants 才附加在 root 下
  → 每個檔案驗證大小
  → 驗證 root 類型
  → completion handler 成功
```

Finder promise 不把 partial sidecar 寫到 drop folder，也沒有 staging-to-Finder 第二階段，因此不會在 100% 後等待另一個 commit transaction。一般下載完成仍不對每個檔案強制 durable `fsync`；close、大小驗證與原子替換保留。

## 上傳流程

```text
建立本機 manifest（可取消）
  → 名稱正規化，等價 Unicode／大小寫碰撞加上 (2)、(3)
  → 每個遠端 parent 只列一次並快取
  → 建立缺少資料夾
  → 以 .mtpbridge-upload-<token>-<name> 上傳
  → 讀回 metadata 驗證大小
  → 既有正式檔改成 .mtpbridge-backup-<token>-<name>
  → 新檔改成正式名稱
  → 最終化失敗時嘗試復原舊名稱
  → 成功後刪除備份
```

本機修改時間寫入 MTP metadata。整批重試時，正式遠端檔大小與修改時間相符便跳過。0.4.0 不宣稱通用 partial upload resume。


### Android storage-root parent semantics

For both file upload and folder creation, the bridge preserves `MTP_BRIDGE_ROOT_OBJECT_ID` (`0xffffffff`) when the destination is the storage root. It never converts that value to object handle `0`. Nested items use the concrete parent object ID returned by the current MTP session.

## 大量檔案策略

- 初始資料夾列表不逐項查詢 `DateCreated`。
- 建立日期背景補齊分批更新，傳輸期間暫停。
- 本機目錄只建立一次 manifest；資料夾優先，再傳檔案。
- 每個遠端 parent 只列一次 children，後續在記憶體更新快取。
- 遠端資料夾下載只走訪使用者選取的子樹。
- 一批上傳工作結束後才刷新 UI 目錄與 storage 容量。
- 進度 UI 最高約每 100 ms 更新；queue JSON 最高約每秒持久化一次。
- `.DS_Store`、AppleDouble `._*` 與 symlink 不傳輸。
- 檔名限制在 240 UTF-8 bytes，使用 locale-independent collision key 處理大小寫、寬度與重音等價名稱。

## 錯誤、重試與取消

C bridge 將錯誤分類為 no-device、USB、protocol、I/O、storage-full、cancelled、unsupported、verification 等。可重試錯誤最多四次，使用帶 jitter 的指數退避；第二次起重建 session。

取消 token 使用 C11 atomic。同步 libmtp callback 不需取得 Swift actor 即可看到取消。重試 backoff 以短切片檢查取消；大型 manifest 與遞迴走訪也定期檢查。物理拔線會主動 request 所有 active cancellation tokens。

## 本機權限與安全界線

Open Panel 或 Finder 拖入取得的 URL 轉成 app-scoped security bookmark，與持久工作一起保存。執行時在完整 manifest／傳輸生命週期內成對 start／stop security scope。

App entitlements：

- App Sandbox
- USB device access
- user-selected read-write
- bookmarks.app-scope

App 不使用 ADB、不執行手機程式、不上傳檔案／序號／日誌、不自動預覽或執行遠端內容。下載內容仍應視為不受信任；0.4.0 不包含惡意檔案掃描。

## 已知取捨

- MTP `DateCreated` 是可選 property；部分裝置永遠不提供。
- 大小驗證不能取代 cryptographic hash；MTP 通常沒有一致遠端 hash API。
- capability check 不是相容性保證，因此 partial download 有 full-download fallback。
- 安全替換由多個 MTP 操作組成，不是裝置端真正原子 transaction；USB 在 rename／delete 狹窄視窗中斷時可能留下 `.mtpbridge-*`。
- 無序號同型號多裝置無法保證唯一識別，應一次只連接一支。
- AppKit table、Finder promise 與 USB 拔線反應仍需在實際 macOS／Android 組合驗證；Linux 自動測試只能覆蓋資料流與契約。

## 0.6.7 device-insertion agent

The phone auto-open feature is isolated from the transfer engine. The main sandboxed App embeds a second sandboxed LSBackgroundOnly application at `Contents/Library/LoginItems/Android 傳輸 V2 裝置偵測器.app`. The helper owns event-driven IOKit USB notifications and libmtp presence confirmation. The main App owns ServiceManagement registration and direct current-session helper startup.

Registration is modern `SMAppService.loginItem(identifier:)` first, with a deprecated `SMLoginItemSetEnabled` compatibility bridge used only for locally built/ad-hoc development copies. The helper is a required bundle output and is audited/signature-checked rather than silently omitted.
