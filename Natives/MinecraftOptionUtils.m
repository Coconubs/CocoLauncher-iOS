#import "MinecraftOptionUtils.h"
#import "environ.h"
#import "CocoPerformance.h"
#import "LauncherPreferences.h"

@interface MinecraftOptionUtils ()
@property(nonatomic) NSMutableArray<NSString *> *lineList;
- (void)cocoApplySodiumThreads:(int)threads;
- (void)cocoTuneModConfigs;
@end

@implementation MinecraftOptionUtils

+ (void)setupOptionsAtGameDir:(NSString *)gameDir {
    NSAssert(windowWidth > 0 && windowHeight > 0, @"called before setting windowWidth/windowHeight?");
    MinecraftOptionUtils *options = [MinecraftOptionUtils sharedInstance];
    options.optionsPath = [gameDir stringByAppendingPathComponent:@"options.txt"];
    // initial gui scale, also implicitly calls load
    [options updateMCGuiScale];
    [options setKey:@"fullscreen" value:@"false"];
    [options setKey:@"overrideWidth" value:@(windowWidth)];
    [options setKey:@"overrideHeight" value:@(windowHeight)];
    // Default settings for performance
    [options setDefaultForKey:@"mipmapLevels" value:@"0"];
    [options setDefaultForKey:@"particles" value:@"1"];
    [options setDefaultForKey:@"renderDistance" value:@"2"];
    [options setDefaultForKey:@"simulationDistance" value:@"5"];
    [options setDefaultForKey:@"bobView" value:@"false"];
    [options cocoTuneModConfigs];
    // CocoLauncher: View Bobbing off once (players can turn it back on in the game)
    if (getPrefBool(@"internal.coco_pending_bobview_off")) {
        [options setKey:@"bobView" value:@"false"];
        setPrefBool(@"internal.coco_pending_bobview_off", NO);
    }
    // CocoLauncher: write the Low/Balanced/High preset once after it is picked,
    // so later changes made in the game's own video settings are kept.
    NSString *pending = getPrefObject(@"internal.coco_pending_preset");
    if (pending.length > 0) {
        NSDictionary<NSString *, NSString *> *values = CocoPresetGameOptions(pending);
        for (NSString *key in values) {
            [options setKey:key value:values[key]];
        }
        NSLog(@"[CocoLauncher] Applied %@ preset to options.txt (%lu values)", pending, (unsigned long)values.count);
        [options cocoApplySodiumThreads:CocoPresetChunkThreads(pending)];
        setPrefObject(@"internal.coco_pending_preset", @"");
    }
    // CocoLauncher settings v9: GUI scale 2, VSync, 60 FPS once (after the preset so these win). Only once the pack
    // has put options.txt in place: a file written from nothing would stop the pack's own options from being seeded.
    if (getPrefBool(@"internal.coco_pending_v9_options") && [NSFileManager.defaultManager fileExistsAtPath:options.optionsPath]) {
        [options setKey:@"guiScale" value:@"2"];
        [options setKey:@"enableVsync" value:@"true"];
        [options setKey:@"maxFps" value:@"60"];
        setPrefBool(@"internal.coco_pending_v9_options", NO);
        NSLog(@"[CocoLauncher] options.txt: guiScale 2, VSync on, maxFps 60");
    }
    [options save];
}

// Sodium's own file: only an existing, readable config is changed (Sodium writes
// the full file on its first start), and only the chunk builder thread count.
- (void)cocoApplySodiumThreads:(int)threads {
    NSString *path = [[self.optionsPath stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"config/sodium-options.json"];
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data == nil) {
        return;
    }
    NSMutableDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
    if (![json isKindOfClass:NSMutableDictionary.class] || ![json[@"performance"] isKindOfClass:NSMutableDictionary.class]) {
        return;
    }
    json[@"performance"][@"chunk_builder_threads"] = @(threads);
    NSData *out = [NSJSONSerialization dataWithJSONObject:json options:NSJSONWritingPrettyPrinted error:nil];
    if (out != nil && [out writeToFile:path atomically:YES]) {
        NSLog(@"[CocoLauncher] Sodium chunk builder threads = %d", threads);
    }
}

// Mod configs written once (players can change them back in the game). Each one
// waits until the mod has created its file, so nothing incomplete is written.
- (NSString *)cocoConfigPath:(NSString *)name {
    return [[[self.optionsPath stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"config"] stringByAppendingPathComponent:name];
}

- (NSMutableDictionary *)cocoReadJSON:(NSString *)path {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data == nil) return nil;
    id json = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
    return [json isKindOfClass:NSMutableDictionary.class] ? json : nil;
}

- (BOOL)cocoWriteJSON:(NSDictionary *)json to:(NSString *)path {
    NSData *out = [NSJSONSerialization dataWithJSONObject:json options:NSJSONWritingPrettyPrinted error:nil];
    return out != nil && [out writeToFile:path atomically:YES];
}

// Sets keys that already exist in a section to the given value
static int CocoSetExisting(NSMutableDictionary *json, NSString *section, NSArray<NSString *> *keys, id value) {
    NSMutableDictionary *dict = json[section];
    if (![dict isKindOfClass:NSMutableDictionary.class]) return 0;
    int changed = 0;
    for (NSString *key in keys) {
        if (dict[key] != nil) {
            dict[key] = value;
            changed++;
        }
    }
    return changed;
}

- (void)cocoTuneModConfigs {
    // Sodium Extra: animated textures (re-uploaded every tick through MobileGlues) and some particles off
    if (getPrefBool(@"internal.coco_pending_sodium_extra")) {
        NSString *path = [self cocoConfigPath:@"sodium-extra-options.json"];
        NSMutableDictionary *json = [self cocoReadJSON:path];
        if (json) {
            int n = CocoSetExisting(json, @"animation_settings", @[@"water", @"lava", @"fire", @"portal", @"block_animations"], @NO);
            n += CocoSetExisting(json, @"particle_settings", @[@"rain_splash", @"block_breaking", @"block_break"], @NO);
            n += CocoSetExisting(json, @"render_settings", @[@"beacon_beam"], @NO);
            if ([self cocoWriteJSON:json to:path]) {
                setPrefBool(@"internal.coco_pending_sodium_extra", NO);
                NSLog(@"[CocoLauncher] Sodium Extra: %d effects turned off", n);
            }
        }
    }
    // Settings v9: Sodium Extra weather (rain/snow) off, FPS counter in the top right corner. The file may not exist
    // yet on a new install; Sodium Extra fills in every missing value when it loads a partial file.
    if (getPrefBool(@"internal.coco_pending_v9_sodium_extra")) {
        NSString *path = [self cocoConfigPath:@"sodium-extra-options.json"];
        NSMutableDictionary *json = [self cocoReadJSON:path];
        if (json == nil && ![NSFileManager.defaultManager fileExistsAtPath:path]) {
            json = [NSMutableDictionary new];
            [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        }
        if (json) {
            for (NSString *section in @[@"detail_settings", @"extra_settings"]) {
                if (![json[section] isKindOfClass:NSMutableDictionary.class]) {
                    json[section] = [NSMutableDictionary new];
                }
            }
            json[@"detail_settings"][@"rain_snow"] = @NO;
            json[@"extra_settings"][@"show_fps"] = @YES;
            json[@"extra_settings"][@"overlay_corner"] = @"TOP_RIGHT";
            if ([self cocoWriteJSON:json to:path]) {
                setPrefBool(@"internal.coco_pending_v9_sodium_extra", NO);
                NSLog(@"[CocoLauncher] Sodium Extra: weather off, FPS top right");
            }
        }
    }
    // Dynamic FPS: run a GC when the game is in the background / unfocused
    if (getPrefBool(@"internal.coco_pending_dynamic_fps")) {
        NSString *path = [self cocoConfigPath:@"dynamic_fps.json"];
        NSMutableDictionary *json = [self cocoReadJSON:path];
        if (json && [json[@"states"] isKindOfClass:NSMutableDictionary.class]) {
            int n = 0;
            for (NSString *state in @[@"unfocused", @"invisible"]) {
                NSMutableDictionary *dict = json[@"states"][state];
                if ([dict isKindOfClass:NSMutableDictionary.class]) {
                    dict[@"run_garbage_collector"] = @YES;
                    n++;
                }
            }
            if ([self cocoWriteJSON:json to:path]) {
                setPrefBool(@"internal.coco_pending_dynamic_fps", NO);
                NSLog(@"[CocoLauncher] Dynamic FPS: GC in %d background states", n);
            }
        }
    }
    // MoreCulling (TOML): cull item frames, sign text, rain and beacon beams further away
    if (getPrefBool(@"internal.coco_pending_moreculling")) {
        NSString *path = [self cocoConfigPath:@"moreculling.toml"];
        NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
        if (text) {
            NSDictionary<NSString *, NSString *> *values = @{
                @"itemFrameMapCulling": @"true", @"useItemFrameLOD": @"true", @"itemFrameLODRange": @"128",
                @"useItemFrame3FaceCulling": @"true", @"signTextCulling": @"true", @"rainCulling": @"true",
                @"beaconBeamCulling": @"true"
            };
            NSMutableString *result = [text mutableCopy];
            int n = 0;
            for (NSString *key in values) {
                NSString *pattern = [NSString stringWithFormat:@"(?m)^(\\s*%@\\s*=\\s*)[^\\r\\n#]+", key];
                NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
                NSString *template = [NSString stringWithFormat:@"$1%@", values[key]];
                n += (int)[re replaceMatchesInString:result options:0 range:NSMakeRange(0, result.length) withTemplate:template];
            }
            if ([result writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]) {
                setPrefBool(@"internal.coco_pending_moreculling", NO);
                NSLog(@"[CocoLauncher] MoreCulling: %d values set", n);
            }
        }
    }
}

+ (instancetype)sharedInstance {
    static MinecraftOptionUtils *sharedInstance = nil;
    static dispatch_once_t onceToken;

    dispatch_once(&onceToken, ^{
        sharedInstance = [[MinecraftOptionUtils alloc] init];
    });

    return sharedInstance;
}

- (void)load {
    NSAssert(self.optionsPath.length, @"optionsPath is not set");
    self.lineList = [NSMutableArray array];

    NSError *error = nil;
    NSString *contents = [NSString stringWithContentsOfFile:self.optionsPath
                                                   encoding:NSUTF8StringEncoding
                                                      error:&error];

    if (error != nil) {
        NSLog(@"Could not load options.txt: %@", error);
        return;
    }

    self.lineList = [contents componentsSeparatedByCharactersInSet:
                                  [NSCharacterSet newlineCharacterSet]];
}

- (void)ensureLoaded {
    NSAssert(self.lineList != nil, @"Unitialized MinecraftOptionUtils");
}

- (void)setKey:(NSString *)key value:(NSString *)value {
    [self ensureLoaded];

    NSString *prefix = [key stringByAppendingString:@":"];

    for (NSUInteger i = 0; i < self.lineList.count; i++) {
        NSString *line = self.lineList[i];

        if ([line hasPrefix:prefix]) {
            self.lineList[i] = [NSString stringWithFormat:@"%@:%@", key, value];
            return;
        }
    }

    [self.lineList addObject:[NSString stringWithFormat:@"%@:%@", key, value]];
}

- (void)setDefaultForKey:(NSString *)key value:(NSString *)value {
    if ([self getValueForKey:key] == nil) {
        [self.lineList addObject:[NSString stringWithFormat:@"%@:%@", key, value]];
    }
}

- (nullable NSString *)getValueForKey:(NSString *)key {
    [self ensureLoaded];

    NSString *prefix = [key stringByAppendingString:@":"];

    for (NSString *line in self.lineList) {
        if ([line hasPrefix:prefix]) {
            NSRange range = [line rangeOfString:@":"];

            if (range.location != NSNotFound) {
                return [line substringFromIndex:range.location + 1];
            }
        }
    }

    return nil;
}

- (void)removeValueForKey:(NSString *)key {
    [self ensureLoaded];

    NSString *prefix = [key stringByAppendingString:@":"];

    NSIndexSet *indexes = [self.lineList indexesOfObjectsPassingTest:^BOOL(NSString *line, NSUInteger idx, BOOL *stop) {
        return [line hasPrefix:prefix];
    }];

    if (indexes.count > 0) {
        [self.lineList removeObjectsAtIndexes:indexes];
    }
}

- (void)updateMCGuiScale {
    [self load];
    guiScale = [self getValueForKey:@"guiScale"].intValue;
    //guiScale = (str == null ? 0 :Integer.parseInt(str));

    int scale = MAX(MIN(windowWidth / 320, windowHeight / 240), 1);
    if(scale < guiScale || guiScale == 0){
        guiScale = scale;
    }
}

- (void)save {
    [self ensureLoaded];

    if (self.optionsPath.length == 0) {
        NSLog(@"Could not save options.txt: optionsPath is not set");
        return;
    }

    NSString *result = [self.lineList componentsJoinedByString:@"\n"];

    NSError *error = nil;
    BOOL success = [result writeToFile:self.optionsPath
                            atomically:YES
                              encoding:NSUTF8StringEncoding
                                 error:&error];

    if (!success) {
        NSLog(@"Could not save options.txt: %@", error);
    }

    self.lineList = nil;
}

@end
