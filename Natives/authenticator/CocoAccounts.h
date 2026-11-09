#import <Foundation/Foundation.h>

// CocoLauncher: account layer, kept apart from the installer and the launcher.
//
//   CocoAccountProvider          reads saved accounts, tells Local from Microsoft
//   ├─ CocoLocalAccountProvider  nickname + offline UUID, no Microsoft at all
//   └─ (MicrosoftAuthenticator)  OAuth -> Xbox Live -> Minecraft session
//   CocoLaunchContext            what the game gets for the selected account
//   CocoMinecraftEntitlement     download rule for official Minecraft files,
//                                checked by the download layer only
//
// A Local account never needs a Microsoft account, token or session to be
// created, selected, removed, saved or launched. Microsoft is only asked for
// when official Minecraft files (Mojang servers) are missing on this device
// and no Microsoft account that owns Minecraft: Java Edition has been verified
// here; the installer reports that exact step instead of switching accounts.

typedef NS_ENUM(NSInteger, CocoAccountKind) {
    CocoAccountKindNone = 0,
    CocoAccountKindLocal,
    CocoAccountKindMicrosoft,
    CocoAccountKindMicrosoftDemo // signed in, but the account doesn't own Minecraft
};

@interface CocoAccountProvider : NSObject

// <home>/accounts; home defaults to $AME_HOME
+ (NSString *)accountsDirectoryInHome:(NSString *)home;
+ (NSString *)defaultHome;

+ (CocoAccountKind)kindOfAccountData:(NSDictionary *)data;
+ (NSDictionary *)savedAccountNamed:(NSString *)name inHome:(NSString *)home;
+ (NSArray<NSDictionary *> *)savedAccountsInHome:(NSString *)home;
+ (NSString *)nameForKind:(CocoAccountKind)kind;

@end

@interface CocoLocalAccountProvider : NSObject

// Minecraft player names: 3-16 characters, A-Z a-z 0-9 _
+ (BOOL)isValidName:(NSString *)name;
// UUID.nameUUIDFromBytes("OfflinePlayer:" + name), same as the vanilla game
+ (NSString *)offlineUUIDForName:(NSString *)name;
// The data saved for a Local account (no token, no xuid, no Xbox fields)
+ (NSMutableDictionary *)accountDataForName:(NSString *)name;
// Creates <home>/accounts/<name>.json, or returns the existing Local account.
// Fails (nil + error) for an invalid name or a Microsoft account with that name.
+ (NSDictionary *)createAccountNamed:(NSString *)name inHome:(NSString *)home error:(NSString **)error;

@end

@interface CocoLaunchContext : NSObject

@property(nonatomic, readonly) CocoAccountKind kind;
@property(nonatomic, readonly, copy) NSString *username;
@property(nonatomic, readonly, copy) NSString *uuid;
// "legacy" for Local (the game uses its offline user API, no Yggdrasil calls),
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

// Runs LOCAL-01..06 against a fresh, empty home directory (not the player's
// data) and returns {"LOCAL-01": {"pass": @YES, "detail": ...}, ...}.
// Also written to <realHome>/coco-selftest.json when realHome is given.
+ (NSDictionary *)runWritingResultsTo:(NSString *)realHome;

@end
