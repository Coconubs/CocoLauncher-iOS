#import "CocoConfig.h"
#import "CocoHomeViewController.h"
#import "CocoPerformance.h"
#import "CocoSettingsViewController.h"
#import "CocoUI.h"
#import "CustomControlsViewController.h"
#import "LauncherPreferences.h"
#import "LauncherPreferencesViewController.h"
#import "PLProfiles.h"
#import "utils.h"

@interface CocoSettingsViewController ()
@property(nonatomic) UIView *card;
@property(nonatomic) UIStackView *columns;
@property(nonatomic) BOOL narrowLayout;
@property(nonatomic) BOOL layoutModeSet;

@property(nonatomic) CocoSlider *ramSlider;
@property(nonatomic) UILabel *ramValue;
@property(nonatomic) UILabel *ramNote;
@property(nonatomic) UILabel *ramEntitlement;
@property(nonatomic) int ramStep;

@property(nonatomic) CocoSlider *resolutionSlider;
@property(nonatomic) UILabel *resolutionValue;

@property(nonatomic) NSArray<CocoOptionButton *> *presetButtons;
@property(nonatomic) UILabel *presetNote;
@property(nonatomic) NSArray<CocoOptionButton *> *rendererButtons;
@property(nonatomic) NSArray<CocoOptionButton *> *fpsButtons;
@property(nonatomic) UIButton *verifyButton;
@end

static NSArray<NSString *> *CocoPresetKeys(void) {
    return @[COCO_PRESET_LOW, COCO_PRESET_BALANCED, COCO_PRESET_HIGH];
}

static NSArray<NSString *> *CocoRendererKeys(void) {
    return @[@ RENDERER_NAME_MOBILEGLUES, @ RENDERER_NAME_MTL_ANGLE, @ RENDERER_NAME_VK_ZINK];
}

@implementation CocoSettingsViewController

- (instancetype)init {
    self = [super init];
    if (self) {
        self.modalPresentationStyle = UIModalPresentationOverFullScreen;
        self.modalTransitionStyle = UIModalTransitionStyleCrossDissolve;
        self.ramStep = 128;
    }
    return self;
}

#pragma mark - Building blocks

- (UIStackView *)verticalStack:(CGFloat)spacing {
    UIStackView *stack = [UIStackView new];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = spacing;
    return stack;
}

- (UIView *)headerRow:(NSString *)title value:(UILabel *)value {
    UIStackView *row = [UIStackView new];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 8;
    UILabel *label = CocoLabel(title, CocoFontSemiBold, 17, COCO_INK);
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.8;
    [row addArrangedSubview:label];
    if (value) {
        [value setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [value setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [row addArrangedSubview:value];
    }
    return row;
}

- (UILabel *)noteLabel:(NSString *)text {
    UILabel *label = CocoLabel(text, CocoFontRegular, 14, COCO_DIM);
    label.numberOfLines = 0;
    return label;
}

- (NSArray<CocoOptionButton *> *)optionButtons:(NSArray<NSString *> *)titles action:(SEL)action inRow:(UIStackView **)rowOut {
    UIStackView *row = [UIStackView new];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.axis = UILayoutConstraintAxisHorizontal;
    row.distribution = UIStackViewDistributionFillEqually;
    row.spacing = 10;
    NSMutableArray<CocoOptionButton *> *buttons = [NSMutableArray new];
    for (NSUInteger i = 0; i < titles.count; i++) {
        CocoOptionButton *button = [[CocoOptionButton alloc] initWithFrame:CGRectZero];
        [button setTitle:titles[i] forState:UIControlStateNormal];
        button.tag = (NSInteger)i;
        [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
        [button.heightAnchor constraintEqualToConstant:52].active = YES;
        [row addArrangedSubview:button];
        [buttons addObject:button];
    }
    *rowOut = row;
    return buttons;
}

- (CocoRowButton *)rowButton:(NSString *)title action:(SEL)action {
    CocoRowButton *button = [[CocoRowButton alloc] initWithFrame:CGRectZero];
    [button setTitle:title forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [button.heightAnchor constraintEqualToConstant:54].active = YES;
    return button;
}

#pragma mark - View

- (void)viewDidLoad {
    [super viewDidLoad];
    CocoRegisterFonts();
    self.view.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];

    UIControl *backdrop = [UIControl new];
    backdrop.translatesAutoresizingMaskIntoConstraints = NO;
    [backdrop addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:backdrop];

    UIView *card = [UIView new];
    card.translatesAutoresizingMaskIntoConstraints = NO;
    CocoStyleBox(card, COCO_PANEL, CocoColor(0x1AFFFFFF), 20);
    card.clipsToBounds = YES;
    [self.view addSubview:card];
    self.card = card;

    // Header
    UILabel *title = CocoLabel(localize(@"coco.settings.title", nil), CocoFontExtraBold, 26, COCO_INK);
    UIButton *closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    closeButton.translatesAutoresizingMaskIntoConstraints = NO;
    [closeButton setImage:CocoIcon(@"close") forState:UIControlStateNormal];
    closeButton.tintColor = COCO_INK;
    closeButton.accessibilityLabel = localize(@"coco.settings.close", nil);
    CocoStyleBox(closeButton, UIColor.clearColor, CocoColor(0x24FFFFFF), 14);
    [closeButton addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:title];
    [card addSubview:closeButton];

    UIView *topLine = [UIView new];
    topLine.translatesAutoresizingMaskIntoConstraints = NO;
    topLine.backgroundColor = CocoColor(0x14FFFFFF);
    [card addSubview:topLine];

    // Body
    UIScrollView *scroll = [UIScrollView new];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.indicatorStyle = UIScrollViewIndicatorStyleWhite;
    scroll.alwaysBounceVertical = NO;
    [card addSubview:scroll];

    UIStackView *columns = [UIStackView new];
    columns.translatesAutoresizingMaskIntoConstraints = NO;
    columns.axis = UILayoutConstraintAxisHorizontal;
    columns.alignment = UIStackViewAlignmentTop;
    columns.distribution = UIStackViewDistributionFillEqually;
    columns.spacing = 32;
    [scroll addSubview:columns];
    self.columns = columns;
    [columns addArrangedSubview:[self buildLeftColumn]];
    [columns addArrangedSubview:[self buildRightColumn]];

    // Footer
    UIView *bottomLine = [UIView new];
    bottomLine.translatesAutoresizingMaskIntoConstraints = NO;
    bottomLine.backgroundColor = CocoColor(0x14FFFFFF);
    [card addSubview:bottomLine];

    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    UILabel *about = CocoLabel([NSString stringWithFormat:localize(@"coco.settings.about", nil), version], CocoFontRegular, 15, COCO_DIM);
    about.numberOfLines = 2;
    [card addSubview:about];

    self.verifyButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.verifyButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.verifyButton setTitle:localize(@"coco.settings.verify", nil) forState:UIControlStateNormal];
    [self.verifyButton setTitleColor:COCO_ORANGE forState:UIControlStateNormal];
    [self.verifyButton setTitleColor:COCO_GREEN forState:UIControlStateDisabled];
    self.verifyButton.titleLabel.font = CocoFont(CocoFontSemiBold, 15);
    self.verifyButton.titleLabel.adjustsFontSizeToFitWidth = YES;
    self.verifyButton.titleLabel.minimumScaleFactor = 0.7;
    [self.verifyButton setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.verifyButton addTarget:self action:@selector(verifyFiles) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:self.verifyButton];

    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    NSLayoutConstraint *preferredWidth = [card.widthAnchor constraintEqualToConstant:900];
    preferredWidth.priority = UILayoutPriorityDefaultHigh;
    // Below the labels' compression resistance (750): when the card can't grow,
    // the body scrolls instead of squashing labels
    NSLayoutConstraint *fitHeight = [scroll.heightAnchor constraintEqualToAnchor:columns.heightAnchor constant:48];
    fitHeight.priority = 500;
    [NSLayoutConstraint activateConstraints:@[
        [backdrop.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [backdrop.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [backdrop.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [backdrop.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],

        [card.centerXAnchor constraintEqualToAnchor:safe.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:safe.centerYAnchor],
        [card.widthAnchor constraintLessThanOrEqualToAnchor:safe.widthAnchor constant:-24],
        [card.heightAnchor constraintLessThanOrEqualToAnchor:safe.heightAnchor constant:-16],
        preferredWidth,

        [title.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:28],
        [title.centerYAnchor constraintEqualToAnchor:closeButton.centerYAnchor],
        [title.trailingAnchor constraintLessThanOrEqualToAnchor:closeButton.leadingAnchor constant:-12],
        [closeButton.topAnchor constraintEqualToAnchor:card.topAnchor constant:14],
        [closeButton.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-28],
        [closeButton.widthAnchor constraintEqualToConstant:52],
        [closeButton.heightAnchor constraintEqualToConstant:52],
        [topLine.topAnchor constraintEqualToAnchor:closeButton.bottomAnchor constant:14],
        [topLine.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [topLine.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [topLine.heightAnchor constraintEqualToConstant:1],

        [scroll.topAnchor constraintEqualToAnchor:topLine.bottomAnchor],
        [scroll.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:bottomLine.topAnchor],
        fitHeight,
        [columns.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:24],
        [columns.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-24],
        [columns.leadingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.leadingAnchor constant:28],
        [columns.trailingAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.trailingAnchor constant:-28],

        [bottomLine.leadingAnchor constraintEqualToAnchor:card.leadingAnchor],
        [bottomLine.trailingAnchor constraintEqualToAnchor:card.trailingAnchor],
        [bottomLine.heightAnchor constraintEqualToConstant:1],
        [bottomLine.bottomAnchor constraintEqualToAnchor:about.topAnchor constant:-16],
        [about.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:28],
        [about.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-18],
        [about.trailingAnchor constraintLessThanOrEqualToAnchor:self.verifyButton.leadingAnchor constant:-12],
        [self.verifyButton.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-28],
        [self.verifyButton.centerYAnchor constraintEqualToAnchor:about.centerYAnchor],
    ]];

    [self refreshValues];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    BOOL narrow = self.card.bounds.size.width < 640;
    if (!self.layoutModeSet || narrow != self.narrowLayout) {
        self.layoutModeSet = YES;
        self.narrowLayout = narrow;
        // Portrait phone: one column
        self.columns.axis = narrow ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal;
        self.columns.alignment = narrow ? UIStackViewAlignmentFill : UIStackViewAlignmentTop;
        self.columns.spacing = narrow ? 26 : 32;
    }
}

- (UIView *)buildLeftColumn {
    UIStackView *column = [self verticalStack:10];

    // Game memory
    self.ramValue = CocoLabel(@"", CocoFontExtraBold, 17, COCO_ORANGE);
    [column addArrangedSubview:[self headerRow:localize(@"coco.settings.ram", nil) value:self.ramValue]];
    self.ramSlider = [[CocoSlider alloc] initWithFrame:CGRectZero];
    int deviceMB = CocoDeviceMemoryMB();
    int maxMB = MAX((int)(deviceMB * 0.85) / self.ramStep * self.ramStep, 1024);
    self.ramSlider.minimumValue = 1024;
    self.ramSlider.maximumValue = maxMB;
    [self.ramSlider.heightAnchor constraintEqualToConstant:34].active = YES;
    [self.ramSlider addTarget:self action:@selector(ramChanged:) forControlEvents:UIControlEventValueChanged];
    [column addArrangedSubview:self.ramSlider];
    self.ramNote = [self noteLabel:@""];
    [column addArrangedSubview:self.ramNote];

    // A label (not a button) so that two lines get their full height
    self.ramEntitlement = CocoLabel(@"", CocoFontSemiBold, 13, COCO_GOLD);
    self.ramEntitlement.numberOfLines = 0;
    self.ramEntitlement.userInteractionEnabled = YES;
    self.ramEntitlement.accessibilityTraits = UIAccessibilityTraitButton;
    [self.ramEntitlement addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(showMemoryHelp)]];
    [column addArrangedSubview:self.ramEntitlement];
    [column setCustomSpacing:4 afterView:self.ramNote];

    UIView *gap1 = [UIView new];
    [gap1.heightAnchor constraintEqualToConstant:12].active = YES;
    [column addArrangedSubview:gap1];

    // Resolution
    self.resolutionValue = CocoLabel(@"", CocoFontExtraBold, 17, COCO_ORANGE);
    [column addArrangedSubview:[self headerRow:localize(@"coco.settings.resolution", nil) value:self.resolutionValue]];
    self.resolutionSlider = [[CocoSlider alloc] initWithFrame:CGRectZero];
    self.resolutionSlider.minimumValue = 25;
    self.resolutionSlider.maximumValue = 100;
    [self.resolutionSlider.heightAnchor constraintEqualToConstant:34].active = YES;
    [self.resolutionSlider addTarget:self action:@selector(resolutionChanged:) forControlEvents:UIControlEventValueChanged];
    [column addArrangedSubview:self.resolutionSlider];
    [column addArrangedSubview:[self noteLabel:localize(@"coco.settings.resolution_note", nil)]];

    UIView *gap2 = [UIView new];
    [gap2.heightAnchor constraintEqualToConstant:12].active = YES;
    [column addArrangedSubview:gap2];

    // Performance preset
    [column addArrangedSubview:[self headerRow:localize(@"coco.settings.preset", nil) value:nil]];
    UIStackView *presetRow = nil;
    self.presetButtons = [self optionButtons:@[localize(@"coco.preset.low", nil), localize(@"coco.preset.balanced", nil), localize(@"coco.preset.high", nil)]
        action:@selector(presetTapped:) inRow:&presetRow];
    [column addArrangedSubview:presetRow];
    self.presetNote = [self noteLabel:@""];
    [column addArrangedSubview:self.presetNote];
    return column;
}

- (UIView *)buildRightColumn {
    UIStackView *column = [self verticalStack:10];

    // Renderer
    [column addArrangedSubview:[self headerRow:localize(@"coco.settings.renderer", nil) value:nil]];
    UIStackView *rendererRow = nil;
    self.rendererButtons = [self optionButtons:@[localize(@"coco.settings.renderer_auto", nil), @"ANGLE", @"Zink"]
        action:@selector(rendererTapped:) inRow:&rendererRow];
    [column addArrangedSubview:rendererRow];
    [column addArrangedSubview:[self noteLabel:localize(@"coco.settings.renderer_note", nil)]];

    // 120 Hz, only on ProMotion screens
    if (UIScreen.mainScreen.maximumFramesPerSecond > 60) {
        UIView *gap = [UIView new];
        [gap.heightAnchor constraintEqualToConstant:12].active = YES;
        [column addArrangedSubview:gap];
        [column addArrangedSubview:[self headerRow:localize(@"coco.settings.fps", nil) value:nil]];
        UIStackView *fpsRow = nil;
        self.fpsButtons = [self optionButtons:@[@"60 Hz", @"120 Hz"] action:@selector(fpsTapped:) inRow:&fpsRow];
        [column addArrangedSubview:fpsRow];
        [column addArrangedSubview:[self noteLabel:localize(@"coco.settings.fps_note", nil)]];
    }

    UIView *gap = [UIView new];
    [gap.heightAnchor constraintEqualToConstant:8].active = YES;
    [column addArrangedSubview:gap];
    [column addArrangedSubview:[self rowButton:localize(@"coco.settings.controls", nil) action:@selector(openControls)]];
    [column addArrangedSubview:[self rowButton:localize(@"coco.settings.folder", nil) action:@selector(openFolder)]];
    [column addArrangedSubview:[self rowButton:localize(@"coco.settings.send_log", nil) action:@selector(sendLog:)]];
    [column addArrangedSubview:[self rowButton:localize(@"coco.settings.advanced", nil) action:@selector(openAdvanced)]];
    return column;
}

#pragma mark - Values

- (NSString *)currentRenderer {
    NSString *renderer = PLProfiles.current.profiles[COCO_PROFILE_NAME][@"renderer"];
    if (renderer.length == 0) {
        renderer = getPrefObject(@"video.renderer");
    }
    return renderer;
}

- (void)refreshValues {
    int ram = (int)getPrefInt(@"java.allocated_memory");
    self.ramSlider.value = ram;
    [self updateRamTexts:ram];

    int resolution = MIN((int)getPrefInt(@"video.resolution"), 100);
    self.resolutionSlider.value = resolution;
    self.resolutionValue.text = [NSString stringWithFormat:@"%d %%", resolution];

    [self updatePresetButtons];

    NSString *renderer = [self currentRenderer];
    NSArray<NSString *> *rendererKeys = CocoRendererKeys();
    for (CocoOptionButton *button in self.rendererButtons) {
        button.selected = [rendererKeys[(NSUInteger)button.tag] isEqualToString:renderer];
    }

    BOOL highFps = getPrefBool(@"video.max_framerate");
    for (CocoOptionButton *button in self.fpsButtons) {
        button.selected = (button.tag == 1) == highFps;
    }
}

- (void)updateRamTexts:(int)ram {
    self.ramValue.text = [NSString stringWithFormat:@"%d MB", ram];
    int limit = CocoProcessMemoryLimitMB();
    NSString *limitText = [NSString stringWithFormat:@"%.1f GB", limit / 1024.0];
    NSString *note = limit > 0
        ? [NSString stringWithFormat:localize(@"coco.settings.ram_note", nil), CocoDeviceMemoryMB() / 1024.0, limitText, CocoRecommendedHeapMB()]
        : [NSString stringWithFormat:localize(@"coco.settings.ram_note_nolimit", nil), CocoDeviceMemoryMB() / 1024.0, CocoRecommendedHeapMB()];
    BOOL tooHigh = ram > CocoSafeMaxHeapMB();
    if (tooHigh) {
        note = [note stringByAppendingFormat:@"\n%@", localize(@"coco.memory.too_high", nil)];
    }
    self.ramNote.text = note;
    self.ramNote.textColor = tooHigh ? COCO_RED : COCO_DIM;

    BOOL entitled = CocoHasIncreasedMemoryLimit();
    self.ramEntitlement.text = localize(entitled ? @"coco.settings.ram_entitlement_on" : @"coco.settings.ram_entitlement_off", nil);
    self.ramEntitlement.textColor = entitled ? COCO_GREEN : COCO_GOLD;
}

- (void)updatePresetButtons {
    NSString *preset = getPrefObject(@"video.quality_preset");
    NSArray<NSString *> *keys = CocoPresetKeys();
    for (CocoOptionButton *button in self.presetButtons) {
        button.selected = [keys[(NSUInteger)button.tag] isEqualToString:preset];
    }
    NSString *noteKey = [NSString stringWithFormat:@"coco.settings.preset_note.%@", [keys containsObject:preset] ? preset : COCO_PRESET_CUSTOM];
    self.presetNote.text = localize(noteKey, nil);
}

#pragma mark - Actions

- (void)ramChanged:(CocoSlider *)slider {
    int value = (int)(roundf(slider.value / self.ramStep) * self.ramStep);
    value = MAX(1024, MIN(value, (int)slider.maximumValue));
    setPrefObject(@"java.allocated_memory", @(value));
    [self updateRamTexts:value];
}

- (void)resolutionChanged:(CocoSlider *)slider {
    int value = (int)(roundf(slider.value / 5) * 5);
    setPrefObject(@"video.resolution", @(value));
    self.resolutionValue.text = [NSString stringWithFormat:@"%d %%", value];
    if (![getPrefObject(@"video.quality_preset") isEqualToString:COCO_PRESET_CUSTOM]) {
        setPrefObject(@"video.quality_preset", COCO_PRESET_CUSTOM);
        [self updatePresetButtons];
    }
}

- (void)presetTapped:(CocoOptionButton *)sender {
    CocoApplyPreset(CocoPresetKeys()[(NSUInteger)sender.tag]);
    [self refreshValues];
}

- (void)rendererTapped:(CocoOptionButton *)sender {
    NSString *key = CocoRendererKeys()[(NSUInteger)sender.tag];
    PLProfiles *profiles = PLProfiles.current;
    NSMutableDictionary *list = [NSMutableDictionary dictionaryWithDictionary:profiles.profiles ?: @{}];
    if (list[COCO_PROFILE_NAME] == nil) {
        return;
    }
    NSMutableDictionary *coco = [NSMutableDictionary dictionaryWithDictionary:list[COCO_PROFILE_NAME]];
    coco[@"renderer"] = key;
    list[COCO_PROFILE_NAME] = coco;
    profiles.profileDict[@"profiles"] = (id)list;
    [profiles save];
    [self refreshValues];
}

- (void)fpsTapped:(CocoOptionButton *)sender {
    setPrefBool(@"video.max_framerate", sender.tag == 1);
    setPrefObject(@"video.quality_preset", COCO_PRESET_CUSTOM);
    [self refreshValues];
}

- (void)showMemoryHelp {
    CocoSheetViewController *sheet = [CocoSheetViewController sheetWithTitle:localize(@"preference.title.memory_status", nil)
        message:localize(CocoHasIncreasedMemoryLimit() ? @"coco.memory.help.on" : @"coco.memory.help.off", nil)];
    [sheet addSecondary:localize(@"OK", nil) action:nil];
    [self presentViewController:sheet animated:YES completion:nil];
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

- (void)sendLog:(UIView *)sender {
    NSMutableArray<NSURL *> *files = [NSMutableArray new];
    for (NSString *name in @[@"latestlog.txt", @"latestlog.old.txt"]) {
        NSString *path = [NSString stringWithFormat:@"%s/%@", getenv("AME_HOME"), name];
        if ([NSFileManager.defaultManager fileExistsAtPath:path]) {
            [files addObject:[NSURL fileURLWithPath:path]];
        }
    }
    if (files.count == 0) {
        CocoSheetViewController *sheet = [CocoSheetViewController sheetWithTitle:localize(@"coco.settings.send_log", nil)
            message:localize(@"coco.settings.no_log", nil)];
        [sheet addSecondary:localize(@"OK", nil) action:nil];
        [self presentViewController:sheet animated:YES completion:nil];
        return;
    }
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:files applicationActivities:nil];
    share.popoverPresentationController.sourceView = sender;
    share.popoverPresentationController.sourceRect = sender.bounds;
    [self presentViewController:share animated:YES completion:nil];
}

- (void)openAdvanced {
    LauncherPreferencesViewController *vc = [LauncherPreferencesViewController new];
    vc.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
        target:self action:@selector(closeAdvanced)];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:vc];
    nav.modalPresentationStyle = UIModalPresentationFormSheet;
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)closeAdvanced {
    [self dismissViewControllerAnimated:YES completion:^{
        [self refreshValues];
    }];
}

- (void)verifyFiles {
    // The Coco pack files are always checked against the manifest (SHA-1);
    // this also turns the check back on for the Minecraft files.
    setPrefBool(@"general.check_sha", YES);
    [self.verifyButton setTitle:localize(@"coco.settings.verify_done", nil) forState:UIControlStateDisabled];
    self.verifyButton.enabled = NO;
}

- (void)close {
    void (^onClose)(void) = self.onClose;
    [self dismissViewControllerAnimated:YES completion:^{
        if (onClose) {
            onClose();
        }
    }];
}

@end
