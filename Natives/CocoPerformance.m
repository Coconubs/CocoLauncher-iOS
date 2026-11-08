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
    // driver and texture atlases. Measured on Android builds of the same pack.
    return CocoDeviceMemoryMB() >= 7000 ? 1400 : 1200;
}

int CocoSafeMaxHeapMB(void) {
    int limit = CocoProcessMemoryLimitMB();
    if (limit <= 0) {
        // Unknown limit: assume about half of the RAM without the entitlement.
        limit = CocoHasIncreasedMemoryLimit() ? CocoDeviceMemoryMB() * 0.75 : CocoDeviceMemoryMB() * 0.5;
    }
    return MAX(limit - CocoNativeOverheadMB(), 512);
}

int CocoRecommendedHeapMB(void) {
    int deviceMB = CocoDeviceMemoryMB();
    int wanted;
    if (deviceMB >= 7000) {
        wanted = 3072; // 8 GB and more
    } else if (deviceMB >= 5000) {
        wanted = 2560; // 6 GB
    } else {
        wanted = 2048; // 4 GB and less
    }
    // Never more than what still fits under the process limit, rounded to 128 MB.
    int safe = CocoSafeMaxHeapMB() / 128 * 128;
    return MAX(MIN(wanted, safe), 1024);
}

BOOL CocoIsLowEndDevice(void) {
    return CocoDeviceMemoryMB() < 5000 || NSProcessInfo.processInfo.processorCount <= 4;
}

NSString *CocoDefaultPreset(void) {
    return CocoIsLowEndDevice() ? COCO_PRESET_LOW : COCO_PRESET_BALANCED;
}

int CocoPresetResolution(NSString *preset) {
    if ([preset isEqualToString:COCO_PRESET_LOW]) return 50;
    if ([preset isEqualToString:COCO_PRESET_HIGH]) return 100;
    return 75;
}

BOOL CocoPresetMaxFramerate(NSString *preset) {
    // Only High asks ProMotion screens for 120 Hz; the others stay at 60.
    return [preset isEqualToString:COCO_PRESET_HIGH];
}

NSDictionary<NSString *, NSString *> *CocoPresetGameOptions(NSString *preset) {
    if ([preset isEqualToString:COCO_PRESET_LOW]) {
        return @{
            @"maxFps": @"30",
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
            @"enableVsync": @"false"
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
            @"enableVsync": @"false"
        };
    } else if ([preset isEqualToString:COCO_PRESET_HIGH]) {
        int maxFps = UIScreen.mainScreen.maximumFramesPerSecond > 60 ? 120 : 60;
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
            @"enableVsync": @"false"
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
    if (current == 3072 || current == 2560 || current == 2048) {
        setPrefObject(@"java.allocated_memory", @(CocoRecommendedHeapMB()));
    }
    setPrefObject(@"internal.coco_settings_version", @(COCO_SETTINGS_VERSION));
}

BOOL CocoHeapCappedToSafeMax(void) {
    return !CocoHasIncreasedMemoryLimit() && !getEntitlementValue(@"com.apple.private.memorystatus");
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
