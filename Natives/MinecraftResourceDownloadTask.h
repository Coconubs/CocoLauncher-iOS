#import <UIKit/UIKit.h>

@class ModpackAPI;

@interface MinecraftResourceDownloadTask : NSObject
@property NSProgress *progress, *textProgress;
@property NSMutableArray *fileList, *progressList;
@property NSMutableDictionary* metadata;
@property(nonatomic, copy) void(^handleError)(void);
// CocoLauncher: official Minecraft files are missing and may not be downloaded
// on this device yet; the message names the blocked step. When nil, a dialog
// is shown and handleError is called.
@property(nonatomic, copy) void(^handleBlocked)(NSString *message);
// CocoLauncher: no error dialog (the caller shows its own, with Retry)
@property BOOL quietErrors;
@property(copy) NSString *lastErrorMessage;
@property BOOL lastErrorBlocked;
// CocoLauncher: one line per resource group (state, counts, source, reason)
@property(copy) NSString *lastErrorReport;

- (NSURLSessionDownloadTask *)createDownloadTask:(NSString *)url size:(NSUInteger)size sha:(NSString *)sha altName:(NSString *)altName toPath:(NSString *)path;
- (void)finishDownloadWithErrorString:(NSString *)error;

- (void)downloadVersion:(NSDictionary *)version;
- (void)downloadModpackFromAPI:(ModpackAPI *)api detail:(NSDictionary *)modDetail atIndex:(NSUInteger)selectedVersion;

@end
