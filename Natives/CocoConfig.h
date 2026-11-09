#pragma once

// CocoLauncher: settings for the Coco Cobblemon server.
// CocoLauncher is a fork of Angel Aura Amethyst (GPLv3).

// Profile created on first start (Minecraft 1.21.1 + Fabric Loader 0.18.4).
#define COCO_PROFILE_NAME       @"Coco Cobblemon"
#define COCO_VERSION_ID         @"fabric-loader-0.18.4-1.21.1"
#define COCO_GAME_DIR_NAME      @"CocoLite"
#define COCO_PROFILE_GAME_DIR   @"./CocoLite"
#define COCO_PROFILE_ICON_URL   @"https://coconubs.github.io/CocoLauncher-iOS/icon-256.png"

// Coco Lite pack (the same files as the Android client). Every file is
// listed with its path, size and SHA-1; only files hosted on the
// Coconubs/cocolauncher-pack releases are accepted.
// 2026-11-08: Coco Lite iOS (tools/ios-lite.json in CocoLauncher), lighter than the Android pack
#define COCO_PACK_MANIFEST_URL  @"https://github.com/Coconubs/cocolauncher-pack/releases/download/ios-pack/manifest.json"
#define COCO_PACK_URL_PREFIX    @"https://github.com/Coconubs/cocolauncher-pack/releases/download/"
// Copy of the same releases on Cloudflare R2 (<tag>/<file>, tools/r2-sync.js), used when GitHub fails
#define COCO_PACK_R2_PREFIX     @"https://pub-707713d3c5be45869a45b80dd6fb862a.r2.dev/"
#define COCO_PACK_MARKER        @".coco-pack.json"

// Help page shown in the "News" tab.
#define COCO_HELP_URL           @"https://coconubs.github.io/CocoLauncher-iOS/huong-dan.html"
#define COCO_IOS_SOURCE_URL     @"https://coconubs.github.io/CocoLauncher-iOS/source.json"
#define COCO_IOS_DOWNLOAD_PAGE  @"https://coconubs.github.io/CocoLauncher-iOS/"
// Latest IPA, file named after the bundle ID (SideStore install?url= needs that)
#define COCO_IOS_IPA_URL        @"https://tai.coconubs.workers.dev/ios/dev.coconubs.cocolauncher.ios.ipa"

// Coco home screen (same look as CocoLauncher Android).
#define COCO_MINECRAFT_VERSION  @"1.21.1"
#define COCO_SERVER_HOST        @"185.207.166.112"
#define COCO_SERVER_PORT        19017
#define COCO_DISCORD_URL        @"https://discord.gg/hyspace"
// Event text over the home art; the copy bundled in resources/cocoui is used
// when this one can't be downloaded.
#define COCO_EVENT_URL          @"https://coconubs.github.io/CocoLauncher-iOS/hero_event.json"
