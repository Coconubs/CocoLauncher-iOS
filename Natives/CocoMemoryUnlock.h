// CocoLauncher: turn on Increased Memory Limit for this app's own App ID, inside the app.
// Same idea as GetMoreRam (github.com/hugeBlack/GetMoreRam); the Apple developer services code
// is the Rust library Natives/cocoram, built on isideload (github.com/nab138/isideload, MIT).
#pragma once
#import <UIKit/UIKit.h>

// Asks for the Apple ID that installed CocoLauncher (SideStore), handles 2FA, enables the
// capability, then tells the player to refresh/reinstall CocoLauncher in SideStore.
void CocoPresentMemoryUnlock(UIViewController *presenter);
