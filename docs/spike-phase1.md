# Spike giai đoạn 1 (29/10/2026)

Máy: Mac mini M4, 10 nhân, 16 GB RAM, macOS 27.0.1. Mọi lần chạy chỉ đọc, bằng `Scripts/spike.sh` (bản release, mỗi lần chạy một tiến trình riêng). Shell của Claude **có Full Disk Access**, nên số thư mục không đọc được ở đây là mức tối thiểu; app mở từ Finder mà chưa có FDA sẽ thấy ít hơn.

Không xoá được cache hệ thống (`purge` cần root), nên chỉ lần chạy đầu tiên trên mỗi volume là "lạnh" một phần.

## Tốc độ và bộ nhớ

| Volume | Cách | Luồng | Thời gian | Mục/giây | RAM đỉnh |
|---|---|---|---|---|---|
| Data (1,80 triệu mục) | fts | 1 | 33,3 s / 33,6 s | 54k | 42 MB |
| | getattrlistbulk | 1 | 46,4 s | 39k | 11 MB |
| | getattrlistbulk | 4 | 18,1 s | 100k | 13 MB |
| | getattrlistbulk | 8 | 14,3 s / 14,3 s | 125k | 14 MB |
| | getattrlistbulk + NodeStore | 8 | 14,6 s | 123k | **375 MB** (mảng 213 MB) |
| | FileManager | 1 | 44,7 s | 40k | 17 MB |
| Lexar 256GB, APFS (594k mục) | fts | 1 | 10,6 s / 7,1 s | 56–83k | 15 MB |
| | getattrlistbulk | 1 | 12,9 s | 46k | 7 MB |
| | getattrlistbulk | 8 | 6,1 s / 6,0 s | 98k | 10 MB |
| | getattrlistbulk + NodeStore | 8 | 6,2 s | 96k | 95 MB (mảng 53 MB) |
| | FileManager | 1 | 14,4 s | 41k | 16 MB |

Cả ba cách đếm ra cùng số file (Data 1.463.554, Lexar 521.423) và cùng tổng logical/allocated. FileManager không cho biết số hard link (đếm trùng 0,37 GB), không có cờ dataless/compressed/clone.

## Độ lệch so với df

`df` trên APFS lấy `ATTR_VOL_SPACEUSED` của từng volume. `statfs` trả số của cả container (202,9 GB cho mọi volume), đừng dùng.

| Volume | df | Quét (hard link một lần) | Lệch | Quét + clone đếm chung một lần | Lệch |
|---|---|---|---|---|---|
| Data | 169,17 GB | 165,53 GB | 3,64 GB (2,15%) | 163,24 GB | 5,93 GB (3,5%) |
| Lexar | 63,26 GB | 60,13 GB + 3,05 GB thư mục hệ thống = 63,18 GB | 0,08 GB (0,13%) | như cột trước (không có clone) | |
| System (niêm phong) | 13,66 GB | khoảng 13,38 GB (suy ra bằng phép trừ, xem dưới) | khoảng 2% | | |

Phần lệch trên Data: 210 thư mục không đọc được dù có FDA (SIP/root), ví dụ `.Spotlight-V100`, `.fseventsd`, `.DocumentRevisions-V100`, `System/Library/AssetsV2/com_apple_MobileAsset_UAF_FM_*` (mô hình Apple Intelligence), `Library/Caches/com.apple.*`, `private/var/folders/zz` (cache của root), `private/var/db/*`. Thêm vào đó là metadata APFS. Không có local snapshot. File purgeable đếm được: 273 file, 1,28 GB (đã nằm trong tổng).

## Phát hiện

- **System và Data cùng `st_dev`** (16777231). Quét `/` "không vượt st_dev" vẫn đi qua firmlink vào Data (1,77 triệu file thay vì khoảng 0,3 triệu). `ATTR_CMNEXT_REALDEVID` phân biệt được: `/` và `/bin` cho 16777235, `/Users` và `/System/Volumes/Data` cho 16777231.
- `getattrlistbulk` trả được `ATTR_CMNEXT_PRIVATESIZE`, `CLONEID`, `EXT_FLAGS` ngay trong lô (37.897 file clone, không cần gọi thêm `getattrlist`). Birthtime có cho mọi mục.
- File sparse: 170 file, logical 260,8 GB nhưng chỉ chiếm 49,3 GB. Kích cỡ hiển thị phải là allocated, nếu không sẽ sai gấp 5 lần.
- `setiopolicy_np(...MATERIALIZE_DATALESS_FILES, OFF)` trả 0. Máy không có iCloud Drive, CloudStorage rỗng, 0 file dataless: **chưa thử được trên file dataless thật**.
- `/System/Volumes/Data/home` (autofs, không có `MNT_LOCAL`): bị bỏ qua, không bị chạm.
- NodeStore: khoảng 118 B/node mảng sau khi mảng tự nhân đôi; RSS 375 MB cho 1,8 triệu node. Với 2 triệu node và giao diện, sẽ sát ngưỡng 500 MB nếu không tối ưu.
