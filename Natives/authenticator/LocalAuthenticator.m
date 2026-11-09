#import <CommonCrypto/CommonDigest.h>
#import "BaseAuthenticator.h"
#import "CocoAccounts.h"

@implementation LocalAuthenticator

// CocoLauncher: Local accounts come from CocoLocalAccountProvider: nickname
// + UUID.nameUUIDFromBytes("OfflinePlayer:" + name), saved with "type": "local".
// No Microsoft token, Xbox session or keychain entry is created or read.
+ (NSString *)offlineUUIDForName:(NSString *)name {
    return [CocoLocalAccountProvider offlineUUIDForName:name];
}

- (void)loginWithCallback:(Callback)callback {
    NSString *name = self.authData[@"input"];
    [self.authData addEntriesFromDictionary:[CocoLocalAccountProvider accountDataForName:name]];
    self.authData[@"oldusername"] = name;
    callback(nil, [super saveChanges]);
}

- (void)refreshTokenWithCallback:(Callback)callback {
    // Nothing to do
    callback(nil, YES);
}

@end
