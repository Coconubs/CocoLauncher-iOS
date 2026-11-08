#pragma once

#import <UIKit/UIKit.h>

// CocoLauncher: shared look of the Coco screens (colors, Be Vietnam Pro fonts,
// option buttons, sliders, ping bars), copied from CocoLauncher Android.

typedef NS_ENUM(NSInteger, CocoFontWeight) {
    CocoFontRegular,
    CocoFontSemiBold,
    CocoFontExtraBold
};

// 0xAARRGGBB
UIColor *CocoColor(uint32_t argb);

#define COCO_VOID       CocoColor(0xFF07080F)
#define COCO_PANEL      CocoColor(0xFF121426)
#define COCO_INK        CocoColor(0xFFF3F4FA)
#define COCO_MUTED      CocoColor(0xFF9AA0BD)
#define COCO_SUB        CocoColor(0xFFB6BBD4)
#define COCO_DIM        CocoColor(0xFF8A90AD)
#define COCO_GOLD       CocoColor(0xFFF2C14E)
#define COCO_ORANGE     CocoColor(0xFFFFB347)
#define COCO_ORANGE_END CocoColor(0xFFFF5E3A)
#define COCO_GREEN      CocoColor(0xFF3DDC84)
#define COCO_RED        CocoColor(0xFFFF6B75)
#define COCO_PLAY_TEXT  CocoColor(0xFF1A0D05)
#define COCO_HAIRLINE   CocoColor(0x1FFFFFFF)

void CocoRegisterFonts(void);
UIFont *CocoFont(CocoFontWeight weight, CGFloat size);

// White template icon from resources/cocoui/icons (24 pt, @3x)
UIImage *CocoIcon(NSString *name);
// Picture from resources/cocoui (name without extension; @3x/@2x PNG or .jpg)
UIImage *CocoPicture(NSString *name);

UILabel *CocoLabel(NSString *text, CocoFontWeight weight, CGFloat size, UIColor *color);

// Text with <b>bold</b> parts (event description)
NSAttributedString *CocoRichText(NSString *text, CGFloat size, UIColor *color, UIColor *boldColor);

// Rounded rectangle with a 1 px border (cards, fields, chips)
void CocoStyleBox(UIView *view, UIColor *fill, UIColor *border, CGFloat radius);

// A view that draws a linear gradient (horizontal or vertical)
@interface CocoGradientView : UIView
@property(nonatomic) NSArray<UIColor *> *colors;
@property(nonatomic) NSArray<NSNumber *> *locations;
@property(nonatomic) BOOL vertical;
@end

// Big orange "CHƠI" button
@interface CocoPlayButton : UIButton
@end

// Option chip (selected = orange border + tint), like the Android RadioButtons
@interface CocoOptionButton : UIButton
@end

// Full-width row button with a light border
@interface CocoRowButton : UIButton
@end

// Slider with an orange gradient track and a white round thumb
@interface CocoSlider : UISlider
@end

// Rounded progress bar with an orange gradient fill
@interface CocoProgressBar : UIView
@property(nonatomic) CGFloat progress;
@end

// 4 bars like the Wi-Fi icon; color and number of bars follow the latency
@interface CocoPingBarsView : UIView
// Returns the color used, so the "ms" text can match it
- (UIColor *)setPing:(int)latencyMs;
@end

// Card dialog in the Coco style: title, message and buttons stacked below.
// Each button closes the dialog, then runs its action (nil = just close).
@interface CocoSheetViewController : UIViewController
+ (instancetype)sheetWithTitle:(NSString *)title message:(NSString *)message;
- (void)addPrimary:(NSString *)title action:(void (^)(void))action;
- (void)addSecondary:(NSString *)title action:(void (^)(void))action;
@end

// Minecraft server list ping. Blocking; call it off the main thread.
BOOL CocoServerPing(NSString *host, int port, int timeoutMs, int *online, int *max, int *latencyMs);
