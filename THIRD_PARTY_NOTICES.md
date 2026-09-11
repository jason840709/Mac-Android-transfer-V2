# Third-Party Notices

Android 傳輸 V2 會以獨立動態函式庫使用下列專案。正常的雙擊安裝流程不會把它們安裝到系統：相容的既有版本只會被讀取並複製必要的 arm64 內容；缺少或不相容的元件，才使用套件內附、經 SHA-256 驗證的固定 fallback source archive，在本專案的 `.local/` 內編譯，最後嵌入 `Android 傳輸 V2.app/Contents/Frameworks`。實際採用的版本與來源會寫入 `DEPENDENCY_PROVENANCE.txt`。

## libmtp（隔離 fallback 固定為 1.1.23）

libmtp 提供 Media Transfer Protocol 裝置存取。專案內保留 GNU Lesser General Public License 2.1 文字：

```text
Vendor/licenses/libmtp-LGPL-2.1.txt
```

Upstream project: https://github.com/libmtp/libmtp

隨包來源：`Vendor/source-archives/libmtp-1.1.23.tar.gz`  
SHA-256：`74a2b6e8cb4a0304e95b995496ea3ac644c29371649b892b856e22f12a0bdeed`

## libusb（隔離 fallback 固定為 1.0.30）

libusb 提供跨平台 userspace USB access。專案內保留 GNU Lesser General Public License 2.1 文字：

```text
Vendor/licenses/libusb-LGPL-2.1.txt
```

Upstream project: https://github.com/libusb/libusb

隨包來源：`Vendor/source-archives/libusb-1.0.30.tar.bz2`  
SHA-256：`fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf`

## 動態連結與散布

- 兩個函式庫都以獨立 `.dylib` 放入 App 的 `Contents/Frameworks`。
- 安裝器只在 project-local 複本上移除既有 linker／ad-hoc signature、把 install name 改成 `@rpath`、重新簽章並驗證；拒絕把 Homebrew、MacPorts、使用者目錄、暫存目錄或其他專案的絕對路徑帶進 App。
- App 建立時會先簽署兩個內嵌 dylib，再以相同身分簽署 App。
- 每次建立後的實際來源與版本會記錄在 `Vendor/DEPENDENCY_PROVENANCE.txt`，並複製進 App resources。
- 本專案不修改上游原始碼；若未來加入 patch，應保存 patch、建置指令與對應 source offer／取得方式。

本檔是工程上的 notices 清單，不是法律意見；對外散布前應由發佈者確認適用授權義務。
