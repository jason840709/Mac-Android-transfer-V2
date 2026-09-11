# Mac Android Transfer V2 0.7.0 Release Checklist

- [ ] Package `0.7.0-device-launch-r1`, version 0.7.0, build 22。
- [ ] helper ID 為 `io.github.mtpbridge.DeviceInsertionAgentV2`。
- [ ] 主 App 與 helper 均包含相同 `MTPBridgePackageID` 與 build。
- [ ] 註冊 token 綁定目前主 App 精確 bundle path。
- [ ] 舊 helper 註冊與 process 會被移除。
- [ ] 不存在的父 App 不會傳給 `openApplication`。
- [ ] Launch Services fallback 能找到目前有效 App。
- [ ] `allowsRunningApplicationSubstitution` 為 false。
- [ ] Command+Q 後重新插入手機可自動開啟主 App，無「找不到檔案」。
- [ ] 0.6.11 雙向檔案／資料夾傳輸回歸通過。
