#import <Cocoa/Cocoa.h>
#import <UserNotifications/UserNotifications.h>
#include "scanner.hpp"
#include <vector>
#include <string>
#include <numeric>
#include <algorithm>

using cleaner::Location;

// Top-left-origin view so top-down layout math is simple.
@interface FlippedView : NSView
@end
@implementation FlippedView
- (BOOL)isFlipped { return YES; }
@end

@interface DiskBarView : NSView
@property (nonatomic) CGFloat fraction; // 0..1 fraction of disk used
@end
@implementation DiskBarView
- (void)setFraction:(CGFloat)fraction {
    _fraction = fraction;
    self.needsDisplay = YES;
}
- (void)drawRect:(NSRect)dirtyRect {
    NSRect bounds = self.bounds;
    CGFloat r = bounds.size.height / 2.0;

    NSBezierPath *track = [NSBezierPath bezierPathWithRoundedRect:bounds xRadius:r yRadius:r];
    [[NSColor colorWithWhite:0.5 alpha:0.25] set];
    [track fill];

    CGFloat frac = MAX(0.0, MIN(1.0, _fraction));
    CGFloat w = bounds.size.width * frac;
    if (w > 1) {
        NSRect fillRect = NSMakeRect(0, 0, w, bounds.size.height);
        NSBezierPath *fill = [NSBezierPath bezierPathWithRoundedRect:fillRect xRadius:r yRadius:r];
        NSColor *color = frac < 0.7 ? [NSColor systemGreenColor]
                        : frac < 0.9 ? [NSColor systemOrangeColor]
                        : [NSColor systemRedColor];
        [color set];
        [fill fill];
    }
}
@end

static NSString *SymbolForLabel(const std::string &label) {
    if (label == "App & System Caches")  return @"externaldrive";
    if (label == "Xcode DerivedData")    return @"hammer";
    if (label == "iOS Simulator Caches") return @"iphone";
    if (label == "npm Cache")            return @"shippingbox";
    if (label == "Trash")                return @"trash";
    if (label == "Chrome Browser Cache") return @"globe";
    return @"folder";
}

static NSTextField *MakeLabel(NSRect frame, NSString *text, CGFloat size, NSFontWeight weight, NSColor *color) {
    NSTextField *f = [[NSTextField alloc] initWithFrame:frame];
    f.stringValue = text;
    f.editable = NO;
    f.bordered = NO;
    f.drawsBackground = NO;
    f.selectable = NO;
    f.font = [NSFont systemFontOfSize:size weight:weight];
    f.textColor = color;
    f.lineBreakMode = NSLineBreakByTruncatingTail;
    return f;
}

static const CGFloat kWidth = 300;
static const CGFloat kPad = 14;
static const CGFloat kRowHeight = 42;
static const size_t kBigItemSlots = 5;
static const uint64_t kLowSpaceThresholdBytes = 15ULL * 1024 * 1024 * 1024; // 15 GB

@interface AppDelegate : NSObject <NSApplicationDelegate, NSPopoverDelegate, UNUserNotificationCenterDelegate>
@end

@implementation AppDelegate {
    NSStatusItem *_statusItem;
    NSPopover *_popover;
    std::vector<Location> _locations;
    std::vector<uint64_t> _sizes;
    NSMutableArray<NSTextField *> *_sizeLabels;
    NSMutableArray<NSButton *> *_clearButtons;
    NSMutableArray<NSImageView *> *_rowIcons;
    NSMutableArray<NSTextField *> *_rowNameLabels;
    NSTextField *_totalLabel;
    DiskBarView *_diskBar;
    NSTextField *_diskLabel;
    DiskBarView *_ramBar;
    NSTextField *_ramLabel;
    NSTimer *_liveUpdateTimer;
    BOOL _scanning;
    BOOL _lowSpaceNotified;

    std::vector<cleaner::BigItem> _bigItems;
    NSMutableArray<NSView *> *_bigItemRows;
    NSMutableArray<NSTextField *> *_bigNameLabels;
    NSMutableArray<NSTextField *> *_bigSizeLabels;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    _locations = cleaner::safeLocations();
    _sizes.assign(_locations.size(), 0);
    _scanning = NO;

    _statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    NSImage *statusIcon = [NSImage imageWithSystemSymbolName:@"internaldrive" accessibilityDescription:@"Cache Cleaner"];
    [statusIcon setTemplate:YES];
    _statusItem.button.image = statusIcon;
    _statusItem.button.imagePosition = NSImageLeading;
    _statusItem.button.title = @"…";
    _statusItem.button.target = self;
    _statusItem.button.action = @selector(togglePopover:);

    UNUserNotificationCenter *center = [UNUserNotificationCenter currentNotificationCenter];
    center.delegate = self;
    [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
                           completionHandler:^(BOOL granted, NSError *error) {}];

    [self buildPopover];
    [self refreshSizes];
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
        willPresentNotification:(UNNotification *)notification
          withCompletionHandler:(void (^)(UNNotificationPresentationOptions options))completionHandler {
    completionHandler(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionSound);
}

- (void)buildPopover {
    // Frame height is fixed up at the end once every subview is laid out.
    FlippedView *content = [[FlippedView alloc] initWithFrame:NSMakeRect(0, 0, kWidth, 10)];
    CGFloat y = kPad;

    NSTextField *title = MakeLabel(NSMakeRect(kPad, y, kWidth - 2 * kPad, 18),
                                    @"Cache Cleaner", 14, NSFontWeightSemibold, [NSColor labelColor]);
    [content addSubview:title];
    y += 22;

    _diskBar = [[DiskBarView alloc] initWithFrame:NSMakeRect(kPad, y + 1, kWidth - 2 * kPad, 6)];
    [content addSubview:_diskBar];
    y += 14;

    _diskLabel = MakeLabel(NSMakeRect(kPad, y, kWidth - 2 * kPad, 14),
                            @"Checking disk…", 11, NSFontWeightRegular, [NSColor secondaryLabelColor]);
    [content addSubview:_diskLabel];
    y += 24;

    _ramBar = [[DiskBarView alloc] initWithFrame:NSMakeRect(kPad, y + 1, kWidth - 2 * kPad, 6)];
    [content addSubview:_ramBar];
    y += 14;

    _ramLabel = MakeLabel(NSMakeRect(kPad, y, kWidth - 2 * kPad, 14),
                           @"Checking memory…", 11, NSFontWeightRegular, [NSColor secondaryLabelColor]);
    [content addSubview:_ramLabel];
    y += 24;

    _totalLabel = MakeLabel(NSMakeRect(kPad, y, kWidth - 2 * kPad, 14),
                             @"Scanning…", 11, NSFontWeightRegular, [NSColor secondaryLabelColor]);
    [content addSubview:_totalLabel];
    y += 24;

    [content addSubview:[self separatorAtY:y]];
    y += 11;

    _sizeLabels = [NSMutableArray array];
    _clearButtons = [NSMutableArray array];
    _rowIcons = [NSMutableArray array];
    _rowNameLabels = [NSMutableArray array];

    for (size_t i = 0; i < _locations.size(); i++) {
        NSImageView *icon = [[NSImageView alloc] initWithFrame:NSMakeRect(kPad, y + 10, 18, 18)];
        icon.contentTintColor = [NSColor secondaryLabelColor];
        [content addSubview:icon];
        [_rowIcons addObject:icon];

        CGFloat textX = kPad + 26;
        CGFloat textW = kWidth - textX - kPad - 66;

        NSTextField *name = MakeLabel(NSMakeRect(textX, y, textW, 16), @"",
                                       12, NSFontWeightMedium, [NSColor labelColor]);
        [content addSubview:name];
        [_rowNameLabels addObject:name];

        NSTextField *sizeLabel = MakeLabel(NSMakeRect(textX, y + 17, textW, 14),
                                            @"Scanning…", 11, NSFontWeightRegular, [NSColor secondaryLabelColor]);
        [content addSubview:sizeLabel];
        [_sizeLabels addObject:sizeLabel];

        NSButton *clearBtn = [NSButton buttonWithTitle:@"Clear" target:self action:@selector(clearOneTapped:)];
        clearBtn.frame = NSMakeRect(kWidth - kPad - 58, y + 7, 58, 22);
        clearBtn.bezelStyle = NSBezelStyleRounded;
        clearBtn.font = [NSFont systemFontOfSize:11];
        clearBtn.tag = (NSInteger)i;
        [content addSubview:clearBtn];
        [_clearButtons addObject:clearBtn];

        y += kRowHeight;
    }

    y += 8;
    [content addSubview:[self separatorAtY:y]];
    y += 13;

    NSButton *clearAll = [NSButton buttonWithTitle:@"Clear All" target:self action:@selector(clearAllTapped:)];
    clearAll.frame = NSMakeRect(kPad, y, kWidth - 2 * kPad, 30);
    clearAll.bezelStyle = NSBezelStyleRounded;
    clearAll.keyEquivalent = @"";
    clearAll.font = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    clearAll.contentTintColor = [NSColor whiteColor];
    if (@available(macOS 10.12.2, *)) {
        clearAll.bezelColor = [NSColor controlAccentColor];
    }
    [content addSubview:clearAll];
    y += 38;

    [content addSubview:[self separatorAtY:y]];
    y += 12;

    NSTextField *bigHeader = MakeLabel(NSMakeRect(kPad, y, kWidth - 2 * kPad, 14),
                                        @"Biggest Items — review manually", 11, NSFontWeightSemibold,
                                        [NSColor secondaryLabelColor]);
    [content addSubview:bigHeader];
    y += 20;

    _bigItemRows = [NSMutableArray array];
    _bigNameLabels = [NSMutableArray array];
    _bigSizeLabels = [NSMutableArray array];

    for (size_t i = 0; i < kBigItemSlots; i++) {
        FlippedView *row = [[FlippedView alloc] initWithFrame:NSMakeRect(0, y, kWidth, kRowHeight)];
        [content addSubview:row];

        NSImageView *icon = [[NSImageView alloc] initWithFrame:NSMakeRect(kPad, 10, 18, 18)];
        NSImage *img = [NSImage imageWithSystemSymbolName:@"folder" accessibilityDescription:nil];
        NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration configurationWithPointSize:14 weight:NSFontWeightRegular];
        icon.image = [img imageWithSymbolConfiguration:cfg];
        icon.contentTintColor = [NSColor secondaryLabelColor];
        [row addSubview:icon];

        CGFloat textX = kPad + 26;
        CGFloat textW = kWidth - textX - kPad - 66;

        NSTextField *name = MakeLabel(NSMakeRect(textX, 0, textW, 16), @"", 12, NSFontWeightMedium, [NSColor labelColor]);
        [row addSubview:name];
        [_bigNameLabels addObject:name];

        NSTextField *sizeLabel = MakeLabel(NSMakeRect(textX, 17, textW, 14), @"", 11, NSFontWeightRegular, [NSColor secondaryLabelColor]);
        [row addSubview:sizeLabel];
        [_bigSizeLabels addObject:sizeLabel];

        NSButton *showBtn = [NSButton buttonWithTitle:@"Show" target:self action:@selector(revealTapped:)];
        showBtn.frame = NSMakeRect(kWidth - kPad - 58, 7, 58, 22);
        showBtn.bezelStyle = NSBezelStyleRounded;
        showBtn.font = [NSFont systemFontOfSize:11];
        showBtn.tag = (NSInteger)i;
        [row addSubview:showBtn];

        [_bigItemRows addObject:row];
        row.hidden = YES;
        y += kRowHeight;
    }

    y += 6;
    [content addSubview:[self separatorAtY:y]];
    y += 12;

    NSButton *refresh = [NSButton buttonWithTitle:@"Refresh" target:self action:@selector(refreshSizes)];
    refresh.frame = NSMakeRect(kPad, y, 90, 24);
    refresh.bezelStyle = NSBezelStyleRounded;
    refresh.bordered = YES;
    refresh.font = [NSFont systemFontOfSize:11];
    [content addSubview:refresh];

    NSButton *quit = [NSButton buttonWithTitle:@"Quit" target:self action:@selector(quitTapped:)];
    quit.frame = NSMakeRect(kWidth - kPad - 70, y, 70, 24);
    quit.bezelStyle = NSBezelStyleRounded;
    quit.bordered = YES;
    quit.font = [NSFont systemFontOfSize:11];
    [content addSubview:quit];
    y += 24 + kPad;

    [content setFrameSize:NSMakeSize(kWidth, y)];

    NSViewController *vc = [[NSViewController alloc] init];
    vc.view = content;

    _popover = [[NSPopover alloc] init];
    _popover.contentViewController = vc;
    _popover.behavior = NSPopoverBehaviorTransient;
    _popover.delegate = self;
}

- (void)popoverDidShow:(NSNotification *)notification {
    [_liveUpdateTimer invalidate];
    _liveUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:2.0
                                                          target:self
                                                        selector:@selector(refreshRamUsage)
                                                        userInfo:nil
                                                         repeats:YES];
}

- (void)popoverDidClose:(NSNotification *)notification {
    [_liveUpdateTimer invalidate];
    _liveUpdateTimer = nil;
}

- (NSBox *)separatorAtY:(CGFloat)y {
    NSBox *box = [[NSBox alloc] initWithFrame:NSMakeRect(kPad, y, kWidth - 2 * kPad, 1)];
    box.boxType = NSBoxSeparator;
    return box;
}

- (void)togglePopover:(id)sender {
    if (_popover.isShown) {
        [_popover performClose:sender];
        return;
    }
    [self refreshSizes];
    [NSApp activateIgnoringOtherApps:YES];
    [_popover showRelativeToRect:_statusItem.button.bounds
                           ofView:_statusItem.button
                    preferredEdge:NSMinYEdge];
    [_popover.contentViewController.view.window makeKeyWindow];
}

- (void)refreshDiskUsage {
    cleaner::DiskUsage du = cleaner::getDiskUsage();
    double fraction = du.totalBytes > 0 ? (double)du.usedBytes / (double)du.totalBytes : 0.0;
    _diskBar.fraction = fraction;
    std::string usedStr = cleaner::humanSize(du.usedBytes);
    std::string freeStr = cleaner::humanSize(du.freeBytes);
    std::string totalStr = cleaner::humanSize(du.totalBytes);
    _diskLabel.stringValue = [NSString stringWithFormat:@"%s used · %s free of %s",
                               usedStr.c_str(), freeStr.c_str(), totalStr.c_str()];

    BOOL isLow = du.freeBytes < kLowSpaceThresholdBytes;
    _statusItem.button.contentTintColor = isLow ? [NSColor systemRedColor] : nil;
    if (isLow && !_lowSpaceNotified) {
        _lowSpaceNotified = YES;
        [self sendLowSpaceNotification:[NSString stringWithUTF8String:freeStr.c_str()]];
    } else if (!isLow) {
        _lowSpaceNotified = NO;
    }
}

- (void)refreshRamUsage {
    cleaner::RamUsage ru = cleaner::getRamUsage();
    double fraction = ru.totalBytes > 0 ? (double)ru.usedBytes / (double)ru.totalBytes : 0.0;
    _ramBar.fraction = fraction;
    std::string usedStr = cleaner::humanSize(ru.usedBytes);
    std::string freeStr = cleaner::humanSize(ru.freeBytes);
    std::string totalStr = cleaner::humanSize(ru.totalBytes);
    _ramLabel.stringValue = [NSString stringWithFormat:@"%s used · %s free of %s (RAM)",
                              usedStr.c_str(), freeStr.c_str(), totalStr.c_str()];
}

- (void)sendLowSpaceNotification:(NSString *)freeText {
    UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
    content.title = @"Low Disk Space";
    content.body = [NSString stringWithFormat:@"Only %@ free. Click the Cache Cleaner icon to free up space.", freeText];
    content.sound = [UNNotificationSound defaultSound];
    UNNotificationRequest *req = [UNNotificationRequest requestWithIdentifier:@"low-disk-space"
                                                                       content:content
                                                                       trigger:nil];
    [[UNUserNotificationCenter currentNotificationCenter] addNotificationRequest:req withCompletionHandler:nil];
}

- (void)refreshSizes {
    [self refreshDiskUsage];
    [self refreshRamUsage];
    if (_scanning) return;
    _scanning = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        std::vector<uint64_t> newSizes(self->_locations.size(), 0);
        uint64_t total = 0;
        for (size_t i = 0; i < self->_locations.size(); i++) {
            uint64_t sz = cleaner::locationSize(self->_locations[i]);
            newSizes[i] = sz;
            total += sz;
        }
        std::vector<cleaner::BigItem> bigItems = cleaner::findBiggestItems(kBigItemSlots);

        std::vector<size_t> order(self->_locations.size());
        std::iota(order.begin(), order.end(), 0);
        std::sort(order.begin(), order.end(), [&](size_t a, size_t b) {
            return newSizes[a] > newSizes[b];
        });

        dispatch_async(dispatch_get_main_queue(), ^{
            self->_sizes = newSizes;
            for (size_t row = 0; row < order.size(); row++) {
                size_t locIdx = order[row];
                NSImage *img = [NSImage imageWithSystemSymbolName:SymbolForLabel(self->_locations[locIdx].label)
                                             accessibilityDescription:nil];
                NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration configurationWithPointSize:14 weight:NSFontWeightRegular];
                self->_rowIcons[row].image = [img imageWithSymbolConfiguration:cfg];
                self->_rowNameLabels[row].stringValue = [NSString stringWithUTF8String:self->_locations[locIdx].label.c_str()];
                std::string s = cleaner::humanSize(newSizes[locIdx]);
                self->_sizeLabels[row].stringValue = [NSString stringWithUTF8String:s.c_str()];
                self->_clearButtons[row].tag = (NSInteger)locIdx;
            }
            std::string totalStr = cleaner::humanSize(total);
            self->_totalLabel.stringValue = [NSString stringWithFormat:@"%s reclaimable", totalStr.c_str()];
            self->_statusItem.button.title = [NSString stringWithFormat:@" %s", totalStr.c_str()];

            self->_bigItems = bigItems;
            for (size_t i = 0; i < kBigItemSlots; i++) {
                NSView *row = self->_bigItemRows[i];
                if (i < self->_bigItems.size()) {
                    std::string name = cleaner::shortenHome(self->_bigItems[i].path);
                    std::string size = cleaner::humanSize(self->_bigItems[i].size);
                    self->_bigNameLabels[i].stringValue = [NSString stringWithUTF8String:name.c_str()];
                    self->_bigSizeLabels[i].stringValue = [NSString stringWithUTF8String:size.c_str()];
                    row.hidden = NO;
                } else {
                    row.hidden = YES;
                }
            }
            self->_scanning = NO;
        });
    });
}

- (void)revealTapped:(NSButton *)sender {
    NSInteger idx = sender.tag;
    if (idx < 0 || (size_t)idx >= _bigItems.size()) return;
    NSString *path = [NSString stringWithUTF8String:_bigItems[(size_t)idx].path.c_str()];
    [_popover performClose:sender];
    [[NSWorkspace sharedWorkspace] selectFile:path inFileViewerRootedAtPath:@""];
}

- (void)clearOneTapped:(NSButton *)sender {
    NSInteger idx = sender.tag;
    if (idx < 0 || (size_t)idx >= _locations.size()) return;
    cleaner::Location loc = _locations[(size_t)idx];

    NSUInteger row = [_clearButtons indexOfObject:sender];
    sender.enabled = NO;
    if (row != NSNotFound) {
        _sizeLabels[row].stringValue = @"Clearing…";
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        cleaner::clearLocation(loc);
        dispatch_async(dispatch_get_main_queue(), ^{
            sender.enabled = YES;
            [self refreshSizes];
        });
    });
}

- (void)clearAllTapped:(NSButton *)sender {
    sender.enabled = NO;
    for (NSButton *b in _clearButtons) b.enabled = NO;
    for (NSTextField *l in _sizeLabels) l.stringValue = @"Clearing…";

    std::vector<cleaner::Location> locs = _locations;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        for (auto &loc : locs) cleaner::clearLocation(loc);
        dispatch_async(dispatch_get_main_queue(), ^{
            sender.enabled = YES;
            for (NSButton *b in self->_clearButtons) b.enabled = YES;
            [self refreshSizes];
        });
    });
}

- (void)quitTapped:(id)sender {
    [NSApp terminate:nil];
}

@end

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        [app run];
    }
    return 0;
}
