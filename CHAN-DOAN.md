# DepthWallpaper — Chẩn đoán không có hiệu ứng chiều sâu trên iOS 16.0–18.0

> Phạm vi: chỉ hỗ trợ **iOS 16.0–18.0**. Nguồn đối chiếu: `Tweak.xm` + `Sources/*.m` trong `DepthWallpaper-main.zip`,
> `classes-SpringBoard-16.7.16.txt`, `resolved-SpringBoard.txt`, `lock.txt` (log trên máy).

## 1. Kết luận nhanh

Nguyên nhân chính khiến màn hình khóa **không thấy hiệu ứng chiều sâu**:

1. **BLOCKER — Không nạp được model tách chủ thể (`DWSubject.mlmodel`) do đường dẫn hard-code kiểu rootful.**
   Code đọc cứng `/Library/Application Support/DepthWallpaper/DWSubject.mlmodel`, nhưng package build bằng
   `THEOS_PACKAGE_SCHEME=rootless` / `roothide` cài file dưới prefix `/var/jb/Library/...` (rootless) hoặc
   thư mục jbroot ngẫu nhiên (roothide) → trên máy báo đúng như log: **`model: không có file model`**.
2. **Trên iOS 16, khi không có model thì Vision không tách được vật thể bất kỳ** (chỉ tách người qua
   `VNGeneratePersonSegmentationRequest`). Wallpaper không có người rơi xuống `VNGenerateAttentionBasedSaliencyImageRequest`
   → mask chỉ **5.7%** là đốm nhiệt mềm, alpha gần như trong suốt → lớp "chủ thể" vô hình. Dòng
   `Đã đặt chủ thể lên trên đồng hồ` trong `lock.txt` chỉ là log chạy hết luồng, **không** có nghĩa là nhìn thấy.
3. **Thiếu chặn phiên bản trong code** (chỉ có trong `control`) và CI build deployment target 14.0, vi phạm yêu cầu 16.0–18.0.

## 2. Bằng chứng từ log (`lock.txt`)

| Dòng log | Ý nghĩa |
|---|---|
| `Tìm thấy wallpaper: PBUIWallpaperView bounds={{0, 0}, {414, 736}}` | Tìm thấy wallpaper thật trên máy là `PBUIWallpaperView` (không phải `SBFWallpaperView`) |
| `Chụp wallpaper OK: 414x736` | Chụp được ảnh (nhưng ngưỡng kiểm tra ảnh đen quá thấp — xem lỗi B4) |
| `Nguồn mask: saliency \| model: không có file model \| Mask chủ thể chiếm 5.7%` | Model không load; fallback saliency; mask quá nhỏ/nhạt → không hiện |
| `Đã đặt chủ thể lên trên đồng hồ (cửa sổ chiều sâu)` | Luồng code chạy tới cuối, nhưng ảnh cutout gần như trong suốt |

`resolved-SpringBoard.txt` cho thấy 3 hook chính **tìm thấy đúng class** trên iOS 16.7.16:
`SBFWallpaperView`, `SBFLockScreenDateView`, `CSCoverSheetViewController` → **tên class hook không phải lỗi chính**.

## 3. Đối chiếu class với `classes-SpringBoard-16.7.16.txt`

| Class dùng trong code | Có trong dump 16.7.16? | Vai trò / ghi chú |
|---|---|---|
| `SBFWallpaperView` | ✅ | Hook tắt rung/parallax (`setZoomFactor:`) |
| `SBFLockScreenDateView` | ✅ | Tìm cửa sổ chứa đồng hồ |
| `CSCoverSheetViewController` | ✅ | Hook `viewDidAppear`/`viewDidDisappear` |
| `PBUIWallpaperView` | ✅ | Wallpaper thật trên máy (log thấy) |
| `PBUIStaticWallpaperView` | ✅ | Class dự phòng khi tìm wallpaper |
| `PBUIScrollableStaticWallpaperView` | ✅ | Class dự phòng |
| `SBFStaticWallpaperView` | ❌ không có | Tên dự phòng trong exact-list; resolver quét fallback theo selector nên không crash, không cần sửa |

Classes hệ thống liên quan tới chiều sâu native đã thấy trong dump (`PIParallaxClockMaterialRequest`,
`CSWallpaperFloatingLayerComponent`, `PBUIPosterFloatingView`...) — tweak này không hook chúng mà tự dựng lớp chủ thể riêng.

## 4. Danh sách lỗi theo mức độ

### B1 — BLOCKER: đường dẫn model cứng cho rootful (`Sources/DWModelSegmenter.m`)

- `kDWModelPath = @"/Library/Application Support/DepthWallpaper/DWSubject.mlmodel"`.
- Theo Theos rootless, tài nguyên được cài dưới `/var/jb/...`; roothide dùng jbroot ngẫu nhiên (xem
  https://theos.dev/docs/rootless và https://theos.dev/docs/variables → `THEOS_PACKAGE_INSTALL_PREFIX="/var/jb/"`).
- Hệ quả: `+compiledModelURL` return nil, `lastStatus = @"không có file model"` đúng như log.
- **Đã sửa**: dò thư mục theo chính đường dẫn dylib (`dladdr`) → `<root>/Library/Application Support/DepthWallpaper`,
  kèm candidate `/var/jb/...` và `/Library/...`; chấp nhận sẵn `DWSubject.mlmodelc` đã biên dịch.

### B2 — BLOCKER trên iOS 16: chuỗi fallback Vision không tạo được mask chủ thể thật

- Thứ tự trong `DWDepthEngine.computeMaskForImage`: `instance` (iOS 17+) → **model** → `person` (iOS 15+) → `saliency` → `objectness × saliency`.
- iOS 16 không có `VNGenerateForegroundInstanceMaskRequest`; không có model; wallpaper không người → saliency 5.7%.
- Sau khi B1 được sửa, U²-Net (`DWSubject.mlmodel`, output `[1,1,320,320]` xác suất) chạy được trên iOS 16 và là nguồn mask chính.
- Yêu cầu: sau cài đặt phải **respring** vì `loadedModel` dùng `dispatch_once`; model thiếu ở lần đầu sẽ cache nil tới hết boot đó.

### B3 — Thiếu giới hạn iOS 16.0–18.0 trong code + CI ghi đè target xuống 14.0

- `control` đã có `firmware (>= 16.0), firmware (<< 19.0)` (giữ nguyên, tốt).
- Code không hề kiểm tra major version; `.github/workflows/main.yml` đặt `DEVICE_TARGET=iphone:clang:16.5:14.0`,
  CLI `TARGET` ghi đè `TARGET=iphone:clang:16.5:16.0` trong `Makefile` → deb cho cài/chạy trên iOS 14–15/19+.
- **Đã sửa**: thêm `DWSystemSupported()` (major 16–18) chặn ở `%ctor` và `DWAttachLockDepth`; workflow đổi về `:16.0`.

### B4 — Ảnh chụp wallpaper bị tưởng là "OK" dù có thể gần đen (`Tweak.xm - DWSnapshotView`)

- Ngưỡng `sum < 1000` trên mẫu 16×16 quá thấp: trung bình ~1.3/255 mỗi kênh vẫn pass → ảnh đen/kim loại
  (wallpaper Metal/remote có thể không bắt bằng `drawViewHierarchyInRect`) đi vào saliency thành nhiễu 5.7%.
- **Đã sửa**: nâng ngưỡng lên 20000; thêm log `Cover window: ... level=... frame=...` để soi cửa sổ chủ thể nếu vẫn không hiện.
- Hạn chế còn lại (nếu vẫn đen sau B1): cần đọc thẳng ảnh wallpaper thật (property ảnh của `PBUIWallpaperView`)
  thay vì snapshot hierarchy; đây là phương án tiếp theo, không sửa trong đợt này.

### B5 — Cache mask cũ (`Sources/DWDepthEngine.m`)

- Mask saliency 5.7% đang được cache theo SHA256 ảnh với `kDWAlgoVersion = v17`.
- **Đã sửa**: bump `v17 → v18` để vứt toàn bộ cache sai cũ.

### Lỗi nhỏ (không chặn hiệu ứng)

- `DepthWallpaper.plist` filter có thêm `com.apple.PosterBoard`, nhưng `Makefile` để
  `INSTALL_TARGET_PROCESSES = SpringBoard` → dylib không inject vào PosterBoard, entry filter thừa. Bỏ `PosterBoard`
  khỏi filter hoặc thêm process đó nếu sau này cần hook trình chỉnh sửa.
- `Prefs/Makefile` biên dịch `DWModelSegmenter.m` cho bundle Prefs nhưng màn thử nghiệm không gọi model; vô hại, có thể giữ.
- `DWAttachLockDepth` chạy 0.6s sau `viewDidAppear`; nếu wallpaper tải chậm không retry. Cân nhắc retry 2–3 lần nếu cần.
- `gSubjectWindow` không `makeKey`; không bắt buộc, nhưng nếu sau B1 vẫn không thấy, thêm log `w.isHidden`, `iv.image.size`.

## 5. Các file đã sửa (copy đè vào repo gốc theo đúng đường dẫn)

```
DepthWallpaper-fix/
├── Tweak.xm                                   # B3 guard phiên bản; B4 ngưỡng ảnh đen + log cover window
├── Sources/
│   ├── DWModelSegmenter.m                     # B1 dò động đường dẫn model (rootless/roothide/rootful)
│   └── DWDepthEngine.m                        # B5 bump cache v18
└── .github/workflows/main.yml                 # B3 TARGET 16.0 thay vì 14.0
```

Các thay đổi cụ thể:

- `DWModelSegmenter.m`: bỏ `kDWModelPath` cứng; thêm `DWModelDirectories()` (dò theo `dladdr` dylib + `/var/jb` + `/`),
  `DWExistingRawModelPath()`; hỗ trợ cả `.mlmodelc` đóng gói sẵn.
- `Tweak.xm`: thêm `DWSystemSupported()`; chặn đầu `%ctor` và `DWAttachLockDepth`; log thêm `level/frame` cửa sổ cover;
  ngưỡng đen `1000 → 20000`.
- `DWDepthEngine.m`: `kDWAlgoVersion v17 → v18`.
- `.github/workflows/main.yml`: `DEVICE_TARGET: iphone:clang:16.5:16.0`.

## 6. Kiểm tra trên máy sau khi cài deb (rootless)

```bash
# 1. Model thật sự được cài ở đâu?
dpkg -L com.dj.depthwallpaper | grep -i mlmodel
ls -la /var/jb/Library/Application\ Support/DepthWallpaper/

# 2. Log sau respring, mở khóa vài lần:
cat /var/mobile/Library/Logs/DepthWallpaper/lock.txt
cat /var/mobile/Library/Logs/DepthWallpaper/resolved-SpringBoard.txt
```

Kỳ vọng sau khi sửa:

- Dòng model: `đã nạp model` (hoặc `dùng model .mlmodelc có sẵn`), **không** còn `không có file model`.
- `Nguồn mask: model`, độ phủ thường ~5–40% (không còn 5.7% saliency).
- Chủ thể wallpaper đè lên phần đồng hồ như kiểu chiều sâu iOS.

Nếu log vẫn `không có file model`: chạy `dpkg -L com.dj.depthwallpaper` để xem deb đặt file ở prefix nào,
rồi bổ sung đúng đường dẫn vào `DWModelDirectories()`.

## 7. Lưu ý kiến trúc (không phải lỗi build)

- Hiệu ứng native iOS 16+ dùng lớp "floating layer" do hệ thống tạo (`CSWallpaperFloatingLayerComponent`,
  `PIParallaxClockMaterialRequest`...). Tweak này tự dựng `UIWindow` chủ thể ở `coverWin.windowLevel + 0.5`,
  nên chất lượng phụ thuộc hoàn toàn vào mask. Có model chuẩn (B1) là yếu tố quyết định nhìn thấy được hay không.
- Model 88 MB; deb lớn; lần biên dịch `.mlmodelc` đầu trên máy có thể lâu và cần dung lượng Cache trống.
- Không build rootful; chỉ rootless + roothide theo workflow hiện tại.
