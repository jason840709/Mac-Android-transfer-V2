# Contributing

感謝協助改善 Mac Android Transfer V2。

提交變更前，請優先維持專案既有的安全邊界：MTP 操作序列化、USB presence probe 與 session 狀態解耦、傳輸驗證後再替換、持久工作綁定裝置身分，以及不把私人路徑、bookmark、完整手機序號或日誌中的敏感資料提交到 repository。

建議先執行與修改範圍相關的測試；完整驗證入口為：

```bash
./Scripts/verify.sh
```

詳細架構請先閱讀 `docs/ARCHITECTURE.md`，發布要求請閱讀 `docs/release/RELEASE_CHECKLIST_0.7.0.md`。
