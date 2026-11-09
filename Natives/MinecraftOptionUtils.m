#import "MinecraftOptionUtils.h"
#import "environ.h"
#import "CocoPerformance.h"
#import "LauncherPreferences.h"

@interface MinecraftOptionUtils ()
@property(nonatomic) NSMutableArray<NSString *> *lineList;
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
    // CocoLauncher: write the Low/Balanced/High preset once after it is picked,
    // so later changes made in the game's own video settings are kept.
    NSString *pending = getPrefObject(@"internal.coco_pending_preset");
    if (pending.length > 0) {
        NSDictionary<NSString *, NSString *> *values = CocoPresetGameOptions(pending);
        for (NSString *key in values) {
            [options setKey:key value:values[key]];
        }
        NSLog(@"[CocoLauncher] Applied %@ preset to options.txt (%lu values)", pending, (unsigned long)values.count);
        [self cocoApplySodiumThreads:CocoPresetChunkThreads(pending)];
        setPrefObject(@"internal.coco_pending_preset", @"");
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
