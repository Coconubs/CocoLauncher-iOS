#import <CommonCrypto/CommonDigest.h>
#import "BaseAuthenticator.h"

@implementation LocalAuthenticator

// CocoLauncher: same UUID the vanilla game uses for offline players,
// UUID.nameUUIDFromBytes("OfflinePlayer:" + name) (MD5, version 3), so every
// local account gets its own player data instead of sharing the zero UUID.
// No Microsoft token or session is created for local accounts.
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

- (void)loginWithCallback:(Callback)callback {
    self.authData[@"oldusername"] = self.authData[@"username"] = self.authData[@"input"];
    self.authData[@"profileId"] = [LocalAuthenticator offlineUUIDForName:self.authData[@"username"]];
    callback(nil, [super saveChanges]);
}

- (void)refreshTokenWithCallback:(Callback)callback {
    // Nothing to do
    callback(nil, YES);
}

@end
