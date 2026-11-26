#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Tìm class trên máy lúc chạy.
/// 1. Thử từng tên trong exactNames.
/// 2. Nếu không có, quét class đã load: tên chứa mustContain, là subclass của baseClass,
///    và có instance method selectorName. Chọn tên ngắn nhất để ưu tiên lớp gốc.
/// Ghi kết quả vào resolved.txt. Trả về Nil nếu không tìm thấy.
Class DWFindClass(NSArray<NSString *> *exactNames,
                  NSString *mustContain,
                  NSString *selectorName,
                  Class baseClass,
                  NSString *hookLabel);

/// Lần đầu mỗi phiên bản iOS: ghi danh sách class liên quan ra classes-<iOS>.txt.
void DWDumpRelevantClassesOnce(void);

#ifdef __cplusplus
}
#endif
