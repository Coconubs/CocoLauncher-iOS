#import <Foundation/Foundation.h>

// CocoLauncher: shared installer bookkeeping, independent of the account type.
//
// Resources are split into groups with their own state. A blocked or failed
// group never stops an independent one:
//
//   Java       bundled runtime, checked only (cannot be downloaded)
//   Fabric     loader libraries from the local version JSON (maven.fabricmc.net)
//   Metadata   Minecraft version JSON + asset index (Mojang)
//   Libraries  Minecraft libraries + client jar (Mojang)      needs Metadata
//   Assets     Minecraft assets (Mojang)                       needs the asset index
//   CocoPack   Coco Cobblemon mods/configs/resource packs (GitHub releases)
//
// Every file is checked with its checksum first; only missing or broken files
// are downloaded, to "<file>.part", verified, then moved into place.

typedef NS_ENUM(NSInteger, CocoInstallGroup) {
    CocoInstallGroupJava = 0,
    CocoInstallGroupFabric,
    CocoInstallGroupMetadata,
    CocoInstallGroupLibraries,
    CocoInstallGroupAssets,
    CocoInstallGroupCocoPack,
    CocoInstallGroupCount
};

typedef NS_ENUM(NSInteger, CocoInstallState) {
    CocoInstallStateNotNeeded = 0, // nothing in this group for this version
    CocoInstallStateReady,         // every file present and verified
    CocoInstallStateBlocked,       // not downloaded: a usage condition is not met
    CocoInstallStateWaiting,       // depends on a group that did not finish
    CocoInstallStateFailed         // network / checksum / disk error after retries
};

@interface CocoInstallReport : NSObject

+ (NSString *)keyForGroup:(CocoInstallGroup)group;
+ (NSString *)nameForState:(CocoInstallState)state;
// Group for a file: official (Mojang) JSON -> Metadata, official library ->
// Libraries, official asset -> Assets, other library -> Fabric.
+ (CocoInstallGroup)groupForURL:(NSString *)url name:(NSString *)name isLibrary:(BOOL)isLibrary official:(BOOL)official;

- (void)recordValid:(CocoInstallGroup)group;
- (void)recordQueued:(CocoInstallGroup)group url:(NSString *)url;
- (void)recordDownloaded:(CocoInstallGroup)group;
- (void)recordRetry:(CocoInstallGroup)group name:(NSString *)name reason:(NSString *)reason resumed:(BOOL)resumed;
- (void)recordFailed:(CocoInstallGroup)group name:(NSString *)name url:(NSString *)url reason:(NSString *)reason;
- (void)recordBlocked:(CocoInstallGroup)group name:(NSString *)name url:(NSString *)url reason:(NSString *)reason;
// A whole group (e.g. Libraries) could not be listed because another one did not finish
- (void)markGroup:(CocoInstallGroup)group waitingFor:(CocoInstallGroup)dependency;
- (void)markGroup:(CocoInstallGroup)group failedWithReason:(NSString *)reason;
- (void)setDetail:(NSString *)detail forGroup:(CocoInstallGroup)group;

- (CocoInstallState)stateOfGroup:(CocoInstallGroup)group;
- (NSUInteger)countOf:(NSString *)counter inGroup:(CocoInstallGroup)group; // checked valid queued downloaded failed blocked retries resumed
- (BOOL)hasBlocked;
- (BOOL)hasFailed;
- (BOOL)allReady;
// One line per group, localized ("coco.install.group.*", "coco.install.state.*")
- (NSString *)summaryText;
- (NSDictionary *)dictionaryRepresentation;

@end

@interface CocoDownloadPolicy : NSObject

+ (NSUInteger)maxAttempts;                 // 4
+ (double)delayBeforeAttempt:(NSUInteger)attempt; // 1, 3, 9 s
// Network errors, timeouts, HTTP 408/425/429/5xx are retried; others are not
+ (BOOL)shouldRetryError:(NSError *)error httpStatus:(NSInteger)status attempt:(NSUInteger)attempt;
+ (NSString *)describeError:(NSError *)error httpStatus:(NSInteger)status;

@end

@interface CocoSafeFile : NSObject

// Lowercase hex SHA-1, read in 1 MB chunks; nil if the file can't be read
+ (NSString *)sha1OfFile:(NSString *)path;
// Moves a verified part file over the target in one step; the old file is
// only replaced after the new one is complete.
+ (BOOL)installFile:(NSString *)partPath atPath:(NSString *)path error:(NSString **)error;

@end

@interface CocoInstallSelfTest : NSObject
// INSTALL-01..03: group rules, report states/summary, retry policy, safe file install
+ (NSDictionary *)run;
@end
