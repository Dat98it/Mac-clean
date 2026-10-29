# Mac Clean

Mac Clean liệt kê mọi file và thư mục trên ổ khởi động và trên từng ổ ngoài đang cắm, sắp xếp theo tên, kích cỡ, ngày tạo, ngày sửa hoặc loại. Bạn dùng nó để biết trong vài phút cái gì đang chiếm chỗ, rồi tick những gì muốn dọn và chuyển vào Thùng rác.

App chạy trên macOS 14 trở lên, có icon trên Dock và trên thanh menu. Giao diện tiếng Việt và tiếng Anh, theo ngôn ngữ của máy.

**Nguyên tắc số một: Mac Clean không bao giờ xoá thứ bạn chưa tick, và không bao giờ đụng tới những gì làm hỏng macOS hay app.**

## Cài đặt

1. Tải `MacClean-<phiên bản>.dmg`, mở ra, kéo **Mac Clean** vào **Applications**.
2. App được ký ad-hoc, chưa notarize, nên lần đầu mở macOS sẽ chặn. Khi hộp thoại hiện ra, bấm **Xong** (đừng bấm "Chuyển vào Thùng rác"). Sau đó vào **Cài đặt hệ thống → Quyền riêng tư & Bảo mật**, kéo xuống và bấm **Vẫn mở**.
3. Muốn kiểm tra file tải về, so mã SHA-256 với file `.sha256` đi kèm:
   ```bash
   shasum -a 256 MacClean-0.1.0.dmg
   ```

### Full Disk Access (nên cấp)

Khi chưa có Full Disk Access, Mac Clean **cố ý bỏ qua** các thư mục macOS bảo vệ bằng hộp thoại xin quyền: Desktop, Documents, Downloads, Pictures, Movies, Music, dữ liệu của app khác (Containers, Group Containers), Mail, Messages, Safari, iCloud Drive… Nhờ vậy macOS không hỏi quyền liên tục. Các thư mục này hiện trong cây với nhãn "Bỏ qua: cần Full Disk Access", và cửa sổ có một dải nhắc màu vàng.

Cách cấp quyền: **Cài đặt hệ thống → Quyền riêng tư & Bảo mật → Full Disk Access**, bấm **+**, chọn **Mac Clean** trong Applications rồi bật lên. Mac Clean không tự có mặt trong danh sách. Sau đó thoát, mở lại app và quét lại.

## Dùng

- **Chọn ổ** ở góc trên bên trái. Lần đầu mở cửa sổ, app tự quét ổ khởi động. Với ổ khác, chọn ổ là app bắt đầu quét.
- Kết quả **hiện dần trong lúc quét**. Bấm **Dừng** để huỷ giữa chừng; phần đã quét vẫn còn để xem, nhưng tổng số chưa đầy đủ.
- **Sắp xếp**: bấm tiêu đề cột (Tên, Kích cỡ, Ngày tạo, Ngày sửa, Loại). Tên được xếp như Finder (`file2` đứng trước `file10`).
- **Lọc**:
  - *Kích cỡ tối thiểu*: ẩn ngay trong cây các mục nhỏ hơn mức chọn.
  - *Lọc theo tên* và *tuổi file* (không sửa trong 30 ngày, 90 ngày, 1 năm, 2 năm): chuyển sang danh sách phẳng trên toàn ổ, tối đa 5.000 kết quả. Hai bộ lọc này chạy khi quét xong; trên ổ khoảng 2 triệu file mất vài giây.
- **Gói** (.app, .photoslibrary, .bundle…) hiện như một mục. Tick **Xem bên trong gói** để mở ra.
- **Xem nhanh**: chọn một dòng rồi bấm phím Space. Chuột phải để **Hiện trong Finder** hoặc **Sao chép đường dẫn**.
- **Dọn**:
  1. Tick các mục muốn dọn. Dòng có **ổ khoá đỏ** là chỉ để xem; rê chuột lên để đọc lý do.
  2. Bấm **Chuyển vào Thùng rác…** và đọc danh sách trong hộp xác nhận.
  3. Mục nằm trên ổ ngoài đi vào Thùng rác của chính ổ đó (`/Volumes/<tên ổ>/.Trashes/<uid>`). Mục thuộc root sẽ hỏi mật khẩu quản trị, và chỉ khi bạn tick ô cho phép.
  4. Sau khi chuyển, có thể bấm **Xoá vĩnh viễn các mục này…**. Nút này chỉ xoá đúng những mục vừa chuyển, nếu chúng còn trong Thùng rác và không bị thay đổi. Mac Clean **không bao giờ dọn sạch cả Thùng rác**.
- **Gợi ý dọn dẹp…**: cache của app, DerivedData của Xcode, file hỗ trợ thiết bị, iOS Simulator, bản sao lưu iPhone/iPad, file từ 100 MB trở lên trong Downloads không sửa trong 90 ngày. Mỗi nhóm có giải thích vì sao thường an toàn. **Không mục nào được chọn sẵn**: bạn tick, rồi các mục đó được tick trong cửa sổ chính.
- **Chi tiết…** giải thích chỗ lệch giữa tổng app thấy được và con số `df` báo (xem phần dưới).
- Mọi thao tác chuyển, bỏ qua hay xoá đều được ghi vào **nhật ký** `~/Library/Application Support/local.macclean.app/actions.log`. Mở nhanh từ menu bar: **Xem nhật ký thao tác**.

### Thanh menu và Dock

- Icon trên thanh menu cho biết dung lượng trống của từng ổ và trạng thái quét. Từ đó bạn có thể mở cửa sổ, quét lại, bật/tắt **Hiện icon trên Dock**, **Mở cùng lúc đăng nhập**, mở **Cài đặt…** hoặc thoát.
- Mặc định có icon trên Dock. Tắt **Hiện icon trên Dock** (ở menu bar hoặc trong Cài đặt) thì icon biến mất ngay, không cần mở lại app. Khi đó vẫn mở được cửa sổ từ icon trên thanh menu, và các phím Cmd+C, V, A, W vẫn hoạt động.
- Đóng cửa sổ thì app vẫn chạy trên thanh menu. Bấm icon Dock, hoặc mở lại app từ Finder hay Spotlight, sẽ hiện lại cửa sổ. Muốn tắt hẳn thì chọn **Thoát Mac Clean** (Cmd+Q).

## Mac Clean được dọn ở đâu

| Vùng | Được chuyển vào Thùng rác? |
|---|---|
| Bên trong thư mục nhà của bạn | Có, trừ các mục được bảo vệ bên dưới |
| Bên trong ổ ngoài ghi được (APFS, HFS+, exFAT, FAT) | Có |
| Thư mục bạn thêm trong **Cài đặt → Cho phép một thư mục…** | Có (app không cho thêm thư mục quá rộng hay thư mục hệ thống) |
| Hệ thống (`/System`, `/usr`, `/bin`…), `/Library`, `/Applications`, `/private`… | Chỉ xem |
| Keychains, Mail, Messages, Safari, Lịch, Danh bạ, iCloud Drive, CloudStorage, Cookies | Chỉ xem |
| Thư viện Ảnh (`.photoslibrary`) ở bất kỳ đâu | Chỉ xem |
| Chính các thư mục Desktop, Documents, Downloads, Library, Caches, Application Support… | Chỉ xem (nội dung bên trong thì dọn được) |
| Thùng rác (`~/.Trash`, `.Trashes`), `.Spotlight-V100`, `.fseventsd`, `.DocumentRevisions-V100` | Không bao giờ |
| Ổ NTFS, ổ chỉ đọc, ổ backup Time Machine | Chỉ xem |
| Ổ mạng (SMB, AFP, NFS, WebDAV) | Không quét |

Ngay trước khi chuyển từng mục, app kiểm tra lại mọi điều kiện:
- mục vẫn qua các luật trên;
- không có symlink nào trên đường dẫn;
- vẫn đúng file lúc quét (inode, device và loại file; trên exFAT/FAT thì thêm kích cỡ và ngày sửa);
- ổ vẫn còn cắm;
- không có tiến trình nào đang mở file đó, hay đang mở file nằm trong thư mục đó.

Mục nào không qua thì được giữ nguyên và báo lý do.

## Vì sao tổng của app lệch với `df`

App đo kích cỡ theo **block thực cấp phát** trên đĩa, không theo kích cỡ logic. Vì vậy file sparse (ví dụ ảnh đĩa máy ảo) hiện đúng phần thật sự chiếm chỗ. Hard link chỉ đếm một lần. Phần dữ liệu các bản clone APFS dùng chung được ước tính theo clone id rồi trừ đi trong tổng. File iCloud chưa tải về hiện kích cỡ 0, vì chúng không nằm trên ổ.

Một lần quét file không thể thấy hết. **Chi tiết…** liệt kê các phần sau:
- thư mục hệ thống không cho app nào đọc, kể cả khi đã có Full Disk Access (SIP: một số thư mục trong `/private/var`, `/Library/Caches`, mô hình Apple Intelligence trong `/System/Library/AssetsV2`…);
- local snapshot của Time Machine, metadata của APFS, phần macOS tính là có thể giải phóng (purgeable);
- trên ổ khởi động, các volume khác trong cùng container: hệ thống macOS đã niêm phong, VM swap, Preboot, Recovery (phần "Dữ liệu hệ thống" của macOS nằm ở đây và ở các thư mục trên).

Số đo trên máy phát triển (Mac mini M4, 29/10/2026):

| Ổ | `df` | App thấy | Lệch |
|---|---|---|---|
| Macintosh HD (volume Data, 1,8 triệu mục, có Full Disk Access) | 170,55 GB | 164,62 GB | 3,5%, do 208 thư mục hệ thống không đọc được |
| Ổ ngoài APFS 256 GB (594 nghìn mục) | 63,31 GB | 63,22 GB | 0,13% |

Quét ổ khởi động 1,8 triệu mục mất khoảng 15 giây, RAM đỉnh khoảng 180 MB.

## Quét có hại gì không?

- Không đọc nội dung file nào: chỉ đọc tên và thuộc tính bằng `getattrlistbulk`. Icon và loại file suy ra từ phần mở rộng.
- Không kích hoạt tải file iCloud: app tắt tính năng "materialize dataless files" cho chính nó ngay khi khởi động. Xem nhanh cũng không mở file chưa tải về.
- Không đi theo symlink, không vượt sang volume khác (so device id thật, vì volume hệ thống và volume Data có cùng `st_dev`), không đụng ổ mạng.
- Không có telemetry, không gọi mạng, không gửi dữ liệu đi đâu.

## Build từ mã nguồn

Chỉ cần Command Line Tools (không cần Xcode), SwiftPM, Swift 5 language mode.

```bash
swift build
Scripts/test.sh                       # swift test, tự chạy lại khi gặp lỗi TestingMacros của Command Line Tools
python3 -I Scripts/mutate.py          # phá từng chốt an toàn (51 đột biến), mọi đột biến phải bị test bắt
Scripts/build_app.sh                  # build/Mac Clean.app, ký ad-hoc
Scripts/make_dmg.sh                   # bản universal, build/MacClean-<phiên bản>.dmg và .sha256
swift Scripts/make_icon.swift         # vẽ lại Resources/AppIcon.icns
```

### Thử an toàn trên dữ liệu giả: `--sandbox`

```bash
"build/Mac Clean.app/Contents/MacOS/MacClean" --sandbox /tmp/mc-sandbox
```

Thư mục `<sandbox>` đóng vai ổ khởi động; thư mục nhà là `<sandbox>/home`. Mỗi thư mục con của `<sandbox>/Volumes` đóng vai một ổ ngoài:
- có thư mục `.timemachine` thì đóng vai ổ Time Machine;
- có file `.readonly` thì đóng vai ổ chỉ đọc;
- xoá thư mục đó đi là "rút ổ".

Thùng rác nằm trong sandbox; cài đặt lưu ở `<sandbox>/settings.plist`, không ghi vào `~/Library/Preferences`.

### Công cụ chẩn đoán (chỉ đọc)

`macclean-probe` không có đường code nào xoá hay di chuyển, và không có trong DMG.

```bash
swift build -c release --product macclean-probe
.build/release/macclean-probe volumes          # các ổ đang gắn và app xử lý ra sao
.build/release/macclean-probe scan /           # quét như app: thời gian, RAM, độ lệch df
.build/release/macclean-probe scan / --no-fda  # như khi chưa có Full Disk Access
```

Lưu ý: chạy từ Terminal thì tiến trình **thừa hưởng quyền của Terminal** (kể cả Full Disk Access). Muốn kiểm tra quyền thật của Mac Clean, hãy mở app từ Finder.

## Giấy phép

MIT, xem [LICENSE](LICENSE).
