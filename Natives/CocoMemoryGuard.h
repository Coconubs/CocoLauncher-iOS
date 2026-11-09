#pragma once
#import <Foundation/Foundation.h>

// CocoLauncher: watches the app's memory footprint against the iOS process
// limit while the game runs (every 2 s). Near the limit it returns free malloc
// pages to the system (75%) and asks Java for a full GC (90%, at most once a
// minute), and writes the footprint to latestlog.txt so a player's log shows
// how close the game got before iOS closed it.
// Idea from Witch Launcher (GPL-3.0, github.com/Witch-Launcher/Witch_launcher).
void CocoMemoryGuardStart(void);
