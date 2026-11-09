#import <UIKit/UIKit.h>
#import <mach/mach.h>
#import <os/proc.h>

#import "CocoPerformance.h"
#import "LauncherPreferences.h"
#import "utils.h"

int CocoDeviceMemoryMB(void) {
    return (int)(NSProcessInfo.processInfo.physicalMemory >> 20);
}

BOOL CocoHasIncreasedMemoryLimit(void) {
    return getEntitlementValue(@"com.apple.developer.kernel.increased-memory-limit");
}

static int CocoFootprintMB(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) {
        return 0;
    }
    return (int)(info.phys_footprint >> 20);
}

int CocoProcessMemoryLimitMB(void) {
    if (@available(iOS 13.0, tvOS 13.0, *)) {
        size_t available = os_proc_available_memory();
        if (available > 0) {
            return CocoFootprintMB() + (int)(available >> 20);
        }
    }
    return 0;
}

int CocoNativeOverheadMB(void) {
    // Metaspace + code cache of ~125 Fabric mods, LWJGL/OpenAL natives, the GL
    // driver, texture atlases of ~30 resource packs and Pokemon models. An
    // iPhone 15 Pro Max (limit 6143 MB) with a 4096 MB heap was killed by iOS
    // about a minute after joining Coco, so keep about 2.3 GB outside the heap.
    return CocoDeviceMemoryMB() >= 7000 ? 2300 : 1800;
}

int CocoSafeMaxHeapMB(void) {
    int limit = CocoProcessMemoryLimitMB();
    if (limit <= 0) {
        // Unknown limit: assume about half of the RAM without the entitlement.
        limit = CocoHasIncreasedMemoryLimit() ? CocoDeviceMemoryMB() * 0.75 : CocoDeviceMemoryMB() * 0.5;
    }
    return MAX(limit - CocoNativeOverheadMB(), 512);
}

int CocoMinPlayHeapMB(void) {
    return CocoDeviceMemoryMB() >= 7000 ? 3584 : 2560;
}

int CocoSmoothHeapMB(void) {
    return CocoDeviceMemoryMB() >= 7000 ? 3840 : 2560;
}

int CocoRecommendedHeapMB(void) {
    int deviceMB = CocoDeviceMemoryMB();
    int wanted;
    if (deviceMB >= 7000) {
        wanted = 4096; // 8 GB and more: smooth
    } else {
        wanted = 2560; // 6 GB: 2.5 GB heap leaves room for graphics
    }
    // Never more than what still fits under the process limit, rounded to 128 MB.
    int safe = CocoSafeMaxHeapMB() / 128 * 128;
    return MAX(MIN(wanted, safe), 1024);
}

BOOL CocoIsLowEndDevice(void) {
    // 6 GB devices (A15/A16) start on Low too: 40-60 FPS needs it with ~125 mods
    return CocoDeviceMemoryMB() < 7000 || NSProcessInfo.processInfo.processorCount <= 4;
}

NSString *CocoDefaultPreset(void) {
    return CocoIsLowEndDevice() ? COCO_PRESET_LOW : COCO_PRESET_BALANCED;
}

int CocoPresetResolution(NSString *preset) {
    if ([preset isEqualToString:COCO_PRESET_LOW]) {
        // 720 px on the short side (as Amethyst-Android does on weak devices),
        // sharper than a fixed 50% on large screens
        CGFloat shortSide = MIN(UIScreen.mainScreen.nativeBounds.size.width, UIScreen.mainScreen.nativeBounds.size.height);
        if (shortSide <= 0) return 50;
        return MAX(40, MIN(100, (int)lround(720.0 * 100.0 / shortSide)));
    }
    if ([preset isEqualToString:COCO_PRESET_HIGH]) return 100;
    return 75;
}

int CocoPresetChunkThreads(NSString *preset) {
    // Low: 2 chunk builder threads leave CPU time for the render thread on 6-core phones
    return [preset isEqualToString:COCO_PRESET_LOW] ? 2 : 0;
}

BOOL CocoPresetMaxFramerate(NSString *preset) {
    // Only High asks ProMotion screens for 120 Hz; the others stay at 60.
    return [preset isEqualToString:COCO_PRESET_HIGH];
}

NSDictionary<NSString *, NSString *> *CocoPresetGameOptions(NSString *preset) {
    if ([preset isEqualToString:COCO_PRESET_LOW]) {
        return @{
            // 9/11 (owner): 60 FPS with VSync on every preset
            @"maxFps": @"60",
            @"renderDistance": @"4",
            @"simulationDistance": @"5",
            @"graphicsMode": @"0",
            @"particles": @"2",
            @"renderClouds": @"\"false\"",
            @"entityShadows": @"false",
            @"ao": @"false",
            @"biomeBlendRadius": @"0",
            @"mipmapLevels": @"0",
            @"entityDistanceScaling": @"0.5",
            @"enableVsync": @"true"
        };
    } else if ([preset isEqualToString:COCO_PRESET_BALANCED]) {
        return @{
            @"maxFps": @"60",
            @"renderDistance": @"6",
            @"simulationDistance": @"5",
            @"graphicsMode": @"0",
            @"particles": @"1",
            @"renderClouds": @"\"fast\"",
            @"entityShadows": @"false",
            @"ao": @"true",
            @"biomeBlendRadius": @"1",
            @"mipmapLevels": @"0",
            @"entityDistanceScaling": @"0.75",
            @"enableVsync": @"true"
        };
    } else if ([preset isEqualToString:COCO_PRESET_HIGH]) {
        int maxFps = 60;
        return @{
            @"maxFps": [NSString stringWithFormat:@"%d", maxFps],
            @"renderDistance": @"10",
            @"simulationDistance": @"6",
            @"graphicsMode": @"1",
            @"particles": @"0",
            @"renderClouds": @"\"true\"",
            @"entityShadows": @"true",
            @"ao": @"true",
            @"biomeBlendRadius": @"2",
            @"mipmapLevels": @"2",
            @"entityDistanceScaling": @"1.0",
            @"enableVsync": @"true"
        };
    }
    return @{};
}

void CocoApplyPreset(NSString *preset) {
    setPrefObject(@"video.quality_preset", preset);
    if ([preset isEqualToString:COCO_PRESET_CUSTOM]) {
        return;
    }
    setPrefObject(@"video.resolution", @(CocoPresetResolution(preset)));
    setPrefBool(@"video.max_framerate", CocoPresetMaxFramerate(preset));
    // Written into options.txt on the next launch (MinecraftOptionUtils), so
    // changes made inside the game are kept until another preset is picked.
    setPrefObject(@"internal.coco_pending_preset", preset);
}

void CocoMigrateSettings(void) {
    int version = [getPrefObject(@"internal.coco_settings_version") intValue];
    if (version >= COCO_SETTINGS_VERSION) {
        return;
    }
    // CocoLauncher 1.0.0 set 3072/2560/2048 MB from the device RAM only. Without
    // the increased memory entitlement that is often more than iOS allows.
    int current = getPrefInt(@"java.allocated_memory");
    if (version < 2 && (current == 3072 || current == 2560 || current == 2048)) {
        setPrefObject(@"java.allocated_memory", @(CocoRecommendedHeapMB()));
    }
    // Settings version 3: the pack needs at least 3.5 GB of Java heap.
    if (version < 3 && getPrefInt(@"java.allocated_memory") < COCO_MIN_PLAY_HEAP_MB) {
        setPrefObject(@"java.allocated_memory", @(CocoRecommendedHeapMB()));
    }
    // Version 3: on-screen mouse pointer on by default (tap = click at the pointer)
    if (version < 3) {
        setPrefBool(@"control.virtmouse_enable", YES);
    }
    // Version 4: a heap above the safe maximum (iOS kills the game in the world)
    // goes back to the recommended value
    if (version < 4) {
        if (!CocoLacksMemoryEntitlement() && getPrefInt(@"java.allocated_memory") > CocoSafeMaxHeapMB()) {
            setPrefObject(@"java.allocated_memory", @(CocoRecommendedHeapMB()));
        }
    }
    // Version 5: on-screen buttons shown in screenshots and recordings by default
    if (version < 5) {
        setPrefBool(@"control.recording_hide", NO);
    }
    // Version 6: 6 GB devices get a 2.5 GB heap and the Low preset once
    if (version < 6 && CocoDeviceMemoryMB() < 7000) {
        setPrefObject(@"java.allocated_memory", @(CocoRecommendedHeapMB()));
        if (![getPrefObject(@"video.quality_preset") isEqualToString:COCO_PRESET_LOW]) {
            CocoApplyPreset(COCO_PRESET_LOW);
        }
    }
    // Version 8: Low renders at 720 px on the short side; mod configs tuned once
    // (Sodium Extra animations/particles, Dynamic FPS GC, MoreCulling)
    if (version < 8) {
        if ([getPrefObject(@"video.quality_preset") isEqualToString:COCO_PRESET_LOW]) {
            setPrefObject(@"video.resolution", @(CocoPresetResolution(COCO_PRESET_LOW)));
        }
        setPrefBool(@"internal.coco_pending_sodium_extra", YES);
        setPrefBool(@"internal.coco_pending_dynamic_fps", YES);
        setPrefBool(@"internal.coco_pending_moreculling", YES);
    }
    // Version 9 (9/11, owner): GUI scale 2, VSync on, max 60 FPS; Sodium Extra weather off and the FPS counter
    // in the top right corner. Written once each, the player can change them back in the game.
    if (version < 9) {
        setPrefBool(@"internal.coco_pending_v9_options", YES);
        setPrefBool(@"internal.coco_pending_v9_sodium_extra", YES);
    }
    // Version 7: no vibration on button taps, View Bobbing off (once)
    if (version < 7) {
        setPrefBool(@"control.disable_haptics", YES);
        setPrefBool(@"internal.coco_pending_bobview_off", YES);
    }
    setPrefObject(@"internal.coco_settings_version", @(COCO_SETTINGS_VERSION));
}

BOOL CocoLacksMemoryEntitlement(void) {
    return !CocoHasIncreasedMemoryLimit() && !getEntitlementValue(@"com.apple.private.memorystatus");
}

BOOL CocoHeapCappedToSafeMax(void) {
    // The player can lift the cap at their own risk (Settings > Allow above the safe maximum)
    return CocoLacksMemoryEntitlement() && !getPrefBool(@"java.coco_allow_over_safe");
}

int CocoMaxSelectableHeapMB(void) {
    int deviceMax = MAX((int)(CocoDeviceMemoryMB() * 0.85) / 128 * 128, 1024);
    if (!CocoHeapCappedToSafeMax()) {
        return deviceMax;
    }
    return MIN(deviceMax, MAX(CocoSafeMaxHeapMB() / 128 * 128, 1024));
}

int CocoClampHeapMB(int requested) {
    if (!CocoHeapCappedToSafeMax()) {
        return requested;
    }
    return MIN(requested, CocoMaxSelectableHeapMB());
}

int CocoClampSavedHeap(void) {
    int saved = (int)getPrefInt(@"java.allocated_memory");
    int clamped = CocoClampHeapMB(saved);
    if (clamped >= saved) {
        return 0;
    }
    setPrefObject(@"java.allocated_memory", @(clamped));
    NSLog(@"[CocoLauncher] Saved Java heap lowered from %d MB to %d MB (no increased memory limit entitlement, process limit %d MB)",
        saved, clamped, CocoProcessMemoryLimitMB());
    return saved;
}

#pragma mark - MobileGlues

// Marks a config.json written by CocoLauncher (MobileGlues ignores unknown keys).
static NSString *const CocoMGConfigMarker = @"cocoLauncher";

static NSDictionary *CocoMGOption(NSString *optionId, NSString *mgKey, NSArray<NSNumber *> *values, int def) {
    return @{@"id": optionId, @"pref": [@"video.mg_" stringByAppendingString:optionId], @"mgKey": mgKey,
        @"values": values, @"def": @(def)};
}

NSArray<NSDictionary *> *CocoMGOptions(void) {
    static NSArray<NSDictionary *> *options;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Defaults = the setup the server owner found best on iPhone (8/11/2026): MobileGlues defaults for
        // Apple except Direct State Access off and a 64 MB GLSL cache.
        options = @[
            // 1 Off, 2 Level 1 (partial), 3 Level 2 (full); MobileGlues on Apple: partial
            CocoMGOption(@"no_error", @"enableNoError", @[@1, @2, @3], 2),
            CocoMGOption(@"ext_timer_query", @"enableExtTimerQuery", @[@0, @1], 0),
            CocoMGOption(@"ext_compute_shader", @"enableExtComputeShader", @[@0, @1], 0),
            CocoMGOption(@"ext_dsa", @"enableExtDirectStateAccess", @[@0, @1], 0),
            CocoMGOption(@"ext_gl43", @"enableExtGL43", @[@0, @1], 0),
            CocoMGOption(@"glsl_cache_mb", @"maxGlslCacheSize", @[@0, @30, @64, @128, @256], 64),
            // 0 Auto, 1 Indirect, 2 Unroll (BaseVertex), 4 DrawElements. Compute (5) is left out: MobileGlues
            // does not check that the driver can run it. 3 behaves like Auto in this MobileGlues version.
            CocoMGOption(@"multidraw_mode", @"multidrawMode", @[@0, @1, @2, @4], 0),
            CocoMGOption(@"angle_depth_fix", @"angleDepthClearFixMode", @[@0, @1, @2], 0),
            // 0 = MobileGlues default (OpenGL 4.0)
            CocoMGOption(@"gl_version", @"customGLVersion", @[@0, @32, @33, @40, @41, @42, @43, @44, @45, @46], 0),
            // 0 Off, 1 Ultra quality, 2 Quality, 3 Balanced, 4 Performance
            CocoMGOption(@"fsr1", @"fsr1Setting", @[@0, @1, @2, @3, @4], 0),
        ];
    });
    return options;
}

int CocoMGValue(NSDictionary *option) {
    id saved = getPrefObject(option[@"pref"]);
    if (saved && [option[@"values"] containsObject:@([saved intValue])]) {
        return [saved intValue];
    }
    return [option[@"def"] intValue];
}

void CocoSetMGValue(NSDictionary *option, int value) {
    if (![option[@"values"] containsObject:@(value)]) {
        value = [option[@"def"] intValue];
    }
    setPrefObject(option[@"pref"], @(value));
}

NSString *CocoMGValueName(NSDictionary *option, int value) {
    NSString *optionId = option[@"id"];
    if ([option[@"values"] isEqualToArray:@[@0, @1]]) {
        return localize(value ? @"coco.mg.val.on" : @"coco.mg.val.off", nil);
    }
    if ([optionId isEqualToString:@"glsl_cache_mb"]) {
        return value == 0 ? localize(@"coco.mg.val.off", nil) : [NSString stringWithFormat:@"%d MB", value];
    }
    if ([optionId isEqualToString:@"gl_version"] && value != 0) {
        return [NSString stringWithFormat:@"OpenGL %d.%d", value / 10, value % 10];
    }
    return localize([NSString stringWithFormat:@"coco.mg.%@.%d", optionId, value], nil);
}

void CocoResetMGOptions(void) {
    for (NSDictionary *option in CocoMGOptions()) {
        setPrefObject(option[@"pref"], option[@"def"]);
    }
}

void CocoWriteModernFixConfig(NSString *gameDir) {
    if (gameDir.length == 0) {
        return;
    }
    NSString *key = @"mixin.perf.dynamic_resources";
    BOOL enable = getPrefBool(@"java.coco_mf_dynamic_resources");
    NSString *configDir = [gameDir stringByAppendingPathComponent:@"config"];
    NSString *path = [configDir stringByAppendingPathComponent:@"modernfix-mixins.properties"];
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] ?: @"";
    NSMutableArray<NSString *> *lines = [NSMutableArray new];
    for (NSString *line in [text componentsSeparatedByString:@"\n"]) {
        NSString *trimmed = [line stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if ([trimmed hasPrefix:[key stringByAppendingString:@"="]]) {
            continue;
        }
        [lines addObject:line];
    }
    while (lines.count > 0 && [lines.lastObject stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length == 0) {
        [lines removeLastObject];
    }
    [lines addObject:[NSString stringWithFormat:@"%@=%@", key, enable ? @"true" : @"false"]];
    [NSFileManager.defaultManager createDirectoryAtPath:configDir withIntermediateDirectories:YES attributes:nil error:nil];
    NSError *error = nil;
    if (![[[lines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
        NSLog(@"[CocoLauncher] Could not write %@: %@", path, error.localizedDescription);
        return;
    }
    NSLog(@"[CocoLauncher] ModernFix %@=%@", key, enable ? @"true" : @"false");
}

void CocoWriteMobileGluesConfig(NSString *mgDir) {
    if (mgDir.length == 0) {
        return;
    }
    NSString *path = [mgDir stringByAppendingPathComponent:@"config.json"];
    NSMutableDictionary *config = [NSMutableDictionary new];
    NSData *old = [NSData dataWithContentsOfFile:path];
    id parsed = old ? [NSJSONSerialization JSONObjectWithData:old options:0 error:nil] : nil;
    if ([parsed isKindOfClass:NSDictionary.class]) {
        [config addEntriesFromDictionary:parsed];
    }
    NSMutableArray<NSString *> *summary = [NSMutableArray new];
    for (NSDictionary *option in CocoMGOptions()) {
        int value = CocoMGValue(option);
        config[option[@"mgKey"]] = @(value);
        [summary addObject:[NSString stringWithFormat:@"%@=%d", option[@"mgKey"], value]];
    }
    // MobileGlues 2.0 reads a backend order ("multidrawOrder") instead of "multidrawMode"
    id mode = config[@"multidrawMode"];
    [config removeObjectForKey:@"multidrawMode"];
    NSDictionary<NSNumber *, NSString *> *orders = @{@1: @"indirect,native", @2: @"basevertex,native", @4: @"unroll,native"};
    NSString *order = orders[@([mode intValue])];
    if (order) {
        config[@"multidrawOrder"] = order;
    } else {
        [config removeObjectForKey:@"multidrawOrder"];
    }
    [config removeObjectForKey:@"enableExtGL43"]; // not in MobileGlues 2.0
    config[CocoMGConfigMarker] = @1;
    NSData *data = [NSJSONSerialization dataWithJSONObject:config options:NSJSONWritingPrettyPrinted error:nil];
    if ([data writeToFile:path atomically:YES]) {
        NSLog(@"[CocoLauncher] MobileGlues config.json: %@", [summary componentsJoinedByString:@", "]);
    } else {
        NSLog(@"[CocoLauncher] Could not write %@", path);
    }
}

NSString *CocoMemoryStatusText(void) {
    int limit = CocoProcessMemoryLimitMB();
    NSString *limitText = limit > 0 ? [NSString stringWithFormat:@"%.1f GB", limit / 1024.0] : @"?";
    NSString *entitlement = localize(CocoHasIncreasedMemoryLimit() ?
        @"coco.memory.entitlement.on" : @"coco.memory.entitlement.off", nil);
    int selected = getPrefInt(@"java.allocated_memory");
    return [NSString stringWithFormat:localize(@"coco.memory.status", nil),
        CocoDeviceMemoryMB() / 1024.0, limitText, entitlement,
        selected / 1024.0, CocoRecommendedHeapMB(), CocoSafeMaxHeapMB()];
}
