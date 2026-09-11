# Android 傳輸 V2 0.4.0：互動與穩定性修正

## 本輪回報

本版針對四個可重現問題重新設計，而不是繼續在 0.3.x 的 SwiftUI 表格上疊加手勢：

1. 建立日期空白，五個表頭無法排序。
2. 點到新項目後，藍色反白仍停留在舊項目。
3. 拖到 Finder 會得到 `.pdf.pdf`，而 `.txt` 等檔案不能可靠拖出。
4. 拔除手機後 App 卡死，無法回到等待連線。

## 根因與替換方案

### 1. 表頭只有外觀，缺少完整排序資料流

0.3.x 雖然顯示五欄，但表頭排序描述與實際 `objects` 排序沒有形成可靠的原生資料流。0.4.0 將每個 `NSTableColumn` 綁定 `sortDescriptorPrototype`，再把 `sortDescriptorsDidChange` 回寫到 `BrowserSort`；AppModel 以純 Swift `MTPObjectSorter` 重排資料。

同一欄連續點擊會切換升冪／降冪，並保留 macOS 原生排序箭頭。五種排序皆有單元測試，不再只是 UI 宣告。

### 2. SwiftUI 儲存格手勢搶走列選取事件

0.3.x 在儲存格上同時處理雙擊與拖曳。事件可以先被手勢辨識器消耗，使 SwiftUI selection binding 與底層 row highlight 不同步。

0.4.0 使用 `NSTableView` 的單一 selection model。雙擊由 `doubleAction`、拖曳由 table data source、右鍵由 table menu 處理；儲存格只負責顯示，不攔截點擊。藍色底色與真正被選取的 row index 因此由同一個 AppKit 控制項產生。

### 3. 建立日期從未真正讀取

MTP 一般列表不保證附帶建立日期。0.4.0 新增 `mtp_bridge_get_object_creation_time`，查詢可選的 `LIBMTP_PROPERTY_DateCreated`。能力查詢只作為提示：即使手機宣告不支援，也會進行有限次直接讀取，再按 file type 快取結果，避免部分 Android 裝置錯誤宣告能力時整欄永遠空白。

為避免大資料夾每列多一次 USB round trip，初始列表不查日期；畫面先顯示，再由背景工作逐批補齊。結果有三種明確狀態：

```text
讀取中…
實際日期
裝置未提供
```

未提供不視為錯誤，也不會拿修改日期代替。

### 4. Finder 名稱與型別由兩套機制重複推導

0.3.x 的 `suggestedName` 已含副檔名，同時 item provider 又以 UTType 宣告型別；Finder 對部分型別會再次附加副檔名。未知型別則可能沒有 Finder 可接受的 representation。

0.4.0 使用 `NSFilePromiseProvider`：

- Promise delegate 的 `fileNameForType` 回傳完整檔名一次。
- 已知副檔名使用對應 UTType。
- 未知副檔名 fallback 到 `public.data`。
- Finder 提供目的資料夾後才執行下載。

因此 `report.pdf` 維持 `report.pdf`，`notes.txt` 可正常建立 promise，不再依賴 Finder 猜名稱。

### 5. 拔線處理仍等待可能卡住的 MTP session

0.3.x 在發現 USB 消失後，狀態切換仍可能被舊 MTP 工作或 session close 延遲。0.4.0 把兩件事拆開：

```text
獨立 libusb presence monitor
→ 連續兩次 miss
→ MainActor 立即切回 disconnected
→ 取消資料夾、metadata、傳輸工作
→ 舊 MTP session 在 UI 之外異步收尾
```

USB monitor 不使用主 MTP actor；libusb 探測本身失敗時不會誤判拔線。所有舊非同步工作帶 generation token，斷線後不能恢復舊清單或 loading 狀態。

## 防退步驗證

0.4.0 新增或擴充：

- 五欄升冪／降冪排序測試。
- 未知日期固定在底部測試。
- `.pdf`／`.txt` Promise 名稱只保留一次副檔名測試。
- MTP `DateCreated` 支援、缺值與不支援情境。
- 快速 USB endpoint presence bridge 情境。
- 兩次 miss、present reset、probe failure 不拔線的純狀態機測試。
- 以 object ID 重映射 row index 的選取測試，確保排序與建立日期補齊後反白仍跟著同一個檔案。
- 原生 `NSTableView`、`NSFilePromiseProvider` 與禁止舊 SwiftUI 手勢的靜態稽核。
- 斷線時 UI transition 必須先於舊 session close 的回歸稽核。
- macOS 安裝器在依賴編譯前執行完整 SwiftUI／AppKit type-check。

## 驗證界線

自動測試已驗證資料流、狀態機、C bridge 與原始碼契約；目前封包環境沒有 AppKit runtime、Finder 或實體 Android USB，因此真實藍色反白、Finder promise 與拔線反應仍需在 M 系列 Mac 上執行 `docs/development/TEST_PLAN_0.7.0.md` 的實機矩陣後才能宣稱正式認證。
