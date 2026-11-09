#include <CommonCrypto/CommonDigest.h>

#import "authenticator/BaseAuthenticator.h"
#import "authenticator/CocoAccounts.h"
#import "installer/modpack/ModpackAPI.h"
#import "AFNetworking.h"
#import "CocoConfig.h"
#import "LauncherNavigationController.h"
#import "LauncherPreferences.h"
#import "MinecraftResourceDownloadTask.h"
#import "MinecraftResourceUtils.h"
#import "PLProfiles.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

@interface MinecraftResourceDownloadTask ()
@property AFURLSessionManager* manager;
// CocoLauncher: Coco pack sync state
@property NSInteger cocoRemaining;
@property NSDictionary *cocoManifest;
// CocoLauncher: official Minecraft files (Mojang servers) that could not be
// downloaded because no account that owns the game was verified on this device
@property BOOL cocoOfficialAllowed;
@property NSMutableArray<NSString *> *cocoBlockedOfficial;
@property BOOL cocoFinished;
@end

// CocoLauncher: SHA-1 of a file without reading it all into memory at once
static NSString *CocoSHA1OfFile(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if (data == nil) {
        return nil;
    }
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(data.bytes, (CC_LONG)data.length, digest);
    NSMutableString *hex = [NSMutableString stringWithCapacity:CC_SHA1_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_SHA1_DIGEST_LENGTH; i++) {
        [hex appendFormat:@"%02x", digest[i]];
    }
    return hex;
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

// Add file to the queue
- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url size:(NSUInteger)size sha:(NSString *)sha altName:(NSString *)altName toPath:(NSString *)path success:(void (^)())success {
    BOOL fileExists = [NSFileManager.defaultManager fileExistsAtPath:path];
    // logSuccess?
    if (fileExists && [self checkSHA:sha forFile:path altName:altName]) {
        if (success) success();
        return nil;
    } else if (![self cocoMayDownloadURL:url name:(altName ?: path.lastPathComponent)]) {
        return nil;
    }

    NSString *name = altName ?: path.lastPathComponent;
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:url]];
    __block NSProgress *progress;
    __block NSURLSessionDownloadTask *task = [self.manager downloadTaskWithRequest:request progress:nil
    destination:^NSURL * _Nonnull(NSURL * _Nonnull targetPath, NSURLResponse * _Nonnull response) {
        NSLog(@"[MCDL] Downloading %@", name);
        progress = [self.manager downloadProgressForTask:task];
        if (!size && task) {
            [self addDownloadTaskToProgress:task size:response.expectedContentLength];
            [self.fileList addObject:name];
        }
        [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        [NSFileManager.defaultManager removeItemAtPath:path error:nil];
        return [NSURL fileURLWithPath:path];
    } completionHandler:^(NSURLResponse * _Nonnull response, NSURL * _Nullable filePath, NSError * _Nullable error) {
        if (self.progress.cancelled) {
            // Ignore any further errors
        } else if (error != nil) {
            [self finishDownloadWithError:error file:name];
        } else if (![self checkSHA:sha forFile:path altName:altName]) {
            [self finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to verify file %@: SHA1 mismatch", path.lastPathComponent]];
        } else {
            progress.totalUnitCount = progress.completedUnitCount;
            if (success) success();
        }
    }];

    if (size && task) {
        [self addDownloadTaskToProgress:task size:size];
        [self.fileList addObject:name];
    }

    return task;
}

- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url size:(NSUInteger)size sha:(NSString *)sha altName:(NSString *)altName toPath:(NSString *)path {
    return [self createDownloadTask:url size:size sha:sha altName:altName toPath:path success:nil];
}

- (void)addDownloadTaskToProgress:(NSURLSessionDownloadTask *)task size:(NSInteger)size {
    NSProgress *progress = [self.manager downloadProgressForTask:task];
    NSUInteger fileSize = size>0 ? size : 1;
    progress.kind = NSProgressKindFile;
    if (size > 0) {
        progress.totalUnitCount = fileSize;
    }
    [self.progressList addObject:progress];
    [self.progress addChild:progress withPendingUnitCount:fileSize];
    self.progress.totalUnitCount += fileSize;
    self.textProgress.totalUnitCount = self.progress.totalUnitCount;
}

- (void)downloadVersionMetadata:(NSDictionary *)version success:(void (^)())success {
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

    NSURLSessionDownloadTask *task = [self createDownloadTask:url size:size sha:sha altName:nil toPath:path success:completionBlock];
    [task resume];
    if (task == nil && self.cocoBlockedOfficial.count > 0) {
        [self cocoFinishBlocked];
    }
}

#pragma mark - Minecraft installation

- (void)downloadAssetMetadataWithSuccess:(void (^)())success {
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
    NSURLSessionDownloadTask *task = [self createDownloadTask:url size:size sha:sha altName:name toPath:path success:^{
        self.metadata[@"assetIndexObj"] = parseJSONFromFile(path);
        success();
    }];
    [task resume];
    if (task == nil && self.cocoBlockedOfficial.count > 0) {
        [self cocoFinishBlocked];
    }
}

- (NSArray *)downloadClientLibraries {
    NSMutableArray *tasks = [NSMutableArray new];
    for (NSDictionary *library in self.metadata[@"libraries"]) {
        NSString *name = library[@"name"];

        NSMutableDictionary *artifact = library[@"downloads"][@"artifact"];
        if (artifact == nil && [name containsString:@":"]) {
            NSLog(@"[MCDL] Unknown artifact object for %@, attempting to generate one", name);
            artifact = [[NSMutableDictionary alloc] init];
            NSString *prefix = library[@"url"] == nil ? @"https://libraries.minecraft.net/" : [library[@"url"] stringByReplacingOccurrencesOfString:@"http://" withString:@"https://"];
            NSArray *libParts = [name componentsSeparatedByString:@":"];
            artifact[@"path"] = [NSString stringWithFormat:@"%1$@/%2$@/%3$@/%2$@-%3$@.jar", [libParts[0] stringByReplacingOccurrencesOfString:@"." withString:@"/"], libParts[1], libParts[2]];
            artifact[@"url"] = [NSString stringWithFormat:@"%@%@", prefix, artifact[@"path"]];
            artifact[@"sha1"] = library[@"checksums"][0];
        }

        NSString *path = [NSString stringWithFormat:@"%s/libraries/%@", getenv("GAME_DIR"), artifact[@"path"]];
        NSString *sha = artifact[@"sha1"];
        NSUInteger size = [artifact[@"size"] unsignedLongLongValue];
        NSString *url = artifact[@"url"];
        if ([library[@"skip"] boolValue]) {
            NSLog(@"[MDCL] Skipped library %@", name);
            continue;
        }

        NSURLSessionDownloadTask *task = [self createDownloadTask:url size:size sha:sha altName:name toPath:path success:nil];
        if (task) {
            [tasks addObject:task];
        } else if (self.progress.cancelled) {
            return nil;
        }
    }
    return tasks;
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
        NSURLSessionDownloadTask *task = [self createDownloadTask:url size:size sha:hash altName:name toPath:path success:nil];
        if (task) {
            [tasks addObject:task];
        } else if (self.progress.cancelled) {
            return nil;
        }
    }
    return tasks;
}

- (void)downloadVersion:(NSDictionary *)version {
    [self prepareForDownload];
    [self downloadVersionMetadata:version success:^{
        [self downloadAssetMetadataWithSuccess:^{
            NSArray *libTasks = [self downloadClientLibraries];
            NSArray *assetTasks = [self downloadClientAssets];
            if (self.progress.cancelled) {
                return;
            }
            // CocoLauncher: report the exact blocked step instead of switching accounts
            if (self.cocoBlockedOfficial.count > 0) {
                [self cocoFinishBlocked];
                return;
            }
            // CocoLauncher: after the game files, sync the Coco pack (Coco profile only)
            [self cocoPackTasksWithCompletion:^(NSArray *cocoTasks) {
                // Drop the 1 byte we set initially
                self.progress.totalUnitCount--;
                self.textProgress.totalUnitCount--;
                if (self.progress.totalUnitCount == 0) {
                    // We have nothing to download, invoke completion observer
                    self.progress.totalUnitCount = 1;
                    self.progress.completedUnitCount = 1;
                    self.textProgress.totalUnitCount = 1;
                    self.textProgress.completedUnitCount = 1;
                    return;
                }
                [libTasks makeObjectsPerformSelector:@selector(resume)];
                [assetTasks makeObjectsPerformSelector:@selector(resume)];
                [cocoTasks makeObjectsPerformSelector:@selector(resume)];
                [self.metadata removeObjectForKey:@"assetIndexObj"];
            }];
        }];
    }];
}

#pragma mark - Coco Cobblemon pack (CocoLauncher)

// The Coco pack only contains Coco Cobblemon's own mods, configs and resource
// packs (no Mojang files), so it never goes through the official-files rule
// (cocoMayDownloadURL) and works the same for Local and Microsoft accounts.
// It is synced from inside downloadVersion, after the Minecraft files are valid.

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
                completion(@[]);
            } else {
                [self finishDownloadWithErrorString:localize(@"coco.pack.error.manifest", nil)];
            }
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
                continue;
            }
        }
        if ([fileManager fileExistsAtPath:path]) {
            // "seed" files (most configs, options.txt, servers.dat) are only placed
            // once, so the player's own settings are kept
            if ([file[@"mode"] isEqual:@"seed"]) {
                continue;
            }
            if ([sha isEqualToString:CocoSHA1OfFile(path)]) {
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
    for (NSDictionary *item in pending) {
        NSURLSessionDownloadTask *task = [self cocoCreateDownloadTask:item[@"url"]
            size:[item[@"size"] unsignedLongLongValue] sha:item[@"sha"] name:item[@"name"] toPath:item[@"path"]];
        if (task) {
            [tasks addObject:task];
        }
    }
    return tasks;
}

- (NSURLSessionDownloadTask *)cocoCreateDownloadTask:(NSString *)url size:(NSUInteger)size sha:(NSString *)sha name:(NSString *)name toPath:(NSString *)path {
    NSString *partPath = [path stringByAppendingString:@".part"];
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:url]];
    __block NSProgress *progress;
    __block NSURLSessionDownloadTask *task = [self.manager downloadTaskWithRequest:request progress:nil
    destination:^NSURL * _Nonnull(NSURL * _Nonnull targetPath, NSURLResponse * _Nonnull response) {
        NSLog(@"[CocoPack] Downloading %@", name);
        progress = [self.manager downloadProgressForTask:task];
        [NSFileManager.defaultManager createDirectoryAtPath:partPath.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        [NSFileManager.defaultManager removeItemAtPath:partPath error:nil];
        return [NSURL fileURLWithPath:partPath];
    } completionHandler:^(NSURLResponse * _Nonnull response, NSURL * _Nullable filePath, NSError * _Nullable error) {
        NSFileManager *fileManager = NSFileManager.defaultManager;
        if (self.progress.cancelled) {
            [fileManager removeItemAtPath:partPath error:nil];
        } else if (error != nil) {
            [fileManager removeItemAtPath:partPath error:nil];
            [self finishDownloadWithError:error file:name];
        } else if (![sha isEqualToString:CocoSHA1OfFile(partPath)]) {
            [fileManager removeItemAtPath:partPath error:nil];
            [self finishDownloadWithErrorString:[NSString stringWithFormat:@"Failed to verify file %@: SHA1 mismatch", name]];
        } else {
            [fileManager removeItemAtPath:path error:nil];
            NSError *moveError = nil;
            if (![fileManager moveItemAtPath:partPath toPath:path error:&moveError]) {
                [self finishDownloadWithError:moveError file:name];
                return;
            }
            progress.totalUnitCount = progress.completedUnitCount;
            self.cocoRemaining--;
            if (self.cocoRemaining == 0) {
                [self cocoWriteMarker];
            }
        }
    }];

    if (task) {
        [self addDownloadTaskToProgress:task size:size];
        [self.fileList addObject:name];
    }
    return task;
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
    self.cocoBlockedOfficial = [NSMutableArray new];
    self.cocoFinished = NO;
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

#pragma mark - CocoLauncher: download rule for official Minecraft files

// Only files from Mojang's servers need an account that owns Minecraft:
// the selected account (Microsoft owner or demo), or a Microsoft owner
// verified earlier on this device. Fabric, the Coco pack and Java are never
// blocked, and the selected (Local) account is never changed.
- (BOOL)cocoMayDownloadURL:(NSString *)url name:(NSString *)name {
    if (self.cocoOfficialAllowed || ![CocoMinecraftEntitlement isOfficialMinecraftURL:url]) {
        return YES;
    }
    @synchronized (self) {
        [self.cocoBlockedOfficial addObject:name ?: url.lastPathComponent];
    }
    return NO;
}

- (NSString *)cocoBlockedSummary {
    NSUInteger jsons = 0, jars = 0, assets = 0;
    NSMutableArray *samples = [NSMutableArray new];
    @synchronized (self) {
        for (NSString *name in self.cocoBlockedOfficial) {
            if ([name.pathExtension isEqualToString:@"json"]) {
                jsons++;
            } else if ([name containsString:@":"] || [name.pathExtension isEqualToString:@"jar"]) {
                jars++;
            } else {
                assets++;
            }
            if (samples.count < 3) {
                [samples addObject:name];
            }
        }
    }
    return [NSString stringWithFormat:localize(@"coco.install.blocked.detail", nil),
        (unsigned long)(jsons + jars + assets), (unsigned long)jsons, (unsigned long)jars, (unsigned long)assets,
        [samples componentsJoinedByString:@", "]];
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
        COCO_MINECRAFT_VERSION, [self cocoBlockedSummary], account];
    NSLog(@"[MCDL] Official Minecraft files blocked for %@: %lu file(s)", account, (unsigned long)self.cocoBlockedOfficial.count);
    [self.progress cancel];
    [self.manager invalidateSessionCancelingTasks:YES resetSession:YES];
    self.lastErrorMessage = message;
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
