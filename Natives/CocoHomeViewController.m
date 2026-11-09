#import <AuthenticationServices/AuthenticationServices.h>
#import <SafariServices/SafariServices.h>
#include <sys/time.h>
#include <unistd.h>

#import "authenticator/BaseAuthenticator.h"
#import "authenticator/CocoAccounts.h"
#import "CocoInstall.h"
#import "CocoConfig.h"
#import "CocoHomeViewController.h"
#import "CocoMemoryUnlock.h"
#import "CocoPerformance.h"
#import "CocoSettingsViewController.h"
#import "CocoUI.h"
#import "CustomControlsViewController.h"
#import "LauncherNavigationController.h"
#import "LauncherPreferences.h"
#import "LauncherSplitViewController.h"
#import "MinecraftResourceDownloadTask.h"
#import "MinecraftResourceUtils.h"
#import "PLProfiles.h"
#import "UIKit+hook.h"
#import "ios_uikit_bridge.h"
#import "utils.h"

static void *CocoProgressContext = &CocoProgressContext;

UIViewController *CocoCreateRootViewController(void) {
    if (getPrefBool(@"general.coco_home_ui")) {
        return [CocoHomeViewController new];
    }
    return [[LauncherSplitViewController alloc] initWithStyle:UISplitViewControllerStyleDoubleColumn];
}

void CocoReloadRootViewController(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *window = UIWindow.mainWindow;
        if (window == nil) {
            return;
        }
        void (^swap)(void) = ^{
            UIViewController *root = CocoCreateRootViewController();
            [UIView transitionWithView:window duration:0.25 options:UIViewAnimationOptionTransitionCrossDissolve animations:^{
                window.rootViewController = root;
            } completion:nil];
        };
        // Close the settings sheets first, they belong to the old interface
        UIViewController *current = window.rootViewController;
        if (current.presentedViewController) {
            [current dismissViewControllerAnimated:NO completion:swap];
        } else {
            swap();
        }
    });
}

@interface CocoHomeViewController () <UITextFieldDelegate, ASWebAuthenticationPresentationContextProviding>
@property(nonatomic) UIView *chipView;
@property(nonatomic) UIView *statusDot;
@property(nonatomic) UILabel *statusLabel;
@property(nonatomic) CocoPingBarsView *pingBars;
@property(nonatomic) UILabel *pingLabel;

@property(nonatomic) UIStackView *contentStack;
@property(nonatomic) NSLayoutConstraint *contentBottom;
@property(nonatomic) UIStackView *heroStack;
@property(nonatomic) UILabel *eyebrowLabel;
@property(nonatomic) UILabel *titleLabel;
@property(nonatomic) UILabel *subtitleLabel;
@property(nonatomic) UIStackView *readyRow;
@property(nonatomic) NSLayoutConstraint *readyFullWidth;
@property(nonatomic) NSLayoutConstraint *fieldWidth;
@property(nonatomic) NSLayoutConstraint *playHeight;
@property(nonatomic) UITextField *nameField;
@property(nonatomic) UILabel *nameNoteLabel;
@property(nonatomic) CocoPlayButton *playButton;
@property(nonatomic) UIView *busyCard;
@property(nonatomic) UILabel *busyTitle;
@property(nonatomic) UILabel *busyPercent;
@property(nonatomic) UILabel *busyDetail;
@property(nonatomic) CocoProgressBar *busyBar;
@property(nonatomic) UILabel *metaLabel;
@property(nonatomic) BOOL narrowLayout;
@property(nonatomic) BOOL layoutModeSet;

@property(nonatomic) BOOL busy;
@property(nonatomic) MinecraftResourceDownloadTask *task;
@property(nonatomic) NSProgress *observedProgress;
@property(nonatomic) NSString *playName;
@property(nonatomic) NSString *playId; // storage id of the account being played
@property(nonatomic) ASWebAuthenticationSession *authSession;
@property(nonatomic) NSTimer *pingTimer;
@property(nonatomic) BOOL didAppearOnce;
@property(nonatomic) long lastSecond;
@property(nonatomic) double lastTime;
@property(nonatomic) NSInteger lastCompleted;
@end

@implementation CocoHomeViewController

+ (BOOL)isValidPlayerName:(NSString *)name {
    return name != nil && [name rangeOfString:@"^[A-Za-z0-9_]{3,16}$" options:NSRegularExpressionSearch].location != NSNotFound;
}

+ (NSString *)gameFolderPath {
    return [NSString stringWithFormat:@"%s/instances/%@/%@", getenv("AME_HOME"),
        getPrefObject(@"general.game_directory"), COCO_GAME_DIR_NAME].stringByStandardizingPath;
}

+ (NSString *)sideModsFolderPath {
    return [[self gameFolderPath] stringByAppendingPathComponent:@"sidemods"];
}

+ (void)openSideModsFolderFrom:(UIViewController *)viewController {
    [self openFolder:[self sideModsFolderPath] from:viewController];
}

+ (void)openGameFolderFrom:(UIViewController *)viewController {
    [self openFolder:[self gameFolderPath] from:viewController];
}

+ (void)openFolder:(NSString *)path from:(UIViewController *)viewController {
    [NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *escaped = [path stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
    NSURL *url = [NSURL URLWithString:[@"shareddocuments://" stringByAppendingString:escaped]];
    __weak UIViewController *weakVC = viewController;
    [UIApplication.sharedApplication openURL:url options:@{} completionHandler:^(BOOL success) {
        if (success || weakVC == nil) {
            return;
        }
        CocoSheetViewController *sheet = [CocoSheetViewController sheetWithTitle:localize(@"coco.home.rail.folder", nil)
            message:[NSString stringWithFormat:localize(@"coco.home.folder_path", nil), path]];
        [sheet addSecondary:localize(@"OK", nil) action:nil];
        [weakVC presentViewController:sheet animated:YES completion:nil];
    }];
}

#pragma mark - View

- (void)viewDidLoad {
    [super viewDidLoad];
    CocoRegisterFonts();
    self.view.backgroundColor = COCO_VOID;

    // Same environment the Amethyst menu sets for a full (non-demo) account
    unsetenv("DEMO_LOCK");
    setenv("GAME_DIR", [NSString stringWithFormat:@"%s/Library/Application Support/minecraft", getenv("AME_HOME")].UTF8String, 1);

    [self buildBackground];
    UIView *rail = [self buildRail];
    [self buildChip];
    [self buildContentNextTo:rail];
    [self loadEvent];
    [self restoreName];
    [self refreshMeta];

    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(keyboardWillChange:) name:UIKeyboardWillChangeFrameNotification object:nil];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(keyboardWillChange:) name:UIKeyboardWillHideNotification object:nil];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self.view action:@selector(endEditing:)];
    tap.cancelsTouchesInView = NO;
    [self.view addGestureRecognizer:tap];
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self stopObservingProgress];
}

- (UIStatusBarStyle)preferredStatusBarStyle {
    return UIStatusBarStyleLightContent;
}

- (void)pinToView:(UIView *)subview {
    subview.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:subview];
    [NSLayoutConstraint activateConstraints:@[
        [subview.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [subview.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [subview.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [subview.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
    ]];
}

- (void)buildBackground {
    UIImageView *art = [[UIImageView alloc] initWithImage:CocoPicture(@"hero")];
    art.contentMode = UIViewContentModeScaleAspectFill;
    art.clipsToBounds = YES;
    [self pinToView:art];

    // Dark on the left and at the bottom so the text stays readable
    CocoGradientView *shade = [[CocoGradientView alloc] initWithFrame:CGRectZero];
    shade.colors = @[CocoColor(0xF007080F), CocoColor(0x9907080F), CocoColor(0x0007080F)];
    shade.locations = @[@0, @0.4, @1];
    [self pinToView:shade];

    CocoGradientView *shadeBottom = [[CocoGradientView alloc] initWithFrame:CGRectZero];
    shadeBottom.vertical = YES;
    shadeBottom.colors = @[CocoColor(0x0007080F), CocoColor(0x6607080F), CocoColor(0xE607080F)];
    shadeBottom.locations = @[@0, @0.65, @1];
    [self pinToView:shadeBottom];
}

- (UIControl *)railItem:(NSString *)icon title:(NSString *)title action:(SEL)action {
    UIControl *item = [UIControl new];
    item.translatesAutoresizingMaskIntoConstraints = NO;
    item.layer.cornerRadius = 12;
    item.isAccessibilityElement = YES;
    item.accessibilityLabel = title;
    item.accessibilityTraits = UIAccessibilityTraitButton;

    UIImageView *image = [[UIImageView alloc] initWithImage:CocoIcon(icon)];
    image.translatesAutoresizingMaskIntoConstraints = NO;
    image.contentMode = UIViewContentModeScaleAspectFit;
    image.tintColor = COCO_MUTED;
    image.userInteractionEnabled = NO;
    [item addSubview:image];

    UILabel *label = CocoLabel(title, CocoFontSemiBold, 10, COCO_MUTED);
    label.textAlignment = NSTextAlignmentCenter;
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.7;
    label.userInteractionEnabled = NO;
    [item addSubview:label];

    [NSLayoutConstraint activateConstraints:@[
        [item.widthAnchor constraintEqualToConstant:66],
        [image.topAnchor constraintEqualToAnchor:item.topAnchor constant:7],
        [image.centerXAnchor constraintEqualToAnchor:item.centerXAnchor],
        [image.widthAnchor constraintEqualToConstant:24],
        [image.heightAnchor constraintEqualToConstant:24],
        [label.topAnchor constraintEqualToAnchor:image.bottomAnchor constant:4],
        [label.leadingAnchor constraintEqualToAnchor:item.leadingAnchor constant:2],
        [label.trailingAnchor constraintEqualToAnchor:item.trailingAnchor constant:-2],
        [label.bottomAnchor constraintEqualToAnchor:item.bottomAnchor constant:-6],
    ]];
    [item setContentHuggingPriority:UILayoutPriorityDefaultHigh forAxis:UILayoutConstraintAxisVertical];
    [item addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [item addTarget:self action:@selector(railTouchDown:) forControlEvents:UIControlEventTouchDown | UIControlEventTouchDragEnter];
    [item addTarget:self action:@selector(railTouchUp:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel | UIControlEventTouchDragExit];
    return item;
}

- (void)railTouchDown:(UIControl *)sender {
    sender.backgroundColor = CocoColor(0x1FFFFFFF);
}

- (void)railTouchUp:(UIControl *)sender {
    sender.backgroundColor = UIColor.clearColor;
}

- (UIView *)buildRail {
    UIView *rail = [UIView new];
    rail.translatesAutoresizingMaskIntoConstraints = NO;
    rail.backgroundColor = CocoColor(0xC708091A);
    [self.view addSubview:rail];

    UIView *edge = [UIView new];
    edge.translatesAutoresizingMaskIntoConstraints = NO;
    edge.backgroundColor = CocoColor(0x17FFFFFF);
    [rail addSubview:edge];

    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.showsVerticalScrollIndicator = NO;
    scroll.alwaysBounceVertical = NO;
    [rail addSubview:scroll];

    UIStackView *stack = [UIStackView new];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 4;
    [scroll addSubview:stack];

    UIImageView *logo = [[UIImageView alloc] initWithImage:CocoPicture(@"logo")];
    logo.translatesAutoresizingMaskIntoConstraints = NO;
    logo.contentMode = UIViewContentModeScaleAspectFit;
    logo.accessibilityLabel = @"CocoLauncher";
    [logo.widthAnchor constraintEqualToConstant:42].active = YES;
    [logo.heightAnchor constraintEqualToConstant:42].active = YES;
    [stack addArrangedSubview:logo];

    UIView *divider = [UIView new];
    divider.translatesAutoresizingMaskIntoConstraints = NO;
    divider.backgroundColor = CocoColor(0x17FFFFFF);
    [divider.widthAnchor constraintEqualToConstant:28].active = YES;
    [divider.heightAnchor constraintEqualToConstant:1].active = YES;
    [stack addArrangedSubview:divider];
    [stack setCustomSpacing:8 afterView:logo];
    [stack setCustomSpacing:8 afterView:divider];

    [stack addArrangedSubview:[self railItem:@"discord" title:localize(@"coco.home.rail.discord", nil) action:@selector(openDiscord)]];
    [stack addArrangedSubview:[self railItem:@"controls" title:localize(@"coco.home.rail.controls", nil) action:@selector(openControls)]];
    [stack addArrangedSubview:[self railItem:@"folder" title:localize(@"coco.home.rail.folder", nil) action:@selector(openFolder)]];
    [stack addArrangedSubview:[self railItem:@"guide" title:localize(@"coco.home.rail.guide", nil) action:@selector(openGuide)]];

    UIView *spacer = [UIView new];
    spacer.translatesAutoresizingMaskIntoConstraints = NO;
    [spacer setContentHuggingPriority:1 forAxis:UILayoutConstraintAxisVertical];
    [spacer setContentCompressionResistancePriority:1 forAxis:UILayoutConstraintAxisVertical];
    [spacer.heightAnchor constraintGreaterThanOrEqualToConstant:6].active = YES;
    [stack addArrangedSubview:spacer];

    [stack addArrangedSubview:[self railItem:@"settings" title:localize(@"coco.home.rail.settings", nil) action:@selector(openSettings)]];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [rail.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [rail.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [rail.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [rail.trailingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:76],
        [edge.topAnchor constraintEqualToAnchor:rail.topAnchor],
        [edge.bottomAnchor constraintEqualToAnchor:rail.bottomAnchor],
        [edge.trailingAnchor constraintEqualToAnchor:rail.trailingAnchor],
        [edge.widthAnchor constraintEqualToConstant:1],
        [scroll.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [scroll.widthAnchor constraintEqualToConstant:76],
        [scroll.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor],
        [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:10],
        [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-10],
        [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
        [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor],
        [stack.heightAnchor constraintGreaterThanOrEqualToAnchor:scroll.frameLayoutGuide.heightAnchor constant:-20],
    ]];
    return rail;
}

- (void)buildChip {
    UIView *chip = [UIView new];
    chip.translatesAutoresizingMaskIntoConstraints = NO;
    CocoStyleBox(chip, CocoColor(0x99121424), CocoColor(0x17FFFFFF), 16);
    [self.view addSubview:chip];
    self.chipView = chip;

    UIStackView *row = [UIStackView new];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 8;
    [chip addSubview:row];

    self.statusDot = [UIView new];
    self.statusDot.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusDot.backgroundColor = COCO_MUTED;
    self.statusDot.layer.cornerRadius = 4;
    [self.statusDot.widthAnchor constraintEqualToConstant:8].active = YES;
    [self.statusDot.heightAnchor constraintEqualToConstant:8].active = YES;

    self.statusLabel = CocoLabel(localize(@"coco.home.status_checking", nil), CocoFontRegular, 13, COCO_INK);

    self.pingBars = [[CocoPingBarsView alloc] initWithFrame:CGRectZero];
    [self.pingBars.widthAnchor constraintEqualToConstant:18].active = YES;
    [self.pingBars.heightAnchor constraintEqualToConstant:14].active = YES;
    self.pingBars.hidden = YES;

    self.pingLabel = CocoLabel(@"", CocoFontExtraBold, 13, COCO_GREEN);
    self.pingLabel.hidden = YES;

    [row addArrangedSubview:self.statusDot];
    [row addArrangedSubview:self.statusLabel];
    [row addArrangedSubview:self.pingBars];
    [row addArrangedSubview:self.pingLabel];
    [row setCustomSpacing:10 afterView:self.statusLabel];
    [row setCustomSpacing:6 afterView:self.pingBars];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [chip.topAnchor constraintEqualToAnchor:safe.topAnchor constant:14],
        [chip.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-14],
        [row.topAnchor constraintEqualToAnchor:chip.topAnchor constant:7],
        [row.bottomAnchor constraintEqualToAnchor:chip.bottomAnchor constant:-7],
        [row.leadingAnchor constraintEqualToAnchor:chip.leadingAnchor constant:14],
        [row.trailingAnchor constraintEqualToAnchor:chip.trailingAnchor constant:-14],
    ]];
}

- (void)buildContentNextTo:(UIView *)rail {
    UIStackView *content = [UIStackView new];
    content.translatesAutoresizingMaskIntoConstraints = NO;
    content.axis = UILayoutConstraintAxisVertical;
    content.alignment = UIStackViewAlignmentLeading;
    content.spacing = 8;
    [self.view addSubview:content];
    self.contentStack = content;

    // Event text over the art
    UIStackView *hero = [UIStackView new];
    hero.translatesAutoresizingMaskIntoConstraints = NO;
    hero.axis = UILayoutConstraintAxisVertical;
    hero.alignment = UIStackViewAlignmentLeading;
    hero.spacing = 2;
    self.heroStack = hero;

    self.eyebrowLabel = CocoLabel(@"", CocoFontExtraBold, 11, COCO_GOLD);
    self.titleLabel = CocoLabel(@"", CocoFontExtraBold, 34, COCO_INK);
    self.titleLabel.numberOfLines = 2;
    self.titleLabel.adjustsFontSizeToFitWidth = YES;
    self.titleLabel.minimumScaleFactor = 0.45;
    [self.titleLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisVertical];
    self.subtitleLabel = CocoLabel(@"", CocoFontRegular, 13, COCO_SUB);
    self.subtitleLabel.numberOfLines = 2;
    for (UILabel *label in @[self.eyebrowLabel, self.titleLabel, self.subtitleLabel]) {
        label.layer.shadowColor = UIColor.blackColor.CGColor;
        label.layer.shadowOpacity = 0.8;
        label.layer.shadowRadius = 6;
        label.layer.shadowOffset = CGSizeMake(0, 2);
        [hero addArrangedSubview:label];
    }
    [hero setCustomSpacing:4 afterView:self.titleLabel];

    // Name + play
    UILabel *nameLabel = CocoLabel(localize(@"coco.home.name_label", nil), CocoFontSemiBold, 12, COCO_MUTED);

    UIView *fieldBox = [UIView new];
    fieldBox.translatesAutoresizingMaskIntoConstraints = NO;
    CocoStyleBox(fieldBox, CocoColor(0xC7121424), CocoColor(0x24FFFFFF), 14);

    UIImageView *head = [[UIImageView alloc] initWithImage:[UIImage imageNamed:@"DefaultAccount"]];
    head.translatesAutoresizingMaskIntoConstraints = NO;
    head.contentMode = UIViewContentModeScaleAspectFill;
    head.backgroundColor = CocoColor(0xFF3B7D4F);
    head.layer.cornerRadius = 6;
    head.clipsToBounds = YES;
    [fieldBox addSubview:head];

    UITextField *field = [UITextField new];
    field.translatesAutoresizingMaskIntoConstraints = NO;
    field.font = CocoFont(CocoFontSemiBold, 16);
    field.textColor = COCO_INK;
    field.tintColor = COCO_ORANGE;
    field.attributedPlaceholder = [[NSAttributedString alloc] initWithString:localize(@"coco.home.name_hint", nil)
        attributes:@{NSForegroundColorAttributeName: CocoColor(0xFF6F7594), NSFontAttributeName: CocoFont(CocoFontSemiBold, 16)}];
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.spellCheckingType = UITextSpellCheckingTypeNo;
    field.keyboardType = UIKeyboardTypeASCIICapable;
    field.keyboardAppearance = UIKeyboardAppearanceDark;
    field.returnKeyType = UIReturnKeyGo;
    field.clearButtonMode = UITextFieldViewModeWhileEditing;
    field.delegate = self;
    [field addTarget:self action:@selector(refreshNameNote) forControlEvents:UIControlEventEditingChanged];
    [fieldBox addSubview:field];
    self.nameField = field;

    [NSLayoutConstraint activateConstraints:@[
        [fieldBox.heightAnchor constraintEqualToConstant:56],
        [head.leadingAnchor constraintEqualToAnchor:fieldBox.leadingAnchor constant:12],
        [head.centerYAnchor constraintEqualToAnchor:fieldBox.centerYAnchor],
        [head.widthAnchor constraintEqualToConstant:30],
        [head.heightAnchor constraintEqualToConstant:30],
        [field.leadingAnchor constraintEqualToAnchor:head.trailingAnchor constant:10],
        [field.trailingAnchor constraintEqualToAnchor:fieldBox.trailingAnchor constant:-10],
        [field.topAnchor constraintEqualToAnchor:fieldBox.topAnchor],
        [field.bottomAnchor constraintEqualToAnchor:fieldBox.bottomAnchor],
    ]];
    self.fieldWidth = [fieldBox.widthAnchor constraintEqualToConstant:250];

    UIStackView *nameColumn = [UIStackView new];
    nameColumn.translatesAutoresizingMaskIntoConstraints = NO;
    nameColumn.axis = UILayoutConstraintAxisVertical;
    nameColumn.spacing = 6;
    [nameColumn addArrangedSubview:nameLabel];
    [nameColumn addArrangedSubview:fieldBox];

    self.playButton = [[CocoPlayButton alloc] initWithFrame:CGRectZero];
    [self.playButton setTitle:localize(@"coco.home.play", nil) forState:UIControlStateNormal];
    [self.playButton addTarget:self action:@selector(playTapped) forControlEvents:UIControlEventTouchUpInside];
    self.playHeight = [self.playButton.heightAnchor constraintEqualToConstant:56];
    self.playHeight.active = YES;
    [self.playButton.widthAnchor constraintGreaterThanOrEqualToConstant:150].active = YES;

    UIStackView *ready = [UIStackView new];
    ready.translatesAutoresizingMaskIntoConstraints = NO;
    ready.axis = UILayoutConstraintAxisHorizontal;
    ready.alignment = UIStackViewAlignmentBottom;
    ready.spacing = 12;
    [ready addArrangedSubview:nameColumn];
    [ready addArrangedSubview:self.playButton];
    self.readyRow = ready;

    self.nameNoteLabel = CocoLabel(@"", CocoFontSemiBold, 12, COCO_GREEN);
    self.nameNoteLabel.numberOfLines = 2;
    self.nameNoteLabel.hidden = YES;

    // Progress card (download, login, JIT)
    UIView *card = [UIView new];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    CocoStyleBox(card, CocoColor(0xB8121424), CocoColor(0x1AFFFFFF), 16);
    card.hidden = YES;
    self.busyCard = card;

    self.busyTitle = CocoLabel(@"", CocoFontSemiBold, 13, COCO_INK);
    self.busyTitle.lineBreakMode = NSLineBreakByTruncatingTail;
    self.busyPercent = CocoLabel(@"", CocoFontExtraBold, 17, COCO_ORANGE);
    [self.busyPercent setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.busyPercent setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *busyHeader = [UIStackView new];
    busyHeader.translatesAutoresizingMaskIntoConstraints = NO;
    busyHeader.axis = UILayoutConstraintAxisHorizontal;
    busyHeader.alignment = UIStackViewAlignmentCenter;
    busyHeader.spacing = 10;
    [busyHeader addArrangedSubview:self.busyTitle];
    [busyHeader addArrangedSubview:self.busyPercent];

    self.busyBar = [[CocoProgressBar alloc] initWithFrame:CGRectZero];
    [self.busyBar.heightAnchor constraintEqualToConstant:10].active = YES;
    self.busyDetail = CocoLabel(@"", CocoFontRegular, 12, COCO_DIM);
    self.busyDetail.numberOfLines = 2;

    UIStackView *busyStack = [UIStackView new];
    busyStack.translatesAutoresizingMaskIntoConstraints = NO;
    busyStack.axis = UILayoutConstraintAxisVertical;
    busyStack.spacing = 8;
    [busyStack addArrangedSubview:busyHeader];
    [busyStack addArrangedSubview:self.busyBar];
    [busyStack addArrangedSubview:self.busyDetail];
    [card addSubview:busyStack];
    [NSLayoutConstraint activateConstraints:@[
        [busyStack.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [busyStack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-14],
        [busyStack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:18],
        [busyStack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-18],
    ]];

    self.metaLabel = CocoLabel(@"", CocoFontRegular, 12, COCO_DIM);

    [content addArrangedSubview:hero];
    [content addArrangedSubview:ready];
    [content addArrangedSubview:self.nameNoteLabel];
    [content addArrangedSubview:card];
    [content addArrangedSubview:self.metaLabel];
    [content setCustomSpacing:4 afterView:ready];
    [content setCustomSpacing:14 afterView:self.nameNoteLabel];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    self.contentBottom = [content.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-12];
    NSLayoutConstraint *heroWide = [hero.widthAnchor constraintEqualToAnchor:content.widthAnchor];
    heroWide.priority = UILayoutPriorityDefaultHigh;
    self.readyFullWidth = [ready.widthAnchor constraintEqualToAnchor:content.widthAnchor];
    [NSLayoutConstraint activateConstraints:@[
        [content.leadingAnchor constraintEqualToAnchor:rail.trailingAnchor constant:20],
        [content.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],
        [content.topAnchor constraintGreaterThanOrEqualToAnchor:safe.topAnchor constant:52],
        self.contentBottom,
        [hero.widthAnchor constraintLessThanOrEqualToAnchor:content.widthAnchor],
        [hero.widthAnchor constraintLessThanOrEqualToConstant:560],
        heroWide,
        [ready.widthAnchor constraintLessThanOrEqualToAnchor:content.widthAnchor],
        [self.nameNoteLabel.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [card.widthAnchor constraintEqualToAnchor:content.widthAnchor],
        [self.metaLabel.widthAnchor constraintLessThanOrEqualToAnchor:content.widthAnchor],
    ]];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    self.chipView.layer.cornerRadius = self.chipView.bounds.size.height / 2;
    BOOL narrow = self.contentStack.bounds.size.width < 430;
    if (!self.layoutModeSet || narrow != self.narrowLayout) {
        self.layoutModeSet = YES;
        self.narrowLayout = narrow;
        [self applyLayoutMode];
    }
}

- (void)applyLayoutMode {
    BOOL narrow = self.narrowLayout;
    // Portrait phone: name field and PLAY stacked, full width
    self.readyRow.axis = narrow ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal;
    self.readyRow.alignment = narrow ? UIStackViewAlignmentFill : UIStackViewAlignmentBottom;
    self.fieldWidth.active = !narrow;
    self.readyFullWidth.active = narrow;
    self.playHeight.constant = narrow ? 52 : 56;
    CGFloat titleSize = narrow ? 30 : 34;
    if (self.view.bounds.size.height < 430) {
        titleSize = 28;
    }
    self.titleLabel.font = CocoFont(CocoFontExtraBold, titleSize);
}

#pragma mark - Content

- (void)loadEvent {
    NSDictionary *event = nil;
    NSDictionary *cached = [NSUserDefaults.standardUserDefaults dictionaryForKey:@"CocoHeroEvent"];
    if (cached) {
        event = cached;
    } else {
        NSString *path = [NSBundle.mainBundle pathForResource:@"hero_event" ofType:@"json" inDirectory:@"cocoui"];
        NSData *data = path ? [NSData dataWithContentsOfFile:path] : nil;
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if ([json isKindOfClass:NSDictionary.class]) {
            event = json;
        }
    }
    [self applyEvent:event];

    // The event text can change without a new app version
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:COCO_EVENT_URL]
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:10];
    __weak CocoHomeViewController *weakSelf = self;
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        if (data == nil || status != 200) {
            return;
        }
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if (![json isKindOfClass:NSDictionary.class]) {
            return;
        }
        NSMutableDictionary *clean = [NSMutableDictionary new];
        for (NSString *key in @[@"eyebrow", @"title", @"desc"]) {
            if ([json[key] isKindOfClass:NSString.class]) {
                clean[key] = json[key];
            }
        }
        [NSUserDefaults.standardUserDefaults setObject:clean forKey:@"CocoHeroEvent"];
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf applyEvent:clean];
        });
    }] resume];
}

- (NSString *)eventText:(NSDictionary *)event key:(NSString *)key fallback:(NSString *)fallback {
    id value = event[key];
    if ([value isKindOfClass:NSString.class] && [value length] > 0) {
        return value;
    }
    return localize(fallback, nil);
}

- (void)applyEvent:(NSDictionary *)event {
    NSString *eyebrow = [self eventText:event key:@"eyebrow" fallback:@"coco.home.eyebrow"];
    self.eyebrowLabel.attributedText = [[NSAttributedString alloc] initWithString:eyebrow attributes:@{
        NSFontAttributeName: CocoFont(CocoFontExtraBold, 11),
        NSForegroundColorAttributeName: COCO_GOLD,
        NSKernAttributeName: @2.2
    }];
    self.titleLabel.text = [self eventText:event key:@"title" fallback:@"coco.home.title"];
    self.subtitleLabel.attributedText = CocoRichText([self eventText:event key:@"desc" fallback:@"coco.home.subtitle"], 13, COCO_SUB, COCO_INK);
}

- (void)restoreName {
    NSString *name = [NSUserDefaults.standardUserDefaults stringForKey:@"CocoPlayerName"];
    if (name.length == 0 && [BaseAuthenticator.current isKindOfClass:LocalAuthenticator.class]) {
        name = BaseAuthenticator.current.authData[@"username"];
    }
    self.nameField.text = name;
    [self refreshNameNote];
}

- (BOOL)accountExists:(NSString *)name {
    return [CocoAccountProvider savedAccountsNamed:name kind:CocoAccountKindNone inHome:nil].count > 0;
}

- (void)refreshNameNote {
    NSString *name = [self.nameField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    BOOL saved = [CocoHomeViewController isValidPlayerName:name] && [self accountExists:name];
    self.nameNoteLabel.text = localize(@"coco.home.name_saved", nil);
    self.nameNoteLabel.textColor = COCO_GREEN;
    self.nameNoteLabel.hidden = !saved;
}

- (void)showNameError {
    self.nameNoteLabel.text = localize(@"coco.account.error.name_chars", nil);
    self.nameNoteLabel.textColor = COCO_RED;
    self.nameNoteLabel.hidden = NO;
    CAKeyframeAnimation *shake = [CAKeyframeAnimation animationWithKeyPath:@"transform.translation.x"];
    shake.values = @[@0, @-8, @8, @-6, @6, @-3, @3, @0];
    shake.duration = 0.4;
    [self.readyRow.layer addAnimation:shake forKey:@"shake"];
}

- (void)refreshMeta {
    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    self.metaLabel.text = [NSString stringWithFormat:localize(@"coco.home.meta", nil), version, (long)getPrefInt(@"java.allocated_memory")];
}

#pragma mark - Appearance

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    // CocoLauncher: a heap saved above what iOS allows this install (no increased memory
    // limit entitlement) gets the app killed while the game loads, so lower it first.
    int heapLoweredFrom = CocoClampSavedHeap();
    [self refreshMeta];
    [self startPing];
    if (!self.didAppearOnce) {
        self.didAppearOnce = YES;
        [self checkInstallation];
        [self runPreviewHooks];
        [self checkForAppUpdate];
        [self offerMemoryUnlockIfNeeded];
    }
    if (heapLoweredFrom > 0) {
        [self showHeapLoweredFrom:heapLoweredFrom];
    }
}

#pragma mark - RAM unlock on launch

// CocoLauncher: without the increased memory limit the Coco pack cannot run
// (minimum 3.5 GB heap), so ask for the Apple ID right away on every launch
// until the install is unlocked.
- (void)offerMemoryUnlockIfNeeded {
#if !TARGET_OS_SIMULATOR
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if (!CocoLacksMemoryEntitlement() || [defaults boolForKey:@"cocoAutoPlay"] ||
        [defaults boolForKey:@"cocoSelfTest"] || [defaults stringForKey:@"cocoPreview"].length > 0) {
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.presentedViewController == nil && self.view.window != nil) {
            CocoPresentMemoryUnlock(self);
        }
    });
#endif
}

#pragma mark - App update notice

// CocoLauncher: iOS cannot replace its own app, so tell the player when the Coco source has a newer
// build (compared by CFBundleVersion: the shown version can stay the same between builds).
- (void)checkForAppUpdate {
    NSInteger currentBuild = [NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"] integerValue];
    if (currentBuild <= 0) {
        return;
    }
    NSString *urlString = [NSString stringWithFormat:@"%@?t=%lld", COCO_IOS_SOURCE_URL, (long long)NSDate.date.timeIntervalSince1970];
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:urlString]
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:15];
    __weak CocoHomeViewController *weakSelf = self;
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        if (error || data.length == 0) {
            NSLog(@"[CocoLauncher] Update check failed: %@", error.localizedDescription);
            return;
        }
        id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSArray *apps = [json isKindOfClass:NSDictionary.class] ? json[@"apps"] : nil;
        NSDictionary *app = [apps isKindOfClass:NSArray.class] ? apps.firstObject : nil;
        if (![app isKindOfClass:NSDictionary.class]) {
            return;
        }
        NSArray *versions = [app[@"versions"] isKindOfClass:NSArray.class] ? app[@"versions"] : nil;
        NSDictionary *latest = [versions.firstObject isKindOfClass:NSDictionary.class] ? versions.firstObject : app;
        NSInteger latestBuild = [latest[@"buildVersion"] integerValue];
        NSString *latestVersion = [latest[@"version"] description] ?: @"";
        NSString *downloadURL = [latest[@"downloadURL"] isKindOfClass:NSString.class] ? latest[@"downloadURL"] : nil;
        if (latestBuild <= currentBuild) {
            NSLog(@"[CocoLauncher] Update check: build %ld is the newest (source build %ld)", (long)currentBuild, (long)latestBuild);
            return;
        }
        NSLog(@"[CocoLauncher] Update available: build %ld -> %@ (build %ld)", (long)currentBuild, latestVersion, (long)latestBuild);
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf showAppUpdate:latestVersion build:latestBuild downloadURL:downloadURL attempt:0];
        });
    }] resume];
}

- (void)showAppUpdate:(NSString *)version build:(NSInteger)build downloadURL:(NSString *)downloadURL attempt:(int)attempt {
    if (self.presentedViewController || self.view.window == nil) {
        // Another sheet is open or the game is starting: try again a little later (up to ~1 minute)
        if (attempt < 30) {
            __weak CocoHomeViewController *weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                [weakSelf showAppUpdate:version build:build downloadURL:downloadURL attempt:attempt + 1];
            });
        }
        return;
    }
    NSString *current = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"";
    NSString *currentBuild = NSBundle.mainBundle.infoDictionary[@"CFBundleVersion"] ?: @"";
    NSString *message = [NSString stringWithFormat:localize(@"coco.update.message", nil),
        version, (long)build, current, currentBuild];
    CocoSheetViewController *sheet = [CocoSheetViewController sheetWithTitle:localize(@"coco.update.title", nil) message:message];
    [sheet addPrimary:localize(@"coco.update.sidestore", nil) action:^{
        NSString *encoded = [downloadURL stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.alphanumericCharacterSet];
        NSURL *page = [NSURL URLWithString:COCO_IOS_DOWNLOAD_PAGE];
        if (encoded.length == 0) {
            [UIApplication.sharedApplication openURL:page options:@{} completionHandler:nil];
            return;
        }
        NSURL *sideStore = [NSURL URLWithString:[@"sidestore://install?url=" stringByAppendingString:encoded]];
        [UIApplication.sharedApplication openURL:sideStore options:@{} completionHandler:^(BOOL success) {
            if (!success) {
                [UIApplication.sharedApplication openURL:page options:@{} completionHandler:nil];
            }
        }];
    }];
    [sheet addSecondary:localize(@"coco.update.page", nil) action:^{
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:COCO_IOS_DOWNLOAD_PAGE] options:@{} completionHandler:nil];
    }];
    [sheet addSecondary:localize(@"coco.update.later", nil) action:nil];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)showHeapLoweredFrom:(int)oldMB {
    if (self.presentedViewController) {
        return;
    }
    int limit = CocoProcessMemoryLimitMB();
    NSString *limitText = limit > 0 ? [NSString stringWithFormat:@"%.1f GB", limit / 1024.0] : @"?";
    NSString *message = [NSString stringWithFormat:localize(@"coco.memory.lowered", nil),
        limitText, oldMB, (int)getPrefInt(@"java.allocated_memory")];
    CocoSheetViewController *sheet = [CocoSheetViewController sheetWithTitle:localize(@"coco.memory.lowered.title", nil) message:message];
    [sheet addSecondary:localize(@"OK", nil) action:nil];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.pingTimer invalidate];
    self.pingTimer = nil;
}

- (void)startPing {
    [self.pingTimer invalidate];
    __weak CocoHomeViewController *weakSelf = self;
    self.pingTimer = [NSTimer scheduledTimerWithTimeInterval:30 repeats:YES block:^(NSTimer *timer) {
        [weakSelf pingNow];
    }];
    [self pingNow];
}

- (void)pingNow {
    __weak CocoHomeViewController *weakSelf = self;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int online = 0, max = 0, latency = 0;
        BOOL ok = CocoServerPing(COCO_SERVER_HOST, COCO_SERVER_PORT, 5000, &online, &max, &latency);
        dispatch_async(dispatch_get_main_queue(), ^{
            CocoHomeViewController *strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            strongSelf.statusDot.backgroundColor = ok ? COCO_GREEN : COCO_RED;
            strongSelf.statusLabel.text = ok ? [NSString stringWithFormat:localize(@"coco.home.status_online", nil), online] : localize(@"coco.home.status_offline", nil);
            strongSelf.pingBars.hidden = !ok;
            strongSelf.pingLabel.hidden = !ok;
            if (ok) {
                strongSelf.pingLabel.textColor = [strongSelf.pingBars setPing:latency];
                strongSelf.pingLabel.text = [NSString stringWithFormat:@"%d ms", latency];
            }
        });
    });
}

- (void)checkInstallation {
    // Without get-task-allow the game can't get JIT (ESign/KSign/enterprise installs)
    if (getEntitlementValue(@"get-task-allow") || getenv("SIMULATOR_DEVICE_NAME") != NULL) {
        return;
    }
    if (@available(iOS 13.0, *)) {
        if (NSProcessInfo.processInfo.macCatalystApp) {
            return;
        }
    }
    CocoSheetViewController *sheet = [CocoSheetViewController sheetWithTitle:localize(@"coco.home.nojit.title", nil)
        message:localize(@"coco.home.nojit.message", nil)];
    [sheet addSecondary:localize(@"OK", nil) action:nil];
    [self presentViewController:sheet animated:YES completion:nil];
}

// Used by the Simulator preview workflow to capture each screen
- (void)runPreviewHooks {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([[defaults stringForKey:@"cocoOrientation"] isEqualToString:@"landscape"]) {
        if (@available(iOS 16.0, *)) {
            UIWindowSceneGeometryPreferencesIOS *preferences = [[UIWindowSceneGeometryPreferencesIOS alloc]
                initWithInterfaceOrientations:UIInterfaceOrientationMaskLandscapeRight];
            [self.view.window.windowScene requestGeometryUpdateWithPreferences:preferences errorHandler:^(NSError *error) {
                NSLog(@"[CocoHome] Could not rotate: %@", error.localizedDescription);
            }];
        }
    }
    // Self-tests for the simulator workflow (account layer on temporary empty
    // homes, installer rules); results in Documents/coco-selftest.json
    if ([defaults boolForKey:@"cocoSelfTest"]) {
        NSMutableDictionary *results = [[CocoAccountSelfTest runWritingResultsTo:nil] mutableCopy];
        [results addEntriesFromDictionary:[CocoInstallSelfTest run]];
        saveJSONToFile(results, [[CocoAccountProvider defaultHome] stringByAppendingPathComponent:@"coco-selftest.json"]);
    }
    // Simulator workflow: press CHOI once, like a player (installer run, report
    // in Documents/coco-install-report.json)
    if ([defaults boolForKey:@"cocoAutoPlay"]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self playTapped];
        });
    }
    // Sample name for store/ad screenshots: saved as a Local account like a real player
    NSString *demoName = [defaults stringForKey:@"cocoDemoName"];
    if ([CocoHomeViewController isValidPlayerName:demoName]) {
        if (![self accountExists:demoName]) {
            [self accountForName:demoName];
        }
        self.nameField.text = demoName;
        [self refreshNameNote];
    }
    NSString *preview = [defaults stringForKey:@"cocoPreview"];
    if (preview.length == 0) {
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if ([preview isEqualToString:@"settings"]) {
            [self openSettings];
        } else if ([preview isEqualToString:@"firstrun"]) {
            [self presentFirstDownloadForName:nil];
        }
    });
}

#pragma mark - Keyboard

- (void)keyboardWillChange:(NSNotification *)notification {
    CGFloat overlap = 0;
    if (![notification.name isEqualToString:UIKeyboardWillHideNotification]) {
        CGRect end = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
        CGRect local = [self.view convertRect:end fromView:nil];
        overlap = MAX(0, CGRectGetMaxY(self.view.bounds) - CGRectGetMinY(local));
    }
    self.contentBottom.constant = -(MAX(overlap - self.view.safeAreaInsets.bottom, 0) + 12);
    // Short screens (landscape phone): hide the event text while typing
    self.heroStack.hidden = overlap > 0 && self.view.bounds.size.height < 520;
    double duration = [notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    [UIView animateWithDuration:duration animations:^{
        [self.view layoutIfNeeded];
    }];
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    [self playTapped];
    return NO;
}

- (BOOL)textField:(UITextField *)textField shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString *)string {
    NSString *result = [textField.text stringByReplacingCharactersInRange:range withString:string];
    return result.length <= 16;
}

#pragma mark - Rail actions

- (void)openDiscord {
    [UIApplication.sharedApplication openURL:[NSURL URLWithString:COCO_DISCORD_URL] options:@{} completionHandler:nil];
}

- (void)openControls {
    CustomControlsViewController *vc = [CustomControlsViewController new];
    vc.modalPresentationStyle = UIModalPresentationOverFullScreen;
    vc.setDefaultCtrl = ^(NSString *name) {
        setPrefObject(@"control.default_ctrl", name);
    };
    vc.getDefaultCtrl = ^NSString *{
        return getPrefObject(@"control.default_ctrl");
    };
    [self presentViewController:vc animated:YES completion:nil];
}

- (void)openFolder {
    [CocoHomeViewController openGameFolderFrom:self];
}

- (void)openGuide {
    SFSafariViewController *vc = [[SFSafariViewController alloc] initWithURL:[NSURL URLWithString:COCO_HELP_URL]];
    vc.preferredBarTintColor = COCO_PANEL;
    vc.preferredControlTintColor = COCO_ORANGE;
    [self presentViewController:vc animated:YES completion:nil];
}

- (void)openSettings {
    if (self.presentedViewController) {
        return;
    }
    CocoSettingsViewController *vc = [CocoSettingsViewController new];
    __weak CocoHomeViewController *weakSelf = self;
    vc.onClose = ^{
        [weakSelf refreshMeta];
    };
    [self presentViewController:vc animated:YES completion:nil];
}

#pragma mark - Play

- (void)setBusy:(BOOL)busy title:(NSString *)title {
    self.busy = busy;
    self.playButton.enabled = !busy;
    self.nameField.enabled = !busy;
    self.busyCard.hidden = !busy;
    if (busy) {
        self.busyTitle.text = title;
        self.busyPercent.text = @"";
        self.busyDetail.text = @"";
        self.busyBar.progress = 0;
        self.lastSecond = 0;
        self.lastTime = 0;
        self.lastCompleted = 0;
    }
}

- (void)showError:(NSString *)message {
    CocoSheetViewController *sheet = [CocoSheetViewController sheetWithTitle:localize(@"coco.home.error.title", nil) message:message];
    [sheet addSecondary:localize(@"OK", nil) action:nil];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (BOOL)selectCocoProfile {
    [PLProfiles updateCurrent];
    if (PLProfiles.current.profiles[COCO_PROFILE_NAME] == nil) {
        return NO;
    }
    if (![PLProfiles.current.selectedProfileName isEqualToString:COCO_PROFILE_NAME]) {
        PLProfiles.current.selectedProfileName = COCO_PROFILE_NAME;
    }
    return YES;
}

// Selects (and creates if needed) the account the player will play with
// A saved account with this name (Local or Microsoft) is used as it is; a new
// name becomes a Local account (CocoLocalAccountProvider), no Microsoft involved.
- (BaseAuthenticator *)accountForName:(NSString *)name {
    // The selected account if it has this nickname, else the Local account with
    // it, else a Microsoft account with it, else a new Local account.
    NSString *storageId = [CocoAccountProvider storageIdForPlayName:name
        preferredId:getPrefObject(@"internal.selected_account") inHome:nil];
    if (storageId == nil) {
        NSString *error = nil;
        NSDictionary *created = [CocoLocalAccountProvider createAccountNamed:name inHome:nil error:&error];
        if (created == nil) {
            NSLog(@"[CocoHome] Could not create the Local account %@: %@", name, error);
            return nil;
        }
        storageId = created[CocoAccountStorageIdKey];
    }
    return [BaseAuthenticator loadSavedName:storageId];
}

- (BOOL)gameFilesPresent {
    NSString *jar = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.jar", getenv("GAME_DIR"), COCO_MINECRAFT_VERSION];
    return [NSFileManager.defaultManager fileExistsAtPath:jar];
}

- (void)restorePlayAccount {
    if (self.playId.length == 0) {
        return;
    }
    if (![BaseAuthenticator.current.authData[CocoAccountStorageIdKey] isEqualToString:self.playId]) {
        [BaseAuthenticator loadSavedName:self.playId];
    }
    setPrefObject(@"internal.selected_account", self.playId);
}

- (void)playTapped {
    if (self.busy || self.task) {
        return;
    }
    NSString *name = [self.nameField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    self.nameField.text = name;
    if (![CocoHomeViewController isValidPlayerName:name]) {
        [self showNameError];
        return;
    }
    [self.view endEditing:YES];
    [NSUserDefaults.standardUserDefaults setObject:name forKey:@"CocoPlayerName"];

    // The Coco pack needs at least 3.5 GB of Java heap (3.8-4 GB to play smoothly)
    int heap = (int)getPrefInt(@"java.allocated_memory");
    if (heap < COCO_MIN_PLAY_HEAP_MB) {
        [self presentLowMemorySheet:heap];
        return;
    }

    if (![self selectCocoProfile]) {
        [self showError:localize(@"coco.home.error.profile", nil)];
        return;
    }
    BaseAuthenticator *account = [self accountForName:name];
    if (account == nil) {
        [self showError:localize(@"coco.home.error.account", nil)];
        return;
    }
    self.playName = name;
    self.playId = account.authData[CocoAccountStorageIdKey];
    setPrefObject(@"internal.selected_account", self.playId);
    [self refreshNameNote];

    // CocoLauncher: one Play path for every account type. The shared installer
    // checks Java, Fabric, the Minecraft files and the Coco pack, downloads what
    // is missing and allowed, and names the exact step that is blocked. The
    // selected account is never swapped for another one.
    NSLog(@"[CocoHome] Play: %@", [CocoLaunchContext contextForAccountData:account.authData].logDescription);
    [self prepareAndDownload];
}

- (void)presentLowMemorySheet:(int)heap {
    BOOL locked = CocoLacksMemoryEntitlement();
    NSString *message = [NSString stringWithFormat:localize(locked ? @"coco.ram.min.message_locked" : @"coco.ram.min.message", nil),
        heap, COCO_MIN_PLAY_HEAP_MB, COCO_SMOOTH_HEAP_MB, CocoSafeMaxHeapMB()];
    CocoSheetViewController *sheet = [CocoSheetViewController sheetWithTitle:localize(@"coco.ram.min.title", nil) message:message];
    __weak CocoHomeViewController *weakSelf = self;
    if (locked) {
        [sheet addPrimary:localize(@"coco.ram.min.unlock", nil) action:^{
            CocoHomeViewController *strongSelf = weakSelf;
            if (strongSelf) CocoPresentMemoryUnlock(strongSelf);
        }];
        [sheet addSecondary:localize(@"coco.ram.min.settings", nil) action:^{
            [weakSelf openSettings];
        }];
    } else {
        [sheet addPrimary:localize(@"coco.ram.min.settings", nil) action:^{
            [weakSelf openSettings];
        }];
    }
    [sheet addSecondary:localize(@"coco.home.first.later", nil) action:nil];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)presentFirstDownloadForName:(NSString *)name {
    NSString *message = name.length > 0
        ? [NSString stringWithFormat:localize(@"coco.home.first.message", nil), name, name]
        : localize(@"coco.home.first.message_noname", nil);
    [self presentBlockedSheet:message];
}

// Official Minecraft files are missing and no owner was verified on this
// device. The Local account stays selected; signing in with Microsoft only
// adds a separate account that confirms ownership for the download.
- (void)presentBlockedSheet:(NSString *)message {
    CocoSheetViewController *sheet = [CocoSheetViewController sheetWithTitle:localize(@"coco.home.first.title", nil) message:message];
    __weak CocoHomeViewController *weakSelf = self;
    [sheet addPrimary:localize(@"coco.home.retry", nil) action:^{
        [weakSelf playTapped];
    }];
    [sheet addSecondary:localize(@"coco.home.first.login", nil) action:^{
        [weakSelf loginMicrosoft];
    }];
    [sheet addSecondary:localize(@"coco.home.first.buy", nil) action:^{
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:@"https://www.minecraft.net/store/minecraft-java-bedrock-edition-pc"] options:@{} completionHandler:nil];
    }];
    [sheet addSecondary:localize(@"coco.home.first.later", nil) action:nil];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)prepareAndDownload {
    [self setBusy:YES title:localize(@"coco.home.busy.prepare", nil)];
    __weak CocoHomeViewController *weakSelf = self;
    [self ensureVersionList:^(BOOL ok) {
        CocoHomeViewController *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        if (!ok && ![strongSelf gameFilesPresent]) {
            [strongSelf setBusy:NO title:nil];
            [strongSelf restorePlayAccount];
            [strongSelf showError:localize(@"coco.home.error.versions", nil)];
            return;
        }
        [strongSelf startDownload];
    }];
}

- (void)ensureVersionList:(void (^)(BOOL ok))completion {
    if ([MinecraftResourceUtils findVersion:COCO_MINECRAFT_VERSION inList:remoteVersionList]) {
        completion(YES);
        return;
    }
    NSURLRequest *request = [NSURLRequest requestWithURL:[NSURL URLWithString:@"https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"]
        cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:30];
    [[NSURLSession.sharedSession dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![json isKindOfClass:NSDictionary.class] || ![json[@"versions"] isKindOfClass:NSArray.class]) {
                completion(NO);
                return;
            }
            remoteVersionList = @[
                @{@"id": @"latest-release", @"type": @"release"},
                @{@"id": @"latest-snapshot", @"type": @"snapshot"}
            ].mutableCopy;
            [remoteVersionList addObjectsFromArray:json[@"versions"]];
            if ([json[@"latest"] isKindOfClass:NSDictionary.class]) {
                setPrefObject(@"internal.latest_version", json[@"latest"]);
            }
            completion(YES);
        });
    }] resume];
}

- (void)startDownload {
    NSString *versionId = PLProfiles.current.profiles[COCO_PROFILE_NAME][@"lastVersionId"] ?: COCO_VERSION_ID;
    NSDictionary *object = (NSDictionary *)[MinecraftResourceUtils findVersion:versionId inList:remoteVersionList];
    if (object == nil) {
        object = @{@"id": versionId, @"type": @"custom"};
    }
    MinecraftResourceDownloadTask *task = [MinecraftResourceDownloadTask new];
    self.task = task;
    [self setBusy:YES title:localize(@"coco.home.busy.download", nil)];
    __weak CocoHomeViewController *weakSelf = self;
    __weak MinecraftResourceDownloadTask *weakTask = task;
    task.quietErrors = YES;
    task.handleError = ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf downloadFailed:weakTask];
        });
    };
    task.handleBlocked = ^(NSString *message) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf downloadFailed:weakTask];
        });
    };
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [task downloadVersion:object];
        dispatch_async(dispatch_get_main_queue(), ^{
            CocoHomeViewController *strongSelf = weakSelf;
            if (strongSelf == nil || strongSelf.task != task) {
                return;
            }
            strongSelf.observedProgress = task.progress;
            [task.progress addObserver:strongSelf forKeyPath:@"fractionCompleted"
                options:NSKeyValueObservingOptionInitial context:CocoProgressContext];
        });
    });
}

- (void)stopObservingProgress {
    if (self.observedProgress) {
        [self.observedProgress removeObserver:self forKeyPath:@"fractionCompleted" context:CocoProgressContext];
        self.observedProgress = nil;
    }
}

- (void)downloadFailed:(MinecraftResourceDownloadTask *)task {
    if (task == nil || self.task != task) {
        return;
    }
    [self stopObservingProgress];
    self.task = nil;
    [self setBusy:NO title:nil];
    [self restorePlayAccount];
    NSString *message = task.lastErrorMessage;
    if (message.length == 0) {
        return;
    }
    if (task.lastErrorBlocked) {
        [self presentBlockedSheet:message];
        return;
    }
    // Network or file errors: files already downloaded and verified are kept,
    // so Retry only fetches what is still missing.
    CocoSheetViewController *sheet = [CocoSheetViewController sheetWithTitle:localize(@"coco.home.error.title", nil) message:message];
    __weak CocoHomeViewController *weakSelf = self;
    [sheet addPrimary:localize(@"coco.home.retry", nil) action:^{
        [weakSelf playTapped];
    }];
    [sheet addSecondary:localize(@"coco.home.first.later", nil) action:nil];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context != CocoProgressContext) {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
        return;
    }
    NSProgress *progress = object;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self progressChanged:progress];
    });
}

- (void)progressChanged:(NSProgress *)progress {
    if (progress != self.observedProgress || self.task == nil) {
        return;
    }
    double fraction = progress.fractionCompleted;
    self.busyBar.progress = fraction;
    self.busyPercent.text = [NSString stringWithFormat:@"%d%%", (int)floor(fraction * 100)];

    // Speed and time left, the same way the Amethyst toolbar computes them
    NSProgress *text = self.task.textProgress;
    NSInteger completed = (NSInteger)(self.task.progress.totalUnitCount * fraction);
    text.completedUnitCount = completed;
    struct timeval tv;
    gettimeofday(&tv, NULL);
    if (self.lastSecond < tv.tv_sec) {
        double now = tv.tv_sec + tv.tv_usec / 1000000.0;
        if (self.lastTime > 0 && now > self.lastTime) {
            NSInteger throughput = (NSInteger)((completed - self.lastCompleted) / (now - self.lastTime));
            text.throughput = @(throughput);
            if (throughput > 0) {
                text.estimatedTimeRemaining = @((text.totalUnitCount - completed) / throughput);
            }
        }
        self.lastCompleted = completed;
        self.lastSecond = tv.tv_sec;
        self.lastTime = now;
    }
    self.busyDetail.text = text.localizedAdditionalDescription;

    if (!progress.finished) {
        return;
    }
    NSDictionary *metadata = self.task.metadata;
    [self stopObservingProgress];
    self.task = nil;
    [self restorePlayAccount];
    // Simulator workflow (cocoAutoPlay): stop after the install, the game needs JIT
    if (metadata == nil || [NSUserDefaults.standardUserDefaults boolForKey:@"cocoAutoPlay"]) {
        [self setBusy:NO title:nil];
        return;
    }
    self.busyTitle.text = localize(@"launcher.wait_jit.title", nil);
    self.busyPercent.text = @"";
    __weak CocoHomeViewController *weakSelf = self;
    [self runAfterJIT:^{
        CocoHomeViewController *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        [strongSelf setBusy:NO title:nil];
        UIKit_launchMinecraftSurfaceVC(strongSelf.view.window, metadata);
    } cancelled:^{
        [weakSelf setBusy:NO title:nil];
    }];
}

// Same as LauncherNavigationController's invokeAfterJITEnabled, with a cancel callback
- (void)runAfterJIT:(void (^)(void))handler cancelled:(void (^)(void))cancelled {
    BOOL hasTrollStoreJIT = getEntitlementValue(@"jb.pmap_cs.custom_trust");
    if (isJITEnabled(false)) {
        handler();
        return;
    } else if (hasTrollStoreJIT) {
        NSURL *jitURL = [NSURL URLWithString:[NSString stringWithFormat:@"apple-magnifier://enable-jit?bundle-id=%@", NSBundle.mainBundle.bundleIdentifier]];
        [UIApplication.sharedApplication openURL:jitURL options:@{} completionHandler:nil];
    } else if (getPrefBool(@"debug.debug_skip_wait_jit")) {
        NSLog(@"Debug option skipped waiting for JIT. Java might not work.");
        handler();
        return;
    } else if (@available(iOS 17.4, *)) {
        NSString *scriptDataString = @"";
        if (DeviceHasJITFlags(JIT_FLAG_FORCE_MIRRORED | JIT_FLAG_HAS_TXM)) {
            NSData *scriptData = [NSData dataWithContentsOfFile:[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"UniversalJIT26.js"]];
            scriptDataString = [@"&script-data=" stringByAppendingString:[scriptData base64EncodedStringWithOptions:0]];
        }
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:[NSString stringWithFormat:@"stikjit://enable-jit?bundle-id=%@&pid=%d%@", NSBundle.mainBundle.bundleIdentifier, getpid(), scriptDataString]] options:@{} completionHandler:nil];
    } else {
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:[NSString stringWithFormat:@"sidestore://sidejit-enable?pid=%d", getpid()]] options:@{} completionHandler:nil];
    }

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"launcher.wait_jit.title", nil)
        message:hasTrollStoreJIT ? localize(@"launcher.wait_jit_trollstore.message", nil) : localize(@"launcher.wait_jit.message", nil)
        preferredStyle:UIAlertControllerStyleAlert];
    __block BOOL stop = NO;
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"Cancel", nil) style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        stop = YES;
        if (cancelled) {
            cancelled();
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // After 45 s show what to check; give up after 10 minutes
        int ticks = 0;
        while (!isJITEnabled(false) && !stop) {
            usleep(1000 * 200);
            ticks++;
            if (ticks == 5 * 45) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    alert.message = localize(@"coco.jit.slow", nil);
                });
            } else if (ticks >= 5 * 600) {
                stop = YES;
                dispatch_async(dispatch_get_main_queue(), ^{
                    [alert dismissViewControllerAnimated:YES completion:^{
                        if (cancelled) {
                            cancelled();
                        }
                        showDialog(localize(@"launcher.wait_jit.title", nil), localize(@"coco.jit.timeout", nil));
                    }];
                });
            }
        }
        if (stop) {
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            [alert dismissViewControllerAnimated:YES completion:handler];
        });
    });
}

#pragma mark - Microsoft (only to download the game files once)

- (void)loginMicrosoft {
    NSURL *url = [NSURL URLWithString:@"https://login.live.com/oauth20_authorize.srf?client_id=00000000402b5328&response_type=code&scope=service%3A%3Auser.auth.xboxlive.com%3A%3AMBI_SSL&redirect_url=https%3A%2F%2Flogin.live.com%2Foauth20_desktop.srf"];
    __weak CocoHomeViewController *weakSelf = self;
    self.authSession = [[ASWebAuthenticationSession alloc] initWithURL:url callbackURLScheme:@"ms-xal-00000000402b5328"
        completionHandler:^(NSURL *callbackURL, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf finishMicrosoftLogin:callbackURL error:error];
        });
    }];
    self.authSession.prefersEphemeralWebBrowserSession = YES;
    self.authSession.presentationContextProvider = self;
    if (![self.authSession start]) {
        showDialog(localize(@"Error", nil), @"Unable to open Safari");
    }
}

- (ASPresentationAnchor)presentationAnchorForWebAuthenticationSession:(ASWebAuthenticationSession *)session {
    return self.view.window ?: UIApplication.sharedApplication.windows.firstObject;
}

- (void)finishMicrosoftLogin:(NSURL *)callbackURL error:(NSError *)error {
    if (callbackURL == nil) {
        if (error && error.code != ASWebAuthenticationSessionErrorCodeCanceledLogin) {
            showDialog(localize(@"Error", nil), error.localizedDescription);
        }
        return;
    }
    NSString *code = nil, *errorName = nil, *errorDescription = nil;
    for (NSURLQueryItem *item in [NSURLComponents componentsWithURL:callbackURL resolvingAgainstBaseURL:NO].queryItems) {
        if ([item.name isEqualToString:@"code"]) {
            code = item.value;
        } else if ([item.name isEqualToString:@"error"]) {
            errorName = item.value;
        } else if ([item.name isEqualToString:@"error_description"]) {
            errorDescription = item.value;
        }
    }
    if (code.length == 0) {
        if (![errorName hasPrefix:@"access_denied"] && errorDescription.length > 0) {
            showDialog(localize(@"Error", nil), errorDescription);
        }
        return;
    }
    [self setBusy:YES title:localize(@"coco.home.busy.login", nil)];
    __weak CocoHomeViewController *weakSelf = self;
    [[[MicrosoftAuthenticator alloc] initWithInput:code] loginWithCallback:^(id status, BOOL success) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf microsoftLoginStatus:status success:success];
        });
    }];
}

- (void)microsoftLoginStatus:(id)status success:(BOOL)success {
    if (!success) {
        [self setBusy:NO title:nil];
        [self restorePlayAccount];
        NSString *message = [status isKindOfClass:NSError.class] ? [status localizedDescription] : [status description];
        showDialog(localize(@"Error", nil), message);
        return;
    }
    if (status != nil) {
        // Progress messages while signing in
        if ([status isKindOfClass:NSString.class] && ![status isEqualToString:@"DEMO"]) {
            self.busyTitle.text = status;
        }
        return;
    }
    NSDictionary *auth = BaseAuthenticator.current.authData;
    if (auth[@"xboxGamertag"] == nil || [auth[@"username"] hasPrefix:@"Demo."]) {
        [self setBusy:NO title:nil];
        [self restorePlayAccount];
        CocoSheetViewController *sheet = [CocoSheetViewController sheetWithTitle:localize(@"coco.home.demo.title", nil)
            message:localize(@"coco.home.demo.message", nil)];
        [sheet addSecondary:localize(@"OK", nil) action:nil];
        [self presentViewController:sheet animated:YES completion:nil];
        return;
    }
    // The Microsoft account is saved on its own; the player keeps the account
    // they chose (Local stays Local, no token is copied or converted).
    [self restorePlayAccount];
    [self refreshNameNote];
    [self prepareAndDownload];
}

@end
