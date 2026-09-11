# 0.7.0 安裝說明

請解壓到一個全新的、準備保留的資料夾後執行安裝器。0.7.0 會停止並解除舊的 DeviceInsertionAgent／DeviceWatcher／MTPAutoLaunch，改用新的 `DeviceInsertionAgentV2`，再把註冊綁定目前 App 的 build、package identity 與精確 bundle path。

安裝器會先啟動主 App，讓它完成舊 helper migration，再啟動目前 App 內嵌的背景偵測器。不要把新檔直接覆蓋進舊版本資料夾。
