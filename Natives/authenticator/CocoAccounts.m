#import <CommonCrypto/CommonDigest.h>
#import "CocoAccounts.h"

static NSDictionary *CocoReadJSONObject(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data == nil) {
        return nil;
    }
    id json = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
    return [json isKindOfClass:NSDictionary.class] ? json : nil;
}

static BOOL CocoWriteJSONObject(NSDictionary *object, NSString *path) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:NSJSONWritingPrettyPrinted error:nil];
    if (data == nil) {
        return NO;
    }
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
        withIntermediateDirectories:YES attributes:nil error:nil];
    return [data writeToFile:path atomically:YES];
}

static BOOL CocoIsNonEmptyString(id value) {
    return [value isKindOfClass:NSString.class] && [value length] > 0;
}

#pragma mark - CocoAccountProvider

@implementation CocoAccountProvider

+ (NSString *)defaultHome {
    const char *home = getenv("AME_HOME");
    return home ? @(home) : NSTemporaryDirectory();
}

+ (NSString *)accountsDirectoryInHome:(NSString *)home {
    return [(home ?: [self defaultHome]) stringByAppendingPathComponent:@"accounts"];
}

+ (CocoAccountKind)kindOfAccountData:(NSDictionary *)data {
    if (![data isKindOfClass:NSDictionary.class] || !CocoIsNonEmptyString(data[@"username"])) {
        return CocoAccountKindNone;
    }
    if ([data[@"type"] isEqual:@"local"]) {
        return CocoAccountKindLocal;
    }
    // Upstream files have no "type": Microsoft accounts always carry an
    // expiry time and an xuid, Local accounts carry neither.
    BOOL microsoft = [data[@"expiresAt"] longValue] != 0 || CocoIsNonEmptyString(data[@"xuid"]) ||
        CocoIsNonEmptyString(data[@"xboxGamertag"]);
    if (!microsoft) {
        return CocoAccountKindLocal;
    }
    return [data[@"username"] hasPrefix:@"Demo."] ? CocoAccountKindMicrosoftDemo : CocoAccountKindMicrosoft;
}

+ (NSString *)nameForKind:(CocoAccountKind)kind {
    switch (kind) {
        case CocoAccountKindLocal: return @"Local";
        case CocoAccountKindMicrosoft: return @"Microsoft";
        case CocoAccountKindMicrosoftDemo: return @"MicrosoftDemo";
        default: return @"None";
    }
}

+ (NSDictionary *)savedAccountNamed:(NSString *)name inHome:(NSString *)home {
    if (!CocoIsNonEmptyString(name) || [name containsString:@"/"]) {
        return nil;
    }
    NSString *path = [[self accountsDirectoryInHome:home] stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"json"]];
    return CocoReadJSONObject(path);
}

+ (NSArray<NSDictionary *> *)savedAccountsInHome:(NSString *)home {
    NSString *dir = [self accountsDirectoryInHome:home];
    NSMutableArray *accounts = [NSMutableArray new];
    for (NSString *file in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil]) {
        if (![file.pathExtension isEqualToString:@"json"]) {
            continue;
        }
        NSDictionary *json = CocoReadJSONObject([dir stringByAppendingPathComponent:file]);
        if ([self kindOfAccountData:json] != CocoAccountKindNone) {
            [accounts addObject:json];
        }
    }
    return accounts;
}

@end

#pragma mark - CocoLocalAccountProvider

@implementation CocoLocalAccountProvider

+ (BOOL)isValidName:(NSString *)name {
    return [name isKindOfClass:NSString.class] &&
        [name rangeOfString:@"^[A-Za-z0-9_]{3,16}$" options:NSRegularExpressionSearch].location != NSNotFound;
}

+ (NSString *)offlineUUIDForName:(NSString *)name {
    NSData *data = [[@"OfflinePlayer:" stringByAppendingString:name] dataUsingEncoding:NSUTF8StringEncoding];
    unsigned char md5[CC_MD5_DIGEST_LENGTH];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CC_MD5(data.bytes, (CC_LONG)data.length, md5);
#pragma clang diagnostic pop
    md5[6] = (md5[6] & 0x0f) | 0x30; // version 3
    md5[8] = (md5[8] & 0x3f) | 0x80; // IETF variant
    NSMutableString *hex = [NSMutableString stringWithCapacity:36];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) {
        if (i == 4 || i == 6 || i == 8 || i == 10) {
            [hex appendString:@"-"];
        }
        [hex appendFormat:@"%02x", md5[i]];
    }
    return hex;
}

+ (NSMutableDictionary *)accountDataForName:(NSString *)name {
    return @{
        @"type": @"local",
        @"username": name,
        @"profileId": [self offlineUUIDForName:name]
    }.mutableCopy;
}

+ (NSDictionary *)createAccountNamed:(NSString *)name inHome:(NSString *)home error:(NSString **)error {
    if (![self isValidName:name]) {
        if (error) *error = @"invalid_name";
        return nil;
    }
    NSDictionary *existing = [CocoAccountProvider savedAccountNamed:name inHome:home];
    if (existing != nil) {
        if ([CocoAccountProvider kindOfAccountData:existing] == CocoAccountKindLocal) {
            return existing;
        }
        if (error) *error = @"exists_microsoft";
        return nil;
    }
    NSMutableDictionary *data = [self accountDataForName:name];
    NSString *path = [[CocoAccountProvider accountsDirectoryInHome:home] stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"json"]];
    if (!CocoWriteJSONObject(data, path)) {
        if (error) *error = @"write_failed";
        return nil;
    }
    return data;
}

@end

#pragma mark - CocoLaunchContext

@interface CocoLaunchContext ()
@property(nonatomic, readwrite) CocoAccountKind kind;
@property(nonatomic, readwrite, copy) NSString *username, *uuid, *userType;
@property(nonatomic, readwrite) BOOL usesMicrosoftSession;
@end

@implementation CocoLaunchContext

+ (instancetype)contextForAccountData:(NSDictionary *)data {
    CocoAccountKind kind = [CocoAccountProvider kindOfAccountData:data];
    if (kind == CocoAccountKindNone) {
        return nil;
    }
    CocoLaunchContext *context = [CocoLaunchContext new];
    context.kind = kind;
    NSString *username = data[@"username"];
    if ([username hasPrefix:@"Demo."]) {
        username = [username substringFromIndex:5];
    }
    context.username = username;
    if (kind == CocoAccountKindLocal) {
        // Always derived from the name, so it can't drift between launches
        context.uuid = [CocoLocalAccountProvider offlineUUIDForName:data[@"username"]];
        context.userType = @"legacy";
        context.usesMicrosoftSession = NO;
    } else {
        context.uuid = CocoIsNonEmptyString(data[@"profileId"]) ? data[@"profileId"] : @"00000000-0000-0000-0000-000000000000";
        context.userType = @"msa";
        context.usesMicrosoftSession = YES;
    }
    return context;
}

- (NSString *)logDescription {
    return [NSString stringWithFormat:@"account=%@ kind=%@ uuid=%@ userType=%@ microsoftSession=%@",
        self.username, [CocoAccountProvider nameForKind:self.kind], self.uuid, self.userType,
        self.usesMicrosoftSession ? @"yes" : @"none"];
}

@end

#pragma mark - CocoMinecraftEntitlement

@implementation CocoMinecraftEntitlement

+ (BOOL)isOfficialMinecraftURL:(NSString *)url {
    if (!CocoIsNonEmptyString(url)) {
        return NO;
    }
    NSString *host = [NSURL URLWithString:url].host.lowercaseString;
    if (host.length == 0) {
        return NO;
    }
    for (NSString *domain in @[@"mojang.com", @"minecraft.net"]) {
        if ([host isEqualToString:domain] || [host hasSuffix:[@"." stringByAppendingString:domain]]) {
            return YES;
        }
    }
    return NO;
}

+ (BOOL)accountDataOwnsMinecraft:(NSDictionary *)data {
    return [CocoAccountProvider kindOfAccountData:data] == CocoAccountKindMicrosoft &&
        CocoIsNonEmptyString(data[@"xboxGamertag"]) && CocoIsNonEmptyString(data[@"profileId"]);
}

+ (NSString *)verifiedOwnerInHome:(NSString *)home {
    for (NSDictionary *account in [CocoAccountProvider savedAccountsInHome:home]) {
        if ([self accountDataOwnsMinecraft:account]) {
            return account[@"username"];
        }
    }
    return nil;
}

+ (BOOL)officialDownloadsAllowedForAccountData:(NSDictionary *)selected inHome:(NSString *)home {
    CocoAccountKind kind = [CocoAccountProvider kindOfAccountData:selected];
    if (kind == CocoAccountKindMicrosoftDemo || [self accountDataOwnsMinecraft:selected]) {
        return YES;
    }
    return [self verifiedOwnerInHome:home] != nil;
}

@end

#pragma mark - CocoAccountSelfTest

@implementation CocoAccountSelfTest

+ (NSDictionary *)result:(BOOL)pass detail:(NSString *)detail {
    return @{@"pass": @(pass), @"detail": detail ?: @""};
}

+ (NSDictionary *)runWritingResultsTo:(NSString *)realHome {
    NSMutableDictionary *results = [NSMutableDictionary new];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *home = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"coco-selftest-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    [fm createDirectoryAtPath:home withIntermediateDirectories:YES attributes:nil error:nil];

    NSString *name = @"CocoTester";
    NSString *expectedUUID = @"b31d9215-fe62-3224-ae9d-fda1d68f9e9b";
    NSString *steveUUID = @"5627dd98-e6be-3c21-b8a8-e92344183641"; // known vanilla value
    NSArray *msFields = @[@"accessToken", @"msaRefreshToken", @"xuid", @"xboxGamertag", @"expiresAt"];

    // LOCAL-01: fresh install, no Microsoft account -> Local account created
    {
        NSString *error = nil;
        BOOL fresh = [CocoAccountProvider savedAccountsInHome:home].count == 0 &&
            [CocoMinecraftEntitlement verifiedOwnerInHome:home] == nil;
        NSDictionary *created = [CocoLocalAccountProvider createAccountNamed:name inHome:home error:&error];
        BOOL noMicrosoftFields = YES;
        for (NSString *key in msFields) {
            noMicrosoftFields &= created[key] == nil;
        }
        BOOL invalidRejected = [CocoLocalAccountProvider createAccountNamed:@"ab" inHome:home error:nil] == nil &&
            [CocoLocalAccountProvider createAccountNamed:@"Tên_có_dấu" inHome:home error:nil] == nil &&
            [CocoLocalAccountProvider createAccountNamed:@"abcdefghijklmnopq" inHome:home error:nil] == nil;
        BOOL pass = fresh && created != nil && [created[@"profileId"] isEqualToString:expectedUUID] &&
            [CocoAccountProvider kindOfAccountData:created] == CocoAccountKindLocal && noMicrosoftFields && invalidRejected;
        results[@"LOCAL-01"] = [self result:pass detail:[NSString stringWithFormat:
            @"fresh=%d created=%@ uuid=%@ noMicrosoftFields=%d invalidNamesRejected=%d error=%@",
            fresh, created[@"username"], created[@"profileId"], noMicrosoftFields, invalidRejected, error]];
    }

    // LOCAL-02: no Microsoft token -> the Local account is read back from disk
    {
        NSDictionary *reloaded = [CocoAccountProvider savedAccountNamed:name inHome:home];
        BOOL pass = reloaded != nil && [reloaded[@"username"] isEqualToString:name] &&
            [reloaded[@"profileId"] isEqualToString:expectedUUID] &&
            [CocoAccountProvider kindOfAccountData:reloaded] == CocoAccountKindLocal &&
            reloaded[@"accessToken"] == nil;
        results[@"LOCAL-02"] = [self result:pass detail:[NSString stringWithFormat:
            @"reloaded=%@ uuid=%@ (app restart is checked by the simulator workflow)", reloaded[@"username"], reloaded[@"profileId"]]];
    }

    // LOCAL-03: no Xbox session -> launch context has the Local name/UUID
    {
        CocoLaunchContext *ctx = [CocoLaunchContext contextForAccountData:[CocoAccountProvider savedAccountNamed:name inHome:home]];
        NSString *steve = [CocoLocalAccountProvider offlineUUIDForName:@"Steve"];
        BOOL pass = ctx != nil && [ctx.username isEqualToString:name] && [ctx.uuid isEqualToString:expectedUUID] &&
            [ctx.userType isEqualToString:@"legacy"] && !ctx.usesMicrosoftSession && [steve isEqualToString:steveUUID];
        results[@"LOCAL-03"] = [self result:pass detail:[NSString stringWithFormat:@"%@ steveVector=%@", ctx.logDescription, steve]];
    }

    // LOCAL-04: Microsoft + Local side by side, no shared session
    NSString *msName = @"OwnerMS";
    {
        NSDictionary *ms = @{
            @"username": msName, @"xuid": @"2535400000000000", @"xboxGamertag": @"OwnerGT",
            @"profileId": @"11111111-2222-3333-4444-555555555555",
            @"expiresAt": @((long)NSDate.date.timeIntervalSince1970 + 86400)
        };
        CocoWriteJSONObject(ms, [[CocoAccountProvider accountsDirectoryInHome:home] stringByAppendingPathComponent:@"OwnerMS.json"]);
        NSDictionary *local = [CocoAccountProvider savedAccountNamed:name inHome:home];
        CocoLaunchContext *localCtx = [CocoLaunchContext contextForAccountData:local];
        CocoLaunchContext *msCtx = [CocoLaunchContext contextForAccountData:[CocoAccountProvider savedAccountNamed:msName inHome:home]];
        BOOL localClean = local[@"xuid"] == nil && local[@"accessToken"] == nil && local[@"xboxGamertag"] == nil;
        NSString *clashError = nil;
        BOOL clashRefused = [CocoLocalAccountProvider createAccountNamed:msName inHome:home error:&clashError] == nil &&
            [clashError isEqualToString:@"exists_microsoft"];
        BOOL msUntouched = [CocoAccountProvider kindOfAccountData:[CocoAccountProvider savedAccountNamed:msName inHome:home]] == CocoAccountKindMicrosoft;
        BOOL pass = localClean && !localCtx.usesMicrosoftSession && msCtx.usesMicrosoftSession &&
            ![localCtx.uuid isEqualToString:msCtx.uuid] && [msCtx.userType isEqualToString:@"msa"] &&
            clashRefused && msUntouched && [CocoAccountProvider savedAccountsInHome:home].count == 2;
        results[@"LOCAL-04"] = [self result:pass detail:[NSString stringWithFormat:
            @"local={%@} ms={%@} localClean=%d sameNameRefused=%d msUntouched=%d",
            localCtx.logDescription, msCtx.logDescription, localClean, clashRefused, msUntouched]];
    }

    // LOCAL-05: switching back and forth keeps the Local UUID
    {
        NSMutableSet *uuids = [NSMutableSet new];
        for (int i = 0; i < 6; i++) {
            NSString *selected = (i % 2 == 0) ? name : msName;
            CocoLaunchContext *ctx = [CocoLaunchContext contextForAccountData:[CocoAccountProvider savedAccountNamed:selected inHome:home]];
            if (ctx.kind == CocoAccountKindLocal) {
                [uuids addObject:ctx.uuid];
            }
        }
        NSDictionary *again = [CocoLocalAccountProvider createAccountNamed:name inHome:home error:nil];
        BOOL pass = uuids.count == 1 && [uuids.anyObject isEqualToString:expectedUUID] &&
            [again[@"profileId"] isEqualToString:expectedUUID];
        results[@"LOCAL-05"] = [self result:pass detail:[NSString stringWithFormat:@"distinctLocalUUIDs=%lu value=%@",
            (unsigned long)uuids.count, uuids.anyObject]];
    }

    // LOCAL-06: the shared installer's download rule with a Local account selected
    {
        NSDictionary *local = [CocoAccountProvider savedAccountNamed:name inHome:home];
        BOOL officialOK =
            [CocoMinecraftEntitlement isOfficialMinecraftURL:@"https://piston-data.mojang.com/v1/objects/x/client.jar"] &&
            [CocoMinecraftEntitlement isOfficialMinecraftURL:@"https://piston-meta.mojang.com/v1/packages/x/1.21.1.json"] &&
            [CocoMinecraftEntitlement isOfficialMinecraftURL:@"https://libraries.minecraft.net/com/mojang/brigadier/1.3.10/brigadier-1.3.10.jar"] &&
            [CocoMinecraftEntitlement isOfficialMinecraftURL:@"https://resources.download.minecraft.net/ab/abcdef"];
        BOOL otherOK =
            ![CocoMinecraftEntitlement isOfficialMinecraftURL:@"https://maven.fabricmc.net/net/fabricmc/fabric-loader/0.18.4/fabric-loader-0.18.4.jar"] &&
            ![CocoMinecraftEntitlement isOfficialMinecraftURL:@"https://github.com/Coconubs/cocolauncher-pack/releases/download/ios-pack/manifest.json"] &&
            ![CocoMinecraftEntitlement isOfficialMinecraftURL:@"https://notmojang.com.example.org/a.jar"] &&
            ![CocoMinecraftEntitlement isOfficialMinecraftURL:@"https://evilmojang.com/a.jar"];
        // Owner verified on this device: allowed while the Local account stays selected
        BOOL allowedWithOwner = [CocoMinecraftEntitlement officialDownloadsAllowedForAccountData:local inHome:home];
        // Fresh device without an owner: blocked (reported by the installer), Local still usable
        NSString *bare = [home stringByAppendingPathComponent:@"bare"];
        [CocoLocalAccountProvider createAccountNamed:name inHome:bare error:nil];
        BOOL blockedWithoutOwner = ![CocoMinecraftEntitlement officialDownloadsAllowedForAccountData:
            [CocoAccountProvider savedAccountNamed:name inHome:bare] inHome:bare];
        // A Microsoft account that doesn't own the game is not an owner
        CocoWriteJSONObject(@{@"username": @"Demo.NoGame", @"xuid": @"1", @"xboxGamertag": @"NoGame", @"expiresAt": @(1)},
            [[CocoAccountProvider accountsDirectoryInHome:bare] stringByAppendingPathComponent:@"Demo.NoGame.json"]);
        BOOL demoIsNotOwner = [CocoMinecraftEntitlement verifiedOwnerInHome:bare] == nil;
        BOOL pass = officialOK && otherOK && allowedWithOwner && blockedWithoutOwner && demoIsNotOwner;
        results[@"LOCAL-06"] = [self result:pass detail:[NSString stringWithFormat:
            @"officialHosts=%d nonOfficialHosts=%d allowedWithVerifiedOwner=%d blockedOnBareDevice=%d demoNotOwner=%d",
            officialOK, otherOK, allowedWithOwner, blockedWithoutOwner, demoIsNotOwner]];
    }

    [fm removeItemAtPath:home error:nil];

    NSUInteger passed = 0;
    for (NSDictionary *r in results.allValues) {
        passed += [r[@"pass"] boolValue];
    }
    NSLog(@"[CocoSelfTest] %lu/%lu passed", (unsigned long)passed, (unsigned long)results.count);
    for (NSString *key in [results.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSLog(@"[CocoSelfTest] %@ %@ %@", key, [results[key][@"pass"] boolValue] ? @"PASS" : @"FAIL", results[key][@"detail"]);
    }
    if (realHome.length > 0) {
        CocoWriteJSONObject(results, [realHome stringByAppendingPathComponent:@"coco-selftest.json"]);
    }
    return results;
}

@end
