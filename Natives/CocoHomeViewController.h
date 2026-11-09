#pragma once

#import <UIKit/UIKit.h>

// CocoLauncher: home screen in the CocoLauncher Android style (event art,
// left rail, server status, in-game name + PLAY). The Amethyst screens stay
// available from Settings > Advanced.
@interface CocoHomeViewController : UIViewController

// Minecraft player names: 3-16 characters, A-Z, a-z, 0-9 and _
+ (BOOL)isValidPlayerName:(NSString *)name;

// Opens the Coco game folder in the Files app (falls back to showing the path)
+ (void)openGameFolderFrom:(UIViewController *)viewController;
// CocoLauncher: sidemods/ in the game folder, the player's own mods (loaded with -Dfabric.addMods, never removed)
+ (NSString *)sideModsFolderPath;
+ (void)openSideModsFolderFrom:(UIViewController *)viewController;

@end

// Root view controller for the main window: the Coco home screen, or the
// Amethyst split view when "Coco interface" is turned off in the settings.
UIViewController *CocoCreateRootViewController(void);

// Replaces the main window's root view controller (after switching interfaces)
void CocoReloadRootViewController(void);
