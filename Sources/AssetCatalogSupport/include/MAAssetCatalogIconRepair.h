#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const MAAssetCatalogIconRepairErrorDomain;

typedef NS_ERROR_ENUM(MAAssetCatalogIconRepairErrorDomain, MAAssetCatalogIconRepairError) {
    MAAssetCatalogIconRepairErrorCoreUIUnavailable = 1,
    MAAssetCatalogIconRepairErrorOpenFailed = 2,
    MAAssetCatalogIconRepairErrorWriteFailed = 3
};

/// injectipa `-f`：从 `Assets.car` 里删掉微信夜间/着色主屏图标那两对 rendition。
@interface MAAssetCatalogIconRepair : NSObject

+ (NSArray<NSString *> *)targetRenditionNames;

/// 按名删除每一条匹配的 CAR key（同一名字可能有两条，scale/idiom 不同）。
/// 没有匹配时不写回文件，返回空数组。
+ (nullable NSArray<NSString *> *)removeTargetRenditionsInCatalogAtPath:(NSString *)path
                                                                  error:(NSError *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END
