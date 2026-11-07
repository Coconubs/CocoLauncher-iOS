#import <CoreText/CoreText.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#import "CocoUI.h"

UIColor *CocoColor(uint32_t argb) {
    return [UIColor colorWithRed:((argb >> 16) & 0xFF) / 255.0
                           green:((argb >> 8) & 0xFF) / 255.0
                            blue:(argb & 0xFF) / 255.0
                           alpha:((argb >> 24) & 0xFF) / 255.0];
}

#pragma mark - Fonts

static NSArray<NSString *> *cocoFontNames;

void CocoRegisterFonts(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSArray<NSString *> *files = @[@"BeVietnamPro-Regular", @"BeVietnamPro-SemiBold", @"BeVietnamPro-ExtraBold"];
        NSMutableArray<NSString *> *names = [NSMutableArray new];
        for (NSString *file in files) {
            NSString *name = @"";
            NSString *path = [NSBundle.mainBundle pathForResource:file ofType:@"ttf" inDirectory:@"cocoui/fonts"];
            if (path) {
                NSURL *url = [NSURL fileURLWithPath:path];
                CFErrorRef error = NULL;
                if (!CTFontManagerRegisterFontsForURL((__bridge CFURLRef)url, kCTFontManagerScopeProcess, &error) && error) {
                    CFRelease(error); // already registered
                }
                CFArrayRef descriptors = CTFontManagerCreateFontDescriptorsFromURL((__bridge CFURLRef)url);
                if (descriptors) {
                    if (CFArrayGetCount(descriptors) > 0) {
                        CTFontDescriptorRef descriptor = (CTFontDescriptorRef)CFArrayGetValueAtIndex(descriptors, 0);
                        CFTypeRef value = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute);
                        if (value) {
                            name = (__bridge_transfer NSString *)value;
                        }
                    }
                    CFRelease(descriptors);
                }
            }
            [names addObject:name];
        }
        cocoFontNames = names;
        NSLog(@"[CocoUI] Fonts: %@", [names componentsJoinedByString:@", "]);
    });
}

UIFont *CocoFont(CocoFontWeight weight, CGFloat size) {
    CocoRegisterFonts();
    NSString *name = weight < (NSInteger)cocoFontNames.count ? cocoFontNames[weight] : nil;
    UIFont *font = name.length > 0 ? [UIFont fontWithName:name size:size] : nil;
    if (font == nil) {
        UIFontWeight systemWeight = UIFontWeightRegular;
        if (weight == CocoFontSemiBold) {
            systemWeight = UIFontWeightSemibold;
        } else if (weight == CocoFontExtraBold) {
            systemWeight = UIFontWeightHeavy;
        }
        font = [UIFont systemFontOfSize:size weight:systemWeight];
    }
    return font;
}

#pragma mark - Images

static UIImage *CocoLoadPNG(NSString *directory, NSString *name) {
    for (NSNumber *scale in @[@3, @2]) {
        NSString *file = [NSString stringWithFormat:@"%@@%dx", name, scale.intValue];
        NSString *path = [NSBundle.mainBundle pathForResource:file ofType:@"png" inDirectory:directory];
        NSData *data = path ? [NSData dataWithContentsOfFile:path] : nil;
        if (data) {
            return [UIImage imageWithData:data scale:scale.doubleValue];
        }
    }
    return nil;
}

UIImage *CocoIcon(NSString *name) {
    return [CocoLoadPNG(@"cocoui/icons", name) imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

UIImage *CocoPicture(NSString *name) {
    UIImage *image = CocoLoadPNG(@"cocoui", name);
    if (image == nil) {
        NSString *path = [NSBundle.mainBundle pathForResource:name ofType:@"jpg" inDirectory:@"cocoui"];
        if (path) {
            image = [UIImage imageWithContentsOfFile:path];
        }
    }
    return image;
}

#pragma mark - Text

UILabel *CocoLabel(NSString *text, CocoFontWeight weight, CGFloat size, UIColor *color) {
    UILabel *label = [UILabel new];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.text = text;
    label.font = CocoFont(weight, size);
    label.textColor = color;
    return label;
}

NSAttributedString *CocoRichText(NSString *text, CGFloat size, UIColor *color, UIColor *boldColor) {
    NSMutableAttributedString *result = [NSMutableAttributedString new];
    NSDictionary *normal = @{NSFontAttributeName: CocoFont(CocoFontRegular, size), NSForegroundColorAttributeName: color};
    NSDictionary *bold = @{NSFontAttributeName: CocoFont(CocoFontExtraBold, size), NSForegroundColorAttributeName: boldColor};
    NSScanner *scanner = [NSScanner scannerWithString:text ?: @""];
    scanner.charactersToBeSkipped = nil;
    BOOL inBold = NO;
    while (!scanner.isAtEnd) {
        NSString *tag = inBold ? @"</b>" : @"<b>";
        NSString *chunk = nil;
        [scanner scanUpToString:tag intoString:&chunk];
        if (chunk.length > 0) {
            [result appendAttributedString:[[NSAttributedString alloc] initWithString:chunk attributes:inBold ? bold : normal]];
        }
        if ([scanner scanString:tag intoString:nil]) {
            inBold = !inBold;
        }
    }
    return result;
}

void CocoStyleBox(UIView *view, UIColor *fill, UIColor *border, CGFloat radius) {
    view.backgroundColor = fill;
    view.layer.cornerRadius = radius;
    view.layer.borderWidth = 1;
    view.layer.borderColor = border.CGColor;
    if (@available(iOS 13.0, *)) {
        view.layer.cornerCurve = kCACornerCurveContinuous;
    }
}

#pragma mark - Views

@implementation CocoGradientView

+ (Class)layerClass {
    return CAGradientLayer.class;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.userInteractionEnabled = NO;
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.vertical = NO;
    }
    return self;
}

- (void)setColors:(NSArray<UIColor *> *)colors {
    _colors = colors;
    NSMutableArray *cgColors = [NSMutableArray new];
    for (UIColor *color in colors) {
        [cgColors addObject:(id)color.CGColor];
    }
    ((CAGradientLayer *)self.layer).colors = cgColors;
}

- (void)setLocations:(NSArray<NSNumber *> *)locations {
    _locations = locations;
    ((CAGradientLayer *)self.layer).locations = locations;
}

- (void)setVertical:(BOOL)vertical {
    _vertical = vertical;
    CAGradientLayer *layer = (CAGradientLayer *)self.layer;
    layer.startPoint = vertical ? CGPointMake(0.5, 0) : CGPointMake(0, 0.5);
    layer.endPoint = vertical ? CGPointMake(0.5, 1) : CGPointMake(1, 0.5);
}

@end

@interface CocoPlayButton ()
@property(nonatomic) CAGradientLayer *gradient;
@end

@implementation CocoPlayButton

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.gradient = [CAGradientLayer layer];
        self.gradient.startPoint = CGPointMake(0, 0.5);
        self.gradient.endPoint = CGPointMake(1, 0.5);
        self.gradient.cornerRadius = 14;
        [self.layer insertSublayer:self.gradient atIndex:0];
        self.layer.cornerRadius = 14;
        self.titleLabel.font = CocoFont(CocoFontExtraBold, 19);
        self.titleLabel.adjustsFontSizeToFitWidth = YES;
        self.titleLabel.minimumScaleFactor = 0.7;
        [self setTitleColor:COCO_PLAY_TEXT forState:UIControlStateNormal];
        [self setTitleColor:COCO_MUTED forState:UIControlStateDisabled];
        self.contentEdgeInsets = UIEdgeInsetsMake(0, 28, 0, 28);
        [self updateColors];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    self.gradient.frame = self.bounds;
    [CATransaction commit];
}

- (void)setEnabled:(BOOL)enabled {
    [super setEnabled:enabled];
    [self updateColors];
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    [self updateColors];
}

- (void)updateColors {
    UIColor *start, *end;
    if (!self.enabled) {
        start = end = CocoColor(0xFF3A3D55);
    } else if (self.highlighted) {
        start = CocoColor(0xFFE89A34);
        end = CocoColor(0xFFE04E2E);
    } else {
        start = COCO_ORANGE;
        end = COCO_ORANGE_END;
    }
    self.gradient.colors = @[(id)start.CGColor, (id)end.CGColor];
}

@end

@implementation CocoOptionButton

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.titleLabel.font = CocoFont(CocoFontSemiBold, 15);
        self.titleLabel.adjustsFontSizeToFitWidth = YES;
        self.titleLabel.minimumScaleFactor = 0.7;
        self.contentEdgeInsets = UIEdgeInsetsMake(0, 8, 0, 8);
        [self setTitleColor:COCO_INK forState:UIControlStateNormal];
        [self setTitleColor:COCO_ORANGE forState:UIControlStateSelected];
        [self setTitleColor:COCO_ORANGE forState:UIControlStateSelected | UIControlStateHighlighted];
        self.layer.cornerRadius = 12;
        self.layer.borderWidth = 1;
        if (@available(iOS 13.0, *)) {
            self.layer.cornerCurve = kCACornerCurveContinuous;
        }
        [self updateStyle];
    }
    return self;
}

- (void)setSelected:(BOOL)selected {
    [super setSelected:selected];
    [self updateStyle];
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.alpha = highlighted ? 0.7 : 1;
}

- (void)updateStyle {
    self.backgroundColor = self.selected ? CocoColor(0x24FFB347) : UIColor.clearColor;
    self.layer.borderColor = (self.selected ? COCO_ORANGE : COCO_HAIRLINE).CGColor;
}

@end

@implementation CocoRowButton

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.titleLabel.font = CocoFont(CocoFontSemiBold, 16);
        self.titleLabel.adjustsFontSizeToFitWidth = YES;
        self.titleLabel.minimumScaleFactor = 0.7;
        [self setTitleColor:COCO_INK forState:UIControlStateNormal];
        self.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        self.contentEdgeInsets = UIEdgeInsetsMake(0, 20, 0, 16);
        CocoStyleBox(self, CocoColor(0x0AFFFFFF), COCO_HAIRLINE, 12);
    }
    return self;
}

- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.backgroundColor = highlighted ? CocoColor(0x1AFFFFFF) : CocoColor(0x0AFFFFFF);
}

@end

@implementation CocoSlider

+ (UIImage *)thumbImage {
    static UIImage *image;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(30, 30)];
        image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
            CGContextSetShadowWithColor(context.CGContext, CGSizeMake(0, 1), 3, [UIColor colorWithWhite:0 alpha:0.45].CGColor);
            [UIColor.whiteColor setFill];
            [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(4, 4, 22, 22)] fill];
        }];
    });
    return image;
}

+ (UIImage *)trackImageFrom:(UIColor *)start to:(UIColor *)end {
    CGSize size = CGSizeMake(240, 8);
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, size.width, size.height) cornerRadius:size.height / 2] addClip];
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        NSArray *colors = @[(id)start.CGColor, (id)end.CGColor];
        CGGradientRef gradient = CGGradientCreateWithColors(space, (__bridge CFArrayRef)colors, NULL);
        CGContextDrawLinearGradient(context.CGContext, gradient, CGPointZero, CGPointMake(size.width, 0), 0);
        CGGradientRelease(gradient);
        CGColorSpaceRelease(space);
    }];
    // Stretch (not tile) the middle so the gradient keeps its shape
    return [image resizableImageWithCapInsets:UIEdgeInsetsMake(0, 5, 0, 5) resizingMode:UIImageResizingModeStretch];
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        [self setThumbImage:CocoSlider.thumbImage forState:UIControlStateNormal];
        [self setThumbImage:CocoSlider.thumbImage forState:UIControlStateHighlighted];
        [self setMinimumTrackImage:[CocoSlider trackImageFrom:COCO_ORANGE to:COCO_ORANGE_END] forState:UIControlStateNormal];
        UIColor *rest = CocoColor(0x1AFFFFFF);
        [self setMaximumTrackImage:[CocoSlider trackImageFrom:rest to:rest] forState:UIControlStateNormal];
    }
    return self;
}

- (CGRect)trackRectForBounds:(CGRect)bounds {
    CGRect rect = [super trackRectForBounds:bounds];
    rect.size.height = 8;
    rect.origin.y = (bounds.size.height - 8) / 2;
    return rect;
}

@end

@interface CocoProgressBar ()
@property(nonatomic) CocoGradientView *fill;
@end

@implementation CocoProgressBar

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.backgroundColor = CocoColor(0x14FFFFFF);
        self.clipsToBounds = YES;
        self.fill = [[CocoGradientView alloc] initWithFrame:CGRectZero];
        self.fill.translatesAutoresizingMaskIntoConstraints = YES;
        self.fill.colors = @[COCO_ORANGE, COCO_ORANGE_END];
        [self addSubview:self.fill];
    }
    return self;
}

- (void)setProgress:(CGFloat)progress {
    _progress = MAX(0, MIN(1, progress));
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat height = self.bounds.size.height;
    self.layer.cornerRadius = height / 2;
    self.fill.frame = CGRectMake(0, 0, self.bounds.size.width * self.progress, height);
    self.fill.layer.cornerRadius = height / 2;
}

@end

@interface CocoPingBarsView ()
@property(nonatomic) int bars;
@property(nonatomic) UIColor *barColor;
@end

@implementation CocoPingBarsView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.opaque = NO;
        self.backgroundColor = UIColor.clearColor;
        self.barColor = COCO_GREEN;
    }
    return self;
}

- (UIColor *)setPing:(int)latencyMs {
    // Same thresholds as the PC and Android launchers
    if (latencyMs <= 80) {
        self.bars = 4;
        self.barColor = COCO_GREEN;
    } else if (latencyMs <= 150) {
        self.bars = 3;
        self.barColor = COCO_GOLD;
    } else if (latencyMs <= 300) {
        self.bars = 2;
        self.barColor = CocoColor(0xFFFF9A3D);
    } else {
        self.bars = 1;
        self.barColor = CocoColor(0xFFFF5D5D);
    }
    [self setNeedsDisplay];
    return self.barColor;
}

- (void)drawRect:(CGRect)rect {
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    CGFloat gap = w * 0.08;
    CGFloat barWidth = (w - gap * 3) / 4.0;
    for (int k = 0; k < 4; k++) {
        CGFloat barHeight = h * (0.3 + 0.7 * (k + 1) / 4.0);
        CGRect bar = CGRectMake(k * (barWidth + gap), h - barHeight, barWidth, barHeight);
        [(k < self.bars ? self.barColor : CocoColor(0x2EFFFFFF)) setFill];
        [[UIBezierPath bezierPathWithRoundedRect:bar cornerRadius:barWidth * 0.3] fill];
    }
}

@end

#pragma mark - Server list ping

static void CocoWriteVarInt(NSMutableData *data, int value) {
    unsigned int remaining = (unsigned int)value;
    do {
        uint8_t part = remaining & 0x7F;
        remaining >>= 7;
        if (remaining != 0) {
            part |= 0x80;
        }
        [data appendBytes:&part length:1];
    } while (remaining != 0);
}

static BOOL CocoReadFully(int fd, void *buffer, size_t length) {
    size_t done = 0;
    while (done < length) {
        ssize_t count = recv(fd, (char *)buffer + done, length - done, 0);
        if (count <= 0) {
            return NO;
        }
        done += (size_t)count;
    }
    return YES;
}

static BOOL CocoReadVarInt(int fd, int *value) {
    int result = 0;
    for (int shift = 0; shift < 35; shift += 7) {
        uint8_t byte = 0;
        if (!CocoReadFully(fd, &byte, 1)) {
            return NO;
        }
        result |= (byte & 0x7F) << shift;
        if ((byte & 0x80) == 0) {
            *value = result;
            return YES;
        }
    }
    return NO;
}

static BOOL CocoSendPacket(int fd, NSData *body) {
    NSMutableData *packet = [NSMutableData new];
    CocoWriteVarInt(packet, (int)body.length);
    [packet appendData:body];
    return send(fd, packet.bytes, packet.length, 0) == (ssize_t)packet.length;
}

BOOL CocoServerPing(NSString *host, int port, int timeoutMs, int *online, int *max, int *latencyMs) {
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    struct addrinfo *address = NULL;
    NSString *service = [NSString stringWithFormat:@"%d", port];
    if (getaddrinfo(host.UTF8String, service.UTF8String, &hints, &address) != 0 || address == NULL) {
        return NO;
    }
    int fd = socket(address->ai_family, address->ai_socktype, address->ai_protocol);
    if (fd < 0) {
        freeaddrinfo(address);
        return NO;
    }
    int noSigPipe = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe));

    // Connect with a timeout
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    int result = connect(fd, address->ai_addr, address->ai_addrlen);
    freeaddrinfo(address);
    if (result != 0 && errno != EINPROGRESS) {
        close(fd);
        return NO;
    }
    if (result != 0) {
        fd_set writable;
        FD_ZERO(&writable);
        FD_SET(fd, &writable);
        struct timeval wait = { timeoutMs / 1000, (timeoutMs % 1000) * 1000 };
        if (select(fd + 1, NULL, &writable, NULL, &wait) <= 0) {
            close(fd);
            return NO;
        }
        int socketError = 0;
        socklen_t length = sizeof(socketError);
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length);
        if (socketError != 0) {
            close(fd);
            return NO;
        }
    }
    fcntl(fd, F_SETFL, flags);
    struct timeval timeout = { timeoutMs / 1000, (timeoutMs % 1000) * 1000 };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));

    // Handshake (next state: status), then the status request
    NSMutableData *handshake = [NSMutableData new];
    CocoWriteVarInt(handshake, 0x00);
    CocoWriteVarInt(handshake, 767); // 1.21.1; any number works for status
    NSData *hostData = [host dataUsingEncoding:NSUTF8StringEncoding];
    CocoWriteVarInt(handshake, (int)hostData.length);
    [handshake appendData:hostData];
    uint8_t portBytes[2];
    portBytes[0] = (uint8_t)((port >> 8) & 0xFF);
    portBytes[1] = (uint8_t)(port & 0xFF);
    [handshake appendBytes:portBytes length:2];
    CocoWriteVarInt(handshake, 1);
    uint8_t statusRequest = 0x00;

    BOOL ok = CocoSendPacket(fd, handshake);
    struct timeval start, end;
    gettimeofday(&start, NULL);
    ok = ok && CocoSendPacket(fd, [NSData dataWithBytes:&statusRequest length:1]);
    int packetLength = 0, packetId = -1, jsonLength = 0;
    ok = ok && CocoReadVarInt(fd, &packetLength) && CocoReadVarInt(fd, &packetId) && packetId == 0x00
        && CocoReadVarInt(fd, &jsonLength) && jsonLength > 0 && jsonLength < (1 << 20);
    NSMutableData *json = ok ? [NSMutableData dataWithLength:(NSUInteger)jsonLength] : nil;
    ok = ok && CocoReadFully(fd, json.mutableBytes, (size_t)jsonLength);
    gettimeofday(&end, NULL);
    close(fd);
    if (!ok) {
        return NO;
    }

    NSDictionary *status = [NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
    if (![status isKindOfClass:NSDictionary.class]) {
        return NO;
    }
    NSDictionary *players = status[@"players"];
    if ([players isKindOfClass:NSDictionary.class]) {
        id onlineValue = players[@"online"], maxValue = players[@"max"];
        if (online && [onlineValue isKindOfClass:NSNumber.class]) *online = [onlineValue intValue];
        if (max && [maxValue isKindOfClass:NSNumber.class]) *max = [maxValue intValue];
    }
    if (latencyMs) {
        *latencyMs = (int)((end.tv_sec - start.tv_sec) * 1000 + (end.tv_usec - start.tv_usec) / 1000);
    }
    return YES;
}

#pragma mark - Sheet

@interface CocoSheetViewController ()
@property(nonatomic, copy) NSString *sheetTitle;
@property(nonatomic, copy) NSString *message;
@property(nonatomic) NSMutableArray<UIButton *> *buttons;
@property(nonatomic) NSMutableArray *actions;
@end

@implementation CocoSheetViewController

+ (instancetype)sheetWithTitle:(NSString *)title message:(NSString *)message {
    CocoSheetViewController *sheet = [self new];
    sheet.sheetTitle = title;
    sheet.message = message;
    sheet.buttons = [NSMutableArray new];
    sheet.actions = [NSMutableArray new];
    sheet.modalPresentationStyle = UIModalPresentationOverFullScreen;
    sheet.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
    return sheet;
}

- (void)addButton:(UIButton *)button action:(void (^)(void))action {
    button.tag = (NSInteger)self.buttons.count;
    [button addTarget:self action:@selector(buttonTapped:) forControlEvents:UIControlEventTouchUpInside];
    [self.buttons addObject:button];
    [self.actions addObject:action ? [action copy] : NSNull.null];
}

- (void)addPrimary:(NSString *)title action:(void (^)(void))action {
    CocoPlayButton *button = [[CocoPlayButton alloc] initWithFrame:CGRectZero];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = CocoFont(CocoFontExtraBold, 16);
    [self addButton:button action:action];
}

- (void)addSecondary:(NSString *)title action:(void (^)(void))action {
    CocoRowButton *button = [[CocoRowButton alloc] initWithFrame:CGRectZero];
    [button setTitle:title forState:UIControlStateNormal];
    button.titleLabel.font = CocoFont(CocoFontSemiBold, 15);
    button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentCenter;
    button.contentEdgeInsets = UIEdgeInsetsMake(0, 12, 0, 12);
    [self addButton:button action:action];
}

- (void)buttonTapped:(UIButton *)sender {
    id action = self.actions[(NSUInteger)sender.tag];
    [self dismissViewControllerAnimated:YES completion:^{
        if (action != NSNull.null) {
            ((void (^)(void))action)();
        }
    }];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];

    UIView *card = [UIView new];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    CocoStyleBox(card, COCO_PANEL, CocoColor(0x1AFFFFFF), 20);
    [self.view addSubview:card];

    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.alwaysBounceVertical = NO;
    [card addSubview:scroll];

    UIStackView *stack = [UIStackView new];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 10;
    [scroll addSubview:stack];

    UILabel *title = CocoLabel(self.sheetTitle, CocoFontExtraBold, 20, COCO_INK);
    title.numberOfLines = 0;
    UILabel *message = CocoLabel(self.message, CocoFontRegular, 14, COCO_SUB);
    message.numberOfLines = 0;
    [stack addArrangedSubview:title];
    [stack addArrangedSubview:message];
    [stack setCustomSpacing:18 afterView:message];
    for (UIButton *button in self.buttons) {
        [button.heightAnchor constraintEqualToConstant:50].active = YES;
        [stack addArrangedSubview:button];
    }

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    NSLayoutConstraint *preferredWidth = [card.widthAnchor constraintEqualToConstant:460];
    preferredWidth.priority = UILayoutPriorityDefaultHigh;
    NSLayoutConstraint *fitHeight = [scroll.heightAnchor constraintEqualToAnchor:stack.heightAnchor constant:44];
    fitHeight.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [card.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor],
        [card.widthAnchor constraintLessThanOrEqualToAnchor:safe.widthAnchor constant:-32],
        [card.heightAnchor constraintLessThanOrEqualToAnchor:safe.heightAnchor constant:-24],
        preferredWidth,
        [scroll.topAnchor constraintEqualToAnchor:card.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:card.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        fitHeight,
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:22],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-22],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.leadingAnchor constant:22],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.trailingAnchor constant:-22],
    ]];
}

@end
