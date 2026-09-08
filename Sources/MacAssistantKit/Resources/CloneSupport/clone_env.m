#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <pwd.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// DYLD_INTERPOSE 只改写其它镜像里的符号。本文件里直接调用 getpwuid /
// NSHomeDirectory 会走到 libc / Foundation 的原实现。
// 不要用 dlsym(RTLD_NEXT)：当前 dyld 会返回 interposer 自身，
// getpwuid 递归到栈溢出（微信分身打开即闪退）。

static void MACloneApplyEnvironmentFromPlist(void) {
    Dl_info info;
    if (dladdr((const void *)MACloneApplyEnvironmentFromPlist, &info) == 0 || info.dli_fname == NULL) {
        return;
    }
    NSString *dylibPath = [NSString stringWithUTF8String:info.dli_fname];
    NSString *plistPath = [[[dylibPath stringByDeletingLastPathComponent]
        stringByAppendingPathComponent:@"../Resources/MacAssistantClone.plist"] stringByStandardizingPath];
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:plistPath];
    NSDictionary *environment = plist[@"Environment"];
    if (![environment isKindOfClass:[NSDictionary class]]) {
        return;
    }
    const char *home = getenv("HOME");
    if (home && home[0] && !getenv("REAL_USER_HOME")) {
        setenv("REAL_USER_HOME", home, 1);
    }
    for (NSString *key in environment) {
        id value = environment[key];
        if ([key isKindOfClass:[NSString class]] && [value isKindOfClass:[NSString class]]) {
            setenv(key.UTF8String, [(NSString *)value UTF8String], 1);
        }
    }
}

static NSString *MACloneHome(void) {
    const char *custom = getenv("HOME");
    return (custom && custom[0]) ? [NSString stringWithUTF8String:custom] : nil;
}

static NSString *MACloneTemporaryDirectory(void) {
    const char *custom = getenv("TMPDIR");
    if (!(custom && custom[0])) {
        return nil;
    }
    NSString *path = [NSString stringWithUTF8String:custom];
    if (![path hasSuffix:@"/"]) {
        path = [path stringByAppendingString:@"/"];
    }
    [[NSFileManager defaultManager] createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    return path;
}

static NSString *my_NSHomeDirectory(void) {
    NSString *home = MACloneHome();
    return home ?: NSHomeDirectory();
}

static NSString *my_NSHomeDirectoryForUser(NSString *userName) {
    NSString *home = MACloneHome();
    return home ?: NSHomeDirectoryForUser(userName);
}

static NSString *my_NSTemporaryDirectory(void) {
    NSString *temporary = MACloneTemporaryDirectory();
    return temporary ?: NSTemporaryDirectory();
}

static NSArray<NSString *> *my_NSSearchPathForDirectoriesInDomains(
    NSSearchPathDirectory directory,
    NSSearchPathDomainMask domainMask,
    BOOL expandTilde
) {
    NSString *home = MACloneHome();
    if (home && (domainMask & NSUserDomainMask)) {
        NSString *sub = nil;
        switch (directory) {
            case NSApplicationSupportDirectory: sub = @"Library/Application Support"; break;
            case NSCachesDirectory: sub = @"Library/Caches"; break;
            case NSLibraryDirectory: sub = @"Library"; break;
            case NSDocumentDirectory: sub = @"Documents"; break;
            default: break;
        }
        if (sub) {
            NSString *full = [home stringByAppendingPathComponent:sub];
            [[NSFileManager defaultManager] createDirectoryAtPath:full withIntermediateDirectories:YES attributes:nil error:nil];
            return @[full];
        }
    }
    return NSSearchPathForDirectoriesInDomains(directory, domainMask, expandTilde);
}

static struct passwd *my_getpwuid(uid_t uid) {
    struct passwd *password = getpwuid(uid);
    const char *home = getenv("HOME");
    if (password && home && home[0]) {
        static struct passwd fake;
        fake = *password;
        fake.pw_dir = (char *)home;
        return &fake;
    }
    return password;
}

static int my_getpwuid_r(uid_t uid, struct passwd *pwd, char *buffer, size_t bufsize, struct passwd **result) {
    int status = getpwuid_r(uid, pwd, buffer, bufsize, result);
    const char *home = getenv("HOME");
    if (status == 0 && result && *result && home && home[0]) {
        pwd->pw_dir = (char *)home;
    }
    return status;
}

static size_t my_confstr(int name, char *buf, size_t len) {
    if (name == _CS_DARWIN_USER_TEMP_DIR || name == _CS_DARWIN_USER_CACHE_DIR) {
        const char *temporary = getenv("TMPDIR");
        if (temporary && temporary[0]) {
            size_t needed = strlen(temporary) + 1;
            if (buf && len > 0) {
                strncpy(buf, temporary, len);
                buf[len - 1] = 0;
            }
            return needed;
        }
    }
    return confstr(name, buf, len);
}

#define DYLD_INTERPOSE(_replacement, _replacee) \
    __attribute__((used)) static struct { const void *replacement; const void *replacee; } \
    _interpose_##_replacee __attribute__((section("__DATA,__interpose"))) = { \
        (const void *)(unsigned long)&_replacement, \
        (const void *)(unsigned long)&_replacee \
    };

DYLD_INTERPOSE(my_NSHomeDirectory, NSHomeDirectory)
DYLD_INTERPOSE(my_NSHomeDirectoryForUser, NSHomeDirectoryForUser)
DYLD_INTERPOSE(my_NSTemporaryDirectory, NSTemporaryDirectory)
DYLD_INTERPOSE(my_NSSearchPathForDirectoriesInDomains, NSSearchPathForDirectoriesInDomains)
DYLD_INTERPOSE(my_getpwuid, getpwuid)
DYLD_INTERPOSE(my_getpwuid_r, getpwuid_r)
DYLD_INTERPOSE(my_confstr, confstr)

__attribute__((constructor))
static void macassistant_clone_env_init(void) {
    MACloneApplyEnvironmentFromPlist();
}
