#import <CommonCrypto/CommonDigest.h>
#import "CocoAccounts.h"

NSString *const CocoAccountStorageIdKey = @"storageId";

static NSMutableDictionary *CocoReadJSONObject(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (data == nil) {
        return nil;
    }
    id json = [NSJSONSerialization JSONObjectWithData:data options:NSJSONReadingMutableContainers error:nil];
    return [json isKindOfClass:NSMutableDictionary.class] ? json : nil;
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

static BOOL CocoIsMicrosoftKind(CocoAccountKind kind) {
    return kind == CocoAccountKindMicrosoft || kind == CocoAccountKindMicrosoftDemo;
}

@interface CocoAccountProvider ()
+ (NSString *)pathForId:(NSString *)storageId inHome:(NSString *)home;
+ (NSString *)microsoftIdOfAccountData:(NSDictionary *)data;
@end

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
    id expiresAt = data[@"expiresAt"];
    BOOL hasExpiry = [expiresAt isKindOfClass:NSNumber.class] && [expiresAt longValue] != 0;
    BOOL microsoft = hasExpiry || CocoIsNonEmptyString(data[@"xuid"]) || CocoIsNonEmptyString(data[@"xboxGamertag"]);
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

+ (NSString *)microsoftIdOfAccountData:(NSDictionary *)data {
    if (CocoIsNonEmptyString(data[@"xuid"])) {
        return data[@"xuid"];
    }
    NSString *profileId = data[@"profileId"];
    if (CocoIsNonEmptyString(profileId) && ![profileId isEqualToString:@"00000000-0000-0000-0000-000000000000"]) {
        return profileId;
    }
    return nil;
}

+ (NSString *)storageIdForAccountData:(NSDictionary *)data {
    CocoAccountKind kind = [self kindOfAccountData:data];
    if (kind == CocoAccountKindLocal) {
        return [@"local-" stringByAppendingString:[CocoLocalAccountProvider offlineUUIDForName:data[@"username"]]];
    }
    if (CocoIsMicrosoftKind(kind)) {
        NSString *accountId = [self microsoftIdOfAccountData:data];
        return accountId ? [@"msa-" stringByAppendingString:accountId] : nil;
    }
    return nil;
}

+ (BOOL)accountData:(NSDictionary *)a isSameAccountAs:(NSDictionary *)b {
    CocoAccountKind ka = [self kindOfAccountData:a], kb = [self kindOfAccountData:b];
    if (ka == CocoAccountKindLocal && kb == CocoAccountKindLocal) {
        // The offline UUID comes from the exact nickname
        return [a[@"username"] isEqualToString:b[@"username"]];
    }
    if (CocoIsMicrosoftKind(ka) && CocoIsMicrosoftKind(kb)) {
        NSString *ida = [self microsoftIdOfAccountData:a], *idb = [self microsoftIdOfAccountData:b];
        return ida != nil && [ida isEqualToString:idb];
    }
    return NO;
}

+ (BOOL)isSafeStorageId:(NSString *)storageId {
    return CocoIsNonEmptyString(storageId) && ![storageId hasPrefix:@"."] &&
        [storageId rangeOfString:@"/"].location == NSNotFound &&
        [storageId rangeOfString:@"\\"].location == NSNotFound;
}

+ (NSString *)pathForId:(NSString *)storageId inHome:(NSString *)home {
    return [[self accountsDirectoryInHome:home] stringByAppendingPathComponent:[storageId stringByAppendingPathExtension:@"json"]];
}

+ (NSMutableDictionary *)savedAccountWithId:(NSString *)storageId inHome:(NSString *)home {
    if (![self isSafeStorageId:storageId]) {
        return nil;
    }
    NSMutableDictionary *data = CocoReadJSONObject([self pathForId:storageId inHome:home]);
    if (data == nil) {
        return nil;
    }
    data[CocoAccountStorageIdKey] = storageId;
    return data;
}

+ (NSArray<NSMutableDictionary *> *)savedAccountsInHome:(NSString *)home {
    NSString *dir = [self accountsDirectoryInHome:home];
    NSArray *files = [[NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil]
        sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray *accounts = [NSMutableArray new];
    for (NSString *file in files) {
        if (![file.pathExtension isEqualToString:@"json"]) {
            continue;
        }
        NSMutableDictionary *data = [self savedAccountWithId:file.stringByDeletingPathExtension inHome:home];
        if ([self kindOfAccountData:data] != CocoAccountKindNone) {
            [accounts addObject:data];
        }
    }
    return accounts;
}

+ (NSArray<NSMutableDictionary *> *)savedAccountsNamed:(NSString *)name kind:(CocoAccountKind)kind inHome:(NSString *)home {
    NSMutableArray *result = [NSMutableArray new];
    if (!CocoIsNonEmptyString(name)) {
        return result;
    }
    for (NSMutableDictionary *data in [self savedAccountsInHome:home]) {
        if (![data[@"username"] isEqualToString:name]) {
            continue;
        }
        if (kind == CocoAccountKindNone || [self kindOfAccountData:data] == kind) {
            [result addObject:data];
        }
    }
    return result;
}

+ (NSString *)saveAccountData:(NSMutableDictionary *)data inHome:(NSString *)home
    previousIds:(NSArray<NSString *> *)previousIds error:(NSString **)error {
    NSString *storageId = [self storageIdForAccountData:data];
    if (![self isSafeStorageId:storageId]) {
        if (error) *error = @"no_account_id";
        return nil;
    }
    NSMutableDictionary *content = data.mutableCopy;
    [content removeObjectsForKeys:@[CocoAccountStorageIdKey, @"input", @"oldusername"]];

    // Never overwrite a file that holds another account
    NSDictionary *existing = [self savedAccountWithId:storageId inHome:home];
    if (existing != nil && ![self accountData:existing isSameAccountAs:content]) {
        if (error) *error = @"storage_conflict";
        return nil;
    }
    if (!CocoWriteJSONObject(content, [self pathForId:storageId inHome:home])) {
        if (error) *error = @"write_failed";
        return nil;
    }
    // Move older copies of the SAME account to the new name; anything else stays
    NSMutableSet *checked = [NSMutableSet setWithObject:storageId];
    for (NSString *oldId in previousIds) {
        if (![oldId isKindOfClass:NSString.class] || [checked containsObject:oldId] || ![self isSafeStorageId:oldId]) {
            continue;
        }
        [checked addObject:oldId];
        NSDictionary *old = [self savedAccountWithId:oldId inHome:home];
        if (old != nil && [self accountData:old isSameAccountAs:content]) {
            [NSFileManager.defaultManager removeItemAtPath:[self pathForId:oldId inHome:home] error:nil];
        }
    }
    data[CocoAccountStorageIdKey] = storageId;
    return storageId;
}

+ (BOOL)removeAccountWithId:(NSString *)storageId inHome:(NSString *)home {
    if (![self isSafeStorageId:storageId]) {
        return NO;
    }
    return [NSFileManager.defaultManager removeItemAtPath:[self pathForId:storageId inHome:home] error:nil];
}

+ (NSString *)storageIdForPlayName:(NSString *)name preferredId:(NSString *)preferredId inHome:(NSString *)home {
    NSDictionary *preferred = [self savedAccountWithId:preferredId inHome:home];
    if ([preferred[@"username"] isEqual:name]) {
        return preferredId;
    }
    NSArray *locals = [self savedAccountsNamed:name kind:CocoAccountKindLocal inHome:home];
    if (locals.count > 0) {
        return locals.firstObject[CocoAccountStorageIdKey];
    }
    NSArray *microsoft = [self savedAccountsNamed:name kind:CocoAccountKindMicrosoft inHome:home];
    if (microsoft.count > 0) {
        return microsoft.firstObject[CocoAccountStorageIdKey];
    }
    return nil;
}

+ (NSString *)resolveSelectedId:(NSString *)selected inHome:(NSString *)home {
    if (!CocoIsNonEmptyString(selected)) {
        return nil;
    }
    if ([self savedAccountWithId:selected inHome:home] != nil) {
        return selected;
    }
    for (NSNumber *kind in @[@(CocoAccountKindLocal), @(CocoAccountKindMicrosoft), @(CocoAccountKindMicrosoftDemo)]) {
        NSArray *found = [self savedAccountsNamed:selected kind:(CocoAccountKind)kind.integerValue inHome:home];
        if (found.count > 0) {
            return found.firstObject[CocoAccountStorageIdKey];
        }
    }
    return nil;
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
    NSMutableDictionary *data = [NSMutableDictionary new];
    data[@"type"] = @"local";
    data[@"username"] = name;
    data[@"profileId"] = [self offlineUUIDForName:name];
    return data;
}

+ (NSMutableDictionary *)createAccountNamed:(NSString *)name inHome:(NSString *)home error:(NSString **)error {
    if (![self isValidName:name]) {
        if (error) *error = @"invalid_name";
        return nil;
    }
    NSArray *existing = [CocoAccountProvider savedAccountsNamed:name kind:CocoAccountKindLocal inHome:home];
    if (existing.count > 0) {
        return existing.firstObject;
    }
    NSMutableDictionary *data = [self accountDataForName:name];
    if ([CocoAccountProvider saveAccountData:data inHome:home previousIds:nil error:error] == nil) {
        return nil;
    }
    return data;
}

@end

#pragma mark - CocoLaunchContext

@interface CocoLaunchContext ()
@property(nonatomic, readwrite) CocoAccountKind kind;
@property(nonatomic, readwrite, copy) NSString *storageId;
@property(nonatomic, readwrite, copy) NSString *username;
@property(nonatomic, readwrite, copy) NSString *uuid;
@property(nonatomic, readwrite, copy) NSString *userType;
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
    context.storageId = data[CocoAccountStorageIdKey];
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
    return [NSString stringWithFormat:@"account=%@ storage=%@ kind=%@ uuid=%@ userType=%@ microsoftSession=%@",
        self.username, self.storageId ?: @"-", [CocoAccountProvider nameForKind:self.kind], self.uuid, self.userType,
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
    // Same as CocoLauncher Android (MojoLauncher): every account type, Local
    // included, installs the game. Owning Minecraft: Java Edition is the
    // player's responsibility under the Minecraft EULA.
    return YES;
}

@end

#pragma mark - CocoAccountSelfTest

@implementation CocoAccountSelfTest

+ (NSDictionary *)result:(BOOL)pass detail:(NSString *)detail {
    return @{@"status": pass ? @"PASS" : @"FAIL", @"detail": detail ?: @""};
}

+ (NSString *)freshHome {
    NSString *home = [NSTemporaryDirectory() stringByAppendingPathComponent:
        [@"coco-selftest-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    [NSFileManager.defaultManager createDirectoryAtPath:home withIntermediateDirectories:YES attributes:nil error:nil];
    return home;
}

+ (BOOL)fileExists:(NSString *)storageId inHome:(NSString *)home {
    return [NSFileManager.defaultManager fileExistsAtPath:[CocoAccountProvider pathForId:storageId inHome:home]];
}

+ (NSMutableDictionary *)microsoftDataNamed:(NSString *)name xuid:(NSString *)xuid {
    NSMutableDictionary *ms = [NSMutableDictionary new];
    ms[@"username"] = name;
    ms[@"xuid"] = xuid;
    ms[@"xboxGamertag"] = [name stringByAppendingString:@"GT"];
    ms[@"profileId"] = @"11111111-2222-3333-4444-555555555555";
    ms[@"expiresAt"] = @((long)NSDate.date.timeIntervalSince1970 + 86400);
    return ms;
}

+ (NSDictionary *)runWritingResultsTo:(NSString *)realHome {
    NSMutableDictionary *results = [NSMutableDictionary new];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *home = [self freshHome];

    NSString *name = @"CocoTester";
    NSString *expectedUUID = @"b31d9215-fe62-3224-ae9d-fda1d68f9e9b";
    NSString *steveUUID = @"5627dd98-e6be-3c21-b8a8-e92344183641"; // known vanilla value
    NSString *localId = [@"local-" stringByAppendingString:expectedUUID];
    NSArray *msFields = @[@"accessToken", @"msaRefreshToken", @"xuid", @"xboxGamertag", @"expiresAt"];

    // LOCAL-01: fresh install, no Microsoft account -> Local account created
    {
        NSString *error = nil;
        BOOL fresh = [CocoAccountProvider savedAccountsInHome:home].count == 0 &&
            [CocoMinecraftEntitlement verifiedOwnerInHome:home] == nil;
        NSDictionary *created = [CocoLocalAccountProvider createAccountNamed:name inHome:home error:&error];
        BOOL noMicrosoftFields = YES;
        for (NSString *key in msFields) {
            noMicrosoftFields = noMicrosoftFields && created[key] == nil;
        }
        BOOL invalidRejected = [CocoLocalAccountProvider createAccountNamed:@"ab" inHome:home error:nil] == nil &&
            [CocoLocalAccountProvider createAccountNamed:@"Tên_có_dấu" inHome:home error:nil] == nil &&
            [CocoLocalAccountProvider createAccountNamed:@"abcdefghijklmnopq" inHome:home error:nil] == nil;
        BOOL pass = fresh && created != nil && [created[@"profileId"] isEqualToString:expectedUUID] &&
            [created[CocoAccountStorageIdKey] isEqualToString:localId] && [self fileExists:localId inHome:home] &&
            [CocoAccountProvider kindOfAccountData:created] == CocoAccountKindLocal && noMicrosoftFields && invalidRejected;
        results[@"LOCAL-01"] = [self result:pass detail:[NSString stringWithFormat:
            @"fresh=%d created=%@ storage=%@ uuid=%@ noMicrosoftFields=%d invalidNamesRejected=%d error=%@",
            fresh, created[@"username"], created[CocoAccountStorageIdKey], created[@"profileId"], noMicrosoftFields, invalidRejected, error]];
    }

    // LOCAL-02: no Microsoft token -> the Local account is read back from disk
    {
        NSDictionary *reloaded = [CocoAccountProvider savedAccountWithId:localId inHome:home];
        NSString *fromOldPref = [CocoAccountProvider resolveSelectedId:name inHome:home];
        NSDictionary *again = [CocoLocalAccountProvider createAccountNamed:name inHome:home error:nil];
        BOOL pass = reloaded != nil && [reloaded[@"username"] isEqualToString:name] &&
            [reloaded[@"profileId"] isEqualToString:expectedUUID] &&
            [CocoAccountProvider kindOfAccountData:reloaded] == CocoAccountKindLocal &&
            reloaded[@"accessToken"] == nil && reloaded[CocoAccountStorageIdKey] != nil &&
            [fromOldPref isEqualToString:localId] && [again[CocoAccountStorageIdKey] isEqualToString:localId] &&
            [CocoAccountProvider savedAccountsInHome:home].count == 1;
        results[@"LOCAL-02"] = [self result:pass detail:[NSString stringWithFormat:
            @"reloaded=%@ uuid=%@ oldUsernameSelection->%@ recreateReturnsSame=%@ (app restart: simulator workflow)",
            reloaded[@"username"], reloaded[@"profileId"], fromOldPref, again[CocoAccountStorageIdKey]]];
    }

    // LOCAL-03: no Xbox session -> launch context has the Local name/UUID
    {
        CocoLaunchContext *ctx = [CocoLaunchContext contextForAccountData:[CocoAccountProvider savedAccountWithId:localId inHome:home]];
        NSString *steve = [CocoLocalAccountProvider offlineUUIDForName:@"Steve"];
        BOOL pass = ctx != nil && [ctx.username isEqualToString:name] && [ctx.uuid isEqualToString:expectedUUID] &&
            [ctx.userType isEqualToString:@"legacy"] && !ctx.usesMicrosoftSession && [ctx.storageId isEqualToString:localId] &&
            [steve isEqualToString:steveUUID];
        results[@"LOCAL-03"] = [self result:pass detail:[NSString stringWithFormat:@"%@ steveVector=%@", ctx.logDescription, steve]];
    }

    // LOCAL-04: Microsoft + Local with the SAME nickname, separate files and sessions
    NSString *msId = @"msa-2535400000000000";
    {
        NSMutableDictionary *ms = [self microsoftDataNamed:name xuid:@"2535400000000000"];
        NSString *saveError = nil;
        // Older builds would have written both to accounts/CocoTester.json
        NSString *saved = [CocoAccountProvider saveAccountData:ms inHome:home previousIds:@[name] error:&saveError];
        NSDictionary *local = [CocoAccountProvider savedAccountWithId:localId inHome:home];
        NSDictionary *msBack = [CocoAccountProvider savedAccountWithId:msId inHome:home];
        CocoLaunchContext *localCtx = [CocoLaunchContext contextForAccountData:local];
        CocoLaunchContext *msCtx = [CocoLaunchContext contextForAccountData:msBack];
        BOOL localClean = local[@"xuid"] == nil && local[@"accessToken"] == nil && local[@"xboxGamertag"] == nil &&
            [local[@"profileId"] isEqualToString:expectedUUID];
        BOOL msIntact = [msBack[@"xuid"] isEqualToString:@"2535400000000000"] &&
            [msBack[@"profileId"] isEqualToString:@"11111111-2222-3333-4444-555555555555"];
        NSString *playDefault = [CocoAccountProvider storageIdForPlayName:name preferredId:nil inHome:home];
        NSString *playPreferred = [CocoAccountProvider storageIdForPlayName:name preferredId:msId inHome:home];
        BOOL pass = [saved isEqualToString:msId] && localClean && msIntact &&
            !localCtx.usesMicrosoftSession && msCtx.usesMicrosoftSession &&
            ![localCtx.uuid isEqualToString:msCtx.uuid] && [msCtx.userType isEqualToString:@"msa"] &&
            [CocoAccountProvider savedAccountsNamed:name kind:CocoAccountKindNone inHome:home].count == 2 &&
            [playDefault isEqualToString:localId] && [playPreferred isEqualToString:msId];
        results[@"LOCAL-04"] = [self result:pass detail:[NSString stringWithFormat:
            @"sameNickname: local={%@} ms={%@} localClean=%d msIntact=%d playDefault=%@ playWhenMSSelected=%@ error=%@",
            localCtx.logDescription, msCtx.logDescription, localClean, msIntact, playDefault, playPreferred, saveError]];
    }

    // LOCAL-04b: files from older builds (accounts/<username>.json)
    {
        NSString *old = [self freshHome];
        NSString *dir = [CocoAccountProvider accountsDirectoryInHome:old];
        // legacy Local "Same" and a Microsoft account "Same" signing in later
        CocoWriteJSONObject(@{@"username": @"Same", @"profileId": [CocoLocalAccountProvider offlineUUIDForName:@"Same"]},
            [dir stringByAppendingPathComponent:@"Same.json"]);
        NSMutableDictionary *msSame = [self microsoftDataNamed:@"Same" xuid:@"111"];
        NSString *e1 = nil;
        NSString *msSameId = [CocoAccountProvider saveAccountData:msSame inHome:old previousIds:@[@"Same"] error:&e1];
        BOOL legacyLocalKept = [[CocoAccountProvider savedAccountWithId:@"Same" inHome:old][@"profileId"]
            isEqualToString:[CocoLocalAccountProvider offlineUUIDForName:@"Same"]];
        // legacy Microsoft "Bar" saved again (token refresh) -> moved to msa-222
        NSMutableDictionary *msBar = [self microsoftDataNamed:@"Bar" xuid:@"222"];
        CocoWriteJSONObject(msBar, [dir stringByAppendingPathComponent:@"Bar.json"]);
        NSMutableDictionary *barLoaded = [CocoAccountProvider savedAccountWithId:@"Bar" inHome:old];
        NSString *barId = [CocoAccountProvider saveAccountData:barLoaded inHome:old
            previousIds:@[barLoaded[CocoAccountStorageIdKey]] error:nil];
        BOOL barMigrated = [barId isEqualToString:@"msa-222"] && ![self fileExists:@"Bar" inHome:old] &&
            [self fileExists:@"msa-222" inHome:old] && [CocoAccountProvider savedAccountWithId:@"msa-222" inHome:old][CocoAccountStorageIdKey] != nil;
        BOOL noStorageKeyInFile = [CocoReadJSONObject([dir stringByAppendingPathComponent:@"msa-222.json"]) objectForKey:CocoAccountStorageIdKey] == nil;
        // legacy Local "Foo": creating "Foo" again returns it, no duplicate file
        CocoWriteJSONObject(@{@"username": @"Foo", @"profileId": [CocoLocalAccountProvider offlineUUIDForName:@"Foo"]},
            [dir stringByAppendingPathComponent:@"Foo.json"]);
        NSDictionary *foo = [CocoLocalAccountProvider createAccountNamed:@"Foo" inHome:old error:nil];
        BOOL fooReused = [foo[CocoAccountStorageIdKey] isEqualToString:@"Foo"];
        // a file under the target name holding another account is never overwritten
        CocoWriteJSONObject(@{@"type": @"local", @"username": @"Other", @"profileId": @"x"},
            [dir stringByAppendingPathComponent:@"msa-777.json"]);
        NSString *e2 = nil;
        NSString *conflictId = [CocoAccountProvider saveAccountData:[self microsoftDataNamed:@"Seven" xuid:@"777"]
            inHome:old previousIds:nil error:&e2];
        BOOL conflictSafe = conflictId == nil && [e2 isEqualToString:@"storage_conflict"] &&
            [[CocoAccountProvider savedAccountWithId:@"msa-777" inHome:old][@"username"] isEqualToString:@"Other"];
        BOOL pass = [msSameId isEqualToString:@"msa-111"] && legacyLocalKept && barMigrated && noStorageKeyInFile &&
            fooReused && conflictSafe;
        results[@"LOCAL-04b"] = [self result:pass detail:[NSString stringWithFormat:
            @"msSameNickname=%@ legacyLocalKept=%d legacyMicrosoftMigrated=%d noRuntimeKeyInFile=%d legacyLocalReused=%d conflictRefused=%d (%@ %@)",
            msSameId, legacyLocalKept, barMigrated, noStorageKeyInFile, fooReused, conflictSafe, e1, e2]];
        [fm removeItemAtPath:old error:nil];
    }

    // LOCAL-05: switching back and forth keeps the Local UUID
    {
        NSMutableSet *uuids = [NSMutableSet new];
        for (int i = 0; i < 6; i++) {
            NSString *selected = (i % 2 == 0) ? localId : msId;
            CocoLaunchContext *ctx = [CocoLaunchContext contextForAccountData:[CocoAccountProvider savedAccountWithId:selected inHome:home]];
            if (ctx.kind == CocoAccountKindLocal) {
                [uuids addObject:ctx.uuid];
            }
        }
        BOOL pass = uuids.count == 1 && [uuids.anyObject isEqualToString:expectedUUID];
        results[@"LOCAL-05"] = [self result:pass detail:[NSString stringWithFormat:@"distinctLocalUUIDs=%lu value=%@",
            (unsigned long)uuids.count, uuids.anyObject]];
    }

    // LOCAL-06: the shared installer's download rule with a Local account selected
    {
        NSDictionary *local = [CocoAccountProvider savedAccountWithId:localId inHome:home];
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
        BOOL allowedWithOwner = [CocoMinecraftEntitlement officialDownloadsAllowedForAccountData:local inHome:home];
        NSString *bare = [self freshHome];
        [CocoLocalAccountProvider createAccountNamed:name inHome:bare error:nil];
        NSDictionary *bareLocal = [CocoAccountProvider savedAccountsNamed:name kind:CocoAccountKindLocal inHome:bare].firstObject;
        BOOL allowedOnBareDevice = bareLocal != nil &&
            [CocoMinecraftEntitlement officialDownloadsAllowedForAccountData:bareLocal inHome:bare];
        CocoWriteJSONObject(@{@"username": @"Demo.NoGame", @"xuid": @"1", @"xboxGamertag": @"NoGame", @"expiresAt": @(1)},
            [[CocoAccountProvider accountsDirectoryInHome:bare] stringByAppendingPathComponent:@"msa-1.json"]);
        BOOL demoIsNotOwner = [CocoMinecraftEntitlement verifiedOwnerInHome:bare] == nil;
        [fm removeItemAtPath:bare error:nil];
        BOOL pass = officialOK && otherOK && allowedWithOwner && allowedOnBareDevice && demoIsNotOwner;
        results[@"LOCAL-06"] = [self result:pass detail:[NSString stringWithFormat:
            @"officialHosts=%d nonOfficialHosts=%d allowedWithVerifiedOwner=%d allowedOnBareDevice=%d demoNotOwner=%d",
            officialOK, otherOK, allowedWithOwner, allowedOnBareDevice, demoIsNotOwner]];
    }

    [fm removeItemAtPath:home error:nil];

    NSUInteger passed = 0;
    for (NSDictionary *r in results.allValues) {
        passed += [r[@"status"] isEqualToString:@"PASS"] ? 1 : 0;
    }
    NSLog(@"[CocoSelfTest] %lu/%lu passed", (unsigned long)passed, (unsigned long)results.count);
    for (NSString *key in [results.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSLog(@"[CocoSelfTest] %@ %@ %@", key, results[key][@"status"], results[key][@"detail"]);
    }
    if (realHome.length > 0) {
        CocoWriteJSONObject(results, [realHome stringByAppendingPathComponent:@"coco-selftest.json"]);
    }
    return results;
}

@end
