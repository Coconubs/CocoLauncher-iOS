#import <Foundation/Foundation.h>

// CocoLauncher: account layer, kept apart from the installer and the launcher.
//
//   CocoAccountProvider          storage, Local/Microsoft detection, selection
//   ├─ CocoLocalAccountProvider  nickname + offline UUID, no Microsoft at all
//   └─ (MicrosoftAuthenticator)  OAuth -> Xbox Live -> Minecraft session
//   CocoLaunchContext            what the game gets for the selected account
//   CocoMinecraftEntitlement     download rule for official Minecraft files,
//                                checked by the download layer only
//
// Storage: every account is one file accounts/<storageId>.json, where the
// storage id comes from the provider and the account's own ID:
//   Local      local-<offline UUID>
//   Microsoft  msa-<xuid>
// so a Local and a Microsoft account with the same nickname never share a
// file. Files saved by older builds (accounts/<username>.json) keep working:
// their storage id is the old file name, and they are only moved to the new
// name when the SAME account (same provider and ID) is saved again. A file
// that belongs to another account is never deleted or overwritten.
//
// The runtime key "storageId" is added to account data in memory (it is the
// file name the data came from) and is never written into the file.

typedef NS_ENUM(NSInteger, CocoAccountKind) {
    CocoAccountKindNone = 0,
    CocoAccountKindLocal,
    CocoAccountKindMicrosoft,
    CocoAccountKindMicrosoftDemo // signed in, but the account doesn't own Minecraft
};

extern NSString *const CocoAccountStorageIdKey; // @"storageId"

@interface CocoAccountProvider : NSObject

// <home>/accounts; home defaults to $AME_HOME
+ (NSString *)accountsDirectoryInHome:(NSString *)home;
+ (NSString *)defaultHome;

+ (CocoAccountKind)kindOfAccountData:(NSDictionary *)data;
+ (NSString *)nameForKind:(CocoAccountKind)kind;

// local-<uuid> / msa-<xuid>; nil when the data has no usable ID
+ (NSString *)storageIdForAccountData:(NSDictionary *)data;
// Same provider and same account ID (not just the same nickname)
+ (BOOL)accountData:(NSDictionary *)a isSameAccountAs:(NSDictionary *)b;
+ (BOOL)isSafeStorageId:(NSString *)storageId;

// Loaded data carries CocoAccountStorageIdKey = the file name it came from
+ (NSMutableDictionary *)savedAccountWithId:(NSString *)storageId inHome:(NSString *)home;
+ (NSArray<NSMutableDictionary *> *)savedAccountsInHome:(NSString *)home;
+ (NSArray<NSMutableDictionary *> *)savedAccountsNamed:(NSString *)name kind:(CocoAccountKind)kind inHome:(NSString *)home;

// Writes <storageId>.json (atomic). previousIds: files this data may have
// been loaded from (old storage id, old username); each is removed only if
// it holds the same account. Returns the storage id, or nil + error.
+ (NSString *)saveAccountData:(NSMutableDictionary *)data inHome:(NSString *)home
    previousIds:(NSArray<NSString *> *)previousIds error:(NSString **)error;
// Removes only <storageId>.json
+ (BOOL)removeAccountWithId:(NSString *)storageId inHome:(NSString *)home;

// The account the home screen plays with for a typed nickname: the preferred
// (selected) account if it has this nickname, else the Local account with
// it, else a Microsoft account with it; nil if none.
+ (NSString *)storageIdForPlayName:(NSString *)name preferredId:(NSString *)preferredId inHome:(NSString *)home;
// A saved selection that no longer exists (older builds stored the username):
// the account with that nickname, Local first. nil if none.
+ (NSString *)resolveSelectedId:(NSString *)selected inHome:(NSString *)home;

@end

@interface CocoLocalAccountProvider : NSObject

// Minecraft player names: 3-16 characters, A-Z a-z 0-9 _
+ (BOOL)isValidName:(NSString *)name;
// UUID.nameUUIDFromBytes("OfflinePlayer:" + name), same as the vanilla game
+ (NSString *)offlineUUIDForName:(NSString *)name;
// The data saved for a Local account (no token, no xuid, no Xbox fields)
+ (NSMutableDictionary *)accountDataForName:(NSString *)name;
// Returns the existing Local account with this nickname, or creates
// accounts/local-<uuid>.json. A Microsoft account with the same nickname is
// a different account and is left untouched. nil + error for an invalid name.
+ (NSMutableDictionary *)createAccountNamed:(NSString *)name inHome:(NSString *)home error:(NSString **)error;

@end

@interface CocoLaunchContext : NSObject

@property(nonatomic, readonly) CocoAccountKind kind;
@property(nonatomic, readonly, copy) NSString *storageId;
@property(nonatomic, readonly, copy) NSString *username;
@property(nonatomic, readonly, copy) NSString *uuid;
// "legacy" for Local (Minecraft 1.21.1 then uses UserApiService.OFFLINE),
// "msa" for Microsoft
@property(nonatomic, readonly, copy) NSString *userType;
// Only Microsoft accounts read an access token (from the keychain, by xuid)
@property(nonatomic, readonly) BOOL usesMicrosoftSession;

+ (instancetype)contextForAccountData:(NSDictionary *)data;
- (NSString *)logDescription;

@end

@interface CocoMinecraftEntitlement : NSObject

// Official Minecraft files: game JSON, client, libraries and assets from
// Mojang's servers. Fabric, Coco pack and Java files are not official files.
+ (BOOL)isOfficialMinecraftURL:(NSString *)url;
// A saved Microsoft account on this device whose sign-in confirmed it owns
// Minecraft: Java Edition. Read-only: no token, no refresh, no session.
+ (NSString *)verifiedOwnerInHome:(NSString *)home;
// Whether official files may be downloaded right now: the selected account
// owns the game (or is a Microsoft demo account), or an owner was verified
// on this device. The selected account is never changed.
+ (BOOL)officialDownloadsAllowedForAccountData:(NSDictionary *)selected inHome:(NSString *)home;

@end

@interface CocoAccountSelfTest : NSObject

// Runs the account checks (LOCAL-01..06 and LOCAL-04b, duplicate nicknames and
// migration) against fresh temporary home directories, never the player's
// data. Returns {"LOCAL-01": {"status": "PASS"|"FAIL", "detail": ...}, ...}.
// Also written to <realHome>/coco-selftest.json when realHome is given.
+ (NSDictionary *)runWritingResultsTo:(NSString *)realHome;

@end
