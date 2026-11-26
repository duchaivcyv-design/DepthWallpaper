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

## Cập nhật v5
- Trang thử nghiệm có đồng hồ mô phỏng ở lớp giữa, chủ thể ở lớp trên.
- Tách nền nhanh hơn: thu nhỏ ảnh còn tối đa 1024px trước khi tách, dùng Balanced thay vì Accurate.
- Ảnh không có người vẫn tách được nhờ fallback saliency (iOS 13+). iOS 17+ ưu tiên tách vật thể bất kỳ.

## Cập nhật v7
- Trang xem thử: đồng hồ có ngày và giờ 9:41, kéo để di chuyển, vị trí được lưu.
- Góc trắng trên đồng hồ: kéo lên xuống để tăng/giảm độ dày chủ thể. Giá trị lưu vào `subjectThickness` (-1 đến +1), tweak cũng dùng giá trị này.
- Thanh trượt "Độ dày chủ thể" trong Cài đặt chỉnh cùng giá trị.
- Log class thật (iOS 16.7.16) xác nhận: SBFWallpaperView, SBFLockScreenDateView, CSCoverSheetViewController, PRPosterDepthEffectConfiguration. Selector của menu Depth vẫn chưa xác nhận được.

## Cập nhật v8
- Cache mask có phiên bản thuật toán (v8): mask cũ sai không còn được dùng lại. Đây là nguyên nhân có khả năng khiến hiệu ứng không hiện.
- Saliency được chuẩn hoá theo giá trị lớn nhất, ngưỡng 50%.
- Trang xem thử báo tỉ lệ diện tích chủ thể, và báo rõ khi mask rỗng hoặc phủ gần hết ảnh.

## Cập nhật v9: chiều sâu trên màn khóa thật
- Khi cover sheet (CSCoverSheetViewController) hiện, tweak chụp wallpaper (SBFWallpaperView) và chụp ra ảnh.
- Tách chủ thể từ ảnh chụp, rồi đặt lớp: nền (ảnh chụp) -> đồng hồ (SBFLockScreenDateView) -> chủ thể. Wallpaper gốc được ẩn.
- Khi màn khóa ẩn, tweak trả đồng hồ về chỗ cũ và hiện lại wallpaper gốc.
- Mọi bước ghi vào /var/mobile/Library/Logs/DepthWallpaper/lock.txt để biết nơi lỗi.
- Hiệu ứng trên trang trình chỉnh sửa (Xem thử) vẫn có.
- Chưa hoạt động nếu wallpaper được vẽ ở process khác (PosterBoard). Khi đó lock.txt sẽ ghi "Chụp wallpaper thất bại".

## Cập nhật v10: lớp chủ thể trên cover sheet
- Log lock.txt cho thấy wallpaper KHÔNG nằm trong cây view của cover sheet. Wallpaper nằm ở cửa sổ riêng (PRPosterWindow/PBUI).
- Tweak tìm wallpaper ở mọi cửa sổ, chụp và tách chủ thể.
- Chủ thể được đặt trong một UIWindow riêng có windowLevel = cửa sổ cover sheet + 0.5, nên nằm trên đồng hồ và thông báo, còn wallpaper và đồng hồ không bị đụng tới.
- Đồng hồ không còn bị di chuyển. Mục "đẩy đồng hồ xuống" trên màn khóa tạm không hoạt động.

## Cập nhật v11: sửa mask trống (0%)
- Lỗi chính: mask saliency chỉ ghi kênh đỏ nên độ sáng thực chỉ còn ~30% và bị ngưỡng thành đen. Nay ghi đủ R, G, B.
- Ngưỡng saliency ở 30% giá trị đỉnh. Đo tỉ lệ mask ở 128x128.
- Nếu saliency rỗng, dùng bounding box của vật nổi bật (VNGenerateObjectnessBasedSaliencyImageRequest).
- Cache đổi sang v11, mask cũ bị bỏ qua.

## Cập nhật v12
- Fallback không còn là hình chữ nhật thuần: hộp vật nổi bật được giao với saliency ngưỡng 0.1 để viền bám theo vật thể. Nếu giao quá nhỏ thì dùng hộp.
- Hạn chế đã biết trên iOS 16: Vision không tách được vật thể bất kỳ (chỉ có người). Chất lượng viền phụ thuộc ảnh.

## Cập nhật v13: đường nạp model Core ML riêng
- Không dùng model hay code của ExiWall. Tweak đọc model segmentation của bạn tại `/Library/Application Support/DepthWallpaper/DWSubject.mlmodelc`.
- Model phải trả về ảnh (pixel buffer), trắng là chủ thể. Model dạng MLMultiArray (như DeepLabV3 chưa tách lớp) cần bước argmax riêng, chưa có trong bản này.
- Nếu không có model, tweak dùng chuỗi Vision cũ.
- Prefs bundle đã thêm DWModelSegmenter.m để tránh lỗi link.

## Cập nhật v14
- Sửa đơ khi vuốt: DWPrefs có cache trong bộ nhớ, không còn đọc đĩa mỗi lần gọi. Cache chỉ làm mới khi nhận thông báo reload.
- Ghi log màn khóa chạy ở luồng nền, không chặn main thread.
- Bỏ fallback hình chữ nhật thuần để không còn vệt xám. Chỉ nhận mask khi giao với saliency đủ lớn.
- Cache mask đổi sang v14.

## Cập nhật v15
- Đọc đầu ra MLMultiArray của model (nhãn lớp hoặc xác suất theo lớp, lấy argmax). Lớp mặc định 15 (người theo PASCAL VOC). Có thể đổi bằng khóa `segClass` trong prefs.
- Makefile tweak thêm CoreML để link DWModelSegmenter.
- Vẫn cần file model `DWSubject.mlmodelc` do bạn cung cấp.

## Cập nhật v16: U²-Net đã chuyển sang Core ML
- Model: U²-Net (Xuebin Qin et al., Apache License 2.0), trọng số lấy từ rembg (v0.0.0 release, MIT). Chuyển đổi bằng `tools/convert_u2net.py`, nén fp16 bằng `tools/to_fp16.py`, kiểm tra bằng `tools/verify_spec_numpy.py` (sai số tối đa 0.02, trung bình 4e-5 so với onnxruntime).
- File model: `DWSubject.mlmodel` (88 MB), đặt tại `/Library/Application Support/DepthWallpaper/DWSubject.mlmodel`. Tweak biên dịch một lần rồi lưu vào Caches.
- Đầu ra xác suất >= 0.5 là chủ thể. Đây là phần mặc định, không cần cấu hình thêm.
- Thông báo ghi công: U²-Net, Apache-2.0, https://github.com/xuebinqin/U-2-Net
- Model đã được đưa vào `layout/Library/Application Support/DepthWallpaper/` nên `.deb` tự cài đúng đường dẫn. Không cần chép tay.

## Cập nhật v17: chẩn đoán
- lock.txt ghi thêm "Nguồn mask" (model / instance / person / saliency / không có) và trạng thái nạp model (có file, biên dịch, nạp, suy luận).
- Cache mask đổi sang v17.
- Nếu log vẫn cho thấy 5.7% và nguồn "saliency" hoặc "không có", nghĩa là model chưa được nạp.
