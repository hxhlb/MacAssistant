#import "MAAssetCatalogIconRepair.h"

#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>

NSErrorDomain const MAAssetCatalogIconRepairErrorDomain = @"MAAssetCatalogIconRepairErrorDomain";

typedef struct {
    unsigned short identifier;
    unsigned short value;
} renditionkeytoken;

typedef struct {
    unsigned int magic;
    unsigned int reserved;
    unsigned int num_attribs;
    unsigned int attribs[1];
} renditionkeyfmt;

typedef void (*FillCARFn)(int16_t *outKey, const renditionkeytoken *inKey, const renditionkeyfmt *fmt);

static NSError *MAMakeError(MAAssetCatalogIconRepairError code, NSString *path) {
    return [NSError errorWithDomain:MAAssetCatalogIconRepairErrorDomain
                               code:code
                           userInfo:@{NSFilePathErrorKey: path ?: @""}];
}

static BOOL MACSIContainsName(NSData *csi, NSString *name) {
    if (csi.length == 0 || name.length == 0) {
        return NO;
    }
    NSData *needle = [name dataUsingEncoding:NSUTF8StringEncoding];
    return [csi rangeOfData:needle options:0 range:NSMakeRange(0, csi.length)].location != NSNotFound;
}

@implementation MAAssetCatalogIconRepair

+ (NSArray<NSString *> *)targetRenditionNames {
    return @[@"AppIcon_1024_dark.png", @"AppIcon_1024_tinted.png"];
}

+ (nullable NSArray<NSString *> *)removeTargetRenditionsInCatalogAtPath:(NSString *)path
                                                                  error:(NSError *_Nullable *_Nullable)error {
    void *handle = dlopen("/System/Library/PrivateFrameworks/CoreUI.framework/CoreUI", RTLD_NOW);
    FillCARFn fill = handle ? (FillCARFn)dlsym(handle, "CUIFillCARKeyArrayForRenditionKey") : NULL;
    Class storageClass = NSClassFromString(@"CUIMutableCommonAssetStorage");
    if (!handle || !fill || !storageClass) {
        if (error) {
            *error = MAMakeError(MAAssetCatalogIconRepairErrorCoreUIUnavailable, path);
        }
        return nil;
    }

    id store = ((id (*)(id, SEL, NSString *, BOOL))objc_msgSend)(
        [storageClass alloc],
        NSSelectorFromString(@"initWithPath:forWriting:"),
        path,
        YES
    );
    if (!store) {
        if (error) {
            *error = MAMakeError(MAAssetCatalogIconRepairErrorOpenFailed, path);
        }
        return nil;
    }

    const renditionkeyfmt *fmt = ((const renditionkeyfmt *(*)(id, SEL))objc_msgSend)(
        store, NSSelectorFromString(@"keyFormat")
    );
    if (!fmt || fmt->num_attribs == 0 || fmt->num_attribs > 32) {
        if (error) {
            *error = MAMakeError(MAAssetCatalogIconRepairErrorOpenFailed, path);
        }
        return nil;
    }

    NSArray<NSString *> *targets = [self targetRenditionNames];
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    NSMutableArray<NSData *> *keys = [NSMutableArray array];
    NSUInteger keyLength = (NSUInteger)fmt->num_attribs * sizeof(int16_t);

    void (^collect)(renditionkeytoken *, NSData *) = ^(renditionkeytoken *keyList, NSData *csi) {
        if (!keyList || csi.length == 0) {
            return;
        }
        NSString *found = nil;
        for (NSString *name in targets) {
            if (MACSIContainsName(csi, name)) {
                found = name;
                break;
            }
        }
        if (!found) {
            return;
        }
        int16_t carKey[32] = {0};
        fill(carKey, keyList, fmt);
        [names addObject:found];
        [keys addObject:[NSData dataWithBytes:carKey length:keyLength]];
    };
    ((void (*)(id, SEL, id))objc_msgSend)(
        store, NSSelectorFromString(@"enumerateKeysAndObjectsUsingBlock:"), collect
    );

    if (names.count == 0) {
        return @[];
    }

    for (NSData *key in keys) {
        ((void (*)(id, SEL, const void *, NSUInteger))objc_msgSend)(
            store,
            NSSelectorFromString(@"removeAssetForKey:withLength:"),
            key.bytes,
            key.length
        );
    }

    BOOL wrote = ((BOOL (*)(id, SEL, BOOL))objc_msgSend)(
        store, NSSelectorFromString(@"writeToDiskAndCompact:"), YES
    );
    if (!wrote) {
        if (error) {
            *error = MAMakeError(MAAssetCatalogIconRepairErrorWriteFailed, path);
        }
        return nil;
    }
    return [names copy];
}

@end
