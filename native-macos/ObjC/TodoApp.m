#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <float.h>
#import <malloc/malloc.h>

extern char *todo_bridge_call(const char *request);
extern void todo_bridge_free(char *value);

static NSString *const TodoErrorDomain = @"com.xycdev.todo";

static id BridgeCall(NSDictionary *request, NSError **error) {
    @autoreleasepool {
        NSData *requestData = [NSJSONSerialization dataWithJSONObject:request options:0 error:error];
        if (!requestData) return nil;
        NSString *requestString = [[NSString alloc] initWithData:requestData encoding:NSUTF8StringEncoding];
        if (!requestString) {
            if (error) *error = [NSError errorWithDomain:TodoErrorDomain code:1 userInfo:@{NSLocalizedDescriptionKey: @"无法编码 Rust 请求"}];
            return nil;
        }

        char *responsePointer = todo_bridge_call(requestString.UTF8String);
        if (!responsePointer) {
            if (error) *error = [NSError errorWithDomain:TodoErrorDomain code:2 userInfo:@{NSLocalizedDescriptionKey: @"Rust bridge returned null"}];
            return nil;
        }
        NSString *responseString = [NSString stringWithUTF8String:responsePointer];
        todo_bridge_free(responsePointer);
        if (!responseString) {
            if (error) *error = [NSError errorWithDomain:TodoErrorDomain code:3 userInfo:@{NSLocalizedDescriptionKey: @"Rust 返回了无效文本"}];
            return nil;
        }

        NSData *responseData = [responseString dataUsingEncoding:NSUTF8StringEncoding];
        NSDictionary *envelope = [NSJSONSerialization JSONObjectWithData:responseData options:0 error:error];
        if (![envelope isKindOfClass:NSDictionary.class]) return nil;
        if (![envelope[@"ok"] boolValue]) {
            NSString *message = envelope[@"error"] ?: @"Rust 操作失败";
            if (error) *error = [NSError errorWithDomain:TodoErrorDomain code:4 userInfo:@{NSLocalizedDescriptionKey: message}];
            return nil;
        }
        return envelope[@"value"];
    }
}

static void DrawVerticallyCenteredText(NSString *text, NSFont *font, NSColor *color, NSRect bounds) {
    NSMutableParagraphStyle *paragraph = [[NSMutableParagraphStyle alloc] init];
    paragraph.alignment = NSTextAlignmentCenter;
    paragraph.lineBreakMode = NSLineBreakByClipping;

    NSDictionary *attributes = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: color,
        NSParagraphStyleAttributeName: paragraph,
    };
    CGFloat textHeight = ceil([text sizeWithAttributes:attributes].height);
    NSRect textRect = NSMakeRect(
        NSMinX(bounds),
        floor(NSMidY(bounds) - textHeight / 2.0),
        NSWidth(bounds),
        textHeight
    );
    [text drawInRect:textRect withAttributes:attributes];
}

typedef NS_ENUM(NSInteger, LiteButtonStyle) {
    LiteButtonStylePlain,
    LiteButtonStyleBordered,
    LiteButtonStylePrimary,
    LiteButtonStyleDanger,
};

@interface LiteButton : NSControl
@property(nonatomic, copy) NSString *title;
@property(nonatomic) LiteButtonStyle buttonStyle;
@property(nonatomic, strong, nullable) NSColor *foregroundColor;
@property(nonatomic, copy, nullable) void (^handler)(void);
- (instancetype)initWithTitle:(NSString *)title style:(LiteButtonStyle)style;
@end

@implementation LiteButton {
    BOOL _pressed;
}
- (instancetype)initWithTitle:(NSString *)title style:(LiteButtonStyle)style {
    if ((self = [super initWithFrame:NSZeroRect])) {
        _title = [title copy];
        _buttonStyle = style;
        self.accessibilityElement = YES;
        self.accessibilityRole = NSAccessibilityButtonRole;
        self.accessibilityLabel = title;
    }
    return self;
}
- (void)setTitle:(NSString *)title {
    _title = [title copy];
    self.accessibilityLabel = title;
    [self invalidateIntrinsicContentSize];
    self.needsDisplay = YES;
}
- (void)setButtonStyle:(LiteButtonStyle)buttonStyle { _buttonStyle = buttonStyle; self.needsDisplay = YES; }
- (void)setForegroundColor:(NSColor *)foregroundColor { _foregroundColor = foregroundColor; self.needsDisplay = YES; }
- (NSSize)intrinsicContentSize {
    NSFont *font = [NSFont systemFontOfSize:12.5 weight:self.buttonStyle == LiteButtonStylePrimary ? NSFontWeightSemibold : NSFontWeightMedium];
    CGFloat width = ceil([self.title sizeWithAttributes:@{NSFontAttributeName: font}].width);
    CGFloat padding = (self.buttonStyle == LiteButtonStylePlain || self.buttonStyle == LiteButtonStyleDanger) ? 8 : 22;
    return NSMakeSize(width + padding, 30);
}
- (BOOL)acceptsFirstResponder { return self.enabled; }
- (void)drawRect:(NSRect)dirtyRect {
    NSRect rect = NSInsetRect(self.bounds, 1, 1);
    NSBezierPath *path = [NSBezierPath bezierPathWithRoundedRect:rect xRadius:7 yRadius:7];
    if (self.buttonStyle == LiteButtonStylePrimary) {
        NSColor *fill = _pressed ? [NSColor.controlAccentColor blendedColorWithFraction:0.18 ofColor:NSColor.blackColor] : NSColor.controlAccentColor;
        [fill setFill]; [path fill];
    } else if (self.buttonStyle == LiteButtonStyleBordered) {
        [(_pressed ? [NSColor.controlAccentColor colorWithAlphaComponent:0.14] : NSColor.controlBackgroundColor) setFill]; [path fill];
        [NSColor.separatorColor setStroke]; [path stroke];
    } else if (_pressed) {
        [[NSColor.selectedContentBackgroundColor colorWithAlphaComponent:0.12] setFill]; [path fill];
    }

    NSFont *font = [NSFont systemFontOfSize:12.5 weight:self.buttonStyle == LiteButtonStylePrimary ? NSFontWeightSemibold : NSFontWeightMedium];
    NSColor *color;
    if (!self.enabled) color = NSColor.disabledControlTextColor;
    else if (self.foregroundColor) color = self.foregroundColor;
    else if (self.buttonStyle == LiteButtonStylePrimary) color = NSColor.whiteColor;
    else if (self.buttonStyle == LiteButtonStyleDanger) color = NSColor.systemRedColor;
    else color = NSColor.secondaryLabelColor;
    DrawVerticallyCenteredText(self.title, font, color, rect);
}
- (void)mouseDown:(NSEvent *)event {
    if (!self.enabled) return;
    _pressed = YES; self.needsDisplay = YES;
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    if (NSPointInRect(point, self.bounds)) {
        if (self.handler) self.handler();
        [self sendAction:self.action to:self.target];
    }
    _pressed = NO; self.needsDisplay = YES;
}
- (void)keyDown:(NSEvent *)event {
    if (event.keyCode == 36 || event.keyCode == 49) {
        if (self.handler) self.handler();
        [self sendAction:self.action to:self.target];
    } else [super keyDown:event];
}
@end

@interface DisclosureControl : NSControl
@property(nonatomic, copy) NSString *title;
@property(nonatomic) BOOL expanded;
@property(nonatomic, copy, nullable) void (^handler)(BOOL expanded);
- (instancetype)initWithTitle:(NSString *)title;
@end

@implementation DisclosureControl {
    BOOL _pressed;
}
- (instancetype)initWithTitle:(NSString *)title {
    if ((self = [super initWithFrame:NSZeroRect])) {
        _title = [title copy];
        _expanded = NO;
        self.accessibilityElement = YES;
        self.accessibilityRole = NSAccessibilityButtonRole;
        self.accessibilityLabel = title;
        self.accessibilityValue = @"collapsed";
    }
    return self;
}
- (void)setTitle:(NSString *)title {
    _title = [title copy];
    self.accessibilityLabel = title;
    self.needsDisplay = YES;
}
- (void)setExpanded:(BOOL)expanded {
    _expanded = expanded;
    self.accessibilityValue = expanded ? @"expanded" : @"collapsed";
    self.needsDisplay = YES;
}
- (BOOL)acceptsFirstResponder { return self.enabled; }
- (void)activate {
    if (!self.enabled) return;
    self.expanded = !self.expanded;
    if (self.handler) self.handler(self.expanded);
}
- (void)drawRect:(NSRect)dirtyRect {
    NSRect bounds = self.bounds;
    if (_pressed) {
        [[NSColor.selectedContentBackgroundColor colorWithAlphaComponent:0.08] setFill];
        NSRectFill(bounds);
    }

    CGFloat centerY = NSMidY(bounds);
    NSBezierPath *chevron = [NSBezierPath bezierPath];
    if (self.expanded) {
        [chevron moveToPoint:NSMakePoint(16, centerY + 3)];
        [chevron lineToPoint:NSMakePoint(20, centerY - 2)];
        [chevron lineToPoint:NSMakePoint(24, centerY + 3)];
    } else {
        [chevron moveToPoint:NSMakePoint(18, centerY - 5)];
        [chevron lineToPoint:NSMakePoint(23, centerY)];
        [chevron lineToPoint:NSMakePoint(18, centerY + 5)];
    }
    chevron.lineWidth = 1.6;
    chevron.lineCapStyle = NSLineCapStyleRound;
    chevron.lineJoinStyle = NSLineJoinStyleRound;
    [(self.enabled ? NSColor.secondaryLabelColor : NSColor.disabledControlTextColor) setStroke];
    [chevron stroke];

    NSFont *font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightSemibold];
    NSColor *color = self.enabled ? NSColor.secondaryLabelColor : NSColor.disabledControlTextColor;
    NSDictionary *attributes = @{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: color,
    };
    CGFloat textHeight = ceil([self.title sizeWithAttributes:attributes].height);
    NSRect textRect = NSMakeRect(32, floor(centerY - textHeight / 2.0), MAX(0, NSWidth(bounds) - 44), textHeight);
    [self.title drawInRect:textRect withAttributes:attributes];
}
- (void)mouseDown:(NSEvent *)event {
    if (!self.enabled) return;
    _pressed = YES;
    self.needsDisplay = YES;
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    if (NSPointInRect(point, self.bounds)) [self activate];
    _pressed = NO;
    self.needsDisplay = YES;
}
- (void)keyDown:(NSEvent *)event {
    if (event.keyCode == 36 || event.keyCode == 49) [self activate];
    else [super keyDown:event];
}
@end

@interface LiteSegmentedControl : NSControl
@property(nonatomic, copy) NSArray<NSString *> *labels;
@property(nonatomic) NSInteger selectedIndex;
@property(nonatomic, copy, nullable) void (^changeHandler)(NSInteger index);
- (instancetype)initWithLabels:(NSArray<NSString *> *)labels;
@end

@implementation LiteSegmentedControl
- (instancetype)initWithLabels:(NSArray<NSString *> *)labels {
    if ((self = [super initWithFrame:NSZeroRect])) {
        _labels = [labels copy];
        _selectedIndex = 0;
        self.accessibilityElement = YES;
        self.accessibilityRole = NSAccessibilityRadioGroupRole;
    }
    return self;
}
- (void)setLabels:(NSArray<NSString *> *)labels {
    _labels = [labels copy];
    _selectedIndex = MAX(0, MIN(_selectedIndex, (NSInteger)_labels.count - 1));
    [self invalidateIntrinsicContentSize];
    self.needsDisplay = YES;
}
- (void)setSelectedIndex:(NSInteger)selectedIndex {
    _selectedIndex = MAX(0, MIN(selectedIndex, (NSInteger)self.labels.count - 1));
    self.needsDisplay = YES;
}
- (NSSize)intrinsicContentSize {
    NSFont *font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightMedium];
    CGFloat widest = 32;
    for (NSString *label in self.labels) widest = MAX(widest, ceil([label sizeWithAttributes:@{NSFontAttributeName: font}].width));
    return NSMakeSize(self.labels.count * (widest + 18), 28);
}
- (void)drawRect:(NSRect)dirtyRect {
    NSRect outer = NSInsetRect(self.bounds, 1, 1);
    NSBezierPath *outline = [NSBezierPath bezierPathWithRoundedRect:outer xRadius:7 yRadius:7];
    [NSColor.controlBackgroundColor setFill]; [outline fill]; [NSColor.separatorColor setStroke]; [outline stroke];
    if (self.labels.count == 0) return;
    CGFloat width = NSWidth(outer) / self.labels.count;
    NSRect selected = NSMakeRect(NSMinX(outer) + self.selectedIndex * width + 2, NSMinY(outer) + 2, width - 4, NSHeight(outer) - 4);
    [NSColor.textBackgroundColor setFill]; [[NSBezierPath bezierPathWithRoundedRect:selected xRadius:5 yRadius:5] fill];
    NSFont *font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightMedium];
    [self.labels enumerateObjectsUsingBlock:^(NSString *label, NSUInteger index, BOOL *stop) {
        NSRect segmentRect = NSMakeRect(NSMinX(outer) + index * width, NSMinY(outer), width, NSHeight(outer));
        NSColor *color = !self.enabled ? NSColor.disabledControlTextColor : (index == self.selectedIndex ? NSColor.labelColor : NSColor.secondaryLabelColor);
        DrawVerticallyCenteredText(label, font, color, segmentRect);
    }];
}
- (void)mouseDown:(NSEvent *)event {
    if (!self.enabled || self.labels.count == 0) return;
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    if (!NSPointInRect(point, self.bounds)) return;
    CGFloat width = MAX(NSWidth(self.bounds) / self.labels.count, 1);
    NSInteger index = MIN((NSInteger)(point.x / width), (NSInteger)self.labels.count - 1);
    if (index == self.selectedIndex) return;
    self.selectedIndex = index;
    if (self.changeHandler) self.changeHandler(index);
}
@end

@interface CheckControl : NSControl
@property(nonatomic) BOOL checked;
@property(nonatomic, copy, nullable) void (^changeHandler)(BOOL checked);
@end
@implementation CheckControl
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.accessibilityElement = YES;
        self.accessibilityRole = NSAccessibilityCheckBoxRole;
        self.accessibilityLabel = @"完成任务";
    }
    return self;
}
- (NSSize)intrinsicContentSize { return NSMakeSize(20, 20); }
- (void)setChecked:(BOOL)checked { _checked = checked; self.accessibilityValue = checked ? @1 : @0; self.needsDisplay = YES; }
- (void)drawRect:(NSRect)dirtyRect {
    NSRect square = NSMakeRect(2, 2, 16, 16);
    NSBezierPath *box = [NSBezierPath bezierPathWithRoundedRect:square xRadius:5 yRadius:5];
    if (self.checked) {
        [NSColor.systemGreenColor setFill]; [box fill];
        NSBezierPath *check = [NSBezierPath bezierPath]; [check moveToPoint:NSMakePoint(6, 10)]; [check lineToPoint:NSMakePoint(9, 7)]; [check lineToPoint:NSMakePoint(14, 13)];
        check.lineWidth = 2; check.lineCapStyle = NSLineCapStyleRound; check.lineJoinStyle = NSLineJoinStyleRound; [NSColor.whiteColor setStroke]; [check stroke];
    } else { [NSColor.separatorColor setStroke]; box.lineWidth = 1.2; [box stroke]; }
}
- (void)mouseDown:(NSEvent *)event { if (!self.enabled) return; self.checked = !self.checked; if (self.changeHandler) self.changeHandler(self.checked); }
@end

@interface TaskCellView : NSTableCellView
@property CheckControl *check;
@property NSTextField *titleLabel;
@property NSTextField *subtitleLabel;
- (void)configure:(NSDictionary *)summary handler:(void (^)(BOOL))handler;
@end
@implementation TaskCellView
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _check = [[CheckControl alloc] initWithFrame:NSZeroRect];
        _titleLabel = [NSTextField labelWithString:@""];
        _titleLabel.font = [NSFont systemFontOfSize:13.5 weight:NSFontWeightSemibold];
        _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        _subtitleLabel = [NSTextField labelWithString:@""];
        _subtitleLabel.font = [NSFont systemFontOfSize:11.5];
        _subtitleLabel.textColor = NSColor.secondaryLabelColor;
        _subtitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        [self addSubview:_check]; [self addSubview:_titleLabel]; [self addSubview:_subtitleLabel];
    }
    return self;
}
- (void)layout {
    [super layout];
    CGFloat h = NSHeight(self.bounds);
    self.check.frame = NSMakeRect(10, (h - 20) / 2, 20, 20);
    CGFloat x = 38, w = MAX(0, NSWidth(self.bounds) - x - 10);
    self.titleLabel.frame = NSMakeRect(x, h / 2 + 3, w, 19);
    self.subtitleLabel.frame = NSMakeRect(x, h / 2 - 17, w, 17);
}
- (void)configure:(NSDictionary *)summary handler:(void (^)(BOOL))handler {
    self.titleLabel.stringValue = summary[@"title"] ?: @"";
    self.subtitleLabel.stringValue = summary[@"subtitle"] ?: @"";
    BOOL completed = [summary[@"completed"] boolValue];
    self.check.checked = completed;
    self.check.changeHandler = handler;
    self.titleLabel.textColor = completed ? NSColor.tertiaryLabelColor : NSColor.labelColor;
    self.subtitleLabel.textColor = completed ? NSColor.tertiaryLabelColor : NSColor.secondaryLabelColor;
}
@end

typedef NS_ENUM(NSInteger, TodoDateFilterMode) {
    TodoDateFilterModeAll = 0,
    TodoDateFilterModeLast24Hours = 1,
    TodoDateFilterModeLast7Days = 2,
    TodoDateFilterModeCustom = 3,
};

typedef NS_ENUM(NSInteger, TodoLanguage) {
    TodoLanguageChinese = 0,
    TodoLanguageEnglish = 1,
};

typedef NS_ENUM(NSInteger, TodoViewMode) {
    TodoViewModeEdit = 0,
    TodoViewModeSplit = 1,
    TodoViewModePreview = 2,
};

static NSString *const TodoLanguageDefaultsKey = @"TodoLanguage";
static NSString *const TodoViewModeDefaultsKey = @"TodoWorkspaceModeV2";
static NSString *const TodoCompletionResultRatioDefaultsKey = @"TodoCompletionResultRatio";
static NSNotificationName const TodoLanguageDidChangeNotification = @"TodoLanguageDidChangeNotification";

static NSString *TodoLocalized(TodoLanguage language, NSString *chinese, NSString *english) {
    return language == TodoLanguageEnglish ? english : chinese;
}

@interface SidebarView : NSView
@property NSTextField *dateLabel;
@property NSTextField *headingLabel;
@property LiteButton *createTaskButton;
@property LiteSegmentedControl *languageControl;
@property LiteButton *toggleAllButton;
@property LiteSegmentedControl *filterControl;
@property LiteSegmentedControl *datePresetControl;
@property NSTextField *dateRangeLabel;
@property NSScrollView *scrollView;
@property NSTableView *tableView;
@property NSTextField *countLabel;
@property LiteButton *clearButton;
@end
@implementation SidebarView
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _dateLabel = [NSTextField labelWithString:@""]; _dateLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold]; _dateLabel.textColor = NSColor.systemOrangeColor;
        _headingLabel = [NSTextField labelWithString:@"今天要做什么？"]; _headingLabel.font = [NSFont systemFontOfSize:24 weight:NSFontWeightBold];
        _createTaskButton = [[LiteButton alloc] initWithTitle:@"新建任务" style:LiteButtonStyleBordered];
        _languageControl = [[LiteSegmentedControl alloc] initWithLabels:@[@"中", @"EN"]];
        _toggleAllButton = [[LiteButton alloc] initWithTitle:@"全部完成" style:LiteButtonStylePlain];
        _filterControl = [[LiteSegmentedControl alloc] initWithLabels:@[@"全部", @"待办", @"已完成"]];
        _datePresetControl = [[LiteSegmentedControl alloc] initWithLabels:@[@"全部", @"24小时", @"近7天", @"自定义"]];
        _dateRangeLabel = [NSTextField labelWithString:@"全部首次定义时间"];
        _dateRangeLabel.font = [NSFont systemFontOfSize:10.5];
        _dateRangeLabel.textColor = NSColor.secondaryLabelColor;
        _dateRangeLabel.alignment = NSTextAlignmentCenter;
        _dateRangeLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        _tableView = [[NSTableView alloc] initWithFrame:NSZeroRect]; NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"task"]; [_tableView addTableColumn:column]; _tableView.headerView = nil; _tableView.rowHeight = 62; _tableView.intercellSpacing = NSMakeSize(0, 1); _tableView.backgroundColor = NSColor.clearColor;
        _scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect]; _scrollView.documentView = _tableView; _scrollView.hasVerticalScroller = YES; _scrollView.autohidesScrollers = YES; _scrollView.drawsBackground = NO;
        _countLabel = [NSTextField labelWithString:@""]; _countLabel.font = [NSFont systemFontOfSize:11]; _countLabel.textColor = NSColor.secondaryLabelColor;
        _clearButton = [[LiteButton alloc] initWithTitle:@"清除已完成" style:LiteButtonStyleDanger];
        for (NSView *v in @[_dateLabel,_headingLabel,_createTaskButton,_languageControl,_toggleAllButton,_filterControl,_datePresetControl,_dateRangeLabel,_scrollView,_countLabel,_clearButton]) [self addSubview:v];
    }
    return self;
}
- (BOOL)isFlipped { return YES; }
- (void)layout {
    [super layout]; CGFloat w = NSWidth(self.bounds), h = NSHeight(self.bounds);
    NSSize languageSize = self.languageControl.intrinsicContentSize;
    self.dateLabel.frame = NSMakeRect(16, 18, MAX(80, w - languageSize.width - 44), 16);
    self.languageControl.frame = NSMakeRect(w - languageSize.width - 12, 10, languageSize.width, 28);
    NSSize newTaskSize = self.createTaskButton.intrinsicContentSize;
    self.headingLabel.frame = NSMakeRect(16, 39, MAX(80, w - newTaskSize.width - 48), 31);
    self.createTaskButton.frame = NSMakeRect(w - newTaskSize.width - 12, 40, newTaskSize.width, 30);
    self.toggleAllButton.frame = NSMakeRect(10, 83, self.toggleAllButton.intrinsicContentSize.width, 28);
    NSSize filterSize = self.filterControl.intrinsicContentSize; self.filterControl.frame = NSMakeRect(w - filterSize.width - 12, 83, filterSize.width, 28);
    NSSize datePresetSize = self.datePresetControl.intrinsicContentSize;
    self.datePresetControl.frame = NSMakeRect((w - datePresetSize.width) / 2, 123, datePresetSize.width, 28);
    self.dateRangeLabel.frame = NSMakeRect(12, 154, w - 24, 17);
    self.countLabel.frame = NSMakeRect(12, h - 31, w - 130, 18);
    NSSize clearSize = self.clearButton.intrinsicContentSize; self.clearButton.frame = NSMakeRect(w - clearSize.width - 8, h - 37, clearSize.width, 28);
    self.scrollView.frame = NSMakeRect(0, 178, w, MAX(0, h - 178 - 42));
}
- (void)drawRect:(NSRect)dirtyRect {
    [NSColor.controlBackgroundColor setFill]; NSRectFill(self.bounds);
    [NSColor.separatorColor setFill];
    NSRectFill(NSMakeRect(0, 73, NSWidth(self.bounds), 1)); NSRectFill(NSMakeRect(0, 116, NSWidth(self.bounds), 1)); NSRectFill(NSMakeRect(0, 177, NSWidth(self.bounds), 1)); NSRectFill(NSMakeRect(0, NSHeight(self.bounds)-42, NSWidth(self.bounds), 1));
}
@end

static void SizeTextViewToScrollView(NSTextView *textView, NSScrollView *scrollView) {
    NSSize viewport = scrollView.contentView.bounds.size;
    CGFloat width = MAX(1.0, viewport.width);
    CGFloat minimumHeight = MAX(1.0, viewport.height);
    CGFloat horizontalInsets = textView.textContainerInset.width * 2.0;
    CGFloat containerWidth = MAX(1.0, width - horizontalInsets);

    textView.minSize = NSMakeSize(0, minimumHeight);
    textView.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
    textView.horizontallyResizable = NO;
    textView.textContainer.widthTracksTextView = NO;
    textView.textContainer.containerSize = NSMakeSize(containerWidth, CGFLOAT_MAX);
    textView.frame = NSMakeRect(0, 0, width, minimumHeight);

    [textView.layoutManager ensureLayoutForTextContainer:textView.textContainer];
    CGFloat usedHeight = NSHeight([textView.layoutManager usedRectForTextContainer:textView.textContainer]);
    CGFloat documentHeight = MAX(minimumHeight, ceil(usedHeight + textView.textContainerInset.height * 2.0));
    textView.frame = NSMakeRect(0, 0, width, documentHeight);
}

@interface DetailView : NSView
@property LiteButton *completeButton;
@property LiteSegmentedControl *modeControl;
@property LiteButton *closeButton;
@property NSScrollView *editorScroll;
@property NSTextView *editor;
@property NSTextField *placeholder;
@property DisclosureControl *completionResultDisclosure;
@property NSScrollView *completionResultScroll;
@property NSTextView *completionResultEditor;
@property LiteButton *deleteButton;
@property NSTextField *saveStatus;
@property LiteButton *saveButton;
@property(nullable) NSScrollView *previewScroll;
@property(nullable) NSTextView *preview;
@property(nullable) NSScrollView *completionResultPreviewScroll;
@property(nullable) NSTextView *completionResultPreview;
@property(nonatomic) BOOL resultExpanded;
@property(nonatomic) CGFloat resultRatio;
@property(nonatomic) TodoViewMode viewMode;
@end
@implementation DetailView
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _completeButton = [[LiteButton alloc] initWithTitle:@"标记完成" style:LiteButtonStylePlain];
        _modeControl = [[LiteSegmentedControl alloc] initWithLabels:@[@"编辑", @"分栏", @"预览"]];
        _closeButton = [[LiteButton alloc] initWithTitle:@"关闭" style:LiteButtonStylePlain];

        _editor = [[NSTextView alloc] initWithFrame:NSZeroRect];
        _editor.richText = NO;
        _editor.importsGraphics = NO;
        _editor.allowsUndo = YES;
        _editor.usesFindPanel = YES;
        _editor.font = [NSFont monospacedSystemFontOfSize:14 weight:NSFontWeightRegular];
        _editor.textContainerInset = NSMakeSize(44, 34);
        _editor.automaticQuoteSubstitutionEnabled = NO;
        _editor.automaticDashSubstitutionEnabled = NO;
        _editor.automaticTextReplacementEnabled = NO;
        _editor.automaticSpellingCorrectionEnabled = NO;
        _editor.continuousSpellCheckingEnabled = NO;
        _editor.grammarCheckingEnabled = NO;
        _editor.verticallyResizable = YES;
        _editor.horizontallyResizable = NO;
        _editor.autoresizingMask = NSViewWidthSizable;
        _editor.textContainer.widthTracksTextView = YES;

        _editorScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
        _editorScroll.documentView = _editor;
        _editorScroll.hasVerticalScroller = YES;
        _editorScroll.hasHorizontalScroller = NO;
        _editorScroll.autohidesScrollers = YES;
        _editorScroll.drawsBackground = YES;
        _editorScroll.borderType = NSNoBorder;
        _editorScroll.backgroundColor = NSColor.textBackgroundColor;

        _placeholder = [NSTextField labelWithString:@"从左侧选择一个任务"];
        _placeholder.font = [NSFont systemFontOfSize:14];
        _placeholder.textColor = NSColor.tertiaryLabelColor;
        _placeholder.alignment = NSTextAlignmentCenter;

        _completionResultDisclosure = [[DisclosureControl alloc] initWithTitle:@"完成结果"];
        _completionResultDisclosure.hidden = YES;

        _completionResultEditor = [[NSTextView alloc] initWithFrame:NSZeroRect];
        _completionResultEditor.richText = NO;
        _completionResultEditor.importsGraphics = NO;
        _completionResultEditor.allowsUndo = YES;
        _completionResultEditor.usesFindPanel = YES;
        _completionResultEditor.font = [NSFont monospacedSystemFontOfSize:13.5 weight:NSFontWeightRegular];
        _completionResultEditor.textContainerInset = NSMakeSize(16, 12);
        _completionResultEditor.automaticQuoteSubstitutionEnabled = NO;
        _completionResultEditor.automaticDashSubstitutionEnabled = NO;
        _completionResultEditor.automaticTextReplacementEnabled = NO;
        _completionResultEditor.automaticSpellingCorrectionEnabled = NO;
        _completionResultEditor.continuousSpellCheckingEnabled = NO;
        _completionResultEditor.grammarCheckingEnabled = NO;
        _completionResultEditor.verticallyResizable = YES;
        _completionResultEditor.horizontallyResizable = NO;
        _completionResultEditor.autoresizingMask = NSViewWidthSizable;
        _completionResultEditor.textContainer.widthTracksTextView = YES;

        _completionResultScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
        _completionResultScroll.documentView = _completionResultEditor;
        _completionResultScroll.hasVerticalScroller = YES;
        _completionResultScroll.hasHorizontalScroller = NO;
        _completionResultScroll.autohidesScrollers = YES;
        _completionResultScroll.drawsBackground = YES;
        _completionResultScroll.borderType = NSNoBorder;
        _completionResultScroll.backgroundColor = NSColor.textBackgroundColor;
        _completionResultScroll.hidden = YES;

        _deleteButton = [[LiteButton alloc] initWithTitle:@"删除" style:LiteButtonStyleDanger];
        _saveStatus = [NSTextField labelWithString:@""];
        _saveStatus.font = [NSFont systemFontOfSize:11];
        _saveStatus.textColor = NSColor.secondaryLabelColor;
        _saveStatus.alignment = NSTextAlignmentRight;
        _saveButton = [[LiteButton alloc] initWithTitle:@"保存" style:LiteButtonStylePrimary];

        CGFloat savedRatio = [NSUserDefaults.standardUserDefaults doubleForKey:TodoCompletionResultRatioDefaultsKey];
        NSString *benchmarkRatio = NSProcessInfo.processInfo.environment[@"TODO_BENCHMARK_RESULT_RATIO"];
        CGFloat configuredRatio = benchmarkRatio.length ? benchmarkRatio.doubleValue : savedRatio;
        _resultRatio = configuredRatio > 0.0 ? configuredRatio : 0.24;
        _resultExpanded = NO;
        _viewMode = TodoViewModeSplit;

        for (NSView *view in @[
            _completeButton, _modeControl, _closeButton, _editorScroll, _placeholder,
            _completionResultDisclosure, _completionResultScroll, _deleteButton, _saveStatus, _saveButton
        ]) {
            [self addSubview:view];
        }
    }
    return self;
}
- (BOOL)isFlipped { return YES; }
- (CGFloat)dividerThickness { return 1.0; }
- (CGFloat)availableContentHeight {
    return MAX(0.0, NSHeight(self.bounds) - 55.0 - 53.0);
}
- (CGFloat)resultHeight {
    CGFloat divider = [self dividerThickness];
    CGFloat usable = MAX(0.0, [self availableContentHeight] - divider);
    if (!self.resultExpanded || usable <= 0.0) return 0.0;
    CGFloat minimumResult = MIN(100.0, usable);
    CGFloat minimumDocument = MIN(150.0, MAX(0.0, usable - minimumResult));
    CGFloat maximumResult = MAX(minimumResult, usable - minimumDocument);
    return MIN(maximumResult, MAX(minimumResult, round(usable * self.resultRatio)));
}
- (NSRect)dividerRect {
    if (!self.resultExpanded) return NSZeroRect;
    CGFloat footerTop = MAX(55.0, NSHeight(self.bounds) - 53.0);
    CGFloat resultHeight = [self resultHeight];
    return NSMakeRect(0, footerTop - resultHeight - [self dividerThickness], NSWidth(self.bounds), [self dividerThickness]);
}
- (void)layoutPaneFrame:(NSRect)frame
              editorScroll:(NSScrollView *)editorScroll
             previewScroll:(NSScrollView *)previewScroll {
    if (self.viewMode == TodoViewModeSplit) {
        CGFloat separator = 1.0;
        CGFloat editorWidth = floor(MAX(0.0, NSWidth(frame) - separator) / 2.0);
        CGFloat previewWidth = MAX(0.0, NSWidth(frame) - editorWidth - separator);
        editorScroll.frame = NSMakeRect(NSMinX(frame), NSMinY(frame), editorWidth, NSHeight(frame));
        previewScroll.frame = NSMakeRect(NSMinX(frame) + editorWidth + separator, NSMinY(frame), previewWidth, NSHeight(frame));
    } else {
        editorScroll.frame = frame;
        previewScroll.frame = frame;
    }
}
- (void)layout {
    [super layout];
    CGFloat width = NSWidth(self.bounds);
    CGFloat height = NSHeight(self.bounds);

    NSSize completeSize = self.completeButton.intrinsicContentSize;
    self.completeButton.frame = NSMakeRect(12, 12, MAX(96, completeSize.width), 30);
    NSSize modeSize = self.modeControl.intrinsicContentSize;
    self.modeControl.frame = NSMakeRect((width - modeSize.width) / 2, 13, modeSize.width, 28);
    NSSize closeSize = self.closeButton.intrinsicContentSize;
    self.closeButton.frame = NSMakeRect(width - closeSize.width - 12, 12, closeSize.width, 30);

    CGFloat footerTop = MAX(55.0, height - 53.0);
    NSRect documentFrame;
    CGFloat disclosureHeight = 38.0;
    if (self.resultExpanded) {
        NSRect divider = [self dividerRect];
        documentFrame = NSMakeRect(0, 55, width, MAX(0.0, NSMinY(divider) - 55.0));
        CGFloat resultTop = NSMaxY(divider);
        CGFloat resultHeight = MAX(0.0, footerTop - resultTop);
        self.completionResultDisclosure.frame = NSMakeRect(0, resultTop, width, disclosureHeight);
        NSRect resultContentFrame = NSMakeRect(0, resultTop + disclosureHeight, width, MAX(0.0, resultHeight - disclosureHeight));
        [self layoutPaneFrame:resultContentFrame
                  editorScroll:self.completionResultScroll
                 previewScroll:self.completionResultPreviewScroll];
        SizeTextViewToScrollView(self.completionResultEditor, self.completionResultScroll);
        if (self.completionResultPreview && self.completionResultPreviewScroll) {
            SizeTextViewToScrollView(self.completionResultPreview, self.completionResultPreviewScroll);
        }
    } else {
        CGFloat disclosureTop = MAX(55.0, footerTop - disclosureHeight);
        documentFrame = NSMakeRect(0, 55, width, MAX(0.0, disclosureTop - 55.0));
        self.completionResultDisclosure.frame = NSMakeRect(0, disclosureTop, width, disclosureHeight);
        self.completionResultScroll.frame = NSZeroRect;
        self.completionResultPreviewScroll.frame = NSZeroRect;
    }

    [self layoutPaneFrame:documentFrame editorScroll:self.editorScroll previewScroll:self.previewScroll];
    SizeTextViewToScrollView(self.editor, self.editorScroll);
    if (self.preview && self.previewScroll) SizeTextViewToScrollView(self.preview, self.previewScroll);
    self.placeholder.frame = NSMakeRect((width - 280) / 2, 55 + (NSHeight(documentFrame) - 24) / 2, 280, 24);

    NSSize deleteSize = self.deleteButton.intrinsicContentSize;
    self.deleteButton.frame = NSMakeRect(12, height - 41, deleteSize.width, 30);
    NSSize saveSize = self.saveButton.intrinsicContentSize;
    self.saveButton.frame = NSMakeRect(width - saveSize.width - 12, height - 42, saveSize.width, 30);
    self.saveStatus.frame = NSMakeRect(MAX(80, width - 260), height - 35, MAX(80, 180 - saveSize.width), 18);
    [self resetCursorRects];
}
- (void)setViewMode:(TodoViewMode)viewMode {
    _viewMode = viewMode;
    [self setNeedsLayout:YES];
    [self setNeedsDisplay:YES];
}
- (void)setResultExpanded:(BOOL)resultExpanded {
    _resultExpanded = resultExpanded;
    self.completionResultDisclosure.expanded = resultExpanded;
    [self setNeedsLayout:YES];
    [self setNeedsDisplay:YES];
}
- (NSRect)dividerHitRect {
    NSRect divider = [self dividerRect];
    if (NSIsEmptyRect(divider)) return NSZeroRect;
    return NSInsetRect(divider, 0, -3.0);
}
- (void)resetCursorRects {
    [super resetCursorRects];
    NSRect hitRect = [self dividerHitRect];
    if (!NSIsEmptyRect(hitRect)) [self addCursorRect:hitRect cursor:NSCursor.resizeUpDownCursor];
}
- (void)mouseDown:(NSEvent *)event {
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    if (!self.resultExpanded || !NSPointInRect(point, [self dividerHitRect])) {
        [super mouseDown:event];
        return;
    }

    CGFloat available = MAX(1.0, [self availableContentHeight] - [self dividerThickness]);
    while (YES) {
        NSEvent *next = [self.window nextEventMatchingMask:(NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp)];
        if (!next || next.type == NSEventTypeLeftMouseUp) break;
        NSPoint dragPoint = [self convertPoint:next.locationInWindow fromView:nil];
        CGFloat footerTop = MAX(55.0, NSHeight(self.bounds) - 53.0);
        CGFloat desiredResultHeight = footerTop - dragPoint.y - [self dividerThickness] / 2.0;
        self.resultRatio = desiredResultHeight / available;
        [self setNeedsLayout:YES];
        [self setNeedsDisplay:YES];
        [self layoutSubtreeIfNeeded];
    }
    self.resultRatio = [self resultHeight] / available;
    [NSUserDefaults.standardUserDefaults setDouble:self.resultRatio forKey:TodoCompletionResultRatioDefaultsKey];
}
- (void)drawRect:(NSRect)dirtyRect {
    [NSColor.textBackgroundColor setFill];
    NSRectFill(self.bounds);
    [NSColor.separatorColor setFill];
    CGFloat footerTop = MAX(55.0, NSHeight(self.bounds) - 53.0);
    NSRectFill(NSMakeRect(0, 54, NSWidth(self.bounds), 1));
    if (self.resultExpanded) {
        NSRectFill([self dividerRect]);
    } else if (!self.completionResultDisclosure.hidden) {
        NSRectFill(NSMakeRect(0, NSMinY(self.completionResultDisclosure.frame), NSWidth(self.bounds), 1));
    }
    if (self.viewMode == TodoViewModeSplit) {
        if (!self.editorScroll.hidden && !self.previewScroll.hidden && self.previewScroll) {
            NSRect frame = self.editorScroll.frame;
            NSRectFill(NSMakeRect(NSMaxX(frame), NSMinY(frame), 1, NSHeight(frame)));
        }
        if (self.resultExpanded && !self.completionResultScroll.hidden
            && !self.completionResultPreviewScroll.hidden && self.completionResultPreviewScroll) {
            NSRect frame = self.completionResultScroll.frame;
            NSRectFill(NSMakeRect(NSMaxX(frame), NSMinY(frame), 1, NSHeight(frame)));
        }
    }
    NSRectFill(NSMakeRect(0, footerTop, NSWidth(self.bounds), 1));
}
@end

@interface TodoController : NSViewController <NSTableViewDataSource,NSTableViewDelegate,NSTextViewDelegate,NSSplitViewDelegate,NSTextFieldDelegate>
@property NSSplitView *split;
@property SidebarView *sidebar;
@property DetailView *detail;
@property NSArray<NSDictionary *> *summaries;
@property NSArray<NSDictionary *> *filtered;
@property TodoLanguage language;
@property TodoViewMode viewMode;
@property NSInteger filterIndex;
@property TodoDateFilterMode dateFilterMode;
@property(nullable) NSDate *createdFromDate;
@property(nullable) NSDate *createdToExclusiveDate;
@property(nullable) NSNumber *selectedID;
@property(nullable) NSDictionary *currentTodo;
@property NSString *editorSnapshot;
@property NSString *completionResultSnapshot;
@property NSMutableDictionary<NSNumber *, NSNumber *> *resultExpansionOverrides;
@property BOOL dirty;
@property BOOL suppressTextChanges;
@property(nullable) NSTimer *saveTimer;
@property(nullable) NSTimer *previewTimer;
@property BOOL benchmarkRan;
@end

@implementation TodoController
- (void)loadView {
    self.summaries = @[]; self.filtered = @[]; self.editorSnapshot = @""; self.completionResultSnapshot = @"";
    self.resultExpansionOverrides = [NSMutableDictionary dictionary];
    NSString *savedLanguage = [NSUserDefaults.standardUserDefaults stringForKey:TodoLanguageDefaultsKey];
    NSString *benchmarkLanguage = NSProcessInfo.processInfo.environment[@"TODO_BENCHMARK_LANGUAGE"];
    NSString *initialLanguage = benchmarkLanguage.length ? benchmarkLanguage : savedLanguage;
    self.language = [initialLanguage isEqualToString:@"en"] ? TodoLanguageEnglish : TodoLanguageChinese;
    NSNumber *savedViewMode = [NSUserDefaults.standardUserDefaults objectForKey:TodoViewModeDefaultsKey];
    NSInteger configuredViewMode = savedViewMode ? savedViewMode.integerValue : TodoViewModeSplit;
    self.viewMode = (TodoViewMode)MAX(TodoViewModeEdit, MIN(configuredViewMode, TodoViewModePreview));
    self.split = [[NSSplitView alloc] initWithFrame:NSMakeRect(0,0,1120,780)]; self.split.vertical = YES; self.split.dividerStyle = NSSplitViewDividerStyleThin; self.split.delegate = self; self.split.autoresizingMask = NSViewWidthSizable|NSViewHeightSizable;
    self.sidebar = [[SidebarView alloc] initWithFrame:NSMakeRect(0,0,320,780)]; self.detail = [[DetailView alloc] initWithFrame:NSMakeRect(0,0,800,780)];
    self.detail.viewMode = self.viewMode;
    self.sidebar.autoresizingMask = NSViewHeightSizable;
    self.detail.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.split addArrangedSubview:self.sidebar]; [self.split addArrangedSubview:self.detail]; self.view = self.split;
    self.sidebar.tableView.delegate = self; self.sidebar.tableView.dataSource = self;
    __weak typeof(self) weakSelf = self;
    self.sidebar.createTaskButton.handler = ^{ [weakSelf addEditableTask]; };
    self.sidebar.languageControl.changeHandler = ^(NSInteger index) { [weakSelf changeLanguage:(TodoLanguage)index]; };
    self.sidebar.toggleAllButton.handler = ^{ [weakSelf toggleAll]; };
    self.sidebar.clearButton.handler = ^{ [weakSelf clearCompleted]; };
    self.sidebar.filterControl.changeHandler = ^(NSInteger index) { weakSelf.filterIndex = index; [weakSelf applyFilter]; };
    self.sidebar.datePresetControl.changeHandler = ^(NSInteger index) { [weakSelf selectDateFilter:(TodoDateFilterMode)index]; };
    self.detail.completeButton.handler = ^{ [weakSelf toggleCurrent]; };
    self.detail.completionResultDisclosure.handler = ^(BOOL expanded) { [weakSelf setCompletionResultExpanded:expanded remember:YES]; };
    self.detail.modeControl.changeHandler = ^(NSInteger index) { [weakSelf changeViewMode:index]; };
    self.detail.closeButton.handler = ^{ [weakSelf closeCurrent]; };
    self.detail.deleteButton.handler = ^{ [weakSelf deleteCurrent]; };
    self.detail.saveButton.handler = ^{ [weakSelf saveIfNeeded]; };
    self.detail.editor.delegate = self;
    self.detail.completionResultEditor.delegate = self;
    [self applyLanguage];
    [self setDocumentAvailable:NO]; [self reloadSummaries];
}
- (void)viewDidAppear {
    [super viewDidAppear];
    [self.split adjustSubviews];
    [self.split setPosition:320 ofDividerAtIndex:0];
    [self.split adjustSubviews];
    [self runBenchmarkMode];
}
- (void)changeViewMode:(NSInteger)viewMode {
    TodoViewMode normalizedMode = (TodoViewMode)MAX(TodoViewModeEdit, MIN(viewMode, TodoViewModePreview));
    self.viewMode = normalizedMode;
    self.detail.viewMode = normalizedMode;
    self.detail.modeControl.selectedIndex = normalizedMode;
    [NSUserDefaults.standardUserDefaults setInteger:normalizedMode forKey:TodoViewModeDefaultsKey];
    if (!self.currentTodo) {
        [self applyWorkspacePresentation];
        return;
    }
    if (normalizedMode == TodoViewModeEdit) [self showEditor];
    else if (normalizedMode == TodoViewModeSplit) [self showSplit];
    else [self showPreview];
}
- (void)fallBackToEditorMode {
    self.viewMode = TodoViewModeEdit;
    self.detail.viewMode = TodoViewModeEdit;
    self.detail.modeControl.selectedIndex = TodoViewModeEdit;
    [NSUserDefaults.standardUserDefaults setInteger:TodoViewModeEdit forKey:TodoViewModeDefaultsKey];
    [self showEditor];
}
- (void)applyWorkspacePresentation {
    BOOL available = self.currentTodo != nil;
    self.detail.viewMode = self.viewMode;
    self.detail.placeholder.hidden = available;
    self.detail.completionResultDisclosure.hidden = !available;
    self.detail.completionResultDisclosure.enabled = available;
    self.detail.completionResultDisclosure.expanded = self.detail.resultExpanded;

    BOOL showEditor = available && self.viewMode != TodoViewModePreview;
    BOOL showPreview = available && self.viewMode != TodoViewModeEdit && self.detail.previewScroll != nil;
    self.detail.editorScroll.hidden = !showEditor;
    self.detail.previewScroll.hidden = !showPreview;

    BOOL showResultEditor = available && self.detail.resultExpanded && self.viewMode != TodoViewModePreview;
    BOOL showResultPreview = available && self.detail.resultExpanded && self.viewMode != TodoViewModeEdit
        && self.detail.completionResultPreviewScroll != nil;
    self.detail.completionResultScroll.hidden = !showResultEditor;
    self.detail.completionResultPreviewScroll.hidden = !showResultPreview;
    [self.detail setNeedsLayout:YES];
    [self.detail setNeedsDisplay:YES];
    [self.detail layoutSubtreeIfNeeded];
}
- (void)setCompletionResultExpanded:(BOOL)expanded remember:(BOOL)remember {
    if (!self.currentTodo) return;
    self.detail.resultExpanded = expanded;
    if (remember && self.selectedID) self.resultExpansionOverrides[self.selectedID] = @(expanded);

    if (!expanded && self.detail.completionResultPreviewScroll) {
        [self.detail.completionResultPreviewScroll removeFromSuperview];
        self.detail.completionResultPreviewScroll = nil;
        self.detail.completionResultPreview = nil;
    }
    if (expanded && self.viewMode != TodoViewModeEdit) {
        NSError *error = nil;
        if (![self renderCompletionResultPreview:&error]) [self showError:error];
    }
    [self applyWorkspacePresentation];
}
- (void)changeLanguage:(TodoLanguage)language {
    if (language == self.language) return;
    self.language = language;
    [NSUserDefaults.standardUserDefaults setObject:(language == TodoLanguageEnglish ? @"en" : @"zh") forKey:TodoLanguageDefaultsKey];
    [self applyLanguage];
}
- (void)applyLanguage {
    BOOL english = self.language == TodoLanguageEnglish;
    self.sidebar.languageControl.selectedIndex = self.language;

    NSDateFormatter *dateFormatter = [NSDateFormatter new];
    dateFormatter.locale = [NSLocale localeWithLocaleIdentifier:(english ? @"en_US" : @"zh_CN")];
    dateFormatter.dateFormat = english ? @"EEEE, MMM d" : @"M月d日 EEEE";
    self.sidebar.dateLabel.stringValue = [dateFormatter stringFromDate:NSDate.date];

    self.sidebar.headingLabel.stringValue = TodoLocalized(self.language, @"今天要做什么？", @"Today's tasks");
    self.sidebar.createTaskButton.title = TodoLocalized(self.language, @"新建任务", @"New Task");
    self.sidebar.filterControl.labels = english ? @[@"All", @"Active", @"Done"] : @[@"全部", @"待办", @"已完成"];
    self.sidebar.datePresetControl.labels = english ? @[@"All", @"24h", @"7 days", @"Custom"] : @[@"全部", @"24小时", @"近7天", @"自定义"];
    self.sidebar.clearButton.title = TodoLocalized(self.language, @"清除已完成", @"Clear Done");

    self.detail.modeControl.labels = english ? @[@"Edit", @"Split", @"Preview"] : @[@"编辑", @"分栏", @"预览"];
    self.detail.modeControl.selectedIndex = self.viewMode;
    self.detail.closeButton.title = TodoLocalized(self.language, @"关闭", @"Close");
    self.detail.placeholder.stringValue = TodoLocalized(self.language, @"从左侧选择一个任务", @"Select a task from the sidebar");
    self.detail.completionResultDisclosure.title = TodoLocalized(self.language, @"完成结果", @"Completion Result");
    self.detail.deleteButton.title = TodoLocalized(self.language, @"删除", @"Delete");
    self.detail.saveButton.title = TodoLocalized(self.language, @"保存", @"Save");

    [self updateCompletion];
    [self updateDateRangeControls];
    [self applyFilter];
    if (self.currentTodo) {
        [self setSaveStatus:(self.dirty ? TodoLocalized(self.language, @"等待保存…", @"Waiting to save…") : TodoLocalized(self.language, @"已保存", @"Saved")) error:NO];
    }

    [self.sidebar setNeedsLayout:YES];
    [self.sidebar layoutSubtreeIfNeeded];
    [self.detail setNeedsLayout:YES];
    [self.detail layoutSubtreeIfNeeded];
    [NSNotificationCenter.defaultCenter postNotificationName:TodoLanguageDidChangeNotification object:self];
}
- (CGFloat)splitView:(NSSplitView *)splitView constrainMinCoordinate:(CGFloat)proposedMinimumPosition ofSubviewAt:(NSInteger)dividerIndex { return 280; }
- (CGFloat)splitView:(NSSplitView *)splitView constrainMaxCoordinate:(CGFloat)proposedMaximumPosition ofSubviewAt:(NSInteger)dividerIndex { return MIN(380, NSWidth(splitView.bounds)-440); }
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView { return self.filtered.count; }
- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    if (row < 0 || row >= self.filtered.count) return nil; NSDictionary *summary = self.filtered[row];
    TaskCellView *cell = [tableView makeViewWithIdentifier:@"TaskCell" owner:self]; if (!cell) { cell = [[TaskCellView alloc] initWithFrame:NSZeroRect]; cell.identifier = @"TaskCell"; }
    NSNumber *todoID = summary[@"id"]; __weak typeof(self) weakSelf = self;
    [cell configure:summary handler:^(BOOL completed) { [weakSelf toggleID:todoID completed:completed]; }]; return cell;
}
- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    NSInteger row = self.sidebar.tableView.selectedRow; if (row < 0 || row >= self.filtered.count) return; NSNumber *todoID = self.filtered[row][@"id"]; if ([todoID isEqual:self.selectedID]) return;
    if (![self saveIfNeeded]) { [self updateSelection]; return; } [self selectID:todoID];
}
- (void)reloadSummaries {
    NSError *error = nil; id value = BridgeCall(@{@"command":@"list"}, &error); if (!value) { [self showError:error]; return; }
    self.summaries = value; if (self.selectedID && ![self summaryForID:self.selectedID]) { self.selectedID = nil; [self clearCurrent]; }
    [self applyFilter];
}
- (void)applyFilter {
    NSInteger statusFilter = self.filterIndex;
    NSDate *effectiveFrom = self.createdFromDate;
    NSDate *effectiveTo = self.createdToExclusiveDate;
    NSDate *now = NSDate.date;

    if (self.dateFilterMode == TodoDateFilterModeLast24Hours) {
        effectiveFrom = [now dateByAddingTimeInterval:-(24.0 * 60.0 * 60.0)];
        effectiveTo = now;
    } else if (self.dateFilterMode == TodoDateFilterModeLast7Days) {
        effectiveFrom = [now dateByAddingTimeInterval:-(7.0 * 24.0 * 60.0 * 60.0)];
        effectiveTo = now;
    } else if (self.dateFilterMode == TodoDateFilterModeAll) {
        effectiveFrom = nil;
        effectiveTo = nil;
    }

    BOOL hasFrom = effectiveFrom != nil;
    BOOL hasTo = effectiveTo != nil;
    BOOL toIsExclusive = self.dateFilterMode == TodoDateFilterModeCustom;
    double fromMs = hasFrom ? effectiveFrom.timeIntervalSince1970 * 1000.0 : 0;
    double toMs = hasTo ? effectiveTo.timeIntervalSince1970 * 1000.0 : 0;

    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(NSDictionary *summary, NSDictionary *bindings) {
        BOOL completed = [summary[@"completed"] boolValue];
        if (statusFilter == 1 && completed) return NO;
        if (statusFilter == 2 && !completed) return NO;

        if (hasFrom || hasTo) {
            id timestampValue = summary[@"createdAtMs"];
            if (![timestampValue isKindOfClass:NSNumber.class]) return NO;
            double createdAtMs = [timestampValue doubleValue];
            if (hasFrom && createdAtMs < fromMs) return NO;
            if (hasTo && (toIsExclusive ? createdAtMs >= toMs : createdAtMs > toMs)) return NO;
        }
        return YES;
    }];

    self.filtered = [self.summaries filteredArrayUsingPredicate:predicate];
    NSInteger active = 0;
    BOOL hasCompleted = NO;
    for (NSDictionary *summary in self.summaries) {
        if ([summary[@"completed"] boolValue]) hasCompleted = YES;
        else active++;
    }

    if (self.dateFilterMode != TodoDateFilterModeAll) {
        self.sidebar.countLabel.stringValue = self.language == TodoLanguageEnglish
            ? [NSString stringWithFormat:@"%ld shown · %ld tasks", (long)self.filtered.count, (long)self.summaries.count]
            : [NSString stringWithFormat:@"%ld 项显示 · %ld 项任务", (long)self.filtered.count, (long)self.summaries.count];
    } else {
        self.sidebar.countLabel.stringValue = self.language == TodoLanguageEnglish
            ? [NSString stringWithFormat:@"%ld active · %ld tasks", (long)active, (long)self.summaries.count]
            : [NSString stringWithFormat:@"%ld 项待办 · %ld 项任务", (long)active, (long)self.summaries.count];
    }
    self.sidebar.clearButton.hidden = !hasCompleted;
    self.sidebar.toggleAllButton.title = active == 0 && self.summaries.count
        ? TodoLocalized(self.language, @"全部恢复", @"Restore All")
        : TodoLocalized(self.language, @"全部完成", @"Complete All");
    [self.sidebar.tableView reloadData];
    [self updateSelection];
}
- (void)selectDateFilter:(TodoDateFilterMode)mode {
    if (mode == TodoDateFilterModeCustom) {
        [self chooseDateRange];
        return;
    }

    self.dateFilterMode = mode;
    self.createdFromDate = nil;
    self.createdToExclusiveDate = nil;
    [self updateDateRangeControls];
    [self applyFilter];
}
- (void)chooseDateRange {
    NSCalendar *calendar = NSCalendar.currentCalendar;
    NSDate *now = NSDate.date;
    NSDate *defaultStart = self.dateFilterMode == TodoDateFilterModeCustom ? self.createdFromDate : nil;
    if (!defaultStart) {
        double earliestMs = DBL_MAX;
        for (NSDictionary *summary in self.summaries) {
            id value = summary[@"createdAtMs"];
            if ([value isKindOfClass:NSNumber.class]) earliestMs = MIN(earliestMs, [value doubleValue]);
        }
        defaultStart = earliestMs < DBL_MAX ? [NSDate dateWithTimeIntervalSince1970:earliestMs / 1000.0] : [calendar dateByAddingUnit:NSCalendarUnitMonth value:-1 toDate:now options:0];
    }
    NSDate *defaultEnd = self.dateFilterMode == TodoDateFilterModeCustom && self.createdToExclusiveDate
        ? [calendar dateByAddingUnit:NSCalendarUnitDay value:-1 toDate:self.createdToExclusiveDate options:0]
        : now;

    NSView *accessory = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 330, 76)];
    NSTextField *fromLabel = [NSTextField labelWithString:TodoLocalized(self.language, @"开始日期", @"Start date")];
    NSTextField *toLabel = [NSTextField labelWithString:TodoLocalized(self.language, @"结束日期", @"End date")];
    fromLabel.frame = NSMakeRect(0, 48, 70, 20);
    toLabel.frame = NSMakeRect(0, 10, 70, 20);

    NSDatePicker *fromPicker = [[NSDatePicker alloc] initWithFrame:NSMakeRect(78, 43, 240, 28)];
    NSDatePicker *toPicker = [[NSDatePicker alloc] initWithFrame:NSMakeRect(78, 5, 240, 28)];
    for (NSDatePicker *picker in @[fromPicker, toPicker]) {
        picker.datePickerStyle = NSDatePickerStyleTextFieldAndStepper;
        picker.datePickerMode = NSDatePickerModeSingle;
        picker.datePickerElements = NSDatePickerElementFlagYearMonthDay;
    }
    fromPicker.dateValue = defaultStart;
    toPicker.dateValue = defaultEnd;
    [accessory addSubview:fromLabel];
    [accessory addSubview:toLabel];
    [accessory addSubview:fromPicker];
    [accessory addSubview:toPicker];

    NSAlert *alert = [NSAlert new];
    alert.messageText = TodoLocalized(self.language, @"按首次定义时间筛选", @"Filter by creation time");
    alert.informativeText = TodoLocalized(self.language, @"开始和结束日期均包含在筛选范围内。", @"Both start and end dates are included.");
    alert.accessoryView = accessory;
    [alert addButtonWithTitle:TodoLocalized(self.language, @"应用", @"Apply")];
    [alert addButtonWithTitle:TodoLocalized(self.language, @"取消", @"Cancel")];
    [alert addButtonWithTitle:TodoLocalized(self.language, @"全部时间", @"All Time")];

    __weak typeof(self) weakSelf = self;
    [alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse response) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (response == NSAlertThirdButtonReturn) {
            [strongSelf selectDateFilter:TodoDateFilterModeAll];
            return;
        }
        if (response != NSAlertFirstButtonReturn) {
            strongSelf.sidebar.datePresetControl.selectedIndex = strongSelf.dateFilterMode;
            return;
        }

        NSDate *start = [calendar startOfDayForDate:fromPicker.dateValue];
        NSDate *endDay = [calendar startOfDayForDate:toPicker.dateValue];
        NSDate *endExclusive = [calendar dateByAddingUnit:NSCalendarUnitDay value:1 toDate:endDay options:0];
        if ([start compare:endExclusive] != NSOrderedAscending) {
            strongSelf.sidebar.datePresetControl.selectedIndex = strongSelf.dateFilterMode;
            NSError *error = [NSError errorWithDomain:TodoErrorDomain code:6 userInfo:@{NSLocalizedDescriptionKey: TodoLocalized(strongSelf.language, @"开始日期不能晚于结束日期", @"The start date cannot be later than the end date")}];
            [strongSelf showError:error];
            return;
        }

        strongSelf.dateFilterMode = TodoDateFilterModeCustom;
        strongSelf.createdFromDate = start;
        strongSelf.createdToExclusiveDate = endExclusive;
        [strongSelf updateDateRangeControls];
        [strongSelf applyFilter];
    }];
}
- (void)updateDateRangeControls {
    self.sidebar.datePresetControl.selectedIndex = self.dateFilterMode;

    if (self.dateFilterMode == TodoDateFilterModeLast24Hours) {
        self.sidebar.dateRangeLabel.stringValue = TodoLocalized(self.language, @"滚动范围：过去 24 小时", @"Rolling range: last 24 hours");
        return;
    }
    if (self.dateFilterMode == TodoDateFilterModeLast7Days) {
        self.sidebar.dateRangeLabel.stringValue = TodoLocalized(self.language, @"滚动范围：过去 7 天", @"Rolling range: last 7 days");
        return;
    }
    if (self.dateFilterMode != TodoDateFilterModeCustom || !self.createdFromDate || !self.createdToExclusiveDate) {
        self.sidebar.dateRangeLabel.stringValue = TodoLocalized(self.language, @"全部首次定义时间", @"All creation times");
        return;
    }

    NSDate *inclusiveEnd = [NSCalendar.currentCalendar dateByAddingUnit:NSCalendarUnitDay value:-1 toDate:self.createdToExclusiveDate options:0];
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:(self.language == TodoLanguageEnglish ? @"en_US" : @"zh_CN")];
    formatter.dateFormat = @"yyyy-MM-dd";
    self.sidebar.dateRangeLabel.stringValue = [NSString stringWithFormat:(self.language == TodoLanguageEnglish ? @"%@ to %@" : @"%@ 至 %@"), [formatter stringFromDate:self.createdFromDate], [formatter stringFromDate:inclusiveEnd]];
}
- (NSDictionary *)summaryForID:(NSNumber *)todoID { for (NSDictionary *s in self.summaries) if ([s[@"id"] isEqual:todoID]) return s; return nil; }
- (void)updateSelection { NSInteger row = NSNotFound; if (self.selectedID) for (NSInteger i=0;i<self.filtered.count;i++) if ([self.filtered[i][@"id"] isEqual:self.selectedID]) { row=i; break; } if (row==NSNotFound) [self.sidebar.tableView deselectAll:nil]; else { [self.sidebar.tableView selectRowIndexes:[NSIndexSet indexSetWithIndex:row] byExtendingSelection:NO]; [self.sidebar.tableView scrollRowToVisible:row]; } }
- (void)selectID:(NSNumber *)todoID {
    NSError *error = nil;
    NSDictionary *todo = BridgeCall(@{@"command": @"get", @"id": todoID}, &error);
    if (!todo) {
        [self showError:error];
        [self updateSelection];
        return;
    }

    self.selectedID = todoID;
    self.currentTodo = todo;
    [self releasePreview];

    NSString *document = [self documentText:todo];
    NSString *completionResult = [self completionResultText:todo];
    self.suppressTextChanges = YES;
    self.detail.editor.string = document;
    self.detail.completionResultEditor.string = completionResult;
    self.suppressTextChanges = NO;

    NSCharacterSet *trimSet = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    self.editorSnapshot = [document stringByTrimmingCharactersInSet:trimSet];
    self.completionResultSnapshot = [completionResult stringByTrimmingCharactersInSet:trimSet];
    NSNumber *expansionOverride = self.resultExpansionOverrides[todoID];
    BOOL defaultExpanded = self.completionResultSnapshot.length > 0;
    self.detail.resultExpanded = expansionOverride ? expansionOverride.boolValue : defaultExpanded;
    self.dirty = NO;
    self.detail.modeControl.selectedIndex = self.viewMode;
    [self updateCompletion];
    [self setDocumentAvailable:YES];
    [self setSaveStatus:TodoLocalized(self.language, @"已保存", @"Saved") error:NO];
    [self updateSelection];
    if (self.viewMode == TodoViewModeEdit) [self showEditor];
    else if (self.viewMode == TodoViewModeSplit) [self showSplit];
    else [self showPreview];
}
- (NSString *)documentText:(NSDictionary *)todo {
    NSString *title = [todo[@"title"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    NSString *content = [todo[@"content"] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
    if (!title.length) return content;
    if (!content.length) return title;
    return [NSString stringWithFormat:@"%@\n\n%@", title, content];
}
- (NSString *)completionResultText:(NSDictionary *)todo {
    id value = todo[@"completionResult"];
    return [value isKindOfClass:NSString.class] ? value : @"";
}
- (NSString *)normalizedDocumentEditorText {
    return [self.detail.editor.string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}
- (NSString *)normalizedCompletionResultEditorText {
    return [self.detail.completionResultEditor.string stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}
- (void)setDocumentAvailable:(BOOL)available {
    self.detail.completeButton.enabled = available;
    self.detail.modeControl.enabled = available;
    self.detail.closeButton.enabled = available;
    self.detail.deleteButton.enabled = available;
    self.detail.saveButton.enabled = available;
    if (!available) self.detail.resultExpanded = NO;
    [self applyWorkspacePresentation];
}
- (void)clearCurrent {
    [self.saveTimer invalidate];
    self.saveTimer = nil;
    [self.previewTimer invalidate];
    self.previewTimer = nil;
    [self releasePreview];
    self.currentTodo = nil;
    self.suppressTextChanges = YES;
    self.detail.editor.string = @"";
    self.detail.completionResultEditor.string = @"";
    self.suppressTextChanges = NO;
    self.editorSnapshot = @"";
    self.completionResultSnapshot = @"";
    self.detail.resultExpanded = NO;
    self.dirty = NO;
    [self setDocumentAvailable:NO];
    [self setSaveStatus:@"" error:NO];
}
- (void)handleEditorChange {
    if (self.suppressTextChanges || !self.currentTodo) return;

    NSString *document = [self normalizedDocumentEditorText];
    NSString *completionResult = [self normalizedCompletionResultEditorText];
    self.dirty = ![document isEqual:self.editorSnapshot] || ![completionResult isEqual:self.completionResultSnapshot];
    [self setSaveStatus:(self.dirty
        ? TodoLocalized(self.language, @"等待保存…", @"Waiting to save…")
        : TodoLocalized(self.language, @"已保存", @"Saved")) error:NO];

    [self.saveTimer invalidate];
    if (self.dirty) {
        __weak typeof(self) weakSelf = self;
        self.saveTimer = [NSTimer scheduledTimerWithTimeInterval:0.65 repeats:NO block:^(NSTimer *timer) {
            [weakSelf saveIfNeeded];
        }];
    }
    [self scheduleLivePreviewUpdate];
}
- (void)textDidChange:(NSNotification *)notification {
    if (notification.object == self.detail.editor || notification.object == self.detail.completionResultEditor) {
        [self handleEditorChange];
    }
}
- (BOOL)saveIfNeeded {
    [self.saveTimer invalidate];
    self.saveTimer = nil;
    if (!self.currentTodo) return YES;

    NSString *document = [self normalizedDocumentEditorText];
    NSString *completionResult = [self normalizedCompletionResultEditorText];
    if (!document.length) {
        [self setSaveStatus:TodoLocalized(self.language, @"内容不能为空", @"Content cannot be empty") error:YES];
        NSBeep();
        return NO;
    }
    if (!self.dirty && [document isEqual:self.editorSnapshot] && [completionResult isEqual:self.completionResultSnapshot]) return YES;

    [self setSaveStatus:TodoLocalized(self.language, @"正在保存…", @"Saving…") error:NO];
    NSError *error = nil;
    NSDictionary *todo = BridgeCall(@{
        @"command": @"update",
        @"id": self.selectedID,
        @"title": @"",
        @"content": document,
        @"completionResult": completionResult,
    }, &error);
    if (!todo) {
        [self setSaveStatus:TodoLocalized(self.language, @"保存失败", @"Save failed") error:YES];
        [self showError:error];
        return NO;
    }

    self.currentTodo = todo;
    self.editorSnapshot = [[self documentText:todo] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    self.completionResultSnapshot = [[self completionResultText:todo] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    self.dirty = ![[self normalizedDocumentEditorText] isEqual:self.editorSnapshot]
        || ![[self normalizedCompletionResultEditorText] isEqual:self.completionResultSnapshot];
    [self setSaveStatus:(self.dirty
        ? TodoLocalized(self.language, @"有未保存修改", @"Unsaved changes")
        : TodoLocalized(self.language, @"已保存", @"Saved")) error:NO];
    [self reloadSummaries];
    return !self.dirty;
}
- (void)setSaveStatus:(NSString *)status error:(BOOL)isError { self.detail.saveStatus.stringValue=status; self.detail.saveStatus.textColor=isError?NSColor.systemRedColor:NSColor.secondaryLabelColor; }
- (void)addEditableTask {
    if (![self saveIfNeeded]) return;
    NSError *error = nil;
    NSDictionary *summary = BridgeCall(@{@"command": @"add", @"title": TodoLocalized(self.language, @"新任务", @"New Task")}, &error);
    if (!summary) {
        [self showError:error];
        return;
    }
    [self reloadSummaries];
    [self selectID:summary[@"id"]];
    if (self.viewMode != TodoViewModePreview) {
        [self.detail.editor setSelectedRange:NSMakeRange(0, self.detail.editor.string.length)];
        [self.view.window makeFirstResponder:self.detail.editor];
    }
}
- (void)toggleID:(NSNumber *)todoID completed:(BOOL)completed { if ([todoID isEqual:self.selectedID] && ![self saveIfNeeded]) { [self reloadSummaries]; return; } NSError *error=nil; NSDictionary *todo=BridgeCall(@{@"command":@"update",@"id":todoID,@"completed":@(completed)},&error); if (!todo){[self showError:error];[self reloadSummaries];return;} [self reloadSummaries]; if ([todoID isEqual:self.selectedID]) { self.currentTodo=todo; [self updateCompletion]; } }
- (void)toggleAll { if (![self saveIfNeeded]) return; BOOL complete=NO; for (NSDictionary *s in self.summaries) if (![s[@"completed"] boolValue]) {complete=YES;break;} NSError *error=nil; id value=BridgeCall(@{@"command":@"setAllCompleted",@"completed":@(complete)},&error); if(!value){[self showError:error];return;} self.summaries=value; [self applyFilter]; if(self.selectedID)[self selectID:self.selectedID]; }
- (void)clearCompleted { if (![self saveIfNeeded]) return; BOOL selectedCompleted=[self summaryForID:self.selectedID][@"completed"]?[ [self summaryForID:self.selectedID][@"completed"] boolValue]:NO; NSError *error=nil; if(!BridgeCall(@{@"command":@"clearCompleted"},&error)){[self showError:error];return;} if(selectedCompleted){self.selectedID=nil;[self clearCurrent];} [self reloadSummaries]; }
- (void)toggleCurrent { if(![self saveIfNeeded]||!self.currentTodo)return; [self toggleID:self.selectedID completed:![self.currentTodo[@"completed"] boolValue]]; }
- (void)updateCompletion { BOOL completed=[self.currentTodo[@"completed"] boolValue]; self.detail.completeButton.title=completed?TodoLocalized(self.language, @"恢复为待办", @"Restore to Active"):TodoLocalized(self.language, @"标记完成", @"Mark Complete"); self.detail.completeButton.foregroundColor=completed?NSColor.systemGreenColor:NSColor.secondaryLabelColor; [self.detail setNeedsLayout:YES]; [self.detail layoutSubtreeIfNeeded]; }
- (void)deleteCurrent { if(!self.selectedID)return; NSNumber *deletedID=self.selectedID; NSError *error=nil; if(!BridgeCall(@{@"command":@"delete",@"id":deletedID},&error)){[self showError:error];return;} [self.resultExpansionOverrides removeObjectForKey:deletedID]; self.selectedID=nil; [self clearCurrent]; [self reloadSummaries]; }
- (void)closeCurrent { if(![self saveIfNeeded])return; self.selectedID=nil; [self clearCurrent]; [self updateSelection]; }
- (void)scheduleLivePreviewUpdate {
    [self.previewTimer invalidate];
    self.previewTimer = nil;
    if (self.viewMode != TodoViewModeSplit || !self.currentTodo) return;

    __weak typeof(self) weakSelf = self;
    self.previewTimer = [NSTimer scheduledTimerWithTimeInterval:0.12 repeats:NO block:^(NSTimer *timer) {
        [weakSelf refreshMarkdownPreviewPresentingErrors:NO];
    }];
}
- (BOOL)renderCompletionResultPreview:(NSError **)error {
    if (!self.detail.resultExpanded) return YES;
    NSArray *runs = BridgeCall(
        @{@"command": @"renderMarkdown", @"markdown": self.detail.completionResultEditor.string},
        error
    );
    if (!runs) return NO;

    NSTextView *preview = [self ensureCompletionResultPreview];
    [preview.textStorage setAttributedString:[self attributedMarkdown:runs]];
    SizeTextViewToScrollView(preview, self.detail.completionResultPreviewScroll);
    return YES;
}
- (BOOL)refreshMarkdownPreviewPresentingErrors:(BOOL)presentErrors {
    if (!self.currentTodo || self.viewMode == TodoViewModeEdit) return YES;

    @try {
        NSError *documentError = nil;
        NSArray *documentRuns = BridgeCall(
            @{@"command": @"renderMarkdown", @"markdown": self.detail.editor.string},
            &documentError
        );
        if (!documentRuns) {
            if (presentErrors) [self showError:documentError];
            else fprintf(stderr, "live document preview failed: %s\n", documentError.localizedDescription.UTF8String);
            return NO;
        }

        NSError *resultError = nil;
        if (![self renderCompletionResultPreview:&resultError]) {
            if (presentErrors) [self showError:resultError];
            else fprintf(stderr, "live result preview failed: %s\n", resultError.localizedDescription.UTF8String);
            return NO;
        }

        NSTextView *documentPreview = [self ensurePreview];
        [documentPreview.textStorage setAttributedString:[self attributedMarkdown:documentRuns]];
        SizeTextViewToScrollView(documentPreview, self.detail.previewScroll);
        [self applyWorkspacePresentation];
        return YES;
    } @catch (NSException *exception) {
        fprintf(stderr, "preview exception: %s (%s)\n", exception.name.UTF8String, exception.reason.UTF8String);
        if (presentErrors) {
            NSError *error = [NSError errorWithDomain:TodoErrorDomain
                                                 code:5
                                             userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: TodoLocalized(self.language, @"Markdown 预览失败", @"Markdown preview failed")}];
            [self showError:error];
        }
        return NO;
    }
}
- (void)showEditor {
    [self.previewTimer invalidate];
    self.previewTimer = nil;
    [self releasePreview];
    self.detail.modeControl.selectedIndex = TodoViewModeEdit;
    [self applyWorkspacePresentation];
    SizeTextViewToScrollView(self.detail.editor, self.detail.editorScroll);
    if (self.detail.resultExpanded) {
        SizeTextViewToScrollView(self.detail.completionResultEditor, self.detail.completionResultScroll);
    }
    [self.view.window makeFirstResponder:self.detail.editor];
}
- (void)showSplit {
    self.detail.modeControl.selectedIndex = TodoViewModeSplit;
    if (![self refreshMarkdownPreviewPresentingErrors:YES]) {
        [self fallBackToEditorMode];
        return;
    }
    [self applyWorkspacePresentation];
    [self.view.window makeFirstResponder:self.detail.editor];
}
- (void)showPreview {
    [self.previewTimer invalidate];
    self.previewTimer = nil;
    if (![self saveIfNeeded] || !self.currentTodo) {
        [self fallBackToEditorMode];
        return;
    }
    self.detail.modeControl.selectedIndex = TodoViewModePreview;
    if (![self refreshMarkdownPreviewPresentingErrors:YES]) {
        [self fallBackToEditorMode];
        return;
    }
    [self applyWorkspacePresentation];
    [self.detail.preview setSelectedRange:NSMakeRange(0, 0)];
    [self.detail.preview scrollToBeginningOfDocument:nil];
    [self.view.window makeFirstResponder:self.detail.preview];
}
- (NSTextView *)newMarkdownPreviewWithInsets:(NSSize)insets {
    NSTextView *text = [[NSTextView alloc] initWithFrame:NSZeroRect];
    text.editable = NO;
    text.selectable = YES;
    text.richText = YES;
    text.drawsBackground = YES;
    text.backgroundColor = NSColor.textBackgroundColor;
    text.textContainerInset = insets;
    text.verticallyResizable = YES;
    text.horizontallyResizable = NO;
    text.autoresizingMask = NSViewWidthSizable;
    text.textContainer.widthTracksTextView = YES;
    text.linkTextAttributes = @{
        NSForegroundColorAttributeName: NSColor.linkColor,
        NSUnderlineStyleAttributeName: @(NSUnderlineStyleSingle),
    };
    return text;
}
- (NSScrollView *)newMarkdownPreviewScrollWithTextView:(NSTextView *)text relativeTo:(NSView *)relativeView {
    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scroll.documentView = text;
    scroll.hasVerticalScroller = YES;
    scroll.hasHorizontalScroller = NO;
    scroll.autohidesScrollers = YES;
    scroll.drawsBackground = YES;
    scroll.borderType = NSNoBorder;
    scroll.backgroundColor = NSColor.textBackgroundColor;
    [self.detail addSubview:scroll positioned:NSWindowAbove relativeTo:relativeView];
    return scroll;
}
- (NSTextView *)ensurePreview {
    if (self.detail.preview) return self.detail.preview;
    NSTextView *text = [self newMarkdownPreviewWithInsets:NSMakeSize(48, 36)];
    NSScrollView *scroll = [self newMarkdownPreviewScrollWithTextView:text relativeTo:self.detail.editorScroll];
    self.detail.preview = text;
    self.detail.previewScroll = scroll;
    [self.detail setNeedsLayout:YES];
    [self.detail layoutSubtreeIfNeeded];
    SizeTextViewToScrollView(text, scroll);
    return text;
}
- (NSTextView *)ensureCompletionResultPreview {
    if (self.detail.completionResultPreview) return self.detail.completionResultPreview;
    NSTextView *text = [self newMarkdownPreviewWithInsets:NSMakeSize(16, 12)];
    NSScrollView *scroll = [self newMarkdownPreviewScrollWithTextView:text relativeTo:self.detail.completionResultScroll];
    self.detail.completionResultPreview = text;
    self.detail.completionResultPreviewScroll = scroll;
    [self.detail setNeedsLayout:YES];
    [self.detail layoutSubtreeIfNeeded];
    SizeTextViewToScrollView(text, scroll);
    return text;
}
- (void)releasePreview {
    [self.detail.previewScroll removeFromSuperview];
    [self.detail.completionResultPreviewScroll removeFromSuperview];
    self.detail.previewScroll = nil;
    self.detail.preview = nil;
    self.detail.completionResultPreviewScroll = nil;
    self.detail.completionResultPreview = nil;
    self.detail.editorScroll.hidden = NO;
    self.detail.completionResultScroll.hidden = !self.detail.resultExpanded;
}
- (NSAttributedString *)attributedMarkdown:(NSArray<NSDictionary *> *)runs { NSMutableAttributedString *output=[[NSMutableAttributedString alloc] init]; for(NSDictionary *run in runs){NSString *style=run[@"style"]?:@"body";NSFont *font=[NSFont systemFontOfSize:15];NSColor *color=NSColor.labelColor;NSMutableParagraphStyle *p=[[NSMutableParagraphStyle alloc] init];p.lineSpacing=3;if([style isEqual:@"heading1"])font=[NSFont systemFontOfSize:30 weight:NSFontWeightBold];else if([style isEqual:@"heading2"])font=[NSFont systemFontOfSize:24 weight:NSFontWeightBold];else if([style isEqual:@"heading3"])font=[NSFont systemFontOfSize:20 weight:NSFontWeightSemibold];else if([style hasPrefix:@"heading"])font=[NSFont systemFontOfSize:16 weight:NSFontWeightSemibold];else if([style isEqual:@"quote"]){color=NSColor.secondaryLabelColor;p.headIndent=p.firstLineHeadIndent=18;}else if([style isEqual:@"code"]){font=[NSFont monospacedSystemFontOfSize:13.5 weight:NSFontWeightRegular];p.headIndent=p.firstLineHeadIndent=12;}else if([style isEqual:@"table"]){font=[NSFont monospacedSystemFontOfSize:13 weight:NSFontWeightRegular];}else if([style isEqual:@"separator"])color=NSColor.separatorColor; NSFontTraitMask traits=0;if([run[@"bold"] boolValue])traits|=NSBoldFontMask;if([run[@"italic"] boolValue])traits|=NSItalicFontMask;if(traits)font=[NSFontManager.sharedFontManager convertFont:font toHaveTrait:traits];NSMutableDictionary *a=[@{NSFontAttributeName:font,NSForegroundColorAttributeName:color,NSParagraphStyleAttributeName:p} mutableCopy];if([run[@"strikethrough"] boolValue])a[NSStrikethroughStyleAttributeName]=@(NSUnderlineStyleSingle);id linkValue=run[@"link"];NSString *link=[linkValue isKindOfClass:NSString.class]?linkValue:nil;if(link.length){NSURL *url=[NSURL URLWithString:link];if(url){a[NSLinkAttributeName]=url;a[NSForegroundColorAttributeName]=NSColor.linkColor;a[NSUnderlineStyleAttributeName]=@(NSUnderlineStyleSingle);}}[output appendAttributedString:[[NSAttributedString alloc] initWithString:run[@"text"]?:@"" attributes:a]];}return output; }
- (void)showError:(NSError *)error { if(!error)return;if(!self.view.window){NSLog(@"Todo error: %@",error.localizedDescription);return;}NSAlert *alert=[NSAlert alertWithError:error];[alert beginSheetModalForWindow:self.view.window completionHandler:nil]; }
- (void)runBenchmarkMode {
    if (self.benchmarkRan) return;
    self.benchmarkRan = YES;
    NSString *mode = NSProcessInfo.processInfo.environment[@"TODO_BENCHMARK_MODE"];
    if (!mode.length || !self.summaries.count) return;

    NSDictionary<NSString *, NSString *> *environment = NSProcessInfo.processInfo.environment;
    NSString *benchmarkDateFilter = environment[@"TODO_BENCHMARK_DATE_FILTER"];
    NSString *benchmarkFrom = environment[@"TODO_BENCHMARK_FROM_MS"];
    NSString *benchmarkTo = environment[@"TODO_BENCHMARK_TO_MS"];
    if ([benchmarkDateFilter isEqualToString:@"24h"]) {
        self.dateFilterMode = TodoDateFilterModeLast24Hours;
    } else if ([benchmarkDateFilter isEqualToString:@"7d"]) {
        self.dateFilterMode = TodoDateFilterModeLast7Days;
    } else if (benchmarkFrom.length || benchmarkTo.length) {
        self.dateFilterMode = TodoDateFilterModeCustom;
        if (benchmarkFrom.length) self.createdFromDate = [NSDate dateWithTimeIntervalSince1970:benchmarkFrom.doubleValue / 1000.0];
        if (benchmarkTo.length) self.createdToExclusiveDate = [NSDate dateWithTimeIntervalSince1970:benchmarkTo.doubleValue / 1000.0];
    }
    if (benchmarkDateFilter.length || benchmarkFrom.length || benchmarkTo.length) {
        [self updateDateRangeControls];
        [self applyFilter];
    }

    NSNumber *first = self.filtered.firstObject[@"id"] ?: self.summaries.firstObject[@"id"];
    if ([mode isEqual:@"edit"] || [mode isEqual:@"split"] || [mode isEqual:@"preview"]) {
        if ([mode isEqual:@"edit"]) self.viewMode = TodoViewModeEdit;
        else if ([mode isEqual:@"split"]) self.viewMode = TodoViewModeSplit;
        else self.viewMode = TodoViewModePreview;
        self.detail.viewMode = self.viewMode;
        self.detail.modeControl.selectedIndex = self.viewMode;
        [self selectID:first];
    }
    if ([environment[@"TODO_BENCHMARK_SWITCH_TO_SECOND"] boolValue] && self.filtered.count > 1) {
        [self selectID:self.filtered[1][@"id"]];
    }
    NSString *forcedResultExpansion = environment[@"TODO_BENCHMARK_RESULT_EXPANDED"];
    if (forcedResultExpansion.length) {
        [self setCompletionResultExpanded:forcedResultExpansion.boolValue remember:NO];
    }

    NSString *replacementDocument = environment[@"TODO_BENCHMARK_REPLACE_DOCUMENT"];
    NSString *replacementResult = environment[@"TODO_BENCHMARK_REPLACE_RESULT"];
    if (replacementDocument || replacementResult) {
        self.suppressTextChanges = YES;
        if (replacementDocument) self.detail.editor.string = replacementDocument;
        if (replacementResult) self.detail.completionResultEditor.string = replacementResult;
        self.suppressTextChanges = NO;
        [self handleEditorChange];
    }

    if ([NSProcessInfo.processInfo.environment[@"TODO_LAYOUT_DIAGNOSTICS"] boolValue]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self.detail layoutSubtreeIfNeeded];
            NSRect viewport = self.detail.editorScroll.contentView.bounds;
            NSRect editorUsed = [self.detail.editor.layoutManager usedRectForTextContainer:self.detail.editor.textContainer];
            NSRect resultUsed = [self.detail.completionResultEditor.layoutManager usedRectForTextContainer:self.detail.completionResultEditor.textContainer];
            NSRect previewUsed = self.detail.preview ? [self.detail.preview.layoutManager usedRectForTextContainer:self.detail.preview.textContainer] : NSZeroRect;
            NSRect resultPreviewUsed = self.detail.completionResultPreview ? [self.detail.completionResultPreview.layoutManager usedRectForTextContainer:self.detail.completionResultPreview.textContainer] : NSZeroRect;
            __block NSUInteger resultPreviewLinks = 0;
            if (self.detail.completionResultPreview.textStorage.length > 0) {
                [self.detail.completionResultPreview.textStorage enumerateAttribute:NSLinkAttributeName
                                                                            inRange:NSMakeRange(0, self.detail.completionResultPreview.textStorage.length)
                                                                            options:0
                                                                         usingBlock:^(id value, NSRange range, BOOL *stop) {
                    if (value) resultPreviewLinks++;
                }];
            }
            fprintf(stderr,
                    "mode=%s viewMode=%s selectedID=%s resultExpanded=%d resultDisclosureHidden=%d resultDisclosure=%.0fx%.0f language=%s heading=%s createTask=%s todos=%lu filtered=%lu window=%.0fx%.0f split=%.0fx%.0f sidebarFrame=%.0f,%.0f,%.0f,%.0f detailFrame=%.0f,%.0f,%.0f,%.0f viewport=%.0fx%.0f editor=%.0fx%.0f editorContainer=%.0f editorUsed=%.0f editorChars=%lu result=%.0fx%.0f resultUsed=%.0fx%.0f resultChars=%lu preview=%.0fx%.0f previewContainer=%.0f previewUsed=%.0f previewChars=%lu resultPreviewExists=%d resultPreview=%.0fx%.0f resultPreviewContainer=%.0f resultPreviewUsed=%.0fx%.0f resultPreviewChars=%lu resultPreviewLinks=%lu resultEditorHidden=%d resultPreviewHidden=%d editorHidden=%d previewHidden=%d\n",
                    mode.UTF8String,
                    self.viewMode == TodoViewModeEdit ? "edit" : (self.viewMode == TodoViewModeSplit ? "split" : "preview"),
                    self.selectedID.stringValue.UTF8String ?: "none",
                    self.detail.resultExpanded,
                    self.detail.completionResultDisclosure.hidden,
                    NSWidth(self.detail.completionResultDisclosure.frame), NSHeight(self.detail.completionResultDisclosure.frame),
                    self.language == TodoLanguageEnglish ? "en" : "zh",
                    self.sidebar.headingLabel.stringValue.UTF8String,
                    self.sidebar.createTaskButton.title.UTF8String,
                    (unsigned long)self.summaries.count, (unsigned long)self.filtered.count,
                    NSWidth(self.view.window.contentView.bounds), NSHeight(self.view.window.contentView.bounds),
                    NSWidth(self.split.bounds), NSHeight(self.split.bounds),
                    NSMinX(self.sidebar.frame), NSMinY(self.sidebar.frame), NSWidth(self.sidebar.frame), NSHeight(self.sidebar.frame),
                    NSMinX(self.detail.frame), NSMinY(self.detail.frame), NSWidth(self.detail.frame), NSHeight(self.detail.frame),
                    NSWidth(viewport), NSHeight(viewport),
                    NSWidth(self.detail.editor.frame), NSHeight(self.detail.editor.frame),
                    self.detail.editor.textContainer.containerSize.width, NSWidth(editorUsed),
                    (unsigned long)self.detail.editor.string.length,
                    NSWidth(self.detail.completionResultScroll.frame), NSHeight(self.detail.completionResultScroll.frame),
                    NSWidth(resultUsed), NSHeight(resultUsed),
                    (unsigned long)self.detail.completionResultEditor.string.length,
                    NSWidth(self.detail.preview.frame), NSHeight(self.detail.preview.frame),
                    self.detail.preview.textContainer.containerSize.width, NSWidth(previewUsed),
                    (unsigned long)self.detail.preview.string.length,
                    self.detail.completionResultPreview != nil,
                    NSWidth(self.detail.completionResultPreview.frame), NSHeight(self.detail.completionResultPreview.frame),
                    self.detail.completionResultPreview.textContainer.containerSize.width,
                    NSWidth(resultPreviewUsed), NSHeight(resultPreviewUsed),
                    (unsigned long)self.detail.completionResultPreview.string.length,
                    (unsigned long)resultPreviewLinks,
                    self.detail.completionResultScroll.hidden,
                    self.detail.completionResultPreviewScroll.hidden,
                    self.detail.editorScroll.hidden,
                    self.detail.previewScroll.hidden);
        });
    }
}
- (BOOL)prepareForTermination { return [self saveIfNeeded]; }
- (void)saveCurrent:(id)sender { [self saveIfNeeded]; }
@end

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property NSWindow *window;
@property TodoController *controller;
@end
@implementation AppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    BOOL headlessBenchmark = [NSProcessInfo.processInfo.environment[@"TODO_BENCHMARK_HEADLESS"] boolValue];
    [NSApp setActivationPolicy:(headlessBenchmark ? NSApplicationActivationPolicyProhibited : NSApplicationActivationPolicyRegular)];
    self.controller = [TodoController new];
    [self configureMenus];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(languageDidChange:) name:TodoLanguageDidChangeNotification object:nil];

    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1120, 780)
                                             styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
                                               backing:NSBackingStoreBuffered
                                                 defer:NO];
    self.window.title = @"Todo";
    self.window.titleVisibility = NSWindowTitleVisible;
    self.window.titlebarAppearsTransparent = NO;
    self.window.minSize = NSMakeSize(720, 560);
    self.window.tabbingMode = NSWindowTabbingModeDisallowed;
    self.window.contentViewController = self.controller;
    [self.window center];

    if (headlessBenchmark) {
        self.window.alphaValue = 0.0;
        self.window.ignoresMouseEvents = YES;
        [self.window orderBack:nil];
    } else {
        [self.window makeKeyAndOrderFront:nil];
        [NSApp activateIgnoringOtherApps:YES];
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        malloc_zone_pressure_relief(NULL, 0);
    });
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender{return YES;}
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender{return [self.controller prepareForTermination]?NSTerminateNow:NSTerminateCancel;}
- (void)languageDidChange:(NSNotification *)notification { [self configureMenus]; }
- (void)configureMenus {
    TodoLanguage language = self.controller ? self.controller.language : TodoLanguageChinese;
    NSMenu *main = [NSMenu new];

    NSMenuItem *appItem = [NSMenuItem new];
    [main addItem:appItem];
    NSMenu *app = [NSMenu new];
    [app addItemWithTitle:TodoLocalized(language, @"退出 Todo", @"Quit Todo") action:@selector(terminate:) keyEquivalent:@"q"];
    appItem.submenu = app;

    NSMenuItem *fileItem = [NSMenuItem new];
    [main addItem:fileItem];
    NSMenu *file = [[NSMenu alloc] initWithTitle:TodoLocalized(language, @"文件", @"File")];
    NSMenuItem *save = [file addItemWithTitle:TodoLocalized(language, @"保存", @"Save") action:@selector(saveCurrent:) keyEquivalent:@"s"];
    save.target = self.controller;
    [file addItemWithTitle:TodoLocalized(language, @"关闭窗口", @"Close Window") action:@selector(performClose:) keyEquivalent:@"w"];
    fileItem.submenu = file;

    NSMenuItem *editItem = [NSMenuItem new];
    [main addItem:editItem];
    NSMenu *edit = [[NSMenu alloc] initWithTitle:TodoLocalized(language, @"编辑", @"Edit")];
    [edit addItemWithTitle:TodoLocalized(language, @"撤销", @"Undo") action:NSSelectorFromString(@"undo:") keyEquivalent:@"z"];
    [edit addItemWithTitle:TodoLocalized(language, @"剪切", @"Cut") action:@selector(cut:) keyEquivalent:@"x"];
    [edit addItemWithTitle:TodoLocalized(language, @"复制", @"Copy") action:@selector(copy:) keyEquivalent:@"c"];
    [edit addItemWithTitle:TodoLocalized(language, @"粘贴", @"Paste") action:@selector(paste:) keyEquivalent:@"v"];
    [edit addItemWithTitle:TodoLocalized(language, @"全选", @"Select All") action:@selector(selectAll:) keyEquivalent:@"a"];
    editItem.submenu = edit;
    NSApp.mainMenu = main;
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *application = NSApplication.sharedApplication;
        AppDelegate *delegate = [AppDelegate new];
        application.delegate = delegate;
        [application run];
    }
    return 0;
}
