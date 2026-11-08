#import "CocoMemoryUnlock.h"
#import "cocoram/cocoram.h"
#import "utils.h"

// One unlock at a time; kept alive (strong) while the Rust thread can still call back.
@interface CocoMemoryUnlocker : NSObject
@property(nonatomic, weak) UIViewController *presenter;
@property(nonatomic) UIAlertController *progressAlert;
- (void)handleEvent:(int)kind message:(NSString *)message;
@end

static CocoMemoryUnlocker *gUnlocker;

static void CocoRamEvent(void *ctx, int kind, const char *message) {
    NSString *text = message ? @(message) : @"";
    dispatch_async(dispatch_get_main_queue(), ^{
        [gUnlocker handleEvent:kind message:text];
    });
}

@implementation CocoMemoryUnlocker

- (UIViewController *)top {
    UIViewController *vc = self.presenter;
    while (vc.presentedViewController && !vc.presentedViewController.isBeingDismissed) {
        vc = vc.presentedViewController;
    }
    return vc;
}

- (void)present:(UIAlertController *)alert {
    UIViewController *presenter = self.presenter;
    if (!presenter) {
        return;
    }
    // Replace whatever alert of ours is on screen
    if (presenter.presentedViewController) {
        [presenter dismissViewControllerAnimated:NO completion:^{
            [presenter presentViewController:alert animated:YES completion:nil];
        }];
    } else {
        [presenter presentViewController:alert animated:YES completion:nil];
    }
}

- (void)askCredentials {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"coco.unlock.title", nil)
        message:localize(@"coco.unlock.message", nil) preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = localize(@"coco.unlock.appleid", nil);
        field.keyboardType = UIKeyboardTypeEmailAddress;
        field.autocapitalizationType = UITextAutocapitalizationTypeNone;
        field.autocorrectionType = UITextAutocorrectionTypeNo;
        field.textContentType = UITextContentTypeUsername;
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = localize(@"coco.unlock.password", nil);
        field.secureTextEntry = YES;
        field.textContentType = UITextContentTypePassword;
    }];
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"coco.unlock.cancel", nil) style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) {
        gUnlocker = nil;
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"coco.unlock.start", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *appleId = [weakAlert.textFields[0].text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSString *password = weakAlert.textFields[1].text ?: @"";
        if (appleId.length == 0 || password.length == 0) {
            [self askCredentials];
            return;
        }
        [self startWithAppleId:appleId password:password];
    }]];
    [self present:alert];
}

- (void)showProgress:(NSString *)step {
    NSString *key = [@"coco.unlock.step." stringByAppendingString:step];
    NSString *message = localize(key, nil);
    if ([message isEqualToString:key]) {
        message = step;
    }
    if (self.progressAlert && self.presenter.presentedViewController == self.progressAlert) {
        self.progressAlert.message = message;
        return;
    }
    self.progressAlert = [UIAlertController alertControllerWithTitle:localize(@"coco.unlock.title", nil)
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [self present:self.progressAlert];
}

- (void)startWithAppleId:(NSString *)appleId password:(NSString *)password {
    NSString *storage = [NSString stringWithFormat:@"%s/.cocoram", getenv("AME_HOME") ?: NSHomeDirectory().UTF8String];
    [NSFileManager.defaultManager createDirectoryAtPath:storage withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *bundleId = NSBundle.mainBundle.bundleIdentifier ?: @"";
    NSLog(@"[CocoRam] Enabling Increased Memory Limit for App ID %@", bundleId);
    [self showProgress:@"login"];
    cocoram_start(appleId.UTF8String, password.UTF8String, bundleId.UTF8String, storage.UTF8String,
        (__bridge void *)self, CocoRamEvent);
}

- (void)askTwoFactor:(NSString *)json {
    NSDictionary *info = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    if (![info isKindOfClass:NSDictionary.class]) {
        info = @{};
    }
    NSString *message;
    if ([info[@"sms"] boolValue] && [info[@"selected"] isKindOfClass:NSString.class]) {
        message = [NSString stringWithFormat:localize(@"coco.unlock.2fa.sms", nil), info[@"selected"]];
    } else {
        message = localize(@"coco.unlock.2fa.devices", nil);
    }
    if ([info[@"error"] isKindOfClass:NSString.class]) {
        message = [NSString stringWithFormat:@"%@\n\n%@", info[@"error"], message];
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"coco.unlock.2fa.title", nil)
        message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
        field.placeholder = @"123456";
        field.keyboardType = UIKeyboardTypeNumberPad;
        field.textContentType = UITextContentTypeOneTimeCode;
    }];
    __weak UIAlertController *weakAlert = alert;
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"coco.unlock.2fa.submit", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *code = [weakAlert.textFields[0].text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        cocoram_submit_two_factor(code.length ? code.UTF8String : "r");
        [self showProgress:@"login"];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"coco.unlock.2fa.devices_button", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        cocoram_submit_two_factor("d");
        [self showProgress:@"login"];
    }]];
    NSArray *numbers = [info[@"numbers"] isKindOfClass:NSArray.class] ? info[@"numbers"] : @[];
    for (NSDictionary *number in numbers) {
        if (![number isKindOfClass:NSDictionary.class]) {
            continue;
        }
        NSString *title = [NSString stringWithFormat:localize(@"coco.unlock.2fa.sms_button", nil), number[@"number"] ?: @"?"];
        NSString *reply = [NSString stringWithFormat:@"p%@", number[@"id"]];
        [alert addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            cocoram_submit_two_factor(reply.UTF8String);
            [self showProgress:@"login"];
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"coco.unlock.cancel", nil) style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) {
        cocoram_submit_two_factor("cancel");
    }]];
    [self present:alert];
}

- (void)finishWithTitle:(NSString *)title message:(NSString *)message success:(BOOL)success {
    self.progressAlert = nil;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    if (success) {
        [alert addAction:[UIAlertAction actionWithTitle:localize(@"coco.unlock.open_sidestore", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [UIApplication.sharedApplication openURL:[NSURL URLWithString:@"sidestore://"] options:@{} completionHandler:nil];
        }]];
    } else {
        [alert addAction:[UIAlertAction actionWithTitle:localize(@"coco.unlock.retry", nil) style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            [self askCredentials];
        }]];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) {
        if (gUnlocker == self) {
            gUnlocker = nil;
        }
    }]];
    [self present:alert];
}

- (void)handleEvent:(int)kind message:(NSString *)message {
    switch (kind) {
        case 1:
            [self askTwoFactor:message];
            break;
        case 2:
            [self showProgress:message];
            break;
        case 3:
            NSLog(@"[CocoRam] Increased Memory Limit enabled (%@)", message);
            [self finishWithTitle:localize(@"coco.unlock.done.title", nil) message:localize(@"coco.unlock.done.message", nil) success:YES];
            break;
        default: {
            NSLog(@"[CocoRam] Failed: %@", message);
            NSString *text;
            if ([message hasPrefix:@"no-appid|"]) {
                NSArray *parts = [message componentsSeparatedByString:@"|"];
                text = [NSString stringWithFormat:localize(@"coco.unlock.error.noappid", nil), parts.count > 1 ? parts[1] : @""];
            } else if ([message isEqualToString:@"no-team"]) {
                text = localize(@"coco.unlock.error.noteam", nil);
            } else if ([message hasPrefix:@"login:"]) {
                text = [NSString stringWithFormat:localize(@"coco.unlock.error.login", nil), message];
            } else {
                text = [NSString stringWithFormat:localize(@"coco.unlock.error.other", nil), message];
            }
            [self finishWithTitle:localize(@"coco.unlock.error.title", nil) message:text success:NO];
            break;
        }
    }
}

@end

void CocoPresentMemoryUnlock(UIViewController *presenter) {
    if (gUnlocker) {
        return; // already running
    }
    gUnlocker = [CocoMemoryUnlocker new];
    gUnlocker.presenter = presenter;
    [gUnlocker askCredentials];
}
