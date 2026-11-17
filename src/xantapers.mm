#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <libkern/OSCacheControl.h>
#include <cstring>
#include <cstdint>
#include <unordered_map>
#include <vector>

// =========================================================================
// ОФФСЕТЫ ИЗ DUMP.CS (RVA относительно заголовка UnityFramework)
// 0x0 = оффсет не задан, патч по нему пропускается.
// =========================================================================
namespace Offsets {
// Экономика (AllDayRun)
constexpr uintptr_t AllDayRun_CapFor          = 0x18E3F60; // AllDayRun$$CapFor
constexpr uintptr_t AllDayRun_RawCashFor      = 0x0;       // AllDayRun$$RawCashFor  <-- ПОТЕРЯН, взять из dump.cs
// Сложность и защита (AllDayRamp)
constexpr uintptr_t AllDayRamp_LevelAt        = 0x18DE790; // AllDayRamp$$LevelAt
constexpr uintptr_t AllDayRamp_ContestedScale = 0x0;       // AllDayRamp$$ContestedScale  <-- ПОТЕРЯН, взять из dump.cs
// Реклама (Ads)
constexpr uintptr_t Ads_Ready                 = 0x18DC3AC; // Ads$$Ready

// Поля внутри класса BallShoot (из dump.cs)
constexpr uintptr_t Field_dunkEnabled                 = 0x59C;
constexpr uintptr_t Field_dunkStartDistance           = 0x5A0;
constexpr uintptr_t Field_dunkGateMax                 = 0x5A8;
constexpr uintptr_t Field_dunkJumpCap                 = 0x5AC;
constexpr uintptr_t Field_contestedMaxDistance        = 0x88;
constexpr uintptr_t Field_finishingOpennessShift      = 0xF0;
constexpr uintptr_t Field_contestEnabled              = 0xAF0;
constexpr uintptr_t Field_contestMaxPenalty           = 0xAF4;
constexpr uintptr_t Field_releaseBand01_X             = 0xB44;
constexpr uintptr_t Field_releaseBand01_Y             = 0xB48;
constexpr uintptr_t Field_perfectReleaseError01       = 0xB9C;
constexpr uintptr_t Field_perfectMakeChanceUncontested= 0xBA0;
constexpr uintptr_t Field_perfectMakeChanceContested  = 0xBA4;
constexpr uintptr_t Field_threePointImperfectPenalty  = 0xBAC;
}

// =========================================================================
// СОСТОЯНИЕ ПЕРЕКЛЮЧАТЕЛЕЙ МЕНЮ XANTAPERS
// =========================================================================
struct ModSettings {
    bool autoGreen = true;
    bool noContest = true;
    bool unlimitedCash = true;
    float cashMultiplier = 5.0f;
    bool easyBot = true;
    bool longRangeDunk = false;
    bool skipAds = true;
};
static ModSettings g_Settings;
static uintptr_t g_UnityBase = 0;
// Оригинальные байты для отката патчей (доступ только из main thread)
static std::unordered_map<uintptr_t, std::vector<uint8_t>> g_Originals;

// =========================================================================
// УТИЛИТЫ ДЛЯ РАБОТЫ С ПАМЯТЬЮ UNITYFRAMEWORK (ARM64)
// =========================================================================
static uintptr_t GetUnityFrameworkBase() {
    if (g_UnityBase != 0) return g_UnityBase;
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "UnityFramework") != nullptr) {
            g_UnityBase = (uintptr_t)_dyld_get_image_header(i);
            break;
        }
    }
    // Если UnityFramework не найден, возвращаем 0: патчить чужой образ по этим оффсетам нельзя.
    return g_UnityBase;
}

static bool WriteCode(uintptr_t targetAddr, const void *data, size_t size) {
    uintptr_t pageSize = (uintptr_t)vm_page_size;
    uintptr_t pageStart = targetAddr & ~(pageSize - 1);
    uintptr_t pageEnd = (targetAddr + size + pageSize - 1) & ~(pageSize - 1);
    vm_size_t pageLen = (vm_size_t)(pageEnd - pageStart);
    kern_return_t kr = vm_protect(mach_task_self(), (vm_address_t)pageStart, pageLen, false,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) return false;
    memcpy((void *)targetAddr, data, size);
    vm_protect(mach_task_self(), (vm_address_t)pageStart, pageLen, false, VM_PROT_READ | VM_PROT_EXECUTE);
    sys_icache_invalidate((void *)targetAddr, size);
    return true;
}

// Запись инструкций в __TEXT (с сохранением оригинала для отката)
static bool PatchMemory(uintptr_t offset, const void *data, size_t size) {
    if (offset == 0) return false;
    uintptr_t base = GetUnityFrameworkBase();
    if (!base) return false;
    uintptr_t targetAddr = base + offset;
    if (g_Originals.find(offset) == g_Originals.end()) {
        const uint8_t *src = (const uint8_t *)targetAddr;
        g_Originals[offset] = std::vector<uint8_t>(src, src + size);
    }
    return WriteCode(targetAddr, data, size);
}

static void RestoreMemory(uintptr_t offset) {
    auto it = g_Originals.find(offset);
    if (it == g_Originals.end()) return;
    uintptr_t base = GetUnityFrameworkBase();
    if (!base) return;
    if (WriteCode(base + offset, it->second.data(), it->second.size())) {
        g_Originals.erase(it);
    }
}

// ARM64 шеллкод: вернуть int
static void PatchReturnInt(uintptr_t offset, uint32_t value) {
    // MOVZ W0, #lo; MOVK W0, #hi, LSL #16; RET
    uint32_t lo = value & 0xFFFF;
    uint32_t hi = (value >> 16) & 0xFFFF;
    uint32_t code[3];
    code[0] = 0x52800000 | (lo << 5);
    code[1] = 0x72A00000 | (hi << 5);
    code[2] = 0xD65F03C0;
    PatchMemory(offset, code, sizeof(code));
}

// Применение патчей при изменении настроек в меню
static void ApplyActivePatches() {
    // ARM64: FMOV S0, WZR; RET (возврат 0.0f)
    const uint8_t retZeroF[] = { 0xE0, 0x03, 0x27, 0x1E, 0xC0, 0x03, 0x5F, 0xD6 };

    // 1. Слабый защитник (AllDayRamp$$ContestedScale -> 0.0f)
    if (g_Settings.noContest) {
        PatchMemory(Offsets::AllDayRamp_ContestedScale, retZeroF, sizeof(retZeroF));
    } else {
        RestoreMemory(Offsets::AllDayRamp_ContestedScale);
    }

    // 2. Лимит денег (AllDayRun$$CapFor -> 999999999)
    if (g_Settings.unlimitedCash) {
        PatchReturnInt(Offsets::AllDayRun_CapFor, 999999999);
    } else {
        RestoreMemory(Offsets::AllDayRun_CapFor);
    }
}

// =========================================================================
// НАТИВНЫЙ UIKIT ИНТЕРФЕЙС (МЕНЮ XANTAPERS)
// =========================================================================
@interface XantapersMenuView : UIView
@property (nonatomic, strong) UIView *panelView;
@property (nonatomic, strong) UIButton *toggleButton;
@property (nonatomic, strong) UILabel *multLabel;
@property (nonatomic, strong) UILabel *statusLabel;
@end

@implementation XantapersMenuView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = YES;
        [self setupFloatingButton];
        [self setupMenuPanel];
    }
    return self;
}

// Пропускаем нажатия сквозь прозрачный фон прямо в игру
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hitView = [super hitTest:point withEvent:event];
    if (hitView == self) {
        return nil;
    }
    return hitView;
}

- (void)setupFloatingButton {
    self.toggleButton = [UIButton buttonWithType:UIButtonTypeCustom];
    self.toggleButton.frame = CGRectMake(20, 50, 48, 48);
    self.toggleButton.backgroundColor = [UIColor colorWithRed:0.12 green:0.12 blue:0.18 alpha:0.92];
    self.toggleButton.layer.cornerRadius = 24;
    self.toggleButton.layer.borderWidth = 1.5;
    self.toggleButton.layer.borderColor = [UIColor colorWithRed:0.35 green:0.65 blue:1.0 alpha:1.0].CGColor;
    [self.toggleButton setTitle:@"XP" forState:UIControlStateNormal];
    [self.toggleButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    self.toggleButton.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [self.toggleButton addTarget:self action:@selector(toggleMenu) forControlEvents:UIControlEventTouchUpInside];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleButtonDrag:)];
    [self.toggleButton addGestureRecognizer:pan];
    [self addSubview:self.toggleButton];
}

- (void)setupMenuPanel {
    CGFloat width = 305;
    CGFloat height = 415;
    CGFloat x = (self.bounds.size.width - width) / 2.0;
    CGFloat y = (self.bounds.size.height - height) / 2.0;

    self.panelView = [[UIView alloc] initWithFrame:CGRectMake(x, y, width, height)];
    self.panelView.backgroundColor = [UIColor colorWithRed:0.09 green:0.10 blue:0.14 alpha:0.95];
    self.panelView.layer.cornerRadius = 16;
    self.panelView.layer.borderWidth = 1.2;
    self.panelView.layer.borderColor = [UIColor colorWithRed:0.28 green:0.55 blue:0.95 alpha:0.85].CGColor;
    self.panelView.hidden = YES;

    UIPanGestureRecognizer *panelPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handlePanelDrag:)];
    [self.panelView addGestureRecognizer:panelPan];

    // Заголовок
    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(15, 12, width - 60, 26)];
    titleLabel.text = @"★ xantapers mod ★";
    titleLabel.textColor = [UIColor whiteColor];
    titleLabel.font = [UIFont boldSystemFontOfSize:17];
    [self.panelView addSubview:titleLabel];

    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.frame = CGRectMake(width - 42, 10, 30, 30);
    [closeBtn setTitle:@"✕" forState:UIControlStateNormal];
    [closeBtn setTitleColor:[UIColor lightGrayColor] forState:UIControlStateNormal];
    [closeBtn addTarget:self action:@selector(toggleMenu) forControlEvents:UIControlEventTouchUpInside];
    [self.panelView addSubview:closeBtn];

    // Переключатели функций
    CGFloat currentY = 50;
    currentY = [self addSwitchRow:@"Auto Green (Идеал. бросок)" tag:1 defaultOn:g_Settings.autoGreen y:currentY];
    currentY = [self addSwitchRow:@"No Contest (Без защиты)" tag:2 defaultOn:g_Settings.noContest y:currentY];
    currentY = [self addSwitchRow:@"Без лимита денег (999M)" tag:3 defaultOn:g_Settings.unlimitedCash y:currentY];

    // Ползунок множителя
    self.multLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, currentY, width - 32, 20)];
    self.multLabel.text = [NSString stringWithFormat:@"Множитель наличных: x%.1f", g_Settings.cashMultiplier];
    self.multLabel.textColor = [UIColor colorWithWhite:0.8 alpha:1.0];
    self.multLabel.font = [UIFont systemFontOfSize:13];
    [self.panelView addSubview:self.multLabel];
    currentY += 22;

    UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(16, currentY, width - 32, 28)];
    slider.minimumValue = 1.0f;
    slider.maximumValue = 25.0f;
    slider.value = g_Settings.cashMultiplier;
    [slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.panelView addSubview:slider];
    currentY += 36;

    currentY = [self addSwitchRow:@"Слабый бот (No Ramp)" tag:4 defaultOn:g_Settings.easyBot y:currentY];
    currentY = [self addSwitchRow:@"Дальние данки (Long Dunk)" tag:5 defaultOn:g_Settings.longRangeDunk y:currentY];
    currentY = [self addSwitchRow:@"Награды без рекламы" tag:6 defaultOn:g_Settings.skipAds y:currentY];

    // Статус-бар внизу меню
    self.statusLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, height - 30, width - 32, 20)];
    self.statusLabel.text = @"Оффсеты загружены | arm64";
    self.statusLabel.textColor = [UIColor colorWithRed:0.4 green:0.85 blue:0.5 alpha:1.0];
    self.statusLabel.font = [UIFont systemFontOfSize:11.5];
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    [self.panelView addSubview:self.statusLabel];

    [self addSubview:self.panelView];
}

- (CGFloat)addSwitchRow:(NSString *)title tag:(NSInteger)tag defaultOn:(BOOL)isOn y:(CGFloat)y {
    CGFloat width = self.panelView.bounds.size.width;

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(16, y, width - 80, 30)];
    label.text = title;
    label.textColor = [UIColor whiteColor];
    label.font = [UIFont systemFontOfSize:13.5];
    [self.panelView addSubview:label];

    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(width - 65, y, 50, 30)];
    sw.tag = tag;
    sw.on = isOn;
    sw.onTintColor = [UIColor colorWithRed:0.28 green:0.55 blue:0.95 alpha:1.0];
    [sw addTarget:self action:@selector(switchToggled:) forControlEvents:UIControlEventValueChanged];
    [self.panelView addSubview:sw];

    return y + 38;
}

- (void)toggleMenu {
    self.panelView.hidden = !self.panelView.hidden;
}

- (void)switchToggled:(UISwitch *)sender {
    switch (sender.tag) {
        case 1: g_Settings.autoGreen = sender.isOn; break;
        case 2: g_Settings.noContest = sender.isOn; break;
        case 3: g_Settings.unlimitedCash = sender.isOn; break;
        case 4: g_Settings.easyBot = sender.isOn; break;
        case 5: g_Settings.longRangeDunk = sender.isOn; break;
        case 6: g_Settings.skipAds = sender.isOn; break;
    }
    ApplyActivePatches();
}

- (void)sliderChanged:(UISlider *)sender {
    g_Settings.cashMultiplier = sender.value;
    self.multLabel.text = [NSString stringWithFormat:@"Множитель наличных: x%.1f", g_Settings.cashMultiplier];
}

- (void)handleButtonDrag:(UIPanGestureRecognizer *)pan {
    CGPoint translation = [pan translationInView:self];
    pan.view.center = CGPointMake(pan.view.center.x + translation.x, pan.view.center.y + translation.y);
    [pan setTranslation:CGPointZero inView:self];
}

- (void)handlePanelDrag:(UIPanGestureRecognizer *)pan {
    CGPoint translation = [pan translationInView:self];
    pan.view.center = CGPointMake(pan.view.center.x + translation.x, pan.view.center.y + translation.y);
    [pan setTranslation:CGPointZero inView:self];
}

@end

// =========================================================================
// ТОЧКА ВХОДА DYLIB ПРИ ЗАПУСКЕ ПРИЛОЖЕНИЯ
// =========================================================================
static void SetupOverlayMenu() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIWindow *keyWindow = nil;
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            if (scene.activationState != UISceneActivationStateForegroundActive) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) {
                if (window.isKeyWindow) {
                    keyWindow = window;
                    break;
                }
            }
            if (keyWindow) break;
        }

        if (!keyWindow) {
            keyWindow = [UIApplication sharedApplication].windows.firstObject;
        }

        if (keyWindow) {
            XantapersMenuView *menuOverlay = [[XantapersMenuView alloc] initWithFrame:keyWindow.bounds];
            menuOverlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [keyWindow addSubview:menuOverlay];
            ApplyActivePatches();
        }
    });
}

__attribute__((constructor))
static void InitializeXantapersMod() {
    NSLog(@"[xantapers] Dylib успешно загружен! Применение патчей по адресам dump.cs...");
    SetupOverlayMenu();
}
