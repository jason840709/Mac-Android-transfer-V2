# Build Validation — 0.7.0-device-launch-r1

Release identity: `0.7.0-device-launch-r1`, version 0.7.0, build 22.

驗證流程共 27 階段，包含 64 個 Swift tests、10 個 C bridge scenarios、Clang static analyzer、Swift warnings-as-errors、Finder exact-destination、雙向檔案／資料夾傳輸、MTP 共存、queue migration、UI/readability，以及 path-safe Device Agent contract。

Device Agent contract 會檢查：

- helper V2 bundle identifier 與 build/package identity；
- 註冊 token 含目前主 App 精確路徑；
- 舊 helper 解除與 process retirement；
- 不存在的父 App 不得被開啟；
- Launch Services fallback；
- 候選 App 必須有正確 bundle ID、存在且有可執行檔；
- 禁止 running-application substitution；
- direct builder、Xcode target 與 macOS preflight 使用相同 candidate-policy source。

最終 ZIP 必須重新解壓，再由解壓內容執行同一套驗證。
