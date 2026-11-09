#import "CocoConfig.h"
#import "CocoHomeViewController.h"
#import "CocoPerformance.h"
#import "CocoMemoryUnlock.h"
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
@property(nonatomic) CocoRowButton *overSafeButton;
@property(nonatomic) CocoRowButton *mfDynamicButton;
@property(nonatomic) CocoRowButton *recordingHideButton;
@property(nonatomic) UILabel *ramEntitlement;
@property(nonatomic) int ramStep;

@property(nonatomic) CocoSlider *resolutionSlider;
@property(nonatomic) UILabel *resolutionValue;

@property(nonatomic) NSArray<CocoOptionButton *> *presetButtons;
@property(nonatomic) UILabel *presetNote;
@property(nonatomic) NSArray<CocoOptionButton *> *rendererButtons;
@property(nonatomic) NSArray<CocoOptionButton *> *fpsButtons;
@property(nonatomic) NSArray<CocoRowButton *> *mgButtons;
@property(nonatomic) UIButton *verifyButton;
@property(nonatomic) UIStackView *footer;
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
    about.adjustsFontSizeToFitWidth = YES;
    about.minimumScaleFactor = 0.6;

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

    // Side by side when wide, stacked on a portrait phone (see viewDidLayoutSubviews)
    UIStackView *footer = [UIStackView new];
    footer.translatesAutoresizingMaskIntoConstraints = NO;
    footer.axis = UILayoutConstraintAxisHorizontal;
    footer.alignment = UIStackViewAlignmentCenter;
    footer.distribution = UIStackViewDistributionEqualSpacing;
    footer.spacing = 12;
    [footer addArrangedSubview:about];
    [footer addArrangedSubview:self.verifyButton];
    [card addSubview:footer];
    self.footer = footer;

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
        [bottomLine.bottomAnchor constraintEqualToAnchor:footer.topAnchor constant:-14],
        [footer.leadingAnchor constraintEqualToAnchor:card.leadingAnchor constant:28],
        [footer.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-28],
        [footer.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-16],
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
        self.footer.axis = narrow ? UILayoutConstraintAxisVertical : UILayoutConstraintAxisHorizontal;
        self.footer.alignment = narrow ? UIStackViewAlignmentLeading : UIStackViewAlignmentCenter;
        self.footer.spacing = narrow ? 4 : 12;
    }
}

- (UIView *)buildLeftColumn {
    UIStackView *column = [self verticalStack:10];

    // Game memory
    self.ramValue = CocoLabel(@"", CocoFontExtraBold, 17, COCO_ORANGE);
    [column addArrangedSubview:[self headerRow:localize(@"coco.settings.ram", nil) value:self.ramValue]];
    self.ramSlider = [[CocoSlider alloc] initWithFrame:CGRectZero];
    // Without the increased memory limit entitlement: never above the safe maximum
    int maxMB = CocoMaxSelectableHeapMB();
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
    // Only without the increased memory limit entitlement: allow a heap above the safe maximum
    if (CocoLacksMemoryEntitlement()) {
        // In-app GetMoreRam: turn on Increased Memory Limit for this App ID (Natives/cocoram)
        [column addArrangedSubview:[self rowButton:localize(@"coco.unlock.row", nil) action:@selector(memoryUnlockTapped)]];
        self.overSafeButton = [self rowButton:@"" action:@selector(overSafeTapped)];
        [column addArrangedSubview:self.overSafeButton];
    }
    self.mfDynamicButton = [self rowButton:@"" action:@selector(mfDynamicTapped)];
    [column addArrangedSubview:self.mfDynamicButton];

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

    // Advanced graphics: MobileGlues settings (config.json), one row per option + reset
    UIView *mgGap = [UIView new];
    [mgGap.heightAnchor constraintEqualToConstant:12].active = YES;
    [column addArrangedSubview:mgGap];
    [column addArrangedSubview:[self headerRow:localize(@"coco.mg.title", nil) value:nil]];
    NSMutableArray<CocoRowButton *> *mgButtons = [NSMutableArray new];
    NSArray<NSDictionary *> *mgOptions = CocoMGOptions();
    for (NSUInteger i = 0; i < mgOptions.count; i++) {
        CocoRowButton *button = [self rowButton:@"" action:@selector(mgOptionTapped:)];
        button.tag = (NSInteger)i;
        [column addArrangedSubview:button];
        [mgButtons addObject:button];
    }
    self.mgButtons = mgButtons;
    [column addArrangedSubview:[self rowButton:localize(@"coco.mg.reset_all", nil) action:@selector(mgResetAllTapped)]];
    [column addArrangedSubview:[self noteLabel:localize(@"coco.mg.note", nil)]];

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
    // On-screen buttons in screenshots / screen recordings / livestreams
    self.recordingHideButton = [self rowButton:@"" action:@selector(recordingHideTapped)];
    [column addArrangedSubview:self.recordingHideButton];
    [column addArrangedSubview:[self noteLabel:localize(@"coco.settings.recording_hide_note", nil)]];
    [column addArrangedSubview:[self rowButton:localize(@"coco.settings.folder", nil) action:@selector(openFolder)]];
    [column addArrangedSubview:[self rowButton:localize(@"coco.settings.sidemods", nil) action:@selector(openSideMods)]];
    [column addArrangedSubview:[self noteLabel:localize(@"coco.settings.sidemods_note", nil)]];
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
    CocoClampSavedHeap();
    int ram = (int)getPrefInt(@"java.allocated_memory");
    self.ramSlider.maximumValue = CocoMaxSelectableHeapMB();
    self.ramSlider.value = ram;
    if (self.overSafeButton) {
        [self.overSafeButton setTitle:[NSString stringWithFormat:localize(@"coco.memory.over_safe", nil),
            localize(getPrefBool(@"java.coco_allow_over_safe") ? @"coco.mg.val.on" : @"coco.mg.val.off", nil)]
            forState:UIControlStateNormal];
    }
    [self.mfDynamicButton setTitle:[NSString stringWithFormat:localize(@"coco.memory.mf_dynamic", nil),
        localize(getPrefBool(@"java.coco_mf_dynamic_resources") ? @"coco.mg.val.on" : @"coco.mg.val.off", nil)]
        forState:UIControlStateNormal];
    [self updateRamTexts:ram];
    [self.recordingHideButton setTitle:[NSString stringWithFormat:localize(@"coco.settings.recording_hide", nil),
        localize(getPrefBool(@"control.recording_hide") ? @"coco.settings.recording_hide.hidden" : @"coco.settings.recording_hide.shown", nil)]
        forState:UIControlStateNormal];

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

    NSArray<NSDictionary *> *mgOptions = CocoMGOptions();
    for (CocoRowButton *button in self.mgButtons) {
        NSDictionary *option = mgOptions[(NSUInteger)button.tag];
        NSString *label = localize([NSString stringWithFormat:@"coco.mg.opt.%@", option[@"id"]], nil);
        [button setTitle:[NSString stringWithFormat:@"%@: %@", label, CocoMGValueName(option, CocoMGValue(option))]
            forState:UIControlStateNormal];
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
    } else if (CocoHeapCappedToSafeMax()) {
        note = [note stringByAppendingFormat:@"\n%@",
            [NSString stringWithFormat:localize(@"coco.memory.capped", nil), CocoMaxSelectableHeapMB()]];
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

- (void)mgOptionTapped:(CocoRowButton *)sender {
    NSArray<NSDictionary *> *mgOptions = CocoMGOptions();
    if (sender.tag < 0 || (NSUInteger)sender.tag >= mgOptions.count) {
        return;
    }
    NSDictionary *option = mgOptions[(NSUInteger)sender.tag];
    NSString *optionId = option[@"id"];
    CocoSheetViewController *sheet = [CocoSheetViewController
        sheetWithTitle:localize([NSString stringWithFormat:@"coco.mg.opt.%@", optionId], nil)
        message:localize([NSString stringWithFormat:@"coco.mg.help.%@", optionId], nil)];
    int current = CocoMGValue(option);
    int def = [option[@"def"] intValue];
    __weak CocoSettingsViewController *weakSelf = self;
    for (NSNumber *value in option[@"values"]) {
        NSString *title = CocoMGValueName(option, value.intValue);
        if (value.intValue == def) {
            title = [title stringByAppendingString:localize(@"coco.mg.default_suffix", nil)];
        }
        if (value.intValue == current) {
            title = [@"\u2713 " stringByAppendingString:title];
        }
        [sheet addSecondary:title action:^{
            CocoSetMGValue(option, value.intValue);
            [weakSelf refreshValues];
        }];
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)overSafeTapped {
    __weak CocoSettingsViewController *weakSelf = self;
    if (getPrefBool(@"java.coco_allow_over_safe")) {
        setPrefBool(@"java.coco_allow_over_safe", NO);
        CocoClampSavedHeap();
        [self refreshValues];
        return;
    }
    CocoSheetViewController *sheet = [CocoSheetViewController sheetWithTitle:localize(@"coco.memory.over_safe_title", nil)
        message:[NSString stringWithFormat:localize(@"coco.memory.over_safe_warning", nil), CocoSafeMaxHeapMB()]];
    [sheet addPrimary:localize(@"coco.memory.over_safe_enable", nil) action:^{
        setPrefBool(@"java.coco_allow_over_safe", YES);
        [weakSelf refreshValues];
    }];
    [sheet addSecondary:localize(@"coco.mg.cancel", nil) action:nil];
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)memoryUnlockTapped {
    CocoPresentMemoryUnlock(self);
}

- (void)recordingHideTapped {
    // Applied by the game screen (SurfaceViewController reads it when it opens)
    setPrefBool(@"control.recording_hide", !getPrefBool(@"control.recording_hide"));
    [self refreshValues];
}

- (void)mfDynamicTapped {
    setPrefBool(@"java.coco_mf_dynamic_resources", !getPrefBool(@"java.coco_mf_dynamic_resources"));
    [self refreshValues];
}

- (void)mgResetAllTapped {
    CocoSheetViewController *sheet = [CocoSheetViewController sheetWithTitle:localize(@"coco.mg.reset_all", nil)
        message:localize(@"coco.mg.reset_all_message", nil)];
    __weak CocoSettingsViewController *weakSelf = self;
    [sheet addPrimary:localize(@"coco.mg.reset_all", nil) action:^{
        CocoResetMGOptions();
        [weakSelf refreshValues];
    }];
    [sheet addSecondary:localize(@"coco.mg.cancel", nil) action:nil];
    [self presentViewController:sheet animated:YES completion:nil];
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

- (void)openSideMods {
    [CocoHomeViewController openSideModsFolderFrom:self];
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
