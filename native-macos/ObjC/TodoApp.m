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

static NSString *const TodoLanguageDefaultsKey = @"TodoLanguage";
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
@property NSTextField *completionResultLabel;
@property NSTextField *completionResultField;
@property LiteButton *deleteButton;
@property NSTextField *saveStatus;
@property LiteButton *saveButton;
@property(nullable) NSScrollView *previewScroll;
@property(nullable) NSTextView *preview;
@end
@implementation DetailView
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _completeButton = [[LiteButton alloc] initWithTitle:@"标记完成" style:LiteButtonStylePlain];
        _modeControl = [[LiteSegmentedControl alloc] initWithLabels:@[@"编辑", @"预览"]];
        _closeButton = [[LiteButton alloc] initWithTitle:@"关闭" style:LiteButtonStylePlain];
        _editor = [[NSTextView alloc] initWithFrame:NSZeroRect]; _editor.richText = NO; _editor.importsGraphics = NO; _editor.allowsUndo = YES; _editor.usesFindPanel = YES; _editor.font = [NSFont monospacedSystemFontOfSize:14 weight:NSFontWeightRegular]; _editor.textContainerInset = NSMakeSize(44, 34); _editor.automaticQuoteSubstitutionEnabled = NO; _editor.automaticDashSubstitutionEnabled = NO; _editor.automaticTextReplacementEnabled = NO; _editor.automaticSpellingCorrectionEnabled = NO; _editor.continuousSpellCheckingEnabled = NO; _editor.grammarCheckingEnabled = NO; _editor.verticallyResizable = YES; _editor.horizontallyResizable = NO; _editor.autoresizingMask = NSViewWidthSizable; _editor.textContainer.widthTracksTextView = YES;
        _editorScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect]; _editorScroll.documentView = _editor; _editorScroll.hasVerticalScroller = YES; _editorScroll.hasHorizontalScroller = NO; _editorScroll.autohidesScrollers = YES; _editorScroll.drawsBackground = YES; _editorScroll.borderType = NSNoBorder; _editorScroll.backgroundColor = NSColor.textBackgroundColor;
        _placeholder = [NSTextField labelWithString:@"从左侧选择一个任务"]; _placeholder.font = [NSFont systemFontOfSize:14]; _placeholder.textColor = NSColor.tertiaryLabelColor; _placeholder.alignment = NSTextAlignmentCenter;
        _completionResultLabel = [NSTextField labelWithString:@"完成结果（可选）"]; _completionResultLabel.font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightSemibold]; _completionResultLabel.textColor = NSColor.secondaryLabelColor;
        _completionResultField = [[NSTextField alloc] initWithFrame:NSZeroRect]; _completionResultField.font = [NSFont systemFontOfSize:13]; _completionResultField.placeholderString = @"记录交付内容、链接或验证结果"; _completionResultField.usesSingleLineMode = NO; _completionResultField.lineBreakMode = NSLineBreakByWordWrapping; _completionResultField.cell.wraps = YES; _completionResultField.cell.scrollable = YES; _completionResultField.bordered = YES; _completionResultField.bezeled = YES; _completionResultField.drawsBackground = YES;
        _deleteButton = [[LiteButton alloc] initWithTitle:@"删除" style:LiteButtonStyleDanger];
        _saveStatus = [NSTextField labelWithString:@""]; _saveStatus.font = [NSFont systemFontOfSize:11]; _saveStatus.textColor = NSColor.secondaryLabelColor; _saveStatus.alignment = NSTextAlignmentRight;
        _saveButton = [[LiteButton alloc] initWithTitle:@"保存" style:LiteButtonStylePrimary];
        for (NSView *v in @[_completeButton,_modeControl,_closeButton,_editorScroll,_placeholder,_completionResultLabel,_completionResultField,_deleteButton,_saveStatus,_saveButton]) [self addSubview:v];
    }
    return self;
}
- (BOOL)isFlipped { return YES; }
- (void)layout {
    [super layout]; CGFloat w = NSWidth(self.bounds), h = NSHeight(self.bounds);
    NSSize completeSize = self.completeButton.intrinsicContentSize; self.completeButton.frame = NSMakeRect(12, 12, MAX(96, completeSize.width), 30);
    NSSize modeSize = self.modeControl.intrinsicContentSize; self.modeControl.frame = NSMakeRect((w-modeSize.width)/2, 13, modeSize.width, 28);
    NSSize closeSize = self.closeButton.intrinsicContentSize; self.closeButton.frame = NSMakeRect(w-closeSize.width-12, 12, closeSize.width, 30);

    CGFloat footerTop = MAX(55, h - 53);
    CGFloat resultPanelHeight = 118;
    CGFloat resultTop = MAX(55, footerTop - resultPanelHeight);
    NSRect content = NSMakeRect(0, 55, w, MAX(0, resultTop - 55));
    self.editorScroll.frame = content; self.previewScroll.frame = content;
    SizeTextViewToScrollView(self.editor, self.editorScroll);
    if (self.preview && self.previewScroll) SizeTextViewToScrollView(self.preview, self.previewScroll);
    self.placeholder.frame = NSMakeRect((w-240)/2, 55+(NSHeight(content)-24)/2, 240, 24);

    self.completionResultLabel.frame = NSMakeRect(16, resultTop + 8, w - 32, 18);
    self.completionResultField.frame = NSMakeRect(12, resultTop + 30, MAX(0, w - 24), MAX(48, resultPanelHeight - 38));

    NSSize deleteSize = self.deleteButton.intrinsicContentSize; self.deleteButton.frame = NSMakeRect(12, h-41, deleteSize.width, 30);
    NSSize saveSize = self.saveButton.intrinsicContentSize; self.saveButton.frame = NSMakeRect(w-saveSize.width-12, h-42, saveSize.width, 30);
    self.saveStatus.frame = NSMakeRect(MAX(80,w-260), h-35, MAX(80, 180-saveSize.width), 18);
}
- (void)drawRect:(NSRect)dirtyRect {
    [NSColor.textBackgroundColor setFill]; NSRectFill(self.bounds);
    [NSColor.separatorColor setFill];
    CGFloat footerTop = MAX(55, NSHeight(self.bounds) - 53);
    CGFloat resultTop = MAX(55, footerTop - 118);
    NSRectFill(NSMakeRect(0,54,NSWidth(self.bounds),1));
    NSRectFill(NSMakeRect(0,resultTop,NSWidth(self.bounds),1));
    NSRectFill(NSMakeRect(0,footerTop,NSWidth(self.bounds),1));
}
@end

@interface TodoController : NSViewController <NSTableViewDataSource,NSTableViewDelegate,NSTextViewDelegate,NSSplitViewDelegate,NSTextFieldDelegate>
@property NSSplitView *split;
@property SidebarView *sidebar;
@property DetailView *detail;
@property NSArray<NSDictionary *> *summaries;
@property NSArray<NSDictionary *> *filtered;
@property TodoLanguage language;
@property NSInteger filterIndex;
@property TodoDateFilterMode dateFilterMode;
@property(nullable) NSDate *createdFromDate;
@property(nullable) NSDate *createdToExclusiveDate;
@property(nullable) NSNumber *selectedID;
@property(nullable) NSDictionary *currentTodo;
@property NSString *editorSnapshot;
@property NSString *completionResultSnapshot;
@property BOOL dirty;
@property BOOL suppressTextChanges;
@property(nullable) NSTimer *saveTimer;
@property BOOL benchmarkRan;
@end

@implementation TodoController
- (void)loadView {
    self.summaries = @[]; self.filtered = @[]; self.editorSnapshot = @""; self.completionResultSnapshot = @"";
    NSString *savedLanguage = [NSUserDefaults.standardUserDefaults stringForKey:TodoLanguageDefaultsKey];
    NSString *benchmarkLanguage = NSProcessInfo.processInfo.environment[@"TODO_BENCHMARK_LANGUAGE"];
    NSString *initialLanguage = benchmarkLanguage.length ? benchmarkLanguage : savedLanguage;
    self.language = [initialLanguage isEqualToString:@"en"] ? TodoLanguageEnglish : TodoLanguageChinese;
    self.split = [[NSSplitView alloc] initWithFrame:NSMakeRect(0,0,1120,780)]; self.split.vertical = YES; self.split.dividerStyle = NSSplitViewDividerStyleThin; self.split.delegate = self; self.split.autoresizingMask = NSViewWidthSizable|NSViewHeightSizable;
    self.sidebar = [[SidebarView alloc] initWithFrame:NSMakeRect(0,0,320,780)]; self.detail = [[DetailView alloc] initWithFrame:NSMakeRect(0,0,800,780)];
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
    self.detail.modeControl.changeHandler = ^(NSInteger index) { index == 0 ? [weakSelf showEditor] : [weakSelf showPreview]; };
    self.detail.closeButton.handler = ^{ [weakSelf closeCurrent]; };
    self.detail.deleteButton.handler = ^{ [weakSelf deleteCurrent]; };
    self.detail.saveButton.handler = ^{ [weakSelf saveIfNeeded]; };
    self.detail.editor.delegate = self;
    self.detail.completionResultField.delegate = self;
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

    self.detail.modeControl.labels = english ? @[@"Edit", @"Preview"] : @[@"编辑", @"预览"];
    self.detail.closeButton.title = TodoLocalized(self.language, @"关闭", @"Close");
    self.detail.placeholder.stringValue = TodoLocalized(self.language, @"从左侧选择一个任务", @"Select a task from the sidebar");
    self.detail.completionResultLabel.stringValue = TodoLocalized(self.language, @"完成结果（可选）", @"Completion Result (Optional)");
    self.detail.completionResultField.placeholderString = TodoLocalized(self.language, @"记录交付内容、链接或验证结果", @"Record deliverables, links, or verification notes");
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
    self.detail.completionResultField.stringValue = completionResult;
    self.suppressTextChanges = NO;

    NSCharacterSet *trimSet = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    self.editorSnapshot = [document stringByTrimmingCharactersInSet:trimSet];
    self.completionResultSnapshot = [completionResult stringByTrimmingCharactersInSet:trimSet];
    self.dirty = NO;
    self.detail.modeControl.selectedIndex = 0;
    [self updateCompletion];
    [self setDocumentAvailable:YES];
    [self setSaveStatus:TodoLocalized(self.language, @"已保存", @"Saved") error:NO];
    [self updateSelection];
    [self.view.window makeFirstResponder:self.detail.editor];
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
    return [self.detail.completionResultField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}
- (void)setDocumentAvailable:(BOOL)available {
    self.detail.placeholder.hidden = available;
    self.detail.editorScroll.hidden = !available;
    self.detail.completionResultLabel.hidden = !available;
    self.detail.completionResultField.hidden = !available;
    self.detail.completeButton.enabled = available;
    self.detail.modeControl.enabled = available;
    self.detail.closeButton.enabled = available;
    self.detail.deleteButton.enabled = available;
    self.detail.saveButton.enabled = available;
}
- (void)clearCurrent {
    [self.saveTimer invalidate];
    self.saveTimer = nil;
    [self releasePreview];
    self.currentTodo = nil;
    self.suppressTextChanges = YES;
    self.detail.editor.string = @"";
    self.detail.completionResultField.stringValue = @"";
    self.suppressTextChanges = NO;
    self.editorSnapshot = @"";
    self.completionResultSnapshot = @"";
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
}
- (void)textDidChange:(NSNotification *)notification {
    if (notification.object == self.detail.editor) [self handleEditorChange];
}
- (void)controlTextDidChange:(NSNotification *)notification {
    if (notification.object == self.detail.completionResultField) [self handleEditorChange];
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
    [self.detail.editor setSelectedRange:NSMakeRange(0, self.detail.editor.string.length)];
    [self.view.window makeFirstResponder:self.detail.editor];
}
- (void)toggleID:(NSNumber *)todoID completed:(BOOL)completed { if ([todoID isEqual:self.selectedID] && ![self saveIfNeeded]) { [self reloadSummaries]; return; } NSError *error=nil; NSDictionary *todo=BridgeCall(@{@"command":@"update",@"id":todoID,@"completed":@(completed)},&error); if (!todo){[self showError:error];[self reloadSummaries];return;} [self reloadSummaries]; if ([todoID isEqual:self.selectedID]) { self.currentTodo=todo; [self updateCompletion]; } }
- (void)toggleAll { if (![self saveIfNeeded]) return; BOOL complete=NO; for (NSDictionary *s in self.summaries) if (![s[@"completed"] boolValue]) {complete=YES;break;} NSError *error=nil; id value=BridgeCall(@{@"command":@"setAllCompleted",@"completed":@(complete)},&error); if(!value){[self showError:error];return;} self.summaries=value; [self applyFilter]; if(self.selectedID)[self selectID:self.selectedID]; }
- (void)clearCompleted { if (![self saveIfNeeded]) return; BOOL selectedCompleted=[self summaryForID:self.selectedID][@"completed"]?[ [self summaryForID:self.selectedID][@"completed"] boolValue]:NO; NSError *error=nil; if(!BridgeCall(@{@"command":@"clearCompleted"},&error)){[self showError:error];return;} if(selectedCompleted){self.selectedID=nil;[self clearCurrent];} [self reloadSummaries]; }
- (void)toggleCurrent { if(![self saveIfNeeded]||!self.currentTodo)return; [self toggleID:self.selectedID completed:![self.currentTodo[@"completed"] boolValue]]; }
- (void)updateCompletion { BOOL completed=[self.currentTodo[@"completed"] boolValue]; self.detail.completeButton.title=completed?TodoLocalized(self.language, @"恢复为待办", @"Restore to Active"):TodoLocalized(self.language, @"标记完成", @"Mark Complete"); self.detail.completeButton.foregroundColor=completed?NSColor.systemGreenColor:NSColor.secondaryLabelColor; [self.detail setNeedsLayout:YES]; [self.detail layoutSubtreeIfNeeded]; }
- (void)deleteCurrent { if(!self.selectedID)return; NSError *error=nil; if(!BridgeCall(@{@"command":@"delete",@"id":self.selectedID},&error)){[self showError:error];return;} self.selectedID=nil; [self clearCurrent]; [self reloadSummaries]; }
- (void)closeCurrent { if(![self saveIfNeeded])return; self.selectedID=nil; [self clearCurrent]; [self updateSelection]; }
- (void)showEditor { [self releasePreview]; self.detail.editorScroll.hidden=NO; [self.detail setNeedsLayout:YES]; [self.detail layoutSubtreeIfNeeded]; SizeTextViewToScrollView(self.detail.editor, self.detail.editorScroll); [self.view.window makeFirstResponder:self.detail.editor]; }
- (void)showPreview {
    if (![self saveIfNeeded] || !self.currentTodo) {
        self.detail.modeControl.selectedIndex = 0;
        return;
    }

    @try {
        NSError *error = nil;
        NSArray *runs = BridgeCall(@{@"command": @"renderMarkdown", @"markdown": self.detail.editor.string}, &error);
        if (!runs) {
            self.detail.modeControl.selectedIndex = 0;
            [self showError:error];
            return;
        }

        NSTextView *preview = [self ensurePreview];
        NSAttributedString *rendered = [self attributedMarkdown:runs];
        [preview.textStorage setAttributedString:rendered];
        self.detail.editorScroll.hidden = YES;
        self.detail.previewScroll.hidden = NO;
        [self.detail setNeedsLayout:YES];
        [self.detail layoutSubtreeIfNeeded];
        SizeTextViewToScrollView(preview, self.detail.previewScroll);
        [preview setSelectedRange:NSMakeRange(0, 0)];
        [preview scrollToBeginningOfDocument:nil];
        [self.view.window makeFirstResponder:preview];
    } @catch (NSException *exception) {
        self.detail.modeControl.selectedIndex = 0;
        [self releasePreview];
        NSError *error = [NSError errorWithDomain:TodoErrorDomain
                                             code:5
                                         userInfo:@{NSLocalizedDescriptionKey: exception.reason ?: TodoLocalized(self.language, @"Markdown 预览失败", @"Markdown preview failed")}];
        fprintf(stderr, "preview exception: %s (%s)\n", exception.name.UTF8String, exception.reason.UTF8String);
        [self showError:error];
    }
}
- (NSTextView *)ensurePreview { if(self.detail.preview)return self.detail.preview; NSTextView *text=[[NSTextView alloc] initWithFrame:NSMakeRect(0,0,MAX(1,self.detail.bounds.size.width),MAX(1,self.detail.bounds.size.height))]; text.editable=NO;text.selectable=YES;text.richText=YES;text.drawsBackground=YES;text.backgroundColor=NSColor.textBackgroundColor;text.textContainerInset=NSMakeSize(48,36);text.verticallyResizable=YES;text.horizontallyResizable=NO;text.autoresizingMask=NSViewWidthSizable;text.textContainer.widthTracksTextView=YES;text.linkTextAttributes=@{NSForegroundColorAttributeName:NSColor.linkColor,NSUnderlineStyleAttributeName:@(NSUnderlineStyleSingle)}; NSScrollView *scroll=[[NSScrollView alloc] initWithFrame:NSZeroRect];scroll.documentView=text;scroll.hasVerticalScroller=YES;scroll.hasHorizontalScroller=NO;scroll.autohidesScrollers=YES;scroll.drawsBackground=YES;scroll.borderType=NSNoBorder;scroll.backgroundColor=NSColor.textBackgroundColor;[self.detail addSubview:scroll positioned:NSWindowAbove relativeTo:self.detail.editorScroll];self.detail.preview=text;self.detail.previewScroll=scroll;[self.detail setNeedsLayout:YES];[self.detail layoutSubtreeIfNeeded];SizeTextViewToScrollView(text,scroll);return text; }
- (void)releasePreview { [self.detail.previewScroll removeFromSuperview];self.detail.previewScroll=nil;self.detail.preview=nil;self.detail.editorScroll.hidden=NO; }
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
    if ([mode isEqual:@"edit"] || [mode isEqual:@"preview"]) [self selectID:first];
    if ([mode isEqual:@"preview"]) {
        self.detail.modeControl.selectedIndex = 1;
        [self showPreview];
    }

    if ([NSProcessInfo.processInfo.environment[@"TODO_LAYOUT_DIAGNOSTICS"] boolValue]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.detail layoutSubtreeIfNeeded];
            NSRect viewport = self.detail.editorScroll.contentView.bounds;
            NSRect editorUsed = [self.detail.editor.layoutManager usedRectForTextContainer:self.detail.editor.textContainer];
            NSRect previewUsed = self.detail.preview ? [self.detail.preview.layoutManager usedRectForTextContainer:self.detail.preview.textContainer] : NSZeroRect;
            fprintf(stderr,
                    "mode=%s language=%s heading=%s createTask=%s todos=%lu filtered=%lu window=%.0fx%.0f split=%.0fx%.0f sidebarFrame=%.0f,%.0f,%.0f,%.0f detailFrame=%.0f,%.0f,%.0f,%.0f viewport=%.0fx%.0f editor=%.0fx%.0f editorContainer=%.0f editorUsed=%.0f editorChars=%lu result=%.0fx%.0f resultChars=%lu preview=%.0fx%.0f previewContainer=%.0f previewUsed=%.0f previewChars=%lu\n",
                    mode.UTF8String,
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
                    NSWidth(self.detail.completionResultField.frame), NSHeight(self.detail.completionResultField.frame),
                    (unsigned long)self.detail.completionResultField.stringValue.length,
                    NSWidth(self.detail.preview.frame), NSHeight(self.detail.preview.frame),
                    self.detail.preview.textContainer.containerSize.width, NSWidth(previewUsed),
                    (unsigned long)self.detail.preview.string.length);
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
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    self.controller = [TodoController new];
    [self configureMenus];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(languageDidChange:) name:TodoLanguageDidChangeNotification object:nil];
    self.window=[[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,1120,780) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];self.window.title=@"Todo";self.window.titleVisibility=NSWindowTitleVisible;self.window.titlebarAppearsTransparent=NO;self.window.minSize=NSMakeSize(720,560);self.window.tabbingMode=NSWindowTabbingModeDisallowed;self.window.contentViewController=self.controller;[self.window center];[self.window makeKeyAndOrderFront:nil];[NSApp activateIgnoringOtherApps:YES];dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{malloc_zone_pressure_relief(NULL,0);});
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
