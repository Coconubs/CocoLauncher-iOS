#import <Security/Security.h>
#import "BaseAuthenticator.h"
#import "CocoAccounts.h"
#import "../LauncherPreferences.h"
#import "../ios_uikit_bridge.h"
#import "../utils.h"

@implementation BaseAuthenticator

static BaseAuthenticator *current = nil;

+ (id)current {
    if (current == nil) {
        // CocoLauncher: the selection is a storage id (local-<uuid> / msa-<xuid>);
        // older builds saved the username, which is resolved once here.
        NSString *selected = getPrefObject(@"internal.selected_account");
        NSString *resolved = [CocoAccountProvider resolveSelectedId:selected inHome:nil];
        if (resolved != nil && ![resolved isEqualToString:selected]) {
            setPrefObject(@"internal.selected_account", resolved);
        }
        if (resolved != nil) {
            [self loadSavedName:resolved];
        }
    }
    return current;
}

+ (void)setCurrent:(BaseAuthenticator *)auth {
    current = auth;
}

// name: the account's storage id (its file name in accounts/)
+ (id)loadSavedName:(NSString *)name {
    if (![CocoAccountProvider isSafeStorageId:name]) {
        return nil;
    }
    NSMutableDictionary *authData = parseJSONFromFile([NSString stringWithFormat:@"%s/accounts/%@.json", getenv("AME_HOME"), name]);
    if (authData[@"NSErrorObject"] != nil) {
        NSError *error = ((NSError *)authData[@"NSErrorObject"]);
        if (error.code != NSFileReadNoSuchFileError) {
            showDialog(localize(@"Error", nil), error.localizedDescription);
        }
        return nil;
    }
    authData[CocoAccountStorageIdKey] = name;

    // CocoLauncher: the provider decides (explicit "type": "local", or the
    // upstream rule: no expiry time and no xuid)
    CocoAccountKind kind = [CocoAccountProvider kindOfAccountData:authData];
    if (kind == CocoAccountKindLocal || kind == CocoAccountKindNone) {
        return [[LocalAuthenticator alloc] initWithData:authData];
    } else {
        return [[MicrosoftAuthenticator alloc] initWithData:authData];
    }
}

- (id)initWithData:(NSMutableDictionary *)data {
    current = self = [self init];
    self.authData = data;
    return self;
}

- (id)initWithInput:(NSString *)string {
    NSMutableDictionary *data = [[NSMutableDictionary alloc] init];
    data[@"input"] = string;
    return [self initWithData:data];
}

- (void)loginWithCallback:(Callback)callback {
}

- (void)refreshTokenWithCallback:(Callback)callback {
}

// CocoLauncher: accounts/<storageId>.json, one file per provider + account ID,
// so a Local and a Microsoft account with the same nickname never share a file.
// An older file of the SAME account (old storage id or old username) is moved;
// a file that belongs to another account is never deleted or overwritten.
- (BOOL)saveChanges {
    NSMutableArray *previous = [NSMutableArray new];
    for (NSString *key in @[CocoAccountStorageIdKey, @"oldusername", @"username"]) {
        if ([self.authData[key] isKindOfClass:NSString.class]) {
            [previous addObject:self.authData[key]];
        }
    }
    NSString *error = nil;
    NSString *storageId = [CocoAccountProvider saveAccountData:self.authData inHome:nil previousIds:previous error:&error];
    [self.authData removeObjectForKey:@"input"];
    [self.authData removeObjectForKey:@"oldusername"];
    if (storageId == nil) {
        showDialog(@"Error while saving file", error ?: @"unknown error");
        return NO;
    }
    return YES;
}

@end
