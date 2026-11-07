#pragma once

#import <Foundation/Foundation.h>

// CocoLauncher: device detection, memory recommendation and quality presets
// (Low / Balanced / High) for the Coco Cobblemon pack on iPhone and iPad.

#define COCO_PRESET_LOW      @"low"
#define COCO_PRESET_BALANCED @"balanced"
#define COCO_PRESET_HIGH     @"high"
#define COCO_PRESET_CUSTOM   @"custom"

// Bump when the defaults change in a way that should be re-applied once.
#define COCO_SETTINGS_VERSION 2

// Physical RAM of the device in MB.
int CocoDeviceMemoryMB(void);

// YES if the app was signed with com.apple.developer.kernel.increased-memory-limit.
// Only the signing certificate can grant it; the app cannot enable it itself.
BOOL CocoHasIncreasedMemoryLimit(void);

// Memory iOS lets this process use right now (current footprint + what
// os_proc_available_memory reports), in MB. 0 if unknown.
int CocoProcessMemoryLimitMB(void);

// Memory the JVM, Minecraft natives, mods' native buffers and the GL driver need
// on top of the Java heap (-Xmx), in MB.
int CocoNativeOverheadMB(void);

// Largest -Xmx that should still fit inside the process limit, in MB.
int CocoSafeMaxHeapMB(void);

// Recommended -Xmx for the Coco pack on this device, in MB.
int CocoRecommendedHeapMB(void);

// YES on devices that should start on the Low preset (4 GB RAM or less, few cores).
BOOL CocoIsLowEndDevice(void);

// Low on old devices, Balanced otherwise. High is never picked automatically.
NSString *CocoDefaultPreset(void);

// Launcher-side values of a preset: resolution (%) and the ProMotion switch.
int CocoPresetResolution(NSString *preset);
BOOL CocoPresetMaxFramerate(NSString *preset);

// Minecraft options.txt values of a preset (empty for custom).
NSDictionary<NSString *, NSString *> *CocoPresetGameOptions(NSString *preset);

// Called from Settings when the player picks a preset: updates the launcher
// preferences now and queues the Minecraft options for the next launch.
void CocoApplyPreset(NSString *preset);

// One-time upgrade of settings saved by older CocoLauncher versions.
void CocoMigrateSettings(void);

// Short status text for Settings: device RAM, process limit, entitlement.
NSString *CocoMemoryStatusText(void);
