// cocoram: turns on Increased Memory Limit for CocoLauncher's own App ID.
// Rust static library in Natives/cocoram, built on isideload (github.com/nab138/isideload, MIT);
// idea and flow from GetMoreRam (github.com/hugeBlack/GetMoreRam).
#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// kind: 1 = 2FA code needed (message = JSON), 2 = progress step, 3 = finished OK, 4 = error.
// Called on a background thread.
typedef void (*CocoRamEventCallback)(void *ctx, int kind, const char *message);

void cocoram_start(const char *appleId, const char *password, const char *bundleId,
                   const char *storageDir, void *ctx, CocoRamEventCallback cb);
// code, "d" (send to devices), "r" (resend), "p<id>" (SMS to that number) or "cancel"
void cocoram_submit_two_factor(const char *reply);

#ifdef __cplusplus
}
#endif
