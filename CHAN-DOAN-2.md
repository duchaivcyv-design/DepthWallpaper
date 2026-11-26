# DepthWallpaper — Báo cáo vá V2 (iOS 16.0–18.0)

Tiếp nối bản vá V1. Đợt log mới: `lock.txt`, 3 JetsamEvent `.ips`, `stacks-2026-11-26-223801.ips`,
`resolved-SpringBoard.txt`, `classes-SpringBoard-16.7.16.txt`. Máy: **iPhone10,2 (iPhone 8, 2GB), iOS 16.7.16**.

## 1. Bằng chứng trong log mới nói gì

### 1.1 Model KHÔNG chạy được (nguyên nhân gốc khiến rơi xuống saliency)
`lock.txt` lặp lại 3 lần:

```
Nguồn mask: saliency | model: suy luận lỗi: Error Domain=com.apple.vis Code=3
"The VNCoreMLTransform request failed" ... CoreML Code=1
"Invalid shape for output feature '1959': According to model description, feature '1959'
 must be of rank 3, instead got a multi-array value of rank 4."
| Mask chủ thể chiếm 5.7% / 5.8%
```

- `tools/convert_u2net.py` khai output `("1959", datatypes.Array(1, SIZE, SIZE))` = **rank 3** `[1,320,320]`,
  nhưng ONNX U²-Net thật xuất `[1,1,320,320]` = **rank 4** (xác nhận bởi `verify_spec_numpy.py`: `sess.run(['1959'])[0][0,0]`).
- `VNCoreMLTransform` của Vision kiểm tra shape output theo spec và **từ chối** request trước khi suy luận.
  → model 88MB nạp vào nhưng không bao giờ cho kết quả; pipeline rơi xuống `VNGenerateAttentionBasedSaliencyImageRequest`.

### 1.2 Vệt xám giữa khuôn mặt
- Saliency là heatmap **mềm** (giá trị 0..255 liên tục, tập trung quanh mặt).
- Trong `DWDepthEngine.cutoutFromImage`: `CIMaskToAlpha` chuyển luminance → alpha nguyên chất,
  nên pixel mask xám ~80–180 cho alpha ~30–70%; `CIBlendWithMask` với nền trong suốt → chủ thể
  bán trong suốt, nhìn như **đốm xám đè lên mặt**. Mask 5.7% cũng quá nhỏ.

### 1.3 Đơ vài giây khi vuốt thoát Notification Center → nhảy về màn hình chính, mất "flying"
Bằng chứng Jetsam (SpringBoard `largestProcess`):

| File | SpringBoard rpages | Ghi chú |
|---|---|---|
| JetsamEvent …230943.ips | 34077 (~532 MB) | pressure cao, chưa kill SpringBoard |
| JetsamEvent …230943.000.ips | 33912 (~530 MB) | pressure tiếp |
| JetsamEvent …231038.ips | 33695 (~526 MB) | **SpringBoard `reason: highwater`, `killDelta: 5509`** → bị kill → respring → lên home |

`stacks-2026-11-26-223801.ips` là stackshot kernel (bug 288, lý do BTAudioPlugin, không có backtrace user),
nhưng cho thấy SpringBoard `residentMemoryBytes = 284 MB`, `pageFaults = 1.41 triệu`, `pageIns = 143911` —
đang bị đảo bộ nhớ nặng.

Nguyên nhân code góp phần:
1. **Main thread bị chặn**: `cutoutFromImage:` (CI blend 414×736 + morph) chạy ngay trong completion trên main;
   snapshot `drawViewHierarchyInRect` cũng trên main; model fail nhưng vẫn tốn CPU; log cho thấy attach lặp lại
   liên tục (16:07:40 → 16:08:13 → 16:08:20) sau mỗi lần mở/đóng NC.
2. **Teardown thô**: `viewDidDisappear` đặt `gSubjectWindow = nil`; thoát NC là disappear → cửa sổ biến mất;
   lần appear sau tính lại toàn bộ. Code cũ **không có animation bay/parallax nào** cho chủ thể, và hook jitter
   còn `setParallaxEnabled: NO` → sau khi cửa sổ bị huỷ là "mất hiệu ứng" hoàn toàn.
3. **Bộ nhớ**: `[CIContext contextWithOptions:nil]` tạo mới mỗi lần; ảnh/PNG giữ trên main; model 88MB thường trú;
   đẩy SpringBoard tới ngưỡng highwater → jetsam kill (33695 trang × 16 KB ≈ 526 MB trên máy 2 GB).

## 2. Vá V2 (theo từng lỗi)

### 2.1 Chạy model thật, bỏ Vision để thoát lỗi rank 3 vs rank 4
`Sources/DWModelSegmenter.m`
- Bỏ `VNCoreMLModel`/`VNCoreMLRequest`; dùng thẳng `MLModel predictionFromFeatures:error:` — CoreML trực tiếp
  **không** validate shape output như Vision.
- Tự dựng pixel buffer 320×320 BGRA, ScaleFill (crop giữa, giữ tỷ lệ), input feature `input.1`;
  đọc output `1959` (`MLMultiArray`), hỗ trợ cả rank 3 và rank 4; ngưỡng xác suất ≥ 0.5 → nhị phân 255/0.
- Status log rút gọn còn ~180 ký tự (trước đây dump cả chuỗi lỗi dài nhiều dòng).
- Vẫn giữ dò đường động (`dladdr` dylib → `<root>/Library/Application Support/DepthWallpaper`, `/var/jb/...`,
  `/Library/...`) từ V1.

### 2.2 Hết vệt xám: nhị phân hoá mọi mask
`Sources/DWDepthEngine.m`
- Thêm `DWBinarizeMask()`: quét bitmap, `< 128 → 0`, `≥ 128 → 255`; kèm morphology open (Minimum→Maximum,
  radius 1.0) xoá chấm nhiễu rời.
- Áp dụng cho **tất cả** nguồn mask (instance/model/person/saliency/objectness) trước khi phóng to;
  áp lại một lần trong `cutoutFromImage:` để không còn biên alpha mềm.
- Hệ quả: saliency không thể tạo lớp bán trong suốt nữa; khi model chạy được thì mask là vật thể thật.

### 2.3 Hết đơ khi thoát NC; giữ hiệu ứng giữa các lần hiện
`Sources/DWDepthEngine.m` + `Tweak.xm`
- Thêm `subjectCutoutForImage:data:thickness:completion:`: mask + cắt chủ thể chạy trên
  `QOS_CLASS_USER_INITIATED` (nền), `@autoreleasepool`, completion chỉ dựng UI trên main.
- Cache cả mask PNG **và** cutout PNG theo SHA256 (algo `v19`): lần hiện sau đọc thẳng đĩa, gần như tức thì.
- `Tweak.xm`: giữ `gCutoutImage` + cửa sổ qua các lần ẩn/hiện; `viewDidDisappear` chỉ **fade ẩn** 0.18s,
  không giải phóng; `viewDidAppear` bay lại ngay từ cache (không tái tính mask/CI).
- Hook jitter chỉ ghi `setParallaxEnabled:`/`setZoomFactor:` khi trạng thái đổi, không spam mỗi `layoutSubviews`.

### 2.4 "Flying" kiểu iOS 26 (mô phỏng ổn định trên iOS 16)
`Tweak.xm`
- Bay vào: chủ thể bắt đầu trượt +38pt, alpha 0 → spring 0.55s, damping 0.82, vận tốc 0.25 → về vị trí,
  alpha 1.
- Parallax: `CMMotionManager` accelerometer 30 Hz, dịch container ±7pt ngang / ±5pt dọc (pref `parallax`,
  mặc định bật; tắt bằng pref nếu muốn tĩnh).
- Nhấn giữ (long-press) bật/tắt hiện chủ thể có animation.
- Cảnh báo bộ nhớ (`UIApplicationDidReceiveMemoryWarningNotification`) → giải phóng ảnh/cửa sổ để tránh jetsam.
- `CIContext` dùng chung một instance (GPU) thay vì tạo mới mỗi lần.

### 2.5 Khớp class trên iOS 16.7.16 (không đổi hook)
`resolved-SpringBoard.txt` xác nhận exact: `SBFWallpaperView`, `SBFLockScreenDateView`,
`CSCoverSheetViewController`; log máy thấy wallpaper `PBUIWallpaperView bounds={{0,0},{414,736}}` — giữ nguyên.

## 3. Danh sách file trong `DepthWallpaper-fix/` (đã sẵn sàng dán đè)

| File | Thay đổi V2 |
|---|---|
| `Tweak.xm` | Dựng/ẩn/hiện cửa sổ chủ thể; spring flying + parallax; cutout qua API nền; teardown an toàn; memory warning; jitter hook trạng thái; chặn phiên bản 16–18 |
| `Sources/DWModelSegmenter.m` | Direct `MLModel` prediction (bỏ Vision rank-check); pixel buffer 320; đọc output `1959` rank 3/4; log ngắn |
| `Sources/DWModelSegmenter.h` | Cập nhật mô tả |
| `Sources/DWDepthEngine.m` | `DWBinarizeMask`; shared CIContext; `subjectCutoutForImage:data:thickness:completion:`; cache cutout; algo `v19`; cutout nhị phân |
| `Sources/DWDepthEngine.h` | Khai báo API cutout nền |
| `Makefile` | Thêm `CoreMotion`, `CoreVideo` |
| `Prefs/Makefile` | Thêm `CoreVideo` (bundle pref compile cùng segmenter) |
| `control` | Version `0.0.2` |
| `.github/workflows/main.yml` | Giữ `iphone:clang:16.5:16.0` từ V1 |

## 4. Build và kiểm tra trên máy

```bash
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless     # Dopamine rootless
# hoặc THEOS_PACKAGE_SCHEME=roothide
```
Cài `.deb` trong `packages/`, respring.

`/var/mobile/Library/Logs/DepthWallpaper/lock.txt` kỳ vọng:
- `model: model OK (dự luận trực tiếp)` và `mask: model` (không còn dòng `must be rank 3 ... got rank 4`).
- Coverage chủ thể ở mức vài chục phần trăm, không còn 5.7% saliency.
- Vuốt mở/đóng Notification Center: không đơ; chủ thể fade rồi bay lại, không respring.

Nếu máy còn `.mlmodelc` biên dịch từ bản hỏng: xoá
`/var/mobile/Library/Caches/DepthWallpaper/DWSubject.mlmodelc` rồi respring để biên dịch lại.

## 5. Giới hạn đã biết (ngoài phạm vi vá ổn định 16.0–18.0)

- iOS 16 không có lớp floating depth của iOS 26; `flying` ở đây là spring + parallax accelerometer.
  Hook thẳng `PBUIPosterFloatingView` / `CSWallpaperFloatingLayerComponent` rủi ro crash PosterBoard, không đưa vào bản ổn định.
- Muốn model "chuẩn": chạy lại `tools/convert_u2net.py` với output `datatypes.Array(1,1,320,320)` rồi
  biên dịch lại `.mlmodel`; code V2 đọc được cả rank 3 lẫn rank 4 nên không bắt buộc.
- Snapshot `drawViewHierarchyInRect` có thể không bắt wallpaper Metal/remote trên một số máy;
  nếu vẫn log "Chụp wallpaper thất bại" thì bước tiếp theo là đọc thẳng layer `PBUIWallpaperView` qua
  `CALayer` render thay vì hierarchy snapshot.
