# DepthWallpaper (iOS 16.0 – 18.0) — rootless + roothide

Hiệu ứng chiều sâu cho hình nền trên SpringBoard:
- Tách chủ thể khỏi nền bằng Vision (iOS 16: người; iOS 17+: vật thể bất kỳ).
- Đặt đồng hồ ở lớp giữa giữa nền và chủ thể.
- Tắt zoom/parallax của wallpaper view để hết rung khi vuốt trang chủ.
- Nhấn giữ trung tâm thông báo để bật/tắt đẩy đồng hồ xuống.

## Gói build
- DepthWallpaper.rootless.deb  — THEOS_PACKAGE_SCHEME=rootless
- DepthWallpaper.roothide.deb  — THEOS_PACKAGE_SCHEME=roothide
Không build rootful. Dùng roothide/theos cho cả hai.

## Cách tìm class (không hard-code tên đoán)
Sources/DWClassResolver.m làm 3 việc lúc chạy:
1. Thử danh sách tên đã biết (SBFWallpaperView, SBFStaticWallpaperView...).
2. Nếu không có, quét các class đã load: tên chứa từ khóa, là subclass đúng base class, và có đúng selector cần dùng.
3. Ghi kết quả:
   - /var/mobile/Library/Logs/DepthWallpaper/resolved.txt  (class nào đã được gắn hook)
   - /var/mobile/Library/Logs/DepthWallpaper/classes-<iOS>.txt  (mọi class liên quan)
Gửi lại hai file này để kiểm chứng.

Nguồn đã xác nhận (không phải iOS 16–18):
- SBFWallpaperView (SpringBoardFoundation, header iOS 10): setZoomFactor:, parallaxEnabled, parallaxFactor.
- SBFLockScreenDateView (SpringBoardFoundation, header iOS 7.1–10): setDate:, setTextColor:.
- SBFStaticWallpaperView (header iOS 8): wallpaperImage, setZoomFactor:, subclass của SBFWallpaperView.

## Build local
export THEOS=~/theos
make clean package FINALPACKAGE=1 DEBUG=0 THEOS_PACKAGE_SCHEME=rootless
make clean package FINALPACKAGE=1 DEBUG=0 THEOS_PACKAGE_SCHEME=roothide

## Giới hạn trung thực
- Chưa xác nhận được tên class trên iOS 16–18. Tweak chỉ hook khi tìm thấy, không tìm thấy thì không làm gì (không crash).
- Vị trí nút "…" (3 chấm) trong trình chọn hình nền chưa có nguồn xác nhận; hiện thay bằng nhấn giữ trung tâm thông báo.
- Độ giống iOS 26 99–100% không đảm bảo bằng code: iOS 26 dùng depth map do hệ thống tạo sẵn. Cần depth thật và tinh chỉnh viền mask.
- Hình nền động/video chưa có pipeline theo khung hình.
- Vị trí đồng hồ giữa lớp chiều sâu là giả định cần xác nhận trên máy thật.

## Cập nhật sửa lỗi
- Công tắc có hiệu lực ngay: DWPrefs đọc trực tiếp từ domain com.dj.depthwallpaper, không cache; nhận thông báo com.dj.depthwallpaper/reload để áp lại.
- Hook luôn được gắn khi tìm thấy class; công tắc kiểm tra lúc chạy, không cần respring để bật/tắt.
- Filter thêm com.apple.PosterBoard để dò class trình chỉnh sửa hình nền (3 chấm). Log: /var/mobile/Library/Logs/DepthWallpaper/resolved-<process>.txt và classes-<process>-<iOS>.txt.
- Chưa xác nhận được tên class của nút 3 chấm và mục "Chiều sâu" trong PosterBoard. Cần file classes-PosterBoard-*.txt từ máy để hook đúng.

## Trang thử nghiệm trong Cài đặt
Cài đặt → DepthWallpaper → Xem thử chiều sâu trên ảnh: chọn ảnh từ thư viện, tách chủ thể bằng Vision và xem lớp chiều sâu. Dùng để kiểm tra độ chính xác của mask trên ảnh bất kỳ.

## Còn thiếu
- Mục chiều sâu ngay trong menu 3 chấm của trình chỉnh sửa hình nền (PosterBoard): cần tên class/selector thật từ log PosterBoard.

## Sửa lỗi văng khi bấm "Chọn ảnh"
- Trang thử nghiệm kế thừa PSViewController (đúng kiểu cho PSLinkCell), trước đây là UIViewController nên Settings crash khi tạo.
- Kiểm tra thư viện ảnh có sẵn trước khi mở picker.
