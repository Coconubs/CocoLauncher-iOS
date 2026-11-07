#pragma once

#import <UIKit/UIKit.h>

// CocoLauncher: settings card in the CocoLauncher Android style (game memory,
// resolution, performance preset, renderer, touch layout, folder, logs).
@interface CocoSettingsViewController : UIViewController
// Called after the card is closed
@property(nonatomic, copy) void (^onClose)(void);
@end
