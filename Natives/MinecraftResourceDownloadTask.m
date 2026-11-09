#include <CommonCrypto/CommonDigest.h>

#import "authenticator/BaseAuthenticator.h"
#import "authenticator/CocoAccounts.h"
#import "installer/modpack/ModpackAPI.h"
#import "AFNetworking.h"
#import "CocoConfig.h"
#import "CocoInstall.h"
#import "LauncherNavigationController.h"
#import "LauncherPreferences.h"
#import "MinecraftResourceDownloadTask.h"
#import "MinecraftResourceUtils.h"
#import "PLProfiles.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

// CocoLauncher: one file to download (any group, any account type)
@interface CocoDownloadItem : NSObject
@property(nonatomic, copy) NSString *url, *sha, *name, *path;
@property(nonatomic) NSUInteger size;
@property(nonatomic) CocoInstallGroup group;
@property(nonatomic) BOOL strictSHA; // always verify SHA-1 (Coco pack), ignoring general.check_sha
@property(nonatomic) NSUInteger attempt;
@property(nonatomic) NSProgress *fileProgress;
@property(nonatomic, copy) void (^success)(void);
@property(nonatomic, copy) void (^failure)(NSString *reason);
@end

@implementation CocoDownloadItem
@end

@interface MinecraftResourceDownloadTask ()
@property AFURLSessionManager* manager;
// CocoLauncher: Coco pack sync state
@property NSInteger cocoRemaining;
@property NSDictionary *cocoManifest;
// CocoLauncher: shared installer state
@property CocoInstallReport *cocoReport;
@property dispatch_group_t cocoGroup;      // only set by downloadVersion
@property BOOL cocoOfficialAllowed;
@property BOOL cocoFinished;
@property NSMutableSet<NSString *> *cocoHandledPaths; // loader libraries already queued
@end

// CocoLauncher: SHA-1 of a file without reading it all into memory at once
static NSString *CocoSHA1OfFile(NSString *path) {
    return [CocoSafeFile sha1OfFile:path];
}

@implementation MinecraftResourceDownloadTask

- (instancetype)init {
    self = [super init];
    // TODO: implement background download
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration defaultSessionConfiguration];
    configuration.timeoutIntervalForRequest = 86400;
    // CocoLauncher (idea from Prisma Launcher): more parallel downloads for the
    // thousands of small asset and pack files (iOS default is 4 per host)
    configuration.HTTPMaximumConnectionsPerHost = 16;
    //backgroundSessionConfigurationWithIdentifier:@"net.kdt.pojavlauncher.downloadtask"];
    self.manager = [[AFURLSessionManager alloc] initWithSessionConfiguration:configuration];
    self.fileList = [NSMutableArray new];
    self.progressList = [NSMutableArray new];
    return self;
}

#pragma mark - CocoLauncher: shared downloader

// Every file goes through here. A file that is already present and passes its
// checksum is not downloaded again. Official Minecraft files (Mojang servers)
// are only downloaded when cocoOfficialAllowed; otherwise they are recorded as
// blocked, with the reason, and nothing else is stopped. Downloads go to
// "<file>.part", are retried (with HTTP Range resume data when the server
// allows it), verified, and only then moved over the real file.
- (NSURLSessionDownloadTask *)cocoDownload:(NSString *)url size:(NSUInteger)size sha:(NSString *)sha name:(NSString *)name
    path:(NSString *)path library:(BOOL)library success:(void (^)(void))success failure:(void (^)(NSString *reason))failure {
    CocoDownloadItem *item = [CocoDownloadItem new];
    item.url = url;
    item.size = size;
    item.sha = sha;
    item.name = name ?: path.lastPathComponent;
    item.path = path;
    BOOL official = [CocoMinecraftEntitlement isOfficialMinecraftURL:url];
    item.group = [CocoInstallReport groupForURL:url name:item.name isLibrary:library official:official];
    item.success = success;
    item.failure = failure;
    return [self cocoStartDownload:item];
}

- (BOOL)cocoFileIsValid:(CocoDownloadItem *)item atPath:(NSString *)path {
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
        return NO;
    }
    if (item.strictSHA) {
        return [item.sha isEqualToString:CocoSHA1OfFile(path)];
    }
    return [self checkSHA:item.sha forFile:path altName:item.name];
}

- (void)cocoLeave {
    dispatch_group_t group = self.cocoGroup;
    if (group) {
        dispatch_group_leave(group);
    }
}

- (NSURLSessionDownloadTask *)cocoStartDownload:(CocoDownloadItem *)item {
    if ([self cocoFileIsValid:item atPath:item.path]) {
        [self.cocoReport recordValid:item.group];
        if (item.success) item.success();
        return nil;
    }
    if (!self.cocoOfficialAllowed && [CocoMinecraftEntitlement isOfficialMinecraftURL:item.url]) {
        NSString *reason = localize(@"coco.install.reason.no_owner", nil);
        [self.cocoReport recordBlocked:item.group name:item.name url:item.url reason:reason];
        NSLog(@"[MCDL] Blocked %@ <%@>: %@", item.name, item.url, reason);
        if (item.failure) item.failure(reason);
        return nil;
    }
    if (item.url.length == 0 || [NSURL URLWithString:item.url] == nil) {
        NSString *reason = @"no download URL";
        [self.cocoReport recordFailed:item.group name:item.name url:item.url reason:reason];
        if (item.failure) item.failure(reason);
        if (self.cocoGroup == nil) {
            [self finishDownloadWithErrorString:[NSString stringWithFormat:localize(@"launcher.mcl.error_download", NULL), item.name, reason]];
        }
        return nil;
    }

    [self.cocoReport recordQueued:item.group url:item.url];
    item.attempt = 1;
    int64_t units = item.size > 0 ? (int64_t)item.size : 1;
    item.fileProgress = [NSProgress progressWithTotalUnitCount:units];
    item.fileProgress.kind = NSProgressKindFile;
    @synchronized (self) {
        [self.progressList addObject:item.fileProgress];
        [self.fileList addObject:item.name];
        [self.progress addChild:item.fileProgress withPendingUnitCount:units];
        self.progress.totalUnitCount += units;
        self.textProgress.totalUnitCount = self.progress.totalUnitCount;
    }
    if (self.cocoGroup) {
        dispatch_group_enter(self.cocoGroup);
    }
    return [self cocoTaskForItem:item resumeData:nil];
}

- (NSURLSessionDownloadTask *)cocoTaskForItem:(CocoDownloadItem *)item resumeData:(NSData *)resumeData {
    NSString *partPath = [item.path stringByAppendingString:@".part"];
    void (^progressBlock)(NSProgress *) = ^(NSProgress *downloadProgress) {
        int64_t units = item.fileProgress.totalUnitCount;
        int64_t done = (int64_t)(downloadProgress.fractionCompleted * units);
        // never reach 100% before the checksum passed
        if (done > item.fileProgress.completedUnitCount && done < units) {
            item.fileProgress.completedUnitCount = done;
        }
    };
    NSURL *(^destination)(NSURL *, NSURLResponse *) = ^NSURL *(NSURL *targetPath, NSURLResponse *response) {
        NSLog(@"[MCDL] Downloading %@ (attempt %lu)", item.name, (unsigned long)item.attempt);
        NSFileManager *fm = NSFileManager.defaultManager;
        [fm createDirectoryAtPath:partPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        [fm removeItemAtPath:partPath error:nil];
        return [NSURL fileURLWithPath:partPath];
    };
    void (^completion)(NSURLResponse *, NSURL *, NSError *) = ^(NSURLResponse *response, NSURL *filePath, NSError *error) {
        [self cocoItem:item finishedWithResponse:response error:error partPath:partPath];
    };
    NSURLSessionDownloadTask *task = nil;
    if (resumeData != nil) {
        task = [self.manager downloadTaskWithResumeData:resumeData progress:progressBlock destination:destination completionHandler:completion];
    }
    if (task == nil) {
        NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:item.url]];
        task = [self.manager downloadTaskWithRequest:request progress:progressBlock destination:destination completionHandler:completion];
    }
    return task;
}

- (void)cocoItem:(CocoDownloadItem *)item finishedWithResponse:(NSURLResponse *)response error:(NSError *)error partPath:(NSString *)partPath {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (self.progress.cancelled || self.cocoFinished) {
        [fm removeItemAtPath:partPath error:nil];
        [self cocoLeave];
        return;
    }
    NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
    NSError *failure = error;
    if (failure == nil && status >= 400) {
        failure = [NSError errorWithDomain:@"CocoHTTP" code:status userInfo:nil];
    }
    if (failure == nil && ![self cocoFileIsValid:item atPath:partPath]) {
        NSString *actual = CocoSHA1OfFile(partPath) ?: @"-";
        failure = [NSError errorWithDomain:@"CocoInstall" code:1 userInfo:@{NSLocalizedDescriptionKey:
            [NSString stringWithFormat:@"checksum mismatch: expected %@, got %@", item.sha.length > 0 ? item.sha : @"-", actual]}];
    }
    if (failure != nil) {
        [fm removeItemAtPath:partPath error:nil];
        NSString *reason = [failure.domain isEqualToString:@"CocoInstall"] ? failure.localizedDescription
            : [CocoDownloadPolicy describeError:failure httpStatus:status];
        NSData *resumeData = [failure.domain isEqualToString:NSURLErrorDomain] ? failure.userInfo[NSURLSessionDownloadTaskResumeData] : nil;
        if ([CocoDownloadPolicy shouldRetryError:failure httpStatus:status attempt:item.attempt]) {
            item.attempt++;
            [self.cocoReport recordRetry:item.group name:item.name reason:reason resumed:resumeData != nil];
            NSLog(@"[MCDL] Retry %lu/%lu for %@ <%@>: %@%@", (unsigned long)item.attempt, (unsigned long)[CocoDownloadPolicy maxAttempts],
                item.name, item.url, reason, resumeData ? @" (resuming with HTTP Range)" : @"");
            double delay = [CocoDownloadPolicy delayBeforeAttempt:item.attempt];
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                if (self.progress.cancelled || self.cocoFinished) {
                    [self cocoLeave];
                    return;
                }
                [[self cocoTaskForItem:item resumeData:resumeData] resume];
            });
            return;
        }
        NSLog(@"[MCDL] Failed %@ <%@>: %@", item.name, item.url, reason);
        [self.cocoReport recordFailed:item.group name:item.name url:item.url reason:reason];
        if (item.failure) item.failure(reason);
        if (self.cocoGroup == nil) {
            [self finishDownloadWithErrorString:[NSString stringWithFormat:localize(@"launcher.mcl.error_download", NULL), item.name, reason]];
        }
        [self cocoLeave];
        return;
    }
    NSString *installError = nil;
    if (![CocoSafeFile installFile:partPath atPath:item.path error:&installError]) {
        NSLog(@"[MCDL] Failed to install %@: %@", item.name, installError);
        [self.cocoReport recordFailed:item.group name:item.name url:item.url reason:installError];
        if (item.failure) item.failure(installError);
        if (self.cocoGroup == nil) {
            [self finishDownloadWithErrorString:[NSString stringWithFormat:localize(@"launcher.mcl.error_download", NULL), item.name, installError]];
        }
        [self cocoLeave];
        return;
    }
    item.fileProgress.completedUnitCount = item.fileProgress.totalUnitCount;
    [self.cocoReport recordDownloaded:item.group];
    if (item.success) item.success();
    [self cocoLeave];
}

// Add file to the queue (upstream API, also used by the modpack installers)
- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url size:(NSUInteger)size sha:(NSString *)sha altName:(NSString *)altName toPath:(NSString *)path success:(void (^)())success {
    return [self cocoDownload:url size:size sha:sha name:altName path:path library:NO success:success failure:nil];
}

- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url size:(NSUInteger)size sha:(NSString *)sha altName:(NSString *)altName toPath:(NSString *)path {
    return [self createDownloadTask:url size:size sha:sha altName:altName toPath:path success:nil];
}

- (void)downloadVersionMetadata:(NSDictionary *)version success:(void (^)())success {
    [self downloadVersionMetadata:version success:success failure:nil];
}

- (void)downloadVersionMetadata:(NSDictionary *)version success:(void (^)())success failure:(void (^)(NSString *reason))failure {
    // Download base json
    NSString *versionStr = version[@"id"];
    if ([versionStr isEqualToString:@"latest-release"]) {
        versionStr = getPrefObject(@"internal.latest_version.release");
    } else if ([versionStr isEqualToString:@"latest-snapshot"]) {
        versionStr = getPrefObject(@"internal.latest_version.snapshot");
    }

    NSString *path = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("GAME_DIR"), versionStr];
    // Find it again to resolve latest-*
    version = (id)[MinecraftResourceUtils findVersion:versionStr inList:remoteVersionList];

    void(^completionBlock)(void) = ^{
        self.metadata = parseJSONFromFile(path);
        if (self.metadata[@"NSErrorObject"]) {
            [self finishDownloadWithErrorString:[self.metadata[@"NSErrorObject"] localizedDescription]];
            return;
        }
        if (self.metadata[@"inheritsFrom"]) {
            NSMutableDictionary *inheritsFromDict = parseJSONFromFile([NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("GAME_DIR"), self.metadata[@"inheritsFrom"]]);
            if (inheritsFromDict) {
                [MinecraftResourceUtils processVersion:self.metadata inheritsFrom:inheritsFromDict];
                self.metadata = inheritsFromDict;
            }
        }
        [MinecraftResourceUtils tweakVersionJson:self.metadata];
        success();
    };

    if (!version) {
        // This is likely local version, check if json exists and has inheritsFrom
        NSMutableDictionary *json = parseJSONFromFile(path);
        if (json[@"NSErrorObject"]) {
            [self finishDownloadWithErrorString:[json[@"NSErrorObject"] localizedDescription]];
            return;
        } else if (json[@"inheritsFrom"]) {
            version = (id)[MinecraftResourceUtils findVersion:json[@"inheritsFrom"] inList:remoteVersionList];
            path = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("GAME_DIR"), json[@"inheritsFrom"]];
        } else {
            completionBlock();
            return;
        }
    }

    versionStr = version[@"id"];
    NSString *url = version[@"url"];
    NSString *sha = url.stringByDeletingLastPathComponent.lastPathComponent;
    NSUInteger size = [version[@"size"] unsignedLongLongValue];

    NSURLSessionDownloadTask *task = [self cocoDownload:url size:size sha:sha name:path.lastPathComponent path:path
        library:NO success:completionBlock failure:failure];
    [task resume];
}

#pragma mark - Minecraft installation

- (void)downloadAssetMetadataWithSuccess:(void (^)())success failure:(void (^)(NSString *reason))failure {
    NSDictionary *assetIndex = self.metadata[@"assetIndex"];
    if (!assetIndex) {
        success();
        return;
    }
    NSString *name = [NSString stringWithFormat:@"assets/indexes/%@.json", assetIndex[@"id"]];
    NSString *path = [@(getenv("GAME_DIR")) stringByAppendingPathComponent:name];
    NSString *url = assetIndex[@"url"];
    NSString *sha = url.stringByDeletingLastPathComponent.lastPathComponent;
    NSUInteger size = [assetIndex[@"size"] unsignedLongLongValue];
    NSURLSessionDownloadTask *task = [self cocoDownload:url size:size sha:sha name:name path:path library:NO success:^{
        self.metadata[@"assetIndexObj"] = parseJSONFromFile(path);
        success();
    } failure:failure];
    [task resume];
}

// Libraries from a version JSON. markHandled: loader libraries queued before
// the Minecraft metadata is known (so they are not queued twice later).
- (NSArray *)cocoTasksForLibraries:(NSArray *)libraries markHandled:(BOOL)markHandled {
    NSMutableArray *tasks = [NSMutableArray new];
    for (NSDictionary *library in libraries) {
        if (![library isKindOfClass:NSDictionary.class]) {
            continue;
        }
        NSString *name = library[@"name"];

        NSMutableDictionary *artifact = library[@"downloads"][@"artifact"];
        NSUInteger size = [artifact[@"size"] unsignedLongLongValue];
        if (artifact == nil && [name containsString:@":"]) {
            NSLog(@"[MCDL] Unknown artifact object for %@, attempting to generate one", name);
            artifact = [[NSMutableDictionary alloc] init];
            NSString *prefix = library[@"url"] == nil ? @"https://libraries.minecraft.net/" : [library[@"url"] stringByReplacingOccurrencesOfString:@"http://" withString:@"https://"];
            NSArray *libParts = [name componentsSeparatedByString:@":"];
            artifact[@"path"] = [NSString stringWithFormat:@"%1$@/%2$@/%3$@/%2$@-%3$@.jar", [libParts[0] stringByReplacingOccurrencesOfString:@"." withString:@"/"], libParts[1], libParts[2]];
            artifact[@"url"] = [NSString stringWithFormat:@"%@%@", prefix, artifact[@"path"]];
            // CocoLauncher: Fabric's profile JSON lists "sha1" and "size" on the library itself
            artifact[@"sha1"] = library[@"checksums"][0] ?: library[@"sha1"];
            size = [library[@"size"] unsignedLongLongValue];
        }

        NSString *path = [NSString stringWithFormat:@"%s/libraries/%@", getenv("GAME_DIR"), artifact[@"path"]];
        NSString *sha = artifact[@"sha1"];
        NSString *url = artifact[@"url"];
        if ([library[@"skip"] boolValue]) {
            NSLog(@"[MDCL] Skipped library %@", name);
            continue;
        }
        @synchronized (self) {
            if (markHandled) {
                [self.cocoHandledPaths addObject:path];
            } else if ([self.cocoHandledPaths containsObject:path]) {
                continue;
            }
        }

        NSURLSessionDownloadTask *task = [self cocoDownload:url size:size sha:sha name:name path:path library:YES success:nil failure:nil];
        if (task) {
            [tasks addObject:task];
        } else if (self.progress.cancelled) {
            return nil;
        }
    }
    return tasks;
}

- (NSArray *)downloadClientLibraries {
    return [self cocoTasksForLibraries:self.metadata[@"libraries"] markHandled:NO];
}

// Loader (Fabric) libraries straight from the local version JSON: they don't
// depend on Mojang's metadata, so they are prepared even if it is missing.
- (NSArray *)cocoLoaderLibraryTasksForVersion:(NSDictionary *)version {
    NSString *versionId = version[@"id"];
    if (![versionId isKindOfClass:NSString.class] || versionId.length == 0) {
        return @[];
    }
    NSString *path = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.json", getenv("GAME_DIR"), versionId];
    if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
        return @[];
    }
    NSMutableDictionary *json = parseJSONFromFile(path);
    if (json[@"NSErrorObject"] || json[@"inheritsFrom"] == nil || ![json[@"libraries"] isKindOfClass:NSArray.class]) {
        return @[];
    }
    [MinecraftResourceUtils tweakVersionJson:json];
    return [self cocoTasksForLibraries:json[@"libraries"] markHandled:YES];
}

- (NSArray *)downloadClientAssets {
    NSMutableArray *tasks = [NSMutableArray new];
    NSDictionary *assets = self.metadata[@"assetIndexObj"];
    if (!assets) {
        return @[];
    }
    for (NSString *name in assets[@"objects"]) {
        NSDictionary *object = assets[@"objects"][name];
        NSString *hash = object[@"hash"];
        NSString *pathname = [NSString stringWithFormat:@"%@/%@", [hash substringToIndex:2], hash];
        NSUInteger size = [object[@"size"] unsignedLongLongValue];

        NSString *path;
        if ([assets[@"map_to_resources"] boolValue]) {
            path = [NSString stringWithFormat:@"%s/resources/%@", getenv("GAME_DIR"), name];
        } else {
            path = [NSString stringWithFormat:@"%s/assets/objects/%@", getenv("GAME_DIR"), pathname];
        }

        /* Special case for 1.19+
         * Since 1.19-pre1, setting the window icon on macOS invokes ObjC.
         * However, if an IOException occurs, it won't try to set.
         * We skip downloading the icon file to workaround this. */
        if ([name hasSuffix:@"/minecraft.icns"]) {
            [NSFileManager.defaultManager removeItemAtPath:path error:nil];
            continue;
        }

        NSString *url = [NSString stringWithFormat:@"https://resources.download.minecraft.net/%@", pathname];
        NSURLSessionDownloadTask *task = [self cocoDownload:url size:size sha:hash name:name path:path library:NO success:nil failure:nil];
        if (task) {
            [tasks addObject:task];
        } else if (self.progress.cancelled) {
            return nil;
        }
    }
    return tasks;
}

// CocoLauncher: Java is bundled with the app; it is checked, not downloaded
- (void)cocoCheckJavaRuntime {
    if (![self cocoIsCocoProfile]) {
        return;
    }
    NSString *javaHome = getSelectedJavaHome(@"1_17_newer", 21);
    if (javaHome.length > 0) {
        [self.cocoReport recordValid:CocoInstallGroupJava];
        [self.cocoReport setDetail:javaHome.lastPathComponent forGroup:CocoInstallGroupJava];
    } else {
        [self.cocoReport markGroup:CocoInstallGroupJava failedWithReason:localize(@"coco.install.reason.no_java", nil)];
    }
}

// CocoLauncher: independent resource groups. Fabric libraries, the Coco pack and
// the Minecraft files are prepared side by side; a blocked or failed group is
// reported with its reason when every download has finished, and never stops
// the others. The game only starts when every group is ready.
- (void)downloadVersion:(NSDictionary *)version {
    [self prepareForDownload];
    dispatch_group_t group = dispatch_group_create();
    self.cocoGroup = group;
    [self cocoCheckJavaRuntime];

    // 1. Loader (Fabric) libraries
    dispatch_group_enter(group);
    NSArray *loaderTasks = [self cocoLoaderLibraryTasksForVersion:version];
    [loaderTasks makeObjectsPerformSelector:@selector(resume)];
    dispatch_group_leave(group);

    // 2. Coco pack (Coco profile only)
    dispatch_group_enter(group);
    [self cocoPackTasksWithCompletion:^(NSArray *cocoTasks) {
        [cocoTasks makeObjectsPerformSelector:@selector(resume)];
        dispatch_group_leave(group);
    }];

    // 3. Minecraft: version metadata -> libraries, asset index -> assets
    dispatch_group_enter(group);
    [self downloadVersionMetadata:version success:^{
        NSArray *libTasks = [self downloadClientLibraries];
        [libTasks makeObjectsPerformSelector:@selector(resume)];
        [self downloadAssetMetadataWithSuccess:^{
            NSArray *assetTasks = [self downloadClientAssets];
            [assetTasks makeObjectsPerformSelector:@selector(resume)];
            [self.metadata removeObjectForKey:@"assetIndexObj"];
            dispatch_group_leave(group);
        } failure:^(NSString *reason) {
            [self.cocoReport markGroup:CocoInstallGroupAssets waitingFor:CocoInstallGroupMetadata];
            dispatch_group_leave(group);
        }];
    } failure:^(NSString *reason) {
        [self.cocoReport markGroup:CocoInstallGroupLibraries waitingFor:CocoInstallGroupMetadata];
        [self.cocoReport markGroup:CocoInstallGroupAssets waitingFor:CocoInstallGroupMetadata];
        dispatch_group_leave(group);
    }];

    dispatch_group_notify(group, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        [self cocoFinishInstall];
    });
}

#pragma mark - Coco Cobblemon pack (CocoLauncher)

// The Coco pack only contains Coco Cobblemon's own mods, configs and resource
// packs (no Mojang files, GitHub release URLs only), so the official-files rule
// never applies to it and it works the same for Local and Microsoft accounts.
// It is its own resource group in downloadVersion.

- (NSString *)cocoPackDirectory {
    return [NSString stringWithFormat:@"%s/instances/%@/%@", getenv("AME_HOME"),
        getPrefObject(@"general.game_directory"), COCO_GAME_DIR_NAME].stringByStandardizingPath;
}

- (BOOL)cocoIsCocoProfile {
    if (getenv("DEMO_LOCK") != NULL) {
        return NO;
    }
    NSString *gameDir = [PLProfiles resolveKeyForCurrentProfile:@"gameDir"];
    return [gameDir isEqualToString:COCO_PROFILE_GAME_DIR];
}

- (BOOL)cocoPackInstalled {
    NSString *marker = [[self cocoPackDirectory] stringByAppendingPathComponent:COCO_PACK_MARKER];
    return [NSFileManager.defaultManager fileExistsAtPath:marker];
}

- (void)cocoWriteMarker {
    NSDictionary *manifest = self.cocoManifest;
    NSDictionary *marker = @{
        @"manifest": COCO_PACK_MANIFEST_URL,
        @"generatedAt": manifest[@"generatedAt"] ?: @"",
        @"minecraftVersion": manifest[@"minecraftVersion"] ?: @"",
        @"fabricLoaderVersion": manifest[@"fabricLoaderVersion"] ?: @"",
        @"fileCount": @([manifest[@"files"] count])
    };
    saveJSONToFile(marker, [[self cocoPackDirectory] stringByAppendingPathComponent:COCO_PACK_MARKER]);
    NSLog(@"[CocoPack] Pack is up to date (%@)", marker[@"generatedAt"]);
}

// Relative path inside the pack directory, or nil if it could escape it
- (NSString *)cocoSafePath:(id)relPath inDir:(NSString *)baseDir {
    if (![relPath isKindOfClass:NSString.class] || [relPath length] == 0) {
        return nil;
    }
    if ([relPath hasPrefix:@"/"] || [relPath containsString:@"\\"]) {
        return nil;
    }
    for (NSString *part in [relPath componentsSeparatedByString:@"/"]) {
        if (part.length == 0 || [part isEqualToString:@"."] || [part isEqualToString:@".."]) {
            return nil;
        }
    }
    return [baseDir stringByAppendingPathComponent:relPath];
}

// Download URL of a manifest entry, only if it stays on the Coco release pages
- (NSURL *)cocoDownloadURL:(id)downloadName {
    if (![downloadName isKindOfClass:NSString.class] || [downloadName length] == 0) {
        return nil;
    }
    NSString *escaped = [downloadName stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
    NSURL *url = [NSURL URLWithString:escaped relativeToURL:[NSURL URLWithString:COCO_PACK_MANIFEST_URL]].absoluteURL;
    if (url == nil || ![url.absoluteString hasPrefix:COCO_PACK_URL_PREFIX]) {
        return nil;
    }
    return url;
}

- (void)cocoPackTasksWithCompletion:(void (^)(NSArray *tasks))completion {
    if (![self cocoIsCocoProfile]) {
        completion(@[]);
        return;
    }
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:COCO_PACK_MANIFEST_URL]
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:30];
    NSURLSessionDataTask *dataTask = [NSURLSession.sharedSession dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        NSDictionary *manifest = nil;
        if (data != nil && error == nil && status == 200) {
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([json isKindOfClass:NSDictionary.class] && [json[@"files"] isKindOfClass:NSArray.class]) {
                manifest = json;
            }
        }
        if (self.progress.cancelled) {
            return;
        }
        if (manifest == nil) {
            if ([self cocoPackInstalled]) {
                NSLog(@"[CocoPack] Could not check for pack updates (HTTP %ld, %@), using the installed pack", (long)status, error.localizedDescription);
                [self.cocoReport recordValid:CocoInstallGroupCocoPack];
                [self.cocoReport setDetail:localize(@"coco.install.detail.pack_offline", nil) forGroup:CocoInstallGroupCocoPack];
            } else {
                NSString *reason = [NSString stringWithFormat:@"%@ (HTTP %ld%@%@)", localize(@"coco.pack.error.manifest", nil), (long)status,
                    error ? @", " : @"", error.localizedDescription ?: @""];
                [self.cocoReport recordFailed:CocoInstallGroupCocoPack name:@"manifest.json" url:COCO_PACK_MANIFEST_URL reason:reason];
            }
            completion(@[]);
            return;
        }
        completion([self cocoCreateTasksFromManifest:manifest]);
    }];
    [dataTask resume];
}

- (NSArray *)cocoCreateTasksFromManifest:(NSDictionary *)manifest {
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSString *baseDir = [self cocoPackDirectory];
    [fileManager createDirectoryAtPath:baseDir withIntermediateDirectories:YES attributes:nil error:nil];

    NSMutableSet *packMods = [NSMutableSet new];
    NSMutableSet *packResourcePacks = [NSMutableSet new];
    NSMutableArray *pending = [NSMutableArray new];
    NSUInteger checked = 0;
    for (NSDictionary *file in manifest[@"files"]) {
        if (![file isKindOfClass:NSDictionary.class]) {
            continue;
        }
        NSString *relPath = file[@"path"];
        NSString *path = [self cocoSafePath:relPath inDir:baseDir];
        NSURL *url = [self cocoDownloadURL:file[@"downloadName"]];
        NSString *sha = file[@"sha1"];
        if (path == nil || url == nil || ![sha isKindOfClass:NSString.class] || sha.length != 40) {
            NSLog(@"[CocoPack] Skipping invalid manifest entry: %@", file[@"path"]);
            continue;
        }
        sha = sha.lowercaseString;
        checked++;
        if ([relPath hasPrefix:@"resourcepacks/"]) {
            [packResourcePacks addObject:relPath.lastPathComponent];
        }
        if ([relPath hasPrefix:@"mods/"]) {
            [packMods addObject:relPath.lastPathComponent];
            // "<mod>.jar.disabled" lets a player switch off a mod (e.g. Sodium with ANGLE)
            if ([fileManager fileExistsAtPath:[path stringByAppendingString:@".disabled"]]) {
                [self.cocoReport recordValid:CocoInstallGroupCocoPack];
                continue;
            }
        }
        if ([fileManager fileExistsAtPath:path]) {
            // "seed" files (most configs, options.txt, servers.dat) are only placed
            // once, so the player's own settings are kept
            if ([file[@"mode"] isEqual:@"seed"]) {
                [self.cocoReport recordValid:CocoInstallGroupCocoPack];
                continue;
            }
            if ([sha isEqualToString:CocoSHA1OfFile(path)]) {
                [self.cocoReport recordValid:CocoInstallGroupCocoPack];
                continue;
            }
        }
        [pending addObject:@{
            @"url": url.absoluteString,
            @"path": path,
            @"sha": sha,
            @"name": relPath,
            @"size": file[@"size"] ?: @(0)
        }];
    }

    // Remove mods that are no longer part of the Coco pack
    if (packMods.count > 0) {
        NSString *modsDir = [baseDir stringByAppendingPathComponent:@"mods"];
        for (NSString *name in [fileManager contentsOfDirectoryAtPath:modsDir error:nil]) {
            if ([name.pathExtension.lowercaseString isEqualToString:@"jar"] && ![packMods containsObject:name]) {
                NSLog(@"[CocoPack] Removing a mod that is no longer in the pack: %@", name);
                [fileManager removeItemAtPath:[modsDir stringByAppendingPathComponent:name] error:nil];
            }
        }
    }

    // Resource packs dropped from the pack (Coco Lite iOS) still sit in resourcepacks/ and stay enabled
    // in options.txt; move them out (not deleted) so the game does not load them.
    if (packResourcePacks.count > 0) {
        NSString *rpDir = [baseDir stringByAppendingPathComponent:@"resourcepacks"];
        NSString *movedDir = [baseDir stringByAppendingPathComponent:@"resourcepacks-coco-removed"];
        for (NSString *name in [fileManager contentsOfDirectoryAtPath:rpDir error:nil]) {
            if (![name.pathExtension.lowercaseString isEqualToString:@"zip"] || [packResourcePacks containsObject:name]) {
                continue;
            }
            [fileManager createDirectoryAtPath:movedDir withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *target = [movedDir stringByAppendingPathComponent:name];
            [fileManager removeItemAtPath:target error:nil];
            if ([fileManager moveItemAtPath:[rpDir stringByAppendingPathComponent:name] toPath:target error:nil]) {
                NSLog(@"[CocoPack] Moved a resource pack that is no longer in the pack: %@", name);
            }
        }
    }

    self.cocoManifest = manifest;
    self.cocoRemaining = pending.count;
    NSLog(@"[CocoPack] %lu of %lu files need to be downloaded", (unsigned long)pending.count, (unsigned long)checked);
    if (pending.count == 0) {
        [self cocoWriteMarker];
        return @[];
    }

    NSMutableArray *tasks = [NSMutableArray new];
    for (NSDictionary *entry in pending) {
        CocoDownloadItem *item = [CocoDownloadItem new];
        item.url = entry[@"url"];
        item.size = [entry[@"size"] unsignedLongLongValue];
        item.sha = entry[@"sha"];
        item.name = entry[@"name"];
        item.path = entry[@"path"];
        item.group = CocoInstallGroupCocoPack;
        item.strictSHA = YES;
        item.success = ^{
            BOOL done = NO;
            @synchronized (self) {
                self.cocoRemaining--;
                done = self.cocoRemaining == 0;
            }
            if (done) {
                [self cocoWriteMarker];
            }
        };
        NSURLSessionDownloadTask *task = [self cocoStartDownload:item];
        if (task) {
            [tasks addObject:task];
        }
    }
    return tasks;
}

#pragma mark - Modpack installation

- (void)downloadModpackFromAPI:(ModpackAPI *)api detail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion {
    [self prepareForDownload];

    NSString *url = modDetail[@"versionUrls"][selectedVersion];
    NSUInteger size = [modDetail[@"versionSizes"][selectedVersion] unsignedLongLongValue];
    NSString *sha = modDetail[@"versionHashes"][selectedVersion];
    NSString *name = [[modDetail[@"title"] lowercaseString] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    name = [name stringByReplacingOccurrencesOfString:@" " withString:@"_"];
    NSString *packagePath = [NSTemporaryDirectory() stringByAppendingFormat:@"/%@.zip", name];

    NSURLSessionDownloadTask *task = [self createDownloadTask:url size:size sha:sha altName:nil toPath:packagePath success:^{
        NSString *path = [NSString stringWithFormat:@"%s/custom_gamedir/%@", getenv("GAME_DIR"), name];
        [api downloader:self submitDownloadTasksFromPackage:packagePath toPath:path];
    }];
    [task resume];
}

#pragma mark - Utilities

- (void)prepareForDownload {
    // Create a fake progress which is used to update completedUnitCount properly
    // (completedUnitCount does not update unless subprogress completes)
    self.textProgress = [NSProgress new];
    self.textProgress.kind = NSProgressKindFile;
    self.textProgress.fileOperationKind = NSProgressFileOperationKindDownloading;
    self.textProgress.totalUnitCount = -1;

    self.progress = [NSProgress new];
    // Push 1 byte so it won't accidentally finish after downloading assets index
    self.progress.totalUnitCount = 1;
    [self.fileList removeAllObjects];
    [self.progressList removeAllObjects];

    // CocoLauncher: the installer works the same for every account type
    NSDictionary *selected = BaseAuthenticator.current.authData;
    self.cocoReport = [CocoInstallReport new];
    self.cocoGroup = nil;
    self.cocoHandledPaths = [NSMutableSet new];
    self.cocoFinished = NO;
    self.lastErrorReport = nil;
    self.lastErrorMessage = nil;
    self.lastErrorBlocked = NO;
    self.cocoOfficialAllowed = [CocoMinecraftEntitlement officialDownloadsAllowedForAccountData:selected
        inHome:[CocoAccountProvider defaultHome]];
    CocoLaunchContext *context = [CocoLaunchContext contextForAccountData:selected];
    NSLog(@"[MCDL] Installer for %@, official files %@", context.logDescription ?: @"(no account)",
        self.cocoOfficialAllowed ? @"allowed" : @"only if already valid on this device");
}

- (void)finishDownloadWithErrorString:(NSString *)error {
    @synchronized (self) {
        if (self.cocoFinished) {
            return;
        }
        self.cocoFinished = YES;
    }
    [self.progress cancel];
    [self.manager invalidateSessionCancelingTasks:YES resetSession:YES];
    self.lastErrorMessage = error;
    if (!self.quietErrors) {
        showDialog(localize(@"Error", nil), error);
    }
    if (self.handleError) self.handleError();
}

- (void)finishDownloadWithError:(NSError *)error file:(NSString *)file {
    NSString *errorStr = [NSString stringWithFormat:localize(@"launcher.mcl.error_download", NULL), file, error.localizedDescription];
    NSLog(@"[MCDL] Error: %@ %@", errorStr, NSThread.callStackSymbols);
    [self finishDownloadWithErrorString:errorStr];
}

#pragma mark - CocoLauncher: end of an install run

- (void)cocoWriteReportWithResult:(NSString *)result {
    NSDictionary *selected = BaseAuthenticator.current.authData;
    NSMutableDictionary *report = [NSMutableDictionary new];
    report[@"finishedAt"] = @((long long)(NSDate.date.timeIntervalSince1970 * 1000));
    report[@"result"] = result;
    report[@"account"] = [CocoLaunchContext contextForAccountData:selected].logDescription ?: @"(none)";
    report[@"officialFilesAllowed"] = @(self.cocoOfficialAllowed);
    report[@"groups"] = self.cocoReport.dictionaryRepresentation;
    saveJSONToFile(report, [[CocoAccountProvider defaultHome] stringByAppendingPathComponent:@"coco-install-report.json"]);
    NSLog(@"[MCDL] Install result %@\n%@", result, self.cocoReport.summaryText);
}

- (void)cocoFinishInstall {
    if (self.cocoFinished || self.progress.cancelled) {
        return;
    }
    CocoInstallReport *report = self.cocoReport;
    if (report.hasFailed || (!report.hasBlocked && !report.allReady)) {
        [self cocoWriteReportWithResult:@"FAILED"];
        self.lastErrorReport = report.summaryText;
        [self finishDownloadWithErrorString:[NSString stringWithFormat:localize(@"coco.install.failed.message", nil), report.summaryText]];
        return;
    }
    if (report.hasBlocked) {
        [self cocoWriteReportWithResult:@"BLOCKED"];
        [self cocoFinishBlocked];
        return;
    }
    [self cocoWriteReportWithResult:@"READY"];
    // Drop the 1 byte we set initially: the progress finishes and the caller launches
    self.progress.totalUnitCount--;
    self.textProgress.totalUnitCount--;
    if (self.progress.totalUnitCount == 0) {
        // We have nothing to download, invoke completion observer
        self.progress.totalUnitCount = 1;
        self.progress.completedUnitCount = 1;
        self.textProgress.totalUnitCount = 1;
        self.textProgress.completedUnitCount = 1;
    }
}

- (void)cocoFinishBlocked {
    @synchronized (self) {
        if (self.cocoFinished) {
            return;
        }
        self.cocoFinished = YES;
    }
    NSString *account = BaseAuthenticator.current.authData[@"username"] ?: @"";
    NSString *message = [NSString stringWithFormat:localize(@"coco.install.blocked.message", nil),
        COCO_MINECRAFT_VERSION, self.cocoReport.summaryText, account];
    [self.progress cancel];
    [self.manager invalidateSessionCancelingTasks:YES resetSession:YES];
    self.lastErrorMessage = message;
    self.lastErrorReport = self.cocoReport.summaryText;
    self.lastErrorBlocked = YES;
    if (self.handleBlocked) {
        self.handleBlocked(message);
    } else {
        showDialog(localize(@"coco.install.blocked.title", nil), message);
        if (self.handleError) self.handleError();
    }
}

// Check SHA of the file
- (BOOL)checkSHAIgnorePref:(NSString *)sha forFile:(NSString *)path altName:(NSString *)altName logSuccess:(BOOL)logSuccess {
    if (sha.length == 0) {
        // When sha = skip, only check for file existence
        BOOL existence = [NSFileManager.defaultManager fileExistsAtPath:path];
        if (existence) {
            NSLog(@"[MCDL] Warning: couldn't find SHA for %@, have to assume it's good.", path);
        }
        return existence;
    }

    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data == nil) {
        NSLog(@"[MCDL] SHA1 checker: file doesn't exist: %@", altName ? altName : path.lastPathComponent);
        return NO;
    }

    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *localSHA = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for(int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [localSHA appendFormat:@"%02x", digest[i]];
    }

    BOOL check = [sha isEqualToString:localSHA];
    if (!check || (getPrefBool(@"general.debug_logging") && logSuccess)) {
        NSLog(@"[MCDL] SHA1 %@ for %@%@",
          (check ? @"passed" : @"failed"), 
          (altName ? altName : path.lastPathComponent),
          (check ? @"" : [NSString stringWithFormat:@" (expected: %@, got: %@)", sha, localSHA]));
    }
    return check;
}

- (BOOL)checkSHA:(NSString *)sha forFile:(NSString *)path altName:(NSString *)altName logSuccess:(BOOL)logSuccess {
    if (getPrefBool(@"general.check_sha")) {
        return [self checkSHAIgnorePref:sha forFile:path altName:altName logSuccess:logSuccess];
    } else {
        return [NSFileManager.defaultManager fileExistsAtPath:path];
    }
}

- (BOOL)checkSHA:(NSString *)sha forFile:(NSString *)path altName:(NSString *)altName {
    return [self checkSHA:sha forFile:path altName:altName logSuccess:altName==nil];
}

@end
