#import <Foundation/Foundation.h>
#include <libgen.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static NSString *MACloneExecutableDirectory(void) {
    char execPath[PATH_MAX];
    uint32_t size = sizeof(execPath);
    if (_NSGetExecutablePath(execPath, &size) != 0) {
        return nil;
    }
    char resolved[PATH_MAX];
    if (realpath(execPath, resolved) == NULL) {
        strlcpy(resolved, execPath, sizeof(resolved));
    }
    char *dir = dirname(resolved);
    return dir ? [NSString stringWithUTF8String:dir] : nil;
}

static void MACloneApplyEnvironment(NSDictionary *environment) {
    const char *home = getenv("HOME");
    if (home && home[0] && !getenv("REAL_USER_HOME")) {
        setenv("REAL_USER_HOME", home, 1);
    }
    for (NSString *key in environment) {
        id value = environment[key];
        if (![key isKindOfClass:[NSString class]] || ![value isKindOfClass:[NSString class]]) {
            continue;
        }
        setenv(key.UTF8String, [(NSString *)value UTF8String], 1);
    }
}

static void MACloneInsertLibraries(NSArray *libraries, NSString *directory) {
    if (libraries.count == 0) {
        return;
    }
    NSMutableArray *resolved = [NSMutableArray array];
    const char *existing = getenv("DYLD_INSERT_LIBRARIES");
    if (existing && existing[0]) {
        [resolved addObject:[NSString stringWithUTF8String:existing]];
    }
    for (id item in libraries) {
        if (![item isKindOfClass:[NSString class]]) {
            continue;
        }
        NSString *path = (NSString *)item;
        if (![path hasPrefix:@"/"]) {
            path = [directory stringByAppendingPathComponent:path];
        }
        [resolved addObject:path];
    }
    setenv("DYLD_INSERT_LIBRARIES", [resolved componentsJoinedByString:@":"].UTF8String, 1);
}

int main(int argc, char *argv[]) {
    @autoreleasepool {
        NSString *directory = MACloneExecutableDirectory();
        if (directory.length == 0) {
            fprintf(stderr, "MacAssistant clone launcher: cannot resolve executable path\n");
            return 1;
        }
        NSString *plistPath = [[directory stringByAppendingPathComponent:@"../Resources/MacAssistantClone.plist"] stringByStandardizingPath];
        NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:plistPath];
        if (![plist isKindOfClass:[NSDictionary class]]) {
            fprintf(stderr, "MacAssistant clone launcher: missing %s\n", plistPath.fileSystemRepresentation);
            return 1;
        }

        NSString *target = plist[@"TargetExecutable"];
        if (![target isKindOfClass:[NSString class]] || target.length == 0) {
            fprintf(stderr, "MacAssistant clone launcher: TargetExecutable is missing\n");
            return 1;
        }
        if ([plist[@"TargetIsRelative"] boolValue] && ![target hasPrefix:@"/"]) {
            target = [directory stringByAppendingPathComponent:target];
        }

        MACloneApplyEnvironment([plist[@"Environment"] isKindOfClass:[NSDictionary class]] ? plist[@"Environment"] : @{});
        MACloneInsertLibraries([plist[@"InsertLibraries"] isKindOfClass:[NSArray class]] ? plist[@"InsertLibraries"] : @[], directory);

        NSMutableArray<NSString *> *arguments = [NSMutableArray array];
        [arguments addObject:target];
        id extras = plist[@"Arguments"];
        if ([extras isKindOfClass:[NSArray class]]) {
            for (id item in extras) {
                if ([item isKindOfClass:[NSString class]]) {
                    [arguments addObject:item];
                }
            }
        }
        for (int index = 1; index < argc; index++) {
            [arguments addObject:[NSString stringWithUTF8String:argv[index]]];
        }

        size_t count = arguments.count;
        char **newArgv = calloc(count + 1, sizeof(char *));
        if (!newArgv) {
            return 1;
        }
        for (NSUInteger index = 0; index < count; index++) {
            newArgv[index] = strdup(arguments[index].fileSystemRepresentation);
        }
        execv(target.fileSystemRepresentation, newArgv);
        perror("MacAssistant clone launcher: execv failed");
        return 1;
    }
}
