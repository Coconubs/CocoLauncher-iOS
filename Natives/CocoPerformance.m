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
