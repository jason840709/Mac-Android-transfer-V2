# Android 傳輸 V2 0.6.8 — Finder → Android 上傳修正

實機錯誤 `PTP Layer error 2009 / PTP Invalid Object Handle` 發生在 SendObjectInfo。Android 的 MTP server 在建立新物件前會用 request 的 parent object handle 查找目的資料夾；若該 handle 已因 USB 模式切換、MTP session 重開或其他 client 暫時取得裝置而失效，server 會拒絕 SendObjectInfo。

0.6.7 的上傳 job 只保存 `parentObjectID`。這個 ID 在排隊時有效，但重連後可能已過期。0.6.8 會同時保存從 storage root 到目的資料夾的名稱 breadcrumb，並在**每次真正執行上傳／重試**前從 root 逐層列舉，取得目前 session 的新 object handles。主 App 在重連時也會重建可見 breadcrumbs 的 object IDs。

因此新的流程是：

`Finder 檔案 → 保存目的 path names → 執行前用目前 session 重新解析 folder handles → SendObjectInfo → SendObject`。

舊佇列格式仍可解碼；只有舊 job 沒有 path 時才退回既有 parentObjectID。
