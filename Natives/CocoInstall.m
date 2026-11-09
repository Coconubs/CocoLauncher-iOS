#import <CommonCrypto/CommonDigest.h>
#import "CocoInstall.h"

static NSString *CocoL(NSString *key) {
    return [NSBundle.mainBundle localizedStringForKey:key value:nil table:nil] ?: key;
}

static NSString *const CocoInstallErrorDomain = @"CocoInstall";

#pragma mark - CocoInstallReport

@interface CocoInstallReport ()
@property(nonatomic) NSMutableArray<NSMutableDictionary<NSString *, NSNumber *> *> *counters;
@property(nonatomic) NSMutableArray<NSMutableSet<NSString *> *> *sources;
@property(nonatomic) NSMutableArray<NSMutableArray<NSString *> *> *problems;
@property(nonatomic) NSMutableDictionary<NSNumber *, NSNumber *> *waiting;
@property(nonatomic) NSMutableDictionary<NSNumber *, NSString *> *failedReasons;
@property(nonatomic) NSMutableDictionary<NSNumber *, NSString *> *details;
@end

@implementation CocoInstallReport

- (instancetype)init {
    self = [super init];
    if (self) {
        _counters = [NSMutableArray new];
        _sources = [NSMutableArray new];
        _problems = [NSMutableArray new];
        for (NSInteger g = 0; g < CocoInstallGroupCount; g++) {
            [_counters addObject:[NSMutableDictionary new]];
            [_sources addObject:[NSMutableSet new]];
            [_problems addObject:[NSMutableArray new]];
        }
        _waiting = [NSMutableDictionary new];
        _failedReasons = [NSMutableDictionary new];
        _details = [NSMutableDictionary new];
    }
    return self;
}

+ (NSString *)keyForGroup:(CocoInstallGroup)group {
    switch (group) {
        case CocoInstallGroupJava: return @"java";
        case CocoInstallGroupFabric: return @"fabric";
        case CocoInstallGroupMetadata: return @"metadata";
        case CocoInstallGroupLibraries: return @"libraries";
        case CocoInstallGroupAssets: return @"assets";
        case CocoInstallGroupCocoPack: return @"cocopack";
        default: return @"unknown";
    }
}

+ (NSString *)nameForState:(CocoInstallState)state {
    switch (state) {
        case CocoInstallStateReady: return @"READY";
        case CocoInstallStateBlocked: return @"BLOCKED";
        case CocoInstallStateWaiting: return @"WAITING";
        case CocoInstallStateFailed: return @"FAILED";
        default: return @"NOT_NEEDED";
    }
}

+ (CocoInstallGroup)groupForURL:(NSString *)url name:(NSString *)name isLibrary:(BOOL)isLibrary official:(BOOL)official {
    if (official) {
        if (isLibrary) {
            return CocoInstallGroupLibraries;
        }
        NSString *file = name.length > 0 ? name : [NSURL URLWithString:url].path;
        return [file.pathExtension.lowercaseString isEqualToString:@"json"] ? CocoInstallGroupMetadata : CocoInstallGroupAssets;
    }
    return isLibrary ? CocoInstallGroupFabric : CocoInstallGroupCocoPack;
}

- (void)add:(NSUInteger)amount to:(NSString *)counter inGroup:(CocoInstallGroup)group {
    if (group < 0 || group >= CocoInstallGroupCount) {
        return;
    }
    NSMutableDictionary *c = self.counters[group];
    c[counter] = @([c[counter] unsignedIntegerValue] + amount);
}

- (void)addSource:(NSString *)url group:(CocoInstallGroup)group {
    NSString *host = [NSURL URLWithString:url].host;
    if (host.length > 0 && group >= 0 && group < CocoInstallGroupCount) {
        [self.sources[group] addObject:host];
    }
}

- (void)addProblem:(NSString *)problem group:(CocoInstallGroup)group {
    if (group < 0 || group >= CocoInstallGroupCount) {
        return;
    }
    NSMutableArray *list = self.problems[group];
    if (list.count < 5) {
        [list addObject:problem];
    }
}

- (void)recordValid:(CocoInstallGroup)group {
    @synchronized (self) {
        [self add:1 to:@"checked" inGroup:group];
        [self add:1 to:@"valid" inGroup:group];
    }
}

- (void)recordQueued:(CocoInstallGroup)group url:(NSString *)url {
    @synchronized (self) {
        [self add:1 to:@"checked" inGroup:group];
        [self add:1 to:@"queued" inGroup:group];
        [self addSource:url group:group];
    }
}

- (void)recordDownloaded:(CocoInstallGroup)group {
    @synchronized (self) {
        [self add:1 to:@"downloaded" inGroup:group];
    }
}

- (void)recordRetry:(CocoInstallGroup)group name:(NSString *)name reason:(NSString *)reason resumed:(BOOL)resumed {
    @synchronized (self) {
        [self add:1 to:@"retries" inGroup:group];
        if (resumed) {
            [self add:1 to:@"resumed" inGroup:group];
        }
    }
}

- (void)recordFailed:(CocoInstallGroup)group name:(NSString *)name url:(NSString *)url reason:(NSString *)reason {
    @synchronized (self) {
        [self add:1 to:@"failed" inGroup:group];
        [self addSource:url group:group];
        [self addProblem:[NSString stringWithFormat:@"%@: %@", name, reason] group:group];
    }
}

- (void)recordBlocked:(CocoInstallGroup)group name:(NSString *)name url:(NSString *)url reason:(NSString *)reason {
    @synchronized (self) {
        [self add:1 to:@"checked" inGroup:group];
        [self add:1 to:@"blocked" inGroup:group];
        [self addSource:url group:group];
        [self addProblem:[NSString stringWithFormat:@"%@: %@", name, reason] group:group];
    }
}

- (void)markGroup:(CocoInstallGroup)group waitingFor:(CocoInstallGroup)dependency {
    @synchronized (self) {
        self.waiting[@(group)] = @(dependency);
    }
}

- (void)markGroup:(CocoInstallGroup)group failedWithReason:(NSString *)reason {
    @synchronized (self) {
        self.failedReasons[@(group)] = reason ?: @"";
        [self addProblem:reason ?: @"" group:group];
    }
}

- (void)setDetail:(NSString *)detail forGroup:(CocoInstallGroup)group {
    @synchronized (self) {
        self.details[@(group)] = detail;
    }
}

- (NSUInteger)countOf:(NSString *)counter inGroup:(CocoInstallGroup)group {
    if (group < 0 || group >= CocoInstallGroupCount) {
        return 0;
    }
    @synchronized (self) {
        return [self.counters[group][counter] unsignedIntegerValue];
    }
}

- (CocoInstallState)stateOfGroup:(CocoInstallGroup)group {
    @synchronized (self) {
        if (self.failedReasons[@(group)] != nil || [self countOf:@"failed" inGroup:group] > 0) {
            return CocoInstallStateFailed;
        }
        if ([self countOf:@"blocked" inGroup:group] > 0) {
            return CocoInstallStateBlocked;
        }
        if (self.waiting[@(group)] != nil) {
            return CocoInstallStateWaiting;
        }
        NSUInteger checked = [self countOf:@"checked" inGroup:group];
        if (checked == 0) {
            return CocoInstallStateNotNeeded;
        }
        NSUInteger done = [self countOf:@"valid" inGroup:group] + [self countOf:@"downloaded" inGroup:group];
        return done >= checked ? CocoInstallStateReady : CocoInstallStateWaiting;
    }
}

- (BOOL)anyGroupInState:(CocoInstallState)state {
    for (NSInteger g = 0; g < CocoInstallGroupCount; g++) {
        if ([self stateOfGroup:(CocoInstallGroup)g] == state) {
            return YES;
        }
    }
    return NO;
}

- (BOOL)hasBlocked {
    return [self anyGroupInState:CocoInstallStateBlocked];
}

- (BOOL)hasFailed {
    return [self anyGroupInState:CocoInstallStateFailed];
}

- (BOOL)allReady {
    for (NSInteger g = 0; g < CocoInstallGroupCount; g++) {
        CocoInstallState state = [self stateOfGroup:(CocoInstallGroup)g];
        if (state != CocoInstallStateReady && state != CocoInstallStateNotNeeded) {
            return NO;
        }
    }
    return YES;
}

- (NSString *)summaryText {
    NSMutableArray *lines = [NSMutableArray new];
    @synchronized (self) {
        for (NSInteger g = 0; g < CocoInstallGroupCount; g++) {
            CocoInstallGroup group = (CocoInstallGroup)g;
            CocoInstallState state = [self stateOfGroup:group];
            if (state == CocoInstallStateNotNeeded) {
                continue;
            }
            NSString *key = [CocoInstallReport keyForGroup:group];
            NSMutableString *line = [NSMutableString stringWithFormat:@"%@ %@: %@",
                state == CocoInstallStateReady ? @"✓" : (state == CocoInstallStateWaiting ? @"•" : @"✗"),
                CocoL([@"coco.install.group." stringByAppendingString:key]),
                CocoL([@"coco.install.state." stringByAppendingString:[CocoInstallReport nameForState:state]])];
            NSUInteger checked = [self countOf:@"checked" inGroup:group];
            if (checked > 0) {
                [line appendFormat:CocoL(@"coco.install.counts"),
                    (unsigned long)([self countOf:@"valid" inGroup:group] + [self countOf:@"downloaded" inGroup:group]),
                    (unsigned long)checked, (unsigned long)[self countOf:@"downloaded" inGroup:group]];
            }
            NSString *detail = self.details[@(group)];
            if (detail.length > 0) {
                [line appendFormat:@" (%@)", detail];
            }
            NSArray *hosts = [self.sources[group].allObjects sortedArrayUsingSelector:@selector(compare:)];
            if (hosts.count > 0 && state != CocoInstallStateReady) {
                [line appendFormat:@" [%@]", [hosts componentsJoinedByString:@", "]];
            }
            NSNumber *dependency = self.waiting[@(group)];
            if (state == CocoInstallStateWaiting && dependency != nil) {
                [line appendFormat:CocoL(@"coco.install.waiting_for"),
                    CocoL([@"coco.install.group." stringByAppendingString:[CocoInstallReport keyForGroup:(CocoInstallGroup)dependency.integerValue]])];
            }
            NSString *problem = self.problems[group].firstObject;
            if (problem.length > 0 && state != CocoInstallStateReady) {
                [line appendFormat:@"\n   %@", problem];
            }
            [lines addObject:line];
        }
    }
    return [lines componentsJoinedByString:@"\n"];
}

- (NSDictionary *)dictionaryRepresentation {
    NSMutableDictionary *result = [NSMutableDictionary new];
    @synchronized (self) {
        for (NSInteger g = 0; g < CocoInstallGroupCount; g++) {
            CocoInstallGroup group = (CocoInstallGroup)g;
            NSMutableDictionary *entry = [NSMutableDictionary new];
            entry[@"state"] = [CocoInstallReport nameForState:[self stateOfGroup:group]];
            [entry addEntriesFromDictionary:self.counters[group]];
            entry[@"sources"] = [self.sources[group].allObjects sortedArrayUsingSelector:@selector(compare:)];
            entry[@"problems"] = [self.problems[group] copy];
            if (self.details[@(group)]) {
                entry[@"detail"] = self.details[@(group)];
            }
            NSNumber *dependency = self.waiting[@(group)];
            if (dependency != nil) {
                entry[@"waitingFor"] = [CocoInstallReport keyForGroup:(CocoInstallGroup)dependency.integerValue];
            }
            result[[CocoInstallReport keyForGroup:group]] = entry;
        }
    }
    return result;
}

@end

#pragma mark - CocoDownloadPolicy

@implementation CocoDownloadPolicy

+ (NSUInteger)maxAttempts {
    return 4;
}

+ (double)delayBeforeAttempt:(NSUInteger)attempt {
    // attempt 2 -> 1 s, 3 -> 3 s, 4 -> 9 s
    double delay = 1;
    for (NSUInteger i = 2; i < attempt; i++) {
        delay *= 3;
    }
    return delay;
}

+ (BOOL)shouldRetryError:(NSError *)error httpStatus:(NSInteger)status attempt:(NSUInteger)attempt {
    if (attempt >= [self maxAttempts]) {
        return NO;
    }
    if (status == 408 || status == 425 || status == 429 || status >= 500) {
        return YES;
    }
    if (status >= 400) {
        return NO;
    }
    if ([error.domain isEqualToString:CocoInstallErrorDomain]) {
        return YES; // checksum mismatch: download again from scratch
    }
    if (![error.domain isEqualToString:NSURLErrorDomain]) {
        return NO;
    }
    switch (error.code) {
        case NSURLErrorTimedOut:
        case NSURLErrorCannotFindHost:
        case NSURLErrorCannotConnectToHost:
        case NSURLErrorNetworkConnectionLost:
        case NSURLErrorDNSLookupFailed:
        case NSURLErrorNotConnectedToInternet:
        case NSURLErrorResourceUnavailable:
        case NSURLErrorBadServerResponse:
        case NSURLErrorSecureConnectionFailed:
        case NSURLErrorCannotDecodeRawData:
        case NSURLErrorDownloadDecodingFailedMidStream:
        case NSURLErrorDownloadDecodingFailedToComplete:
        case NSURLErrorInternationalRoamingOff:
        case NSURLErrorCallIsActive:
        case NSURLErrorDataNotAllowed:
            return YES;
        default:
            return NO;
    }
}

+ (NSString *)describeError:(NSError *)error httpStatus:(NSInteger)status {
    if (status >= 400) {
        return [NSString stringWithFormat:@"HTTP %ld", (long)status];
    }
    if (error == nil) {
        return @"unknown error";
    }
    return [NSString stringWithFormat:@"%@ (%@ %ld)", error.localizedDescription, error.domain, (long)error.code];
}

@end

#pragma mark - CocoSafeFile

@implementation CocoSafeFile

+ (NSString *)sha1OfFile:(NSString *)path {
    NSFileHandle *handle = [NSFileHandle fileHandleForReadingAtPath:path];
    if (handle == nil) {
        return nil;
    }
    CC_SHA1_CTX context;
    CC_SHA1_Init(&context);
    while (YES) {
        @autoreleasepool {
            NSData *chunk = [handle readDataOfLength:1024 * 1024];
            if (chunk.length == 0) {
                break;
            }
            CC_SHA1_Update(&context, chunk.bytes, (CC_LONG)chunk.length);
        }
    }
    [handle closeFile];
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1_Final(digest, &context);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return hex;
}

+ (BOOL)installFile:(NSString *)partPath atPath:(NSString *)path error:(NSString **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSError *fsError = nil;
    BOOL ok;
    if ([fm fileExistsAtPath:path]) {
        // Atomic swap: the old file stays until the new one is in place
        ok = [fm replaceItemAtURL:[NSURL fileURLWithPath:path] withItemAtURL:[NSURL fileURLWithPath:partPath]
            backupItemName:nil options:0 resultingItemURL:nil error:&fsError];
    } else {
        [fm createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        ok = [fm moveItemAtPath:partPath toPath:path error:&fsError];
    }
    if (!ok) {
        [fm removeItemAtPath:partPath error:nil];
        if (error) *error = fsError.localizedDescription ?: @"could not move the downloaded file into place";
    }
    return ok;
}

@end

#pragma mark - CocoInstallSelfTest

@implementation CocoInstallSelfTest

+ (NSDictionary *)result:(BOOL)pass detail:(NSString *)detail {
    return @{@"status": pass ? @"PASS" : @"FAIL", @"detail": detail ?: @""};
}

+ (NSDictionary *)run {
    NSMutableDictionary *results = [NSMutableDictionary new];

    // INSTALL-01: which group a file belongs to
    {
        BOOL ok =
            [CocoInstallReport groupForURL:@"https://piston-meta.mojang.com/v1/packages/x/1.21.1.json" name:nil isLibrary:NO official:YES] == CocoInstallGroupMetadata &&
            [CocoInstallReport groupForURL:@"https://piston-meta.mojang.com/v1/packages/x/17.json" name:@"assets/indexes/17.json" isLibrary:NO official:YES] == CocoInstallGroupMetadata &&
            [CocoInstallReport groupForURL:@"https://piston-data.mojang.com/v1/objects/x/client.jar" name:@"1.21.1.jar" isLibrary:YES official:YES] == CocoInstallGroupLibraries &&
            [CocoInstallReport groupForURL:@"https://resources.download.minecraft.net/ab/abcd" name:@"minecraft/sounds/a.ogg" isLibrary:NO official:YES] == CocoInstallGroupAssets &&
            [CocoInstallReport groupForURL:@"https://maven.fabricmc.net/net/fabricmc/fabric-loader/0.18.4/fabric-loader-0.18.4.jar" name:@"net.fabricmc:fabric-loader:0.18.4" isLibrary:YES official:NO] == CocoInstallGroupFabric &&
            [CocoInstallReport groupForURL:@"https://github.com/Coconubs/cocolauncher-pack/releases/download/ios-pack/a.jar" name:@"mods/a.jar" isLibrary:NO official:NO] == CocoInstallGroupCocoPack;
        results[@"INSTALL-01"] = [self result:ok detail:@"metadata/libraries/assets/fabric/cocopack classification"];
    }

    // INSTALL-02: independent group states (blocked Mojang metadata does not stop Fabric or the Coco pack)
    {
        CocoInstallReport *r = [CocoInstallReport new];
        [r recordValid:CocoInstallGroupJava];
        [r recordValid:CocoInstallGroupFabric];
        [r recordQueued:CocoInstallGroupFabric url:@"https://maven.fabricmc.net/a.jar"];
        [r recordDownloaded:CocoInstallGroupFabric];
        [r recordBlocked:CocoInstallGroupMetadata name:@"1.21.1.json" url:@"https://piston-meta.mojang.com/x/1.21.1.json" reason:@"no owner"];
        [r markGroup:CocoInstallGroupLibraries waitingFor:CocoInstallGroupMetadata];
        [r markGroup:CocoInstallGroupAssets waitingFor:CocoInstallGroupMetadata];
        [r recordQueued:CocoInstallGroupCocoPack url:@"https://github.com/x"];
        [r recordDownloaded:CocoInstallGroupCocoPack];
        BOOL states = [r stateOfGroup:CocoInstallGroupJava] == CocoInstallStateReady &&
            [r stateOfGroup:CocoInstallGroupFabric] == CocoInstallStateReady &&
            [r stateOfGroup:CocoInstallGroupMetadata] == CocoInstallStateBlocked &&
            [r stateOfGroup:CocoInstallGroupLibraries] == CocoInstallStateWaiting &&
            [r stateOfGroup:CocoInstallGroupCocoPack] == CocoInstallStateReady &&
            r.hasBlocked && !r.hasFailed && !r.allReady;
        CocoInstallReport *f = [CocoInstallReport new];
        [f recordQueued:CocoInstallGroupCocoPack url:@"https://github.com/x"];
        [f recordFailed:CocoInstallGroupCocoPack name:@"mods/a.jar" url:@"https://github.com/x" reason:@"checksum mismatch"];
        BOOL failed = f.hasFailed && [f stateOfGroup:CocoInstallGroupCocoPack] == CocoInstallStateFailed;
        NSDictionary *dict = r.dictionaryRepresentation;
        BOOL dictOK = [dict[@"metadata"][@"state"] isEqualToString:@"BLOCKED"] &&
            [dict[@"libraries"][@"waitingFor"] isEqualToString:@"metadata"] &&
            [dict[@"metadata"][@"sources"] containsObject:@"piston-meta.mojang.com"];
        results[@"INSTALL-02"] = [self result:states && failed && dictOK && r.summaryText.length > 0
            detail:[NSString stringWithFormat:@"states=%d failedGroup=%d report=%d", states, failed, dictOK]];
    }

    // INSTALL-03: retry policy
    {
        NSError *timeout = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:nil];
        NSError *cancelled = [NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:nil];
        NSError *checksum = [NSError errorWithDomain:CocoInstallErrorDomain code:1 userInfo:nil];
        BOOL ok = [CocoDownloadPolicy shouldRetryError:timeout httpStatus:0 attempt:1] &&
            ![CocoDownloadPolicy shouldRetryError:timeout httpStatus:0 attempt:[CocoDownloadPolicy maxAttempts]] &&
            ![CocoDownloadPolicy shouldRetryError:cancelled httpStatus:0 attempt:1] &&
            ![CocoDownloadPolicy shouldRetryError:nil httpStatus:404 attempt:1] &&
            [CocoDownloadPolicy shouldRetryError:nil httpStatus:503 attempt:1] &&
            [CocoDownloadPolicy shouldRetryError:nil httpStatus:429 attempt:2] &&
            [CocoDownloadPolicy shouldRetryError:checksum httpStatus:0 attempt:1] &&
            [CocoDownloadPolicy delayBeforeAttempt:2] == 1 && [CocoDownloadPolicy delayBeforeAttempt:3] == 3 &&
            [CocoDownloadPolicy delayBeforeAttempt:4] == 9;
        results[@"INSTALL-03"] = [self result:ok detail:@"timeout/5xx/429/checksum retried, 404/cancel not, 4 attempts, 1-3-9 s"];
    }

    // INSTALL-04: chunked SHA-1 and atomic install of a part file
    {
        NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:[@"coco-install-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        NSFileManager *fm = NSFileManager.defaultManager;
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *target = [dir stringByAppendingPathComponent:@"a/file.bin"];
        NSString *part = [target stringByAppendingString:@".part"];
        [fm createDirectoryAtPath:target.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        [[@"old" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:target atomically:YES];
        [[@"abc" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:part atomically:YES];
        NSString *sha = [CocoSafeFile sha1OfFile:part];
        NSString *error = nil;
        BOOL installed = [CocoSafeFile installFile:part atPath:target error:&error];
        NSString *after = [CocoSafeFile sha1OfFile:target];
        BOOL ok = [sha isEqualToString:@"a9993e364706816aba3e25717850c26c9cd0d89d"] && installed &&
            [after isEqualToString:sha] && ![fm fileExistsAtPath:part] && [CocoSafeFile sha1OfFile:[dir stringByAppendingPathComponent:@"missing"]] == nil;
        [fm removeItemAtPath:dir error:nil];
        results[@"INSTALL-04"] = [self result:ok detail:[NSString stringWithFormat:@"sha1(abc)=%@ installed=%d error=%@", sha, installed, error]];
    }
    return results;
}

@end
