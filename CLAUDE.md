# Mac Clean

App macOS liệt kê mọi file và thư mục theo từng volume để tìm và dọn thứ chiếm chỗ. File này chỉ ghi những điều **không thấy được từ code** nhưng dễ làm sai. Tài liệu cho người dùng nằm trong `README.md`.

**Nguyên tắc số một: không bao giờ xoá thứ người dùng không tick, không bao giờ xoá thứ làm hỏng macOS hay app.** Mọi thay đổi chạm tới tick, lập kế hoạch, kiểm tra an toàn hay xoá phải kèm test và phải qua `Scripts/mutate.py`.

Dự án độc lập: không import, không dùng chung package với App Clean (`~/projects/AppClean`). Phần nào chép hoặc viết lại từ App Clean thì ghi nguồn trong comment đầu file và trong commit message (`Adapted from App Clean <file> @<commit>`).

## Cấu trúc

| Target | Vai trò |
|---|---|
| `MacCleanCore` | Mọi quyết định: `NodeStore` (cây), `Scanner`, `SafetyPolicy`, `DeletionPlan`/`Remover`/`PermanentDeleter`, `AdminScript`, `ActionLog`, `Browse` (sắp xếp, lọc), `SuggestionFinder`, `Preferences`, `VolumeCatalogRules`, `FirmlinkMap`. Chỉ Foundation, **không I/O trực tiếp**: đọc qua `FileSystem` và `DirectoryReading`, thay đổi qua `Trashing`, `PermanentRemoving`, `AdminActing`/`AdminRemoving`; hỏi máy qua `OpenFileChecking`, `MountChecking`. |
| `MacCleanSystem` | Nối Core với máy thật: `BulkDirectoryReader` (getattrlistbulk), `RealFileSystem`, `VolumeCatalog`, `OpenFileChecker` (libproc), `MacTrasher`, `AdministratorScriptRunner`, `Permissions`, `MacCleanEnvironment` (thật hoặc sandbox), `FilePreferences`. |
| `MacClean` | App AppKit: `MainWindowController` (NSOutlineView), `AppDelegate` (menu bar, Dock, menu chính), `AppModel`, Settings và Gợi ý (SwiftUI). Lớp mỏng, không ra quyết định an toàn. |
| `macclean-probe` | CLI **chỉ đọc**: `scan`, `volumes`, `bench`, `dataless`. Không có đường code xoá. Không đóng vào DMG. |

## Lệnh thường dùng

```bash
swift build
Scripts/test.sh                        # swift test, tự chạy lại khi gặp lỗi TestingMacros của CLT
python3 -I Scripts/mutate.py [tên]     # phá từng chốt an toàn; mọi đột biến phải bị bắt (KILLED)
Scripts/build_app.sh [release|debug] [universal]
Scripts/make_dmg.sh                    # build universal, build/MacClean-<version>.dmg và .sha256
swift Scripts/make_icon.swift          # Resources/AppIcon.icns từ ảnh gốc Resources/AppIcon-source.png
swift Scripts/make_menubar_icon.swift  # Resources/MenuBarIcon.png và @2x từ Resources/MenuBarIcon-source.png
.build/release/macclean-probe scan /   # quét như app trên máy thật (chỉ đọc)
"build/Mac Clean.app/Contents/MacOS/MacClean" --sandbox <thư mục>
```

**Mọi thử nghiệm xoá chạy bằng `--sandbox` trong thư mục tạm.** Không bao giờ thử trên dữ liệu thật, kể cả ổ ngoài thật.

## Môi trường: chỉ có Command Line Tools

- Test dùng **Swift Testing**. `swift test` hay báo `plugin for module 'TestingMacros' not found`; `Scripts/test.sh` tự chạy lại. Khi hết số lần thử, `mutate.py` có thể báo nhầm BUILD-FAILED; script tự chạy lại một lần, nếu vẫn lỗi thì chạy tay mutation đó.
- **Không dùng `@State`** (thiếu macro plugin). Trạng thái nằm trong `ObservableObject`, binding viết tay bằng `Binding(get:set:)`.
- Trong `#expect`, đừng truyền key path như hàm (`allSatisfy(\.x)`): viết closure.
- `Scanner` trùng tên với `Foundation.Scanner`. Trong target có kiểu cùng tên (như probe), viết `MacCleanCore.Scanner`.
- Chuỗi giao diện: key là câu tiếng Anh, dịch trong `Resources/vi.lproj/Localizable.strings`. Lý do từ Core có đuôi là đường dẫn ("inside protected folder /x") thì dịch bằng `R(_:)`, không dùng `L(_:)`. Thêm chuỗi mới thì thêm bản dịch. Lệnh trích key: `grep -oh 'L("[^"]*")\|LF("[^"]*"' Sources/MacClean/*.swift | sort -u`.

## Viết test

- Core test trên `FakeFileSystem` (trong bộ nhớ), vừa là `FileSystem` vừa là `DirectoryReading`. Fake mô phỏng `lstat` (theo symlink ở thư mục cha, không theo ở thành phần cuối), firmlink (`/Users` là `/System/Volumes/Data/Users`, `canonicalPath` giữ dạng `/Users`), device thật theo mount point, và rút ổ (`gone`). Reader giả **cố ý đi theo symlink** như một reader ngây thơ, để test bắt được nếu Scanner tự đi vào link. Đừng làm đơn giản đi.
- Các lớp phòng thủ che nhau. Muốn chứng minh một lớp tự hoạt động thì test riêng lớp đó: `SafetyPolicy.shapeProblem`, `extraProtectedTrees` (chỉ dùng trong test), file system "cái gì cũng có" `AnythingGoes`.
- Thêm chốt an toàn mới thì thêm một dòng vào `MUTATIONS` trong `Scripts/mutate.py`. Mutation chạy trên một bản sao của Core và Tests (đặt trong thư mục tạm, Package.swift chỉ còn Core và test), để không đụng code đang sửa.
- Không test nào chạm Thùng rác, `UserDefaults` hay `~/Library` thật.

## Những cái bẫy đã gặp

- **Volume hệ thống và volume Data có cùng `st_dev`.** Quét `/` mà chỉ so `st_dev` sẽ đi qua firmlink và đếm trùng toàn bộ Data. Ranh giới là `ATTR_CMNEXT_REALDEVID`; ổ khởi động được quét từ `/System/Volumes/Data`.
- **`realpath` giữ nguyên dạng `/System/Volumes/Data/...`.** Đường dẫn để hiển thị, kiểm tra an toàn và xoá luôn dùng dạng firmlink (`/Users/...`); đổi qua `FirmlinkMap.displayPath` (đọc `/usr/share/firmlinks`).
- **`statfs` trên APFS trả số của cả container** (mọi volume cùng "used"). Số theo từng volume (cũng là số `df` hiện) là `ATTR_VOL_SPACEUSED`.
- **`getattrlistbulk` chỉ xếp các thuộc tính có trong `returned`.** Parser đọc theo bit `returned`. Đừng bật `FSOPT_PACK_INVAL_ATTRS`, vì khi đó vị trí các trường bị lệch. `ATTR_CMN_ERROR` đứng ngay sau `returned`.
- Ổ Data thật có file sparse (logical 260 GB, chiếm 49 GB). Kích cỡ hiển thị phải là **allocated**. Khi tạo dữ liệu thử cũng vậy: `mkfile -n` tạo file sparse (allocated 0), nên dùng `mkfile` không có `-n`.
- **Hộp thoại TCC:** khi chưa có Full Disk Access, đọc Desktop, Documents, Containers của app khác… sẽ làm hiện hộp thoại xin quyền. App bỏ qua các thư mục trong `ScanRules.privacyProtectedInHome` (quyết định đã duyệt).
- **Tiến trình thừa hưởng quyền của thứ đã mở nó.** App hay probe chạy từ shell của Claude sẽ dùng Full Disk Access và Accessibility của Claude. Đừng kết luận gì về quyền của Mac Clean từ những lần chạy đó; phép thử quyền phải để người dùng mở app từ Finder.
- **NSOutlineView tạo bằng code mà không đặt `columnAutoresizingStyle`** thì các cột bị co đều về rất hẹp (cột Tên mất chữ). Dùng `.lastColumnOnlyAutoresizingStyle` và đặt `minWidth` cho cột Tên. Checkbox trong ô cần chiều rộng cố định, nếu không icon và tên bị đẩy sang phải.
- **Đổi activation policy (ẩn hoặc hiện Dock):** từ macOS 14, `NSApp.activate` có thể bị từ chối ngay sau khi đổi. Luôn gọi `orderFrontRegardless()` cho cửa sổ (`AppDelegate.bringForward`). Chưa kiểm chứng được trên app mở từ Finder.
- **Tìm kiếm trên 1,8 triệu tên mất khoảng 3 giây**, nên chạy ở luồng nền. Trong lúc đó không được thay đổi cây: `AppModel.isSearching` chặn quét lại và chuyển vào Thùng rác.
- **Chạy app làm thay đổi môi trường của người dùng:** `--sandbox` không ghi `~/Library/Preferences` (cài đặt nằm trong sandbox, không autosave cửa sổ), nhưng macOS vẫn ghi saved state vào thư mục tạm `/var/folders/.../T/`. App chạy thật thì ghi `~/Library/Preferences/local.macclean.app.plist`.
- **Kiểm thử giao diện bằng System Events cướp focus và bấm vào thanh menu của người dùng.** Chỉ làm khi cần, ngắn gọn. Chụp màn hình thì chỉ chụp cửa sổ của app (`screencapture -l <window id>`), không bao giờ chụp cả màn hình: ảnh sẽ dính nội dung riêng tư của người dùng.
- **App icon là ảnh do người dùng chọn** (tạo bằng ChatGPT), lưu ở `Resources/AppIcon-source.png`. Đừng vẽ lại bằng code. `Scripts/make_icon.swift` tìm thân icon theo kênh alpha và đưa về lưới macOS (thân 824/1024, căn giữa). Muốn đổi icon thì thay ảnh gốc (nền trong suốt) rồi chạy lại script.
- **Glyph thanh menu** (ổ đĩa, chổi, ngôi sao) cũng là ảnh người dùng chọn. Ảnh gốc từ ChatGPT **không có kênh alpha**: nền ô cờ được vẽ thẳng vào ảnh. `Scripts/make_menubar_icon.swift` lấy glyph theo độ tối (đen thành đục, xám nhạt thành trong suốt), rồi xuất glyph cao 16 pt trong ảnh 18 pt, 1x và 2x. App nạp nó làm template image; chạy ngoài bundle (`swift run`) thì dùng SF Symbol `internaldrive`. Không có cửa sổ riêng cho status item: muốn chụp thì lấy vị trí qua Accessibility (`menu bar item 1 of menu bar 2`) rồi `screencapture -R` đúng vùng đó.
- **Không có file dataless (iCloud) thật trên máy phát triển.** Việc không kích hoạt tải về mới được đảm bảo bằng `setiopolicy_np` và việc không mở file, chưa thử trên dữ liệu thật.

## Git và phát hành

- Remote `origin`: `git@github.com-dat98it:Dat98it/Mac-clean.git`. Danh tính commit đặt ở mức repo: `Dat98it <dat98.it@gmail.com>`. Kiểm `git config user.email` trước khi commit.
- **Không thêm trailer `Co-Authored-By`.** Commit message tiếng Anh, theo từng thay đổi lô-gic, ghi nguồn phần chép từ App Clean.
- Chỉ commit, push, tạo release khi người dùng yêu cầu. Release: tag `vX.Y.Z`, đính kèm DMG và SHA-256, ghi chú tiếng Việt (bản nháp trong `docs/release-notes/`). Sửa phiên bản trong `Resources/Info.plist` bằng sửa văn bản (hai dòng), không dùng PlistBuddy.
- App ký ad-hoc, chưa notarize. Hướng dẫn mở khi Gatekeeper chặn: bấm **Xong** (đừng bấm "Chuyển vào Thùng rác") rồi **Vẫn mở** trong Cài đặt hệ thống → Quyền riêng tư & Bảo mật. Bản ký ad-hoc mới có CDHash khác, nên có thể phải cấp lại Full Disk Access.
