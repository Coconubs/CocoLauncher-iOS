#import <mach-o/dyld.h>
#import <spawn.h>
#import <sys/sysctl.h>
#import <UIKit/UIKit.h>

#import "AppDelegate.h"
#import "CocoConfig.h"
#import "CocoPerformance.h"
#import "customcontrols/CustomControlsUtils.h"
#import "JavaLauncher.h"
#import "LauncherPreferences.h"
#import "PLLogOutputView.h"
#import "PLProfiles.h"
#import "SurfaceViewController.h"
#import "UIKit+hook.h"
#import "config.h"

#include <libgen.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include "utils.h"
#include "codesign.h"

#define CS_PLATFORM_BINARY 0x4000000
#define PT_TRACE_ME 0
#define PT_DETACH 11 
int ptrace(int, pid_t, caddr_t, int);
#define fm NSFileManager.defaultManager
extern char** environ;

void printEntitlementAvailability(NSString *key) {
    NSLog(@"* %@: %@", key, getEntitlementValue(key) ? @"YES" : @"NO");
}

void uncaughtExceptionHandler(NSException *exception) {
    NSLog(@"Uncaught exception: %@", exception.description);
    NSLog(@"Call stack: %@", exception.callStackSymbols);
    usleep(10000);
    handle_fatal_exit(SIGABRT);
}

bool init_checkForsubstrated() {
    // Please kindly tell pwn20wnd that he sucks
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0};
    size_t miblen = 4;
    size_t size;
    int st = sysctl(mib, miblen, NULL, &size, NULL, 0);
    struct kinfo_proc * process = NULL;
    struct kinfo_proc * newprocess = NULL;
    do {
        size += size / 10;
        newprocess = realloc(process, size);
        if (!newprocess){
            if (process){
                free(process);
            }
            return nil;
        }
        process = newprocess;
        st = sysctl(mib, miblen, process, &size, NULL, 0);
    } while (st == -1 && errno == ENOMEM);
    if (st == 0){
        if (size % sizeof(struct kinfo_proc) == 0){
            int nprocess = size / sizeof(struct kinfo_proc);
            if (nprocess){
                for (int i = nprocess - 1; i >= 0; i--){
                    if(strcmp(process[i].kp_proc.p_comm,"substrated") == 0) {
                        return true;
                    }
                }
            }
        }
    }
    return false;
}

bool init_checkForJailbreak() {
    if (NSProcessInfo.processInfo.macCatalystApp) {
        // macOS doesn't automatically enable JIT.
        return false;
    } else if (init_checkForsubstrated()) {
        return true;
    }

    // Check if posix_spawn is hooked
    for (int i=0; i < _dyld_image_count(); i++) {
        if (strcmp(_dyld_get_image_name(i),"/usr/lib/pspawn_payload-stg2.dylib") == 0 ||
            strstr(_dyld_get_image_name(i),"/systemhook.dylib") != NULL) {
            return true;
        }
    }

    // Check if we have platform bit set
    uint32_t flags;
    csops(0, CS_OPS_STATUS, &flags, sizeof(flags));
    if ((flags & CS_PLATFORM_BINARY) != 0) {
        return true;
    }

    return opendir("/Applications") != NULL;
}

void init_logDeviceAndVer(char *argument) {
    // Amethyst version
    NSLog(@"[Pre-Init] Amethyst INIT!");
    NSLog(@"[Pre-Init] Version: %@-%s", NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"], CONFIG_TYPE);
    NSLog(@"[Pre-Init] Commit: %s (%s)", CONFIG_COMMIT, CONFIG_BRANCH);
    
    NSString *tsPath = [NSString stringWithFormat:@"%@/../_TrollStore", NSBundle.mainBundle.bundlePath];
    const char *type;
    if (!access(tsPath.UTF8String, F_OK)) {
        type = "TrollStore";
    } else if (isJailbroken) {
        type = "Jailbroken";
    } else {
        type = "Unjailbroken";
    }
    setenv("AME_DETECTEDINST", type, 1);
    
    NSLog(@"[Pre-Init] Device: %@", CocoDeviceModel());
    NSLog(@"[Pre-Init] %@ (%s)", UIDevice.currentDevice.completeOSVersion, type);
    
    NSLog(@"[Pre-init] Entitlements availability:");
    printEntitlementAvailability(@"com.apple.developer.kernel.extended-virtual-addressing");
    printEntitlementAvailability(@"com.apple.developer.kernel.increased-memory-limit");
    printEntitlementAvailability(@"com.apple.private.security.no-sandbox");
    //printEntitlementAvailability(@"dynamic-codesigning");
}

void init_redirectStdio() {
    if (getenv("LOG_TO_CONSOLE") != NULL) {
        NSLog(@"[Pre-init] LOG_TO_CONSOLE is set, not logging to latestlog.txt");
        return;
    }

    NSLog(@"[Pre-init] Starting logging STDIO to latestlog.txt\n");

    NSString *home = @(getenv("AME_HOME"));
    NSString *currName = [home stringByAppendingPathComponent:@"latestlog.txt"];
    NSString *oldName = [home stringByAppendingPathComponent:@"latestlog.old.txt"];
    [fm removeItemAtPath:oldName error:nil];
    [fm moveItemAtPath:currName toPath:oldName error:nil];

    [fm createFileAtPath:currName contents:nil attributes:nil];
    NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:currName];

    if (!file) {
        NSLog(@"[Pre-init] Error: failed to open %@", currName);
        assert(0 && "Failed to open latestlog.txt. Check oslog for more details.");
    }

    setvbuf(stdout, 0, _IOLBF, 0); // make stdout line-buffered
    setvbuf(stderr, 0, _IONBF, 0); // make stderr unbuffered

    /* create the pipe and redirect stdout and stderr */
    static int pfd[2];
    pipe(pfd);
    dup2(pfd[1], fileno(stdout));
    dup2(pfd[1], fileno(stderr));

    /* create the logging thread */
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        static BOOL filteredSessionID;
        ssize_t rsize;
        char buf[2048];
        while((rsize = read(pfd[0], buf, sizeof(buf)-1)) > 0) {
            if (rsize < 2048) {
                buf[rsize] = '\0';
            }
            // Filter out Session ID here
            int index;
            if (!filteredSessionID) {
                char *sessionStr = strstr(buf, "(Session ID is ");
                if (sessionStr) {
                    char *censorStr = "(Session ID is <censored>)\n\0";
                    strcpy(sessionStr, censorStr);
                    rsize = strlen(buf);
                    filteredSessionID = true;
                }
            }
            if (canAppendToLog) {
                [PLLogOutputView appendToLog:@(buf)];
            }
            [file writeData:[NSData dataWithBytes:buf length:rsize]];
            [file synchronizeFile];
        }
        [file closeFile];
    });

    // We can start catching exception right now
    NSSetUncaughtExceptionHandler(&uncaughtExceptionHandler);
}

void init_setupAccounts() {
    NSString *controlPath = [@(getenv("AME_HOME")) stringByAppendingPathComponent:@"accounts"];
    [fm createDirectoryAtPath:controlPath withIntermediateDirectories:NO attributes:nil error:nil];
}

void init_setupCustomControls() {
    NSString *controlPath = [@(getenv("AME_HOME")) stringByAppendingPathComponent:@"controlmap"];
    [fm createDirectoryAtPath:controlPath withIntermediateDirectories:NO attributes:nil error:nil];
    generateAndSaveDefaultControl();
    NSString *gamepadControlPath = [controlPath stringByAppendingPathComponent:@"gamepads"];
    [fm createDirectoryAtPath:gamepadControlPath withIntermediateDirectories:NO attributes:nil error:nil];
    generateAndSaveDefaultControlForGamepad();
}

void init_setupMultiDir() {
    NSString *multidir = getPrefObject(@"general.game_directory");
    if (multidir.length == 0) {
        multidir = @"default";
        setPrefObject(@"general.game_directory", multidir);
        NSLog(@"[Pre-init] Game directory was not set. Defaulting to %@ for future use.\n", multidir);
    } else {
        NSLog(@"[Pre-init] Restored game directory preference (%@)\n", multidir);
    }

    const char *home = getenv("AME_HOME");
    NSString *lasmPath = [NSString stringWithFormat:@"%s/Library/Application Support/minecraft", home];
    NSString *multidirPath = [NSString stringWithFormat:@"%s/instances/%@", home, multidir];


    NSArray *dirsToCreate = @[
        [NSString stringWithFormat:@"%s/.demo", home],
        [NSString stringWithFormat:@"%s/java_runtimes", home],
        lasmPath.stringByDeletingLastPathComponent,
        multidirPath
    ];
    for (NSString *dir in dirsToCreate) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    }
    [fm removeItemAtPath:lasmPath error:nil];
    [fm createSymbolicLinkAtPath:lasmPath withDestinationPath:multidirPath error:nil];
    [fm changeCurrentDirectoryPath:lasmPath];
    setenv("GAME_DIR", lasmPath.UTF8String, 1);
}

// CocoLauncher: Coco Cobblemon profile (Minecraft 1.21.1 + Fabric Loader 0.18.4,
// game directory ./CocoLite). The Fabric version file ships with the app; the
// game itself is still downloaded by the launcher with the player's account.
// CocoLauncher: the Coco button layout (same buttons as CocoLauncher Android:
// D-pad, Inv, Shift, Jump, P/C/M, R, party up/down, Chat, Tab, F3, F5, plus Esc
// and the in-game Menu). Copied again when the bundled layout version goes up;
// made the default once, unless the player picked another layout.
// v3: menu-only "Cuộn ▲/▼" (list scrolling in menus), V (LumyMon dismount), ◁ ▷ fixed (GLFW +1 = previous slot).
// v4: players still on Amethyst's default.json (no Coco buttons at all) are moved to the Coco layout once.
// v5 removed the Menu button (its UIMenu started with Force close, which closed the game); v6 brings it back
// without Force close (SurfaceViewController), merged in by name like any new button.
#define COCO_CONTROLS_VERSION 6
void init_setupCocoControls() {
    NSString *bundled = [NSBundle.mainBundle pathForResource:@"coco_controls" ofType:@"json" inDirectory:@"coco"];
    if (bundled == nil) {
        NSLog(@"[Coco] Bundled coco_controls.json is missing");
        return;
    }
    NSString *dir = [@(getenv("AME_HOME")) stringByAppendingPathComponent:@"controlmap"];
    NSString *target = [dir stringByAppendingPathComponent:@"coco_controls.json"];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSInteger installed = [defaults integerForKey:@"CocoControlsVersion"];
    if (installed >= COCO_CONTROLS_VERSION && [fm fileExistsAtPath:target]) {
        return;
    }
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableDictionary *existing = [fm fileExistsAtPath:target] ? [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:target]
        options:NSJSONReadingMutableContainers error:nil] : nil;
    if ([existing isKindOfClass:NSMutableDictionary.class] && [existing[@"mControlDataList"] isKindOfClass:NSMutableArray.class]) {
        // Keep the player's edits: only add buttons (by name) that the file does not have yet
        NSDictionary *fresh = [NSJSONSerialization JSONObjectWithData:[NSData dataWithContentsOfFile:bundled] options:0 error:nil];
        // Old files (layout v4) get displayInGame/displayInMenu = YES for every button at load time, which
        // would also show the menu-only buttons in game: bring the file to v8 first so the flags are kept.
        for (int i = 0; i < 4 && [existing[@"version"] intValue] < 8; i++) {
            if (!convertLayoutIfNecessary(existing)) break;
        }
        NSMutableArray *list = existing[@"mControlDataList"];
        NSMutableSet *names = [NSMutableSet new];
        for (NSMutableDictionary *button in list) {
            if (button[@"name"]) [names addObject:button[@"name"]];
            // build 28 had ◁ ▷ the wrong way round (SPECIALBTN_SCROLLUP sends -1 = next slot)
            if (installed < 3 && [button[@"name"] isEqualToString:@"◁"] && [button[@"keycodes"] count] > 0 && [button[@"keycodes"][0] intValue] == SPECIALBTN_SCROLLUP) {
                button[@"keycodes"] = [@[@(SPECIALBTN_SCROLLDOWN), @0, @0, @0] mutableCopy];
            } else if (installed < 3 && [button[@"name"] isEqualToString:@"▷"] && [button[@"keycodes"] count] > 0 && [button[@"keycodes"][0] intValue] == SPECIALBTN_SCROLLDOWN) {
                button[@"keycodes"] = [@[@(SPECIALBTN_SCROLLUP), @0, @0, @0] mutableCopy];
            }
        }
        int added = 0;
        for (NSDictionary *button in fresh[@"mControlDataList"]) {
            if (button[@"name"] && ![names containsObject:button[@"name"]]) {
                [list addObject:[button mutableCopy]];
                added++;
            }
        }
        NSData *out = [NSJSONSerialization dataWithJSONObject:existing options:NSJSONWritingPrettyPrinted error:nil];
        if (out == nil || ![out writeToFile:target atomically:YES]) {
            NSLog(@"[Coco] Could not update coco_controls.json");
            return;
        }
        NSLog(@"[Coco] coco_controls.json: added %d new buttons", added);
    } else {
        [fm removeItemAtPath:target error:nil];
        NSError *error = nil;
        if (![fm copyItemAtPath:bundled toPath:target error:&error]) {
            NSLog(@"[Coco] Could not copy coco_controls.json: %@", error.localizedDescription);
            return;
        }
    }
    if (installed < 4) {
        // the Coco profile can carry its own layout (set from the in-game menu); default.json there hides the Coco buttons too
        PLProfiles *profiles = PLProfiles.current;
        NSMutableDictionary *list = [NSMutableDictionary dictionaryWithDictionary:(profiles.profiles ?: @{})];
        NSDictionary *coco = list[COCO_PROFILE_NAME];
        if ([coco[@"defaultTouchCtrl"] isEqual:@"default.json"]) {
            NSMutableDictionary *edited = [coco mutableCopy];
            edited[@"defaultTouchCtrl"] = @"coco_controls.json";
            list[COCO_PROFILE_NAME] = edited;
            profiles.profileDict[@"profiles"] = (id)list;
            [profiles save];
            [PLProfiles updateCurrent];
        }
    }
    if (installed < 4) {
        NSString *current = getPrefObject(@"control.default_ctrl");
        if (current.length == 0 || [current isEqualToString:@"default.json"]) {
            setPrefObject(@"control.default_ctrl", @"coco_controls.json");
        }
    }
    [defaults setInteger:COCO_CONTROLS_VERSION forKey:@"CocoControlsVersion"];
    NSLog(@"[Coco] Installed coco_controls.json v%d", COCO_CONTROLS_VERSION);
}

void init_setupCoco() {
    NSString *gameDir = @(getenv("GAME_DIR"));
    NSString *versionJson = [NSString stringWithFormat:@"%1$@/versions/%2$@/%2$@.json", gameDir, COCO_VERSION_ID];
    if (![fm fileExistsAtPath:versionJson]) {
        NSString *bundled = [NSBundle.mainBundle pathForResource:COCO_VERSION_ID ofType:@"json" inDirectory:@"coco"];
        if (bundled) {
            NSError *copyError = nil;
            [fm createDirectoryAtPath:versionJson.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
            if (![fm copyItemAtPath:bundled toPath:versionJson error:&copyError]) {
                NSLog(@"[Coco] Could not copy %@.json: %@", COCO_VERSION_ID, copyError.localizedDescription);
            }
        } else {
            NSLog(@"[Coco] Bundled %@.json is missing", COCO_VERSION_ID);
        }
    }
    [fm createDirectoryAtPath:[gameDir stringByAppendingPathComponent:COCO_GAME_DIR_NAME] withIntermediateDirectories:YES attributes:nil error:nil];

    PLProfiles *profiles = PLProfiles.current;
    NSMutableDictionary *list = [NSMutableDictionary dictionaryWithDictionary:(profiles.profiles ?: @{})];
    BOOL firstSetup = ![NSUserDefaults.standardUserDefaults boolForKey:@"CocoProfileSetupDone"];
    BOOL changed = NO;
    if (list[COCO_PROFILE_NAME] == nil) {
        list[COCO_PROFILE_NAME] = @{
            @"name": COCO_PROFILE_NAME,
            @"lastVersionId": COCO_VERSION_ID,
            @"gameDir": COCO_PROFILE_GAME_DIR,
            @"renderer": @ RENDERER_NAME_MOBILEGLUES,
            @"icon": COCO_PROFILE_ICON_URL
        }.mutableCopy;
        changed = YES;
    }
    if (firstSetup) {
        // Fresh install: drop the stock "(Default)" profile and select Coco
        NSDictionary *stock = list[@"(Default)"];
        if ([stock[@"lastVersionId"] isEqual:@"latest-release"]) {
            [list removeObjectForKey:@"(Default)"];
        }
        profiles.profileDict[@"selectedProfile"] = (id)COCO_PROFILE_NAME;
        changed = YES;
        [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"CocoProfileSetupDone"];
    }
    if (changed) {
        profiles.profileDict[@"profiles"] = (id)list;
        [profiles save];
        [PLProfiles updateCurrent];
        NSLog(@"[Coco] Profile \"%@\" is ready", COCO_PROFILE_NAME);
    }
}

void init_setupResolvConf() {
    // Write known DNS servers to the config
    NSString *path = [NSString stringWithFormat:@"%s/resolv.conf", getenv("AME_HOME")];
    if (![fm fileExistsAtPath:path]) {
        [@"nameserver 8.8.8.8\n"
         @"nameserver 8.8.4.4"
        writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
}

void init_setupHomeDirectory() {
    setenv("HOME", [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask]
        .lastObject.path.stringByDeletingLastPathComponent.UTF8String, 1);
    NSString *homeDir;
    NSError *homeError;
    
    BOOL isNotSandboxed = [@(getenv("HOME")).lastPathComponent isEqualToString:NSUserName()];
    homeDir = [NSString stringWithFormat:@"%s/Documents%@", getenv("HOME"),
        isNotSandboxed ? @"/CocoLauncher":@""];

    if (![fm fileExistsAtPath:homeDir] ) {
        [fm createDirectoryAtPath:homeDir withIntermediateDirectories:NO attributes:nil error:&homeError];
    }
    
    if(homeError != nil) {
        // TODO: Persistent storage
        homeError = nil;
        homeDir = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).lastObject;
        [fm createDirectoryAtPath:homeDir withIntermediateDirectories:YES attributes:nil error:&homeError];
    }
    
    setenv("AME_HOME", realpath(homeDir.UTF8String, NULL), 1);
}

int main(int argc, char *argv[]) {
    if (pJLI_Launch) {
        return pJLI_Launch(argc, (const char **)argv,
                   0, NULL, // sizeof(const_jargs) / sizeof(char *), const_jargs,
                   0, NULL, // sizeof(const_appclasspath) / sizeof(char *), const_appclasspath,
                   "1.8.0-internal",
                   "1.8",

                   "java", "openjdk",
                   /* (const_jargs != NULL) ? JNI_TRUE : */ JNI_FALSE,
                   JNI_TRUE, JNI_FALSE, JNI_TRUE);
    }

    if (!isJITEnabled(true) && argc == 2) {
        NSLog(@"calling ptrace(PT_TRACE_ME)");
        // Child process can call to PT_TRACE_ME
        // then both parent and child processes get CS_DEBUGGED
        int ret = ptrace(PT_TRACE_ME, 0, 0, 0);
        return ret;
    }

    setenv("BUNDLE_PATH", dirname(argv[0]), 1);
    isJailbroken = init_checkForJailbreak();
    init_setupHomeDirectory();
    init_redirectStdio();
    init_logDeviceAndVer(argv[0]);

    loadPreferences(NO);
    init_hookFunctions();
    init_hookUIKitConstructor();

    debugLogEnabled = getPrefBool(@"general.debug_logging");
    NSLog(@"[Debugging] Debug log enabled: %@", debugLogEnabled ? @"YES" : @"NO");

    init_setupResolvConf();
    init_setupMultiDir();
    toggleIsolatedPref(NO);
    [PLProfiles updateCurrent];
    init_setupCoco();
    init_setupCocoControls();
    CocoMigrateSettings();
    CocoApplyHeapAfterUnlock();
    NSLog(@"[CocoLauncher] RAM %d MB, process limit %d MB, increased-memory-limit %@, heap %ld MB (recommended %d, safe max %d), preset %@",
        CocoDeviceMemoryMB(), CocoProcessMemoryLimitMB(), CocoHasIncreasedMemoryLimit() ? @"YES" : @"NO",
        (long)getPrefInt(@"java.allocated_memory"), CocoRecommendedHeapMB(), CocoSafeMaxHeapMB(),
        getPrefObject(@"video.quality_preset"));
    init_setupAccounts();
    init_setupCustomControls();

    // If sandbox is disabled, W^X JIT can be enabled by Amethyst itself
    if (!isJITEnabled(true) && getEntitlementValue(@"com.apple.private.security.no-sandbox")) {
        NSLog(@"[Pre-init] no-sandbox: YES, trying to enable JIT");
        int pid;
        int ret = posix_spawnp(&pid, argv[0], NULL, NULL, (char *[]){argv[0], "", NULL}, environ);
        if (ret == 0) {
            // Cleanup child process
            waitpid(pid, NULL, WUNTRACED);
            ptrace(PT_DETACH, pid, NULL, 0);
            kill(pid, SIGTERM);
            wait(NULL);

            if (isJITEnabled(true)) {
                NSLog(@"[Pre-init] JIT has been enabled with PT_TRACE_ME");
            } else {
                NSLog(@"[Pre-init] Failed to enable JIT: unknown reason");
            }
        } else {
            NSLog(@"[Pre-init] Failed to enable JIT: posix_spawn() failed errno %d", errno);
        }
    }

    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
