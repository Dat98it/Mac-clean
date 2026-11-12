# Mac Clean

App macOS gồm ba công cụ trong một cửa sổ: khám phá ổ đĩa (liệt kê mọi file theo từng volume để tìm và dọn thứ chiếm chỗ), gỡ app kèm dữ liệu của nó, và tìm dữ liệu còn sót của app đã gỡ. File này chỉ ghi những điều **không thấy được từ code** nhưng dễ làm sai. Tài liệu cho người dùng nằm trong `README.md`.

**Nguyên tắc số một: không bao giờ xoá thứ người dùng không tick, không bao giờ xoá thứ làm hỏng macOS hay app.** Mọi thay đổi chạm tới tick, lập kế hoạch, kiểm tra an toàn hay xoá phải kèm test và phải qua đột biến (`Scripts/mutate_all.sh`).

Mac Clean là bản gộp của hai dự án cũ: Mac Clean (khám phá ổ đĩa) và App Clean (gỡ app, dữ liệu sót). Phần chuyển từ App Clean nằm ở `UninstallCore`, `UninstallSystem`, `Sources/MacClean/Uninstall/`; commit message ghi nguồn khi chép thêm từ đó.

## Cấu trúc

Hai bộ Core/System **độc lập, cố ý không dùng chung kiểu nào**: mỗi bộ có `SafetyPolicy`, `DeletionPlan`/`Remover`/`PermanentDeleter`, `AdminScript`, `ActionLog` riêng với luật và hình dạng khác nhau (xem "Bẫy"). Đừng gộp chúng thành một: gộp sẽ làm lỏng luật của một bên.

| Target | Vai trò |
|---|---|
| `MacCleanCore` | Khám phá ổ đĩa. Mọi quyết định: `NodeStore` (cây), `Scanner`, `SafetyPolicy`, `DeletionPlan`/`Remover`/`PermanentDeleter`, `AdminScript`, `ActionLog`, `Browse` (sắp xếp, lọc), `SuggestionFinder`, `Preferences`, `VolumeCatalogRules`, `FirmlinkMap`. Chỉ Foundation, **không I/O trực tiếp**: đọc qua `FileSystem` và `DirectoryReading`, thay đổi qua `Trashing`, `PermanentRemoving`, `AdminActing`/`AdminRemoving`; hỏi máy qua `OpenFileChecking`, `MountChecking`. |
| `MacCleanSystem` | Nối Core với máy thật: `BulkDirectoryReader` (getattrlistbulk), `RealFileSystem`, `VolumeCatalog`, `OpenFileChecker` (libproc), `MacTrasher`, `AdministratorScriptRunner`, `Permissions`, `MacCleanEnvironment` (thật hoặc sandbox), `FilePreferences`. |
| `UninstallCore` | Gỡ app và dữ liệu sót. Mọi quyết định: luật khớp (`Scanner`), `OrphanFinder`, `SafetyPolicy`, `DeletionPlan`/`Remover`/`PermanentDeleter`, `SizeCalculator`, nhật ký, danh sách bỏ qua. Chỉ Foundation, **không I/O trực tiếp**: đọc qua `FileSystem`, thay đổi qua `Trashing`, `PermanentRemoving`, `AdminActing`, `LaunchAgentUnloading`. |
| `UninstallSystem` | Nối `UninstallCore` với máy thật: `RealFileSystem`, `BundleReader`, `InstalledAppSources` (thư mục app, `lsregister -dump`, `pkgutil`, PATH/Homebrew), `MacTrasher`, `AdministratorScriptRunner`, `CleanerEnvironment` (thật hoặc sandbox). |
| `MacClean` | App AppKit + SwiftUI, lớp mỏng, không ra quyết định an toàn. `Shell.swift`: cửa sổ (thanh bên + trang), `Navigation`. `MainWindow.swift`: trang Khám phá ổ đĩa (NSOutlineView). `Uninstall/`: `UninstallModel` và `UninstallViews` (trang Gỡ ứng dụng, Dữ liệu còn sót), `SelfUninstaller`. `AppDelegate`: thanh menu, thả app lên icon, Dock, menu chính. |
| `macclean-probe` | CLI **chỉ đọc**: `scan`, `volumes`, `bench`, `dataless` (ổ đĩa), `app-scan`, `orphans` (gỡ app). Không có đường code xoá. Không đóng vào DMG. |

Tên kiểu trùng giữa hai Core (`SafetyPolicy`, `Remover`, `Scanner`, `FileSystem`, `Paths`, `Ownership`, `PlannedItem`...) là chủ ý. **Mỗi file chỉ import một Core.** Ngoại lệ duy nhất là `AppDelegate.swift`, `main.swift` (chỉ dùng tên không trùng: `MacCleanEnvironment`, `CleanerEnvironment`...) và `Shell.swift`. Khi cần tên trùng ở file import cả hai, viết `MacCleanCore.X` hoặc `UninstallCore.X`. Kiểu của lớp app trùng tên phải tránh: bên gỡ app dùng `UninstallModel`, `UninstallCancelFlag`.

## Lệnh thường dùng

```bash
swift build
Scripts/test.sh                        # swift test (cả hai bộ), tự chạy lại khi gặp lỗi TestingMacros của CLT
Scripts/test.sh --filter UninstallCoreTests
Scripts/mutate_all.sh [tên]            # phá từng chốt an toàn của cả hai bộ; mọi đột biến phải bị bắt
python3 -I Scripts/mutate.py [tên]     # chỉ khám phá ổ đĩa (51 đột biến, KILLED)
Scripts/mutate_uninstall.sh [tên]      # chỉ gỡ app (48 đột biến, caught)
Scripts/build_app.sh [release|debug]   # build/Mac Clean.app, arm64, ký ad-hoc
Scripts/make_dmg.sh                    # build/MacClean-<version>.dmg và .sha256
swift Scripts/make_icon.swift          # Resources/AppIcon.icns từ ảnh gốc Resources/AppIcon-source.png
swift Scripts/make_menubar_icon.swift  # Resources/MenuBarIcon.png và @2x từ Resources/MenuBarIcon-source.png
.build/release/macclean-probe scan /   # quét như app trên máy thật (chỉ đọc)
.build/debug/macclean-probe orphans --excluded   # xem OrphanFinder làm gì trên máy thật (chỉ đọc)
"build/Mac Clean.app/Contents/MacOS/MacClean" --sandbox <thư mục> [--page disk|uninstall|leftovers] [--open <App.app>] [--leftovers] [--show]
```

**Cả hai script đột biến sửa file nguồn tại chỗ** rồi khôi phục. Chạy trên cây sạch, không sửa code trong lúc chạy, và đừng `pkill` giữa chừng (file sẽ ở lại trạng thái đã bị phá; `git checkout -- <file>` để khôi phục). Muốn vừa chạy vừa làm việc: chép cây sang thư mục tạm rồi chạy ở đó.

**Mọi thử nghiệm xoá chạy bằng `--sandbox` trong thư mục tạm.** Không bao giờ thử trên dữ liệu thật, kể cả ổ ngoài thật. `--sandbox <thư mục>`: home là `<thư mục>/home` (Thùng rác `home/.Trash`), `/Library` là `Library/`, `/Applications` là `Applications/` (cho gỡ app), mỗi thư mục con của `Volumes/` là một ổ ngoài (có `.timemachine` thì là ổ Time Machine, có `.readonly` thì chỉ đọc, xoá thư mục là "rút ổ"). Cài đặt của Mac Clean lưu ở `<thư mục>/settings.plist`.

## Môi trường: chỉ có Command Line Tools

- Test dùng **Swift Testing**. `swift test` hay báo `plugin for module 'TestingMacros' not found`; `Scripts/test.sh` tự chạy lại. Khi hết số lần thử, đột biến có thể báo nhầm BUILD-FAILED; `mutate.py` tự chạy lại một lần, nếu vẫn lỗi thì chạy tay mutation đó.
- **Không dùng `@State`** (thiếu macro plugin). Trạng thái nằm trong `ObservableObject`, binding viết tay bằng `Binding(get:set:)`. Không dùng `#Preview`, `@Observable`.
- Trong `#expect`, đừng truyền key path như hàm (`allSatisfy(\.x)`): viết closure.
- `Scanner` trùng tên với `Foundation.Scanner`. Trong target có kiểu cùng tên (như probe), viết `MacCleanCore.Scanner`.
- `Package.swift` dùng `swift-tools-version:6.0` chỉ vì `.macOS(.v15)` cần nó; `swiftLanguageModes: [.v5]` giữ Swift 5 mode.
- Chuỗi giao diện: key là câu tiếng Anh, dịch trong `Resources/vi.lproj/Localizable.strings` (một file chung cho cả ba trang, sắp theo key). Lý do từ Core có đuôi là đường dẫn ("inside protected folder /x") thì dịch bằng `R(_:)`, không dùng `L(_:)`. Thêm chuỗi mới thì thêm bản dịch. Lệnh trích key: `grep -ohR 'LF\?("[^"]*"' Sources/MacClean | sort -u`.

## Viết test

- Core test trên `FakeFileSystem` (trong bộ nhớ; mỗi bộ test có bản riêng). Fake mô phỏng `lstat` (theo symlink ở thư mục cha, không theo ở thành phần cuối). Bên ổ đĩa còn mô phỏng firmlink, device thật theo mount point, rút ổ (`gone`); reader giả **cố ý đi theo symlink** như một reader ngây thơ, để test bắt được nếu Scanner tự đi vào link. Đừng làm đơn giản đi.
- Các lớp phòng thủ che nhau. Muốn chứng minh một lớp tự hoạt động thì test riêng lớp đó với cấu hình gốc sai (`dataRoots: ["/"]` bên gỡ app, như `misconfigured(_:)` trong `UninstallCoreTests/SafetyTests.swift`) hoặc `SafetyPolicy.shapeProblem`, `extraProtectedTrees`, `AnythingGoes` (bên ổ đĩa).
- Thêm chốt an toàn mới thì thêm một dòng đột biến: `MUTATIONS` trong `Scripts/mutate.py` (ổ đĩa) hoặc trong `Scripts/mutate_uninstall.sh` (gỡ app, thay thế Perl).
- Không test nào chạm Thùng rác, `UserDefaults` hay `~/Library` thật.

## Những cái bẫy đã gặp

Chung:

- **Hai `SafetyPolicy` khác luật có chủ đích.** Gỡ app (`UninstallCore`) chỉ cho phép dữ liệu trong các thư mục `~/Library` quét và `.app` trong `/Applications`, từ chối thành phần của Apple, dữ liệu của chính app, `.app` lồng `.app`. Ổ đĩa (`MacCleanCore`) cho phép cả thư mục nhà, ổ ngoài ghi được và thư mục allowlist, nhưng coi `/Applications` là thư mục được bảo vệ, từ chối Thùng rác, thư viện Ảnh, ổ Time Machine/chỉ đọc, và bảo vệ thêm Safari, Calendars, AddressBook. Đừng dùng cái này thay cái kia.
- **Tiến trình thừa hưởng quyền của thứ đã mở nó.** App hay probe chạy từ shell của Claude sẽ dùng Full Disk Access và Accessibility của Claude. Đừng kết luận gì về quyền của Mac Clean từ những lần chạy đó; phép thử quyền phải để người dùng mở app từ Finder. Muốn biết quyền thật cấp cho ai thì đọc bảng `access` trong `TCC.db` hệ thống (chỉ đọc, cần Full Disk Access).
- **Full Disk Access:** app không tự hiện trong danh sách, người dùng phải bấm + rồi chọn Mac Clean. Bản ký ad-hoc mới (CDHash khác) có thể cần thêm lại. Bên gỡ app dò quyền bằng cách mở `/Library/Application Support/com.apple.TCC/TCC.db` (`Permissions.hasFullDiskAccess`); cách dò cũ (đọc `~/Library/Safari`...) không dùng nữa vì chưa kiểm chứng được.
- **Chạy app làm thay đổi môi trường của người dùng:** app thật ghi `~/Library/Preferences/com.dat98it.MacClean.plist` và `~/Library/Application Support/com.dat98it.MacClean/` (nhật ký `actions.log` dùng chung cho cả ba công cụ, danh sách bỏ qua). `--sandbox` không ghi `~/Library/Preferences`, nhưng macOS vẫn ghi saved state vào thư mục tạm `/var/folders/.../T/`.
- **Máy bị khoá màn hình thì chụp màn hình cũ và Accessibility không trả cửa sổ.** Kiểm tra `CGSessionCopyCurrentDictionary()["CGSSessionScreenIsLocked"]` trước khi kết luận app lỗi giao diện.
- **Kiểm thử giao diện bằng System Events cướp focus và bấm vào thanh menu của người dùng.** Chỉ làm khi cần, ngắn gọn. Chụp màn hình thì chỉ chụp cửa sổ của app (`screencapture -l <window id>`), không bao giờ chụp cả màn hình: ảnh sẽ dính nội dung riêng tư. Khi tìm tiến trình để lái, dùng `pgrep -f "^build/Mac Clean.app/..."` (neo đầu dòng; khớp rộng sẽ trúng cả shell đang chạy lệnh), và đừng `pkill -f MacClean` rộng: nó đóng luôn bản đã cài trong /Applications.
- **App icon là ảnh do người dùng chọn** (tạo bằng ChatGPT), lưu ở `Resources/AppIcon-source.png`. Đừng vẽ lại bằng code. `Scripts/make_icon.swift` tìm thân icon theo kênh alpha và đưa về lưới macOS (thân 824/1024, căn giữa). Muốn đổi icon thì thay ảnh gốc (nền trong suốt) rồi chạy lại script.
- **Glyph thanh menu** (ổ đĩa, chổi, ngôi sao) cũng là ảnh người dùng chọn. Ảnh gốc **không có kênh alpha**: nền ô cờ được vẽ thẳng vào ảnh. `Scripts/make_menubar_icon.swift` lấy glyph theo độ tối (đen thành đục, xám nhạt thành trong suốt), rồi xuất glyph cao 16 pt trong ảnh 18 pt, 1x và 2x. App nạp nó làm template image; chạy ngoài bundle (`swift run`) thì dùng SF Symbol `internaldrive`.

Khám phá ổ đĩa:

- **Volume hệ thống và volume Data có cùng `st_dev`.** Quét `/` mà chỉ so `st_dev` sẽ đi qua firmlink và đếm trùng toàn bộ Data. Ranh giới là `ATTR_CMNEXT_REALDEVID`; ổ khởi động được quét từ `/System/Volumes/Data`.
- **`realpath` giữ nguyên dạng `/System/Volumes/Data/...`.** Đường dẫn để hiển thị, kiểm tra an toàn và xoá luôn dùng dạng firmlink (`/Users/...`); đổi qua `FirmlinkMap.displayPath` (đọc `/usr/share/firmlinks`).
- **`statfs` trên APFS trả số của cả container** (mọi volume cùng "used"). Số theo từng volume (cũng là số `df` hiện) là `ATTR_VOL_SPACEUSED`.
- **`getattrlistbulk` chỉ xếp các thuộc tính có trong `returned`.** Parser đọc theo bit `returned`. Đừng bật `FSOPT_PACK_INVAL_ATTRS`, vì khi đó vị trí các trường bị lệch. `ATTR_CMN_ERROR` đứng ngay sau `returned`.
- Ổ Data thật có file sparse (logical 260 GB, chiếm 49 GB). Kích cỡ hiển thị phải là **allocated**. Khi tạo dữ liệu thử cũng vậy: `mkfile -n` tạo file sparse (allocated 0), nên dùng `mkfile` không có `-n`.
- **Hộp thoại TCC:** khi chưa có Full Disk Access, đọc Desktop, Documents, Containers của app khác… sẽ làm hiện hộp thoại xin quyền. App bỏ qua các thư mục trong `ScanRules.privacyProtectedInHome` (quyết định đã duyệt).
- **NSOutlineView tạo bằng code:** các cột bị co đều về rất hẹp khi bảng lần đầu được dàn trang hẹp hơn cửa sổ (cột Tên mất chữ). Vì vậy `columnAutoresizingStyle = .noColumnAutoresizing` và `MainWindowController.fillNameColumn()` đặt độ rộng cột Tên mỗi khi vùng nội dung được dàn lại (`PageContainerController.onLayout`). Checkbox trong ô cần chiều rộng cố định, nếu không icon và tên bị đẩy sang phải. Cửa sổ không phải key (chạy từ shell) thì ảnh chụp có thể chưa vẽ lại; đo bằng Accessibility chứ đừng tin một ảnh.
- **`NSHostingView`/`NSHostingController` trong cửa sổ:** đặt `sizingOptions = []`, nếu không SwiftUI quyết định kích cỡ cửa sổ (đã từng ra cửa sổ cao 2400 pt vì `List`).
- **Đổi activation policy (ẩn hoặc hiện Dock):** từ macOS 14, `NSApp.activate` có thể bị từ chối ngay sau khi đổi. Luôn gọi `orderFrontRegardless()` cho cửa sổ (`AppDelegate.bringForward`). Chưa kiểm chứng được trên app mở từ Finder.
- **Tìm kiếm trên 1,8 triệu tên mất khoảng 3 giây**, nên chạy ở luồng nền. Trong lúc đó không được thay đổi cây: `AppModel.isSearching` chặn quét lại và chuyển vào Thùng rác.
- **Không có file dataless (iCloud) thật trên máy phát triển.** Việc không kích hoạt tải về mới được đảm bảo bằng `setiopolicy_np` và việc không mở file, chưa thử trên dữ liệu thật.

Gỡ app và dữ liệu sót:

- `URL.resolvingSymlinksInPath()` **cắt bỏ `/private`** (`/private/tmp` thành `/tmp`), làm đường dẫn sai hơn. Dùng `FileSystem.canonicalPath` (realpath).
- Kéo thả có thể mang *file reference URL* (`file:///.file/id=…`), không có đuôi `.app`. Đổi bằng `(url as NSURL).filePathURL` trước khi kiểm tra.
- **Mục thuộc người khác (thường là root) phải đi đường quản trị.** App App Store (`root:wheel`, 755) không chuyển được vào Thùng rác bằng `FileManager.trashItem` (lỗi 513), dù `/Applications` cho nhóm admin ghi: chuyển một thư mục cần quyền ghi trên chính nó. `Ownership.domain` chuyển các mục này sang `.system`. Sau khi chuyển bằng quyền quản trị, mục trong Thùng rác vẫn thuộc root, nên xoá vĩnh viễn cũng phải đi đường quản trị (`AdminRemoving`, `AdminScript.buildRemoval`). `PermanentDeleter` kiểm tra mục (nằm ngay trong Thùng rác, đúng inode) **trước** khi giao cho root.
- **App của Apple cài từ App Store gỡ được** (TestFlight, Pages, Numbers, Keynote...). "App có sẵn của macOS" là app nằm trên volume hệ thống (đường dẫn thật dưới `/System/`, kể cả Safari trong `/Applications` trỏ vào cryptex) hoặc app `com.apple.*` không có `Contents/_MASReceipt/receipt` (`BundleIDs.isBuiltInApp`). Dữ liệu của các app này đều mang tên `com.apple.*`, nên khi gỡ, `SafetyPolicy.appStoreAppleID` mở đúng tên của chính app (bundle ID, thành phần của nó, kèm tiền tố `group.`). Mọi tên Apple khác vẫn bị từ chối. Bộ quét không ghép "cùng nhà phát triển" và thư mục `Apple` cho app Apple.
- App iPad trên Apple Silicon là bundle bọc: thật ra nằm ở `X.app/Wrapper/X.app`, Info.plist không nằm trong `Contents/`.
- Kéo file tới mép trên màn hình (vùng thanh menu) bằng sự kiện giả lập sẽ mở Mission Control, cả khi thả vào vùng trống của thanh menu. Khi drag tới được icon, app mở luôn trang gỡ app có ô thả.
- Luật trong `OrphanFinder` được chỉnh trên một máy duy nhất. Đổi luật thì chạy `macclean-probe orphans --excluded` và xem lại từng nhóm.
- Bundle ID mới (`com.dat98it.MacClean`) làm Full Disk Access và cài đặt của hai app cũ không còn áp dụng. `SelfUninstaller` chỉ chạy khi bundle ID đúng là `com.dat98it.MacClean`.

## Git và phát hành

- Danh tính commit đặt ở mức repo: `Dat98it <dat98.it@gmail.com>`. Kiểm `git config user.email` trước khi commit. Remote `origin`: `git@github.com-dat98it:Dat98it/Mac-clean.git`.
- **Không thêm trailer `Co-Authored-By`.** Commit message tiếng Anh, theo từng thay đổi lô-gic.
- Chỉ commit, push, tạo release khi người dùng yêu cầu. Release: tag `vX.Y.Z`, đính kèm DMG và SHA-256, ghi chú tiếng Việt (bản nháp trong `docs/release-notes/`). Sửa phiên bản trong `Resources/Info.plist` bằng sửa văn bản (hai dòng), không dùng PlistBuddy.
- App ký ad-hoc, chưa notarize, chỉ chạy trên Apple Silicon, macOS 15 trở lên. Hướng dẫn mở khi Gatekeeper chặn: bấm **Xong** (đừng bấm "Chuyển vào Thùng rác") rồi **Vẫn mở** trong Cài đặt hệ thống → Quyền riêng tư & Bảo mật. Bản ký ad-hoc mới có CDHash khác, nên có thể phải cấp lại Full Disk Access.
- Hai repo cũ (App Clean, Mac Clean 0.1.x) được lưu trữ, không phát triển tiếp.
