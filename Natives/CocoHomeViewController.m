#import <AuthenticationServices/AuthenticationServices.h>
#import <SafariServices/SafariServices.h>
#include <sys/time.h>
#include <unistd.h>

#import "authenticator/BaseAuthenticator.h"
#import "CocoConfig.h"
#import "CocoHomeViewController.h"
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

+ (void)openGameFolderFrom:(UIViewController *)viewController {
    NSString *path = [self gameFolderPath];
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
    NSString *path = [NSString stringWithFormat:@"%s/accounts/%@.json", getenv("AME_HOME"), name];
    return [NSFileManager.defaultManager fileExistsAtPath:path];
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
    [self refreshMeta];
    [self startPing];
    if (!self.didAppearOnce) {
        self.didAppearOnce = YES;
        [self checkInstallation];
        [self runPreviewHooks];
    }
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
- (BaseAuthenticator *)accountForName:(NSString *)name {
    if ([self accountExists:name]) {
        return [BaseAuthenticator loadSavedName:name];
    }
    LocalAuthenticator *local = [[LocalAuthenticator alloc] initWithInput:name];
    __block BOOL saved = NO;
    [local loginWithCallback:^(id status, BOOL success) {
        saved = success;
    }];
    return saved ? local : nil;
}

// A saved Microsoft account that owns Minecraft (needed to download the game files once)
- (NSString *)savedOwnerAccount {
    NSString *dir = [NSString stringWithFormat:@"%s/accounts", getenv("AME_HOME")];
    for (NSString *file in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil]) {
        if (![file.pathExtension isEqualToString:@"json"]) {
            continue;
        }
        NSData *data = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:file]];
        NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        if (![json isKindOfClass:NSDictionary.class]) {
            continue;
        }
        NSString *username = json[@"username"];
        if ([username isKindOfClass:NSString.class] && ![username hasPrefix:@"Demo."] && json[@"xboxGamertag"] != nil) {
            return username;
        }
    }
    return nil;
}

- (BOOL)gameFilesPresent {
    NSString *jar = [NSString stringWithFormat:@"%1$s/versions/%2$@/%2$@.jar", getenv("GAME_DIR"), COCO_MINECRAFT_VERSION];
    return [NSFileManager.defaultManager fileExistsAtPath:jar];
}

- (void)restorePlayAccount {
    if (self.playName.length == 0) {
        return;
    }
    if (![BaseAuthenticator.current.authData[@"username"] isEqualToString:self.playName]) {
        [BaseAuthenticator loadSavedName:self.playName];
    }
    setPrefObject(@"internal.selected_account", self.playName);
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
    setPrefObject(@"internal.selected_account", name);
    [self refreshNameNote];

    if ([account isKindOfClass:MicrosoftAuthenticator.class] || [self gameFilesPresent]) {
        [self prepareAndDownload];
        return;
    }
    // The Minecraft files are not on this device yet: they can only be
    // downloaded with an account that owns the game (checked by the download task).
    NSString *owner = [self savedOwnerAccount];
    if (owner) {
        [BaseAuthenticator loadSavedName:owner];
        [self prepareAndDownload];
    } else {
        [self presentFirstDownloadForName:name];
    }
}

- (void)presentFirstDownloadForName:(NSString *)name {
    NSString *message = name.length > 0
        ? [NSString stringWithFormat:localize(@"coco.home.first.message", nil), name]
        : localize(@"coco.home.first.message_noname", nil);
    CocoSheetViewController *sheet = [CocoSheetViewController sheetWithTitle:localize(@"coco.home.first.title", nil) message:message];
    __weak CocoHomeViewController *weakSelf = self;
    [sheet addPrimary:localize(@"coco.home.first.login", nil) action:^{
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
    task.handleError = ^{
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
    if (metadata == nil) {
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
    // Owner account selected: download the game, then play as the typed name
    [self prepareAndDownload];
}

@end
