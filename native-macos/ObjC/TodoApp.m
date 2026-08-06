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

    NSPoint startPoint = [self convertPoint:event.locationInWindow fromView:nil];
    BOOL cancelledByDrag = NO;
    _pressed = NSPointInRect(startPoint, self.bounds);
    self.needsDisplay = YES;

    while (YES) {
        NSEvent *next = [self.window nextEventMatchingMask:(NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp)];
        if (!next) break;

        NSPoint point = [self convertPoint:next.locationInWindow fromView:nil];
        if (next.type == NSEventTypeLeftMouseDragged) {
            CGFloat deltaX = fabs(point.x - startPoint.x);
            CGFloat deltaY = fabs(point.y - startPoint.y);
            if (deltaX > 4.0 || deltaY > 4.0) cancelledByDrag = YES;
            _pressed = !cancelledByDrag && NSPointInRect(point, self.bounds);
            self.needsDisplay = YES;
            continue;
        }

        BOOL shouldActivate = !cancelledByDrag && NSPointInRect(point, self.bounds);
        _pressed = NO;
        self.needsDisplay = YES;
        if (shouldActivate) [self activate];
        break;
    }

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

typedef NS_ENUM(NSInteger, TodoCheckState) {
    TodoCheckStateActive = 0,
    TodoCheckStatePartial = 1,
    TodoCheckStateCompleted = 2,
};

@interface CheckControl : NSControl
@property(nonatomic) BOOL checked;
@property(nonatomic) TodoCheckState checkState;
@property(nonatomic, copy, nullable) void (^changeHandler)(BOOL checked);
@end
@implementation CheckControl
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.accessibilityElement = YES;
        self.accessibilityRole = NSAccessibilityCheckBoxRole;
        self.accessibilityLabel = @"完成任务";
        _checkState = TodoCheckStateActive;
    }
    return self;
}
- (NSSize)intrinsicContentSize { return NSMakeSize(20, 20); }
- (BOOL)checked { return self.checkState == TodoCheckStateCompleted; }
- (void)setChecked:(BOOL)checked { self.checkState = checked ? TodoCheckStateCompleted : TodoCheckStateActive; }
- (void)setCheckState:(TodoCheckState)checkState {
    _checkState = checkState;
    self.accessibilityValue = checkState == TodoCheckStateCompleted
        ? @1
        : (checkState == TodoCheckStatePartial ? @(-1) : @0);
    self.needsDisplay = YES;
}
- (void)drawRect:(NSRect)dirtyRect {
    NSRect square = NSMakeRect(2, 2, 16, 16);
    NSBezierPath *box = [NSBezierPath bezierPathWithRoundedRect:square xRadius:5 yRadius:5];
    if (self.checkState == TodoCheckStateCompleted) {
        [NSColor.systemGreenColor setFill]; [box fill];
        NSBezierPath *check = [NSBezierPath bezierPath]; [check moveToPoint:NSMakePoint(6, 10)]; [check lineToPoint:NSMakePoint(9, 7)]; [check lineToPoint:NSMakePoint(14, 13)];
        check.lineWidth = 2; check.lineCapStyle = NSLineCapStyleRound; check.lineJoinStyle = NSLineJoinStyleRound; [NSColor.whiteColor setStroke]; [check stroke];
    } else if (self.checkState == TodoCheckStatePartial) {
        [NSColor.systemOrangeColor setFill]; [box fill];
        NSBezierPath *dash = [NSBezierPath bezierPath];
        [dash moveToPoint:NSMakePoint(6, 10)]; [dash lineToPoint:NSMakePoint(14, 10)];
        dash.lineWidth = 2; dash.lineCapStyle = NSLineCapStyleRound; [NSColor.whiteColor setStroke]; [dash stroke];
    } else {
        [NSColor.separatorColor setStroke]; box.lineWidth = 1.2; [box stroke];
    }
}
- (void)mouseDown:(NSEvent *)event {
    if (!self.enabled) return;
    BOOL target = self.checkState != TodoCheckStateCompleted;
    self.checked = target;
    if (self.changeHandler) self.changeHandler(target);
}
@end

@interface TaskCellView : NSTableCellView
@property CheckControl *check;
@property NSTextField *idLabel;
@property NSTextField *titleLabel;
@property NSTextField *subtitleLabel;
@property NSTextField *priorityLabel;
- (void)configure:(NSDictionary *)summary handler:(void (^)(BOOL))handler english:(BOOL)english;
@end
@implementation TaskCellView
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _check = [[CheckControl alloc] initWithFrame:NSZeroRect];
        _idLabel = [NSTextField labelWithString:@""];
        _idLabel.font = [NSFont monospacedDigitSystemFontOfSize:10.5 weight:NSFontWeightMedium];
        _idLabel.textColor = NSColor.tertiaryLabelColor;
        _idLabel.lineBreakMode = NSLineBreakByClipping;
        _titleLabel = [NSTextField labelWithString:@""];
        _titleLabel.font = [NSFont systemFontOfSize:13.5 weight:NSFontWeightSemibold];
        _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        _subtitleLabel = [NSTextField labelWithString:@""];
        _subtitleLabel.font = [NSFont systemFontOfSize:11.5];
        _subtitleLabel.textColor = NSColor.secondaryLabelColor;
        _subtitleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        _priorityLabel = [NSTextField labelWithString:@""];
        _priorityLabel.font = [NSFont systemFontOfSize:10.5 weight:NSFontWeightSemibold];
        _priorityLabel.alignment = NSTextAlignmentCenter;
        [self addSubview:_check]; [self addSubview:_idLabel]; [self addSubview:_titleLabel]; [self addSubview:_subtitleLabel]; [self addSubview:_priorityLabel];
    }
    return self;
}
- (void)layout {
    [super layout];
    CGFloat h = NSHeight(self.bounds);
    self.check.frame = NSMakeRect(10, (h - 20) / 2, 20, 20);
    CGFloat x = 38, idWidth = 40, badgeWidth = 28, rightInset = 10;
    CGFloat w = MAX(0, NSWidth(self.bounds) - x - rightInset);
    self.priorityLabel.frame = NSMakeRect(NSWidth(self.bounds) - badgeWidth - rightInset, h / 2 + 3, badgeWidth, 19);
    self.titleLabel.frame = NSMakeRect(x, h / 2 + 3, MAX(0, w - badgeWidth - 6), 19);
    self.idLabel.frame = NSMakeRect(x, h / 2 - 17, idWidth, 17);
    self.subtitleLabel.frame = NSMakeRect(x + idWidth, h / 2 - 17, MAX(0, w - idWidth), 17);
}
- (void)configure:(NSDictionary *)summary handler:(void (^)(BOOL))handler english:(BOOL)english {
    NSNumber *todoID = [summary[@"id"] isKindOfClass:NSNumber.class] ? summary[@"id"] : nil;
    self.idLabel.stringValue = todoID ? [NSString stringWithFormat:@"#%@", todoID] : @"#?";
    self.titleLabel.stringValue = summary[@"title"] ?: @"";
    NSString *subtitle = summary[@"subtitle"] ?: @"";
    NSInteger subtaskCount = [summary[@"subtaskCount"] integerValue];
    NSInteger completedSubtaskCount = [summary[@"completedSubtaskCount"] integerValue];
    self.subtitleLabel.stringValue = subtaskCount > 0
        ? [NSString stringWithFormat:@"%ld/%ld · %@", (long)completedSubtaskCount, (long)subtaskCount, subtitle]
        : subtitle;
    NSString *priority = [summary[@"priority"] isKindOfClass:NSString.class] ? summary[@"priority"] : @"low";
    if ([priority isEqualToString:@"high"]) {
        self.priorityLabel.stringValue = english ? @"H" : @"高";
        self.priorityLabel.textColor = NSColor.systemRedColor;
    } else if ([priority isEqualToString:@"medium"]) {
        self.priorityLabel.stringValue = english ? @"M" : @"中";
        self.priorityLabel.textColor = NSColor.systemOrangeColor;
    } else {
        self.priorityLabel.stringValue = english ? @"L" : @"低";
        self.priorityLabel.textColor = NSColor.tertiaryLabelColor;
    }
    NSString *completionState = [summary[@"completionState"] isKindOfClass:NSString.class]
        ? summary[@"completionState"]
        : ([summary[@"completed"] boolValue] ? @"completed" : @"active");
    BOOL completed = [completionState isEqualToString:@"completed"];
    self.check.checkState = [completionState isEqualToString:@"partial"]
        ? TodoCheckStatePartial
        : (completed ? TodoCheckStateCompleted : TodoCheckStateActive);
    self.check.changeHandler = handler;
    self.idLabel.textColor = NSColor.tertiaryLabelColor;
    self.titleLabel.textColor = completed ? NSColor.tertiaryLabelColor : NSColor.labelColor;
    self.subtitleLabel.textColor = completed ? NSColor.tertiaryLabelColor : NSColor.secondaryLabelColor;
    if (completed) self.priorityLabel.textColor = NSColor.tertiaryLabelColor;
    self.accessibilityLabel = [NSString stringWithFormat:@"%@ %@", self.idLabel.stringValue, self.titleLabel.stringValue];
}
@end

@interface SubtaskCellView : NSTableCellView <NSTextFieldDelegate>
@property CheckControl *check;
@property NSTextField *titleField;
@property LiteButton *deleteButton;
@property NSString *titleSnapshot;
@property(nonatomic, copy, nullable) void (^editHandler)(NSString *title);
@end
@implementation SubtaskCellView
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _check = [[CheckControl alloc] initWithFrame:NSZeroRect];
        _check.accessibilityLabel = @"完成子任务";
        _titleField = [[NSTextField alloc] initWithFrame:NSZeroRect];
        _titleField.bordered = NO;
        _titleField.bezeled = NO;
        _titleField.drawsBackground = NO;
        _titleField.font = [NSFont systemFontOfSize:13];
        _titleField.focusRingType = NSFocusRingTypeNone;
        _titleField.lineBreakMode = NSLineBreakByTruncatingTail;
        _titleField.delegate = self;
        _deleteButton = [[LiteButton alloc] initWithTitle:@"×" style:LiteButtonStylePlain];
        _deleteButton.toolTip = @"删除子任务";
        [self addSubview:_check];
        [self addSubview:_titleField];
        [self addSubview:_deleteButton];
    }
    return self;
}
- (void)layout {
    [super layout];
    CGFloat height = NSHeight(self.bounds);
    self.check.frame = NSMakeRect(12, (height - 20) / 2, 20, 20);
    self.deleteButton.frame = NSMakeRect(NSWidth(self.bounds) - 34, (height - 28) / 2, 28, 28);
    self.titleField.frame = NSMakeRect(40, (height - 22) / 2, MAX(40, NSWidth(self.bounds) - 80), 22);
}
- (void)configure:(NSDictionary *)subtask
          english:(BOOL)english
     toggleHandler:(void (^)(BOOL completed))toggleHandler
       editHandler:(void (^)(NSString *title))editHandler
     deleteHandler:(void (^)(void))deleteHandler {
    NSString *title = [subtask[@"title"] isKindOfClass:NSString.class] ? subtask[@"title"] : @"";
    BOOL completed = [subtask[@"completed"] boolValue];
    self.titleSnapshot = title;
    self.titleField.stringValue = title;
    self.titleField.textColor = completed ? NSColor.tertiaryLabelColor : NSColor.labelColor;
    self.check.checked = completed;
    self.check.changeHandler = toggleHandler;
    self.editHandler = editHandler;
    self.deleteButton.handler = deleteHandler;
    self.deleteButton.toolTip = english ? @"Delete subtask" : @"删除子任务";
    self.accessibilityLabel = title;
}
- (void)controlTextDidEndEditing:(NSNotification *)notification {
    NSString *title = [self.titleField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (![title isEqualToString:self.titleSnapshot] && self.editHandler) self.editHandler(title);
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

typedef NS_ENUM(NSInteger, TodoPriority) {
    TodoPriorityLow = 0,
    TodoPriorityMedium = 1,
    TodoPriorityHigh = 2,
};

typedef NS_ENUM(NSInteger, TodoSortMode) {
    TodoSortModeOriginal = 0,
    TodoSortModeNewestFirst = 1,
    TodoSortModePriorityFirst = 2,
};

static NSString *const TodoLanguageDefaultsKey = @"TodoLanguage";
static NSString *const TodoViewModeDefaultsKey = @"TodoWorkspaceModeV2";
static NSString *const TodoCompletionResultRatioDefaultsKey = @"TodoCompletionResultRatio";
static NSString *const TodoSortModeDefaultsKey = @"TodoSortMode";
static NSNotificationName const TodoLanguageDidChangeNotification = @"TodoLanguageDidChangeNotification";

static NSString *TodoLocalized(TodoLanguage language, NSString *chinese, NSString *english) {
    return language == TodoLanguageEnglish ? english : chinese;
}

static TodoPriority TodoPriorityFromValue(id value) {
    if ([value isKindOfClass:NSString.class]) {
        if ([value isEqualToString:@"high"]) return TodoPriorityHigh;
        if ([value isEqualToString:@"medium"]) return TodoPriorityMedium;
    }
    return TodoPriorityLow;
}

static NSString *TodoPriorityValue(TodoPriority priority) {
    switch (priority) {
        case TodoPriorityHigh: return @"high";
        case TodoPriorityMedium: return @"medium";
        default: return @"low";
    }
}

@interface SidebarView : NSView
@property NSTextField *dateLabel;
@property NSTextField *headingLabel;
@property LiteButton *createTaskButton;
@property LiteSegmentedControl *languageControl;
@property LiteButton *refreshButton;
@property LiteButton *toggleAllButton;
@property LiteButton *filterMenuButton;
@property NSScrollView *scrollView;
@property NSTableView *tableView;
@property NSTextField *countLabel;
@property LiteButton *managementButton;
@end
@implementation SidebarView
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _dateLabel = [NSTextField labelWithString:@""]; _dateLabel.font = [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold]; _dateLabel.textColor = NSColor.systemOrangeColor;
        _headingLabel = [NSTextField labelWithString:@"今天要做什么？"]; _headingLabel.font = [NSFont systemFontOfSize:24 weight:NSFontWeightBold];
        _createTaskButton = [[LiteButton alloc] initWithTitle:@"新建任务" style:LiteButtonStyleBordered];
        _languageControl = [[LiteSegmentedControl alloc] initWithLabels:@[@"中", @"EN"]];
        _refreshButton = [[LiteButton alloc] initWithTitle:@"↻" style:LiteButtonStylePlain];
        _refreshButton.toolTip = @"刷新";
        _refreshButton.accessibilityLabel = @"刷新";
        _toggleAllButton = [[LiteButton alloc] initWithTitle:@"全部完成" style:LiteButtonStylePlain];
        _filterMenuButton = [[LiteButton alloc] initWithTitle:@"筛选/排序 ▾" style:LiteButtonStyleBordered];
        _tableView = [[NSTableView alloc] initWithFrame:NSZeroRect]; NSTableColumn *column = [[NSTableColumn alloc] initWithIdentifier:@"task"]; [_tableView addTableColumn:column]; _tableView.headerView = nil; _tableView.rowHeight = 62; _tableView.intercellSpacing = NSMakeSize(0, 1); _tableView.backgroundColor = NSColor.clearColor;
        _scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect]; _scrollView.documentView = _tableView; _scrollView.hasVerticalScroller = YES; _scrollView.autohidesScrollers = YES; _scrollView.drawsBackground = NO;
        _countLabel = [NSTextField labelWithString:@""]; _countLabel.font = [NSFont systemFontOfSize:11]; _countLabel.textColor = NSColor.secondaryLabelColor;
        _managementButton = [[LiteButton alloc] initWithTitle:@"管理…" style:LiteButtonStylePlain];
        for (NSView *v in @[_dateLabel,_headingLabel,_createTaskButton,_languageControl,_refreshButton,_toggleAllButton,_filterMenuButton,_scrollView,_countLabel,_managementButton]) [self addSubview:v];
    }
    return self;
}
- (BOOL)isFlipped { return YES; }
- (void)layout {
    [super layout]; CGFloat w = NSWidth(self.bounds), h = NSHeight(self.bounds);
    NSSize languageSize = self.languageControl.intrinsicContentSize;
    CGFloat languageX = w - languageSize.width - 12;
    CGFloat refreshWidth = 30.0;
    CGFloat refreshX = languageX - refreshWidth - 4.0;
    self.dateLabel.frame = NSMakeRect(16, 18, MAX(60, refreshX - 24), 16);
    self.refreshButton.frame = NSMakeRect(refreshX, 9, refreshWidth, 30);
    self.languageControl.frame = NSMakeRect(languageX, 10, languageSize.width, 28);
    NSSize newTaskSize = self.createTaskButton.intrinsicContentSize;
    self.headingLabel.frame = NSMakeRect(16, 39, MAX(80, w - newTaskSize.width - 48), 31);
    self.createTaskButton.frame = NSMakeRect(w - newTaskSize.width - 12, 40, newTaskSize.width, 30);
    self.toggleAllButton.frame = NSMakeRect(10, 83, self.toggleAllButton.intrinsicContentSize.width, 28);
    NSSize filterMenuSize = self.filterMenuButton.intrinsicContentSize;
    self.filterMenuButton.frame = NSMakeRect(w - filterMenuSize.width - 10, 83, filterMenuSize.width, 28);
    NSSize managementSize = self.managementButton.intrinsicContentSize;
    self.countLabel.frame = NSMakeRect(12, h - 31, MAX(40, w - managementSize.width - 30), 18);
    self.managementButton.frame = NSMakeRect(w - managementSize.width - 8, h - 37, managementSize.width, 28);
    self.scrollView.frame = NSMakeRect(0, 117, w, MAX(0, h - 117 - 42));
}
- (void)drawRect:(NSRect)dirtyRect {
    [NSColor.controlBackgroundColor setFill]; NSRectFill(self.bounds);
    [NSColor.separatorColor setFill];
    NSRectFill(NSMakeRect(0, 73, NSWidth(self.bounds), 1)); NSRectFill(NSMakeRect(0, 116, NSWidth(self.bounds), 1)); NSRectFill(NSMakeRect(0, NSHeight(self.bounds)-42, NSWidth(self.bounds), 1));
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
@property NSTextField *priorityLabel;
@property LiteSegmentedControl *priorityControl;
@property LiteButton *closeButton;
@property NSTextField *subtaskSummaryLabel;
@property LiteButton *addSubtaskButton;
@property NSScrollView *subtaskScroll;
@property NSTableView *subtaskTable;
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
@property(nonatomic) BOOL subtaskSectionVisible;
@property(nonatomic) NSInteger subtaskCount;
@end
@implementation DetailView
- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _completeButton = [[LiteButton alloc] initWithTitle:@"标记完成" style:LiteButtonStylePlain];
        _modeControl = [[LiteSegmentedControl alloc] initWithLabels:@[@"编辑", @"分栏", @"预览"]];
        _priorityLabel = [NSTextField labelWithString:@"优先级"];
        _priorityLabel.font = [NSFont systemFontOfSize:11.5 weight:NSFontWeightMedium];
        _priorityLabel.textColor = NSColor.secondaryLabelColor;
        _priorityControl = [[LiteSegmentedControl alloc] initWithLabels:@[@"低", @"中", @"高"]];
        _closeButton = [[LiteButton alloc] initWithTitle:@"关闭" style:LiteButtonStylePlain];

        _subtaskSummaryLabel = [NSTextField labelWithString:@"子任务 0/0"];
        _subtaskSummaryLabel.font = [NSFont systemFontOfSize:12 weight:NSFontWeightSemibold];
        _subtaskSummaryLabel.textColor = NSColor.secondaryLabelColor;
        _addSubtaskButton = [[LiteButton alloc] initWithTitle:@"添加子任务" style:LiteButtonStylePlain];
        _subtaskTable = [[NSTableView alloc] initWithFrame:NSZeroRect];
        NSTableColumn *subtaskColumn = [[NSTableColumn alloc] initWithIdentifier:@"subtask"];
        [_subtaskTable addTableColumn:subtaskColumn];
        _subtaskTable.headerView = nil;
        _subtaskTable.rowHeight = 34;
        _subtaskTable.intercellSpacing = NSMakeSize(0, 0);
        _subtaskTable.backgroundColor = NSColor.clearColor;
        _subtaskTable.selectionHighlightStyle = NSTableViewSelectionHighlightStyleNone;
        _subtaskScroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
        _subtaskScroll.documentView = _subtaskTable;
        _subtaskScroll.hasVerticalScroller = YES;
        _subtaskScroll.autohidesScrollers = YES;
        _subtaskScroll.drawsBackground = NO;
        _subtaskScroll.borderType = NSNoBorder;
        _subtaskSummaryLabel.hidden = YES;
        _addSubtaskButton.hidden = YES;
        _subtaskScroll.hidden = YES;

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
        _subtaskSectionVisible = NO;
        _subtaskCount = 0;

        for (NSView *view in @[
            _completeButton, _modeControl, _priorityLabel, _priorityControl, _closeButton,
            _subtaskSummaryLabel, _addSubtaskButton, _subtaskScroll, _editorScroll, _placeholder,
            _completionResultDisclosure, _completionResultScroll, _deleteButton, _saveStatus, _saveButton
        ]) {
            [self addSubview:view];
        }
    }
    return self;
}
- (BOOL)isFlipped { return YES; }
- (CGFloat)dividerThickness { return 1.0; }
- (CGFloat)subtaskSectionHeight {
    if (!self.subtaskSectionVisible) return 0.0;
    CGFloat rowsHeight = MIN(136.0, MAX(0.0, self.subtaskCount * self.subtaskTable.rowHeight));
    return 38.0 + rowsHeight;
}
- (CGFloat)contentTop { return 91.0 + [self subtaskSectionHeight]; }
- (CGFloat)availableContentHeight {
    return MAX(0.0, NSHeight(self.bounds) - [self contentTop] - 53.0);
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
    CGFloat footerTop = MAX([self contentTop], NSHeight(self.bounds) - 53.0);
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
    NSSize priorityLabelSize = self.priorityLabel.intrinsicContentSize;
    NSSize prioritySize = self.priorityControl.intrinsicContentSize;
    CGFloat priorityGroupWidth = priorityLabelSize.width + 8.0 + prioritySize.width;
    CGFloat priorityGroupX = floor((width - priorityGroupWidth) / 2.0);
    self.priorityLabel.frame = NSMakeRect(priorityGroupX, 58, priorityLabelSize.width, 18);
    self.priorityControl.frame = NSMakeRect(priorityGroupX + priorityLabelSize.width + 8.0, 52, prioritySize.width, 28);

    if (self.subtaskSectionVisible) {
        CGFloat sectionTop = 91.0;
        self.subtaskSummaryLabel.frame = NSMakeRect(16, sectionTop + 10, MAX(100, width - 170), 18);
        NSSize addSubtaskSize = self.addSubtaskButton.intrinsicContentSize;
        self.addSubtaskButton.frame = NSMakeRect(width - addSubtaskSize.width - 12, sectionTop + 4, addSubtaskSize.width, 30);
        CGFloat rowsHeight = MAX(0.0, [self subtaskSectionHeight] - 38.0);
        self.subtaskScroll.frame = NSMakeRect(0, sectionTop + 38.0, width, rowsHeight);
    } else {
        self.subtaskSummaryLabel.frame = NSZeroRect;
        self.addSubtaskButton.frame = NSZeroRect;
        self.subtaskScroll.frame = NSZeroRect;
    }

    CGFloat footerTop = MAX([self contentTop], height - 53.0);
    NSRect documentFrame;
    CGFloat disclosureHeight = 38.0;
    if (self.resultExpanded) {
        NSRect divider = [self dividerRect];
        documentFrame = NSMakeRect(0, [self contentTop], width, MAX(0.0, NSMinY(divider) - [self contentTop]));
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
        CGFloat disclosureTop = MAX([self contentTop], footerTop - disclosureHeight);
        documentFrame = NSMakeRect(0, [self contentTop], width, MAX(0.0, disclosureTop - [self contentTop]));
        self.completionResultDisclosure.frame = NSMakeRect(0, disclosureTop, width, disclosureHeight);
        self.completionResultScroll.frame = NSZeroRect;
        self.completionResultPreviewScroll.frame = NSZeroRect;
    }

    [self layoutPaneFrame:documentFrame editorScroll:self.editorScroll previewScroll:self.previewScroll];
    SizeTextViewToScrollView(self.editor, self.editorScroll);
    if (self.preview && self.previewScroll) SizeTextViewToScrollView(self.preview, self.previewScroll);
    self.placeholder.frame = NSMakeRect((width - 280) / 2, [self contentTop] + (NSHeight(documentFrame) - 24) / 2, 280, 24);

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
- (void)setSubtaskSectionVisible:(BOOL)subtaskSectionVisible {
    _subtaskSectionVisible = subtaskSectionVisible;
    self.subtaskSummaryLabel.hidden = !subtaskSectionVisible;
    self.addSubtaskButton.hidden = !subtaskSectionVisible;
    self.subtaskScroll.hidden = !subtaskSectionVisible || self.subtaskCount == 0;
    [self setNeedsLayout:YES];
    [self setNeedsDisplay:YES];
}
- (void)setSubtaskCount:(NSInteger)subtaskCount {
    _subtaskCount = MAX(0, subtaskCount);
    self.subtaskScroll.hidden = !self.subtaskSectionVisible || _subtaskCount == 0;
    [self setNeedsLayout:YES];
    [self setNeedsDisplay:YES];
}
- (NSRect)dividerHitRect {
    NSRect divider = [self dividerRect];
    if (NSIsEmptyRect(divider)) return NSZeroRect;
    return NSInsetRect(divider, 0, -4.0);
}
- (NSView *)hitTest:(NSPoint)point {
    NSPoint localPoint = self.superview ? [self convertPoint:point fromView:self.superview] : point;
    if (self.resultExpanded && NSPointInRect(localPoint, [self dividerHitRect])) return self;
    return [super hitTest:point];
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
        CGFloat footerTop = MAX([self contentTop], NSHeight(self.bounds) - 53.0);
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
    CGFloat footerTop = MAX([self contentTop], NSHeight(self.bounds) - 53.0);
    if (self.subtaskSectionVisible) NSRectFill(NSMakeRect(0, 90.0, NSWidth(self.bounds), 1));
    NSRectFill(NSMakeRect(0, [self contentTop] - 1.0, NSWidth(self.bounds), 1));
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
@property TodoSortMode sortMode;
@property NSInteger filterIndex;
@property BOOL archiveView;
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
- (void)showManagementMenu;
- (void)showFilterMenu;
- (NSMenu *)buildFilterMenu;
- (void)updateFilterMenuPresentation;
- (void)addSubtask;
- (void)updateSubtaskPresentation;
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
    NSInteger savedSortMode = [NSUserDefaults.standardUserDefaults integerForKey:TodoSortModeDefaultsKey];
    self.sortMode = (TodoSortMode)MAX(TodoSortModeOriginal, MIN(savedSortMode, TodoSortModePriorityFirst));
    self.split = [[NSSplitView alloc] initWithFrame:NSMakeRect(0,0,1120,780)]; self.split.vertical = YES; self.split.dividerStyle = NSSplitViewDividerStyleThin; self.split.delegate = self; self.split.autoresizingMask = NSViewWidthSizable|NSViewHeightSizable;
    self.sidebar = [[SidebarView alloc] initWithFrame:NSMakeRect(0,0,320,780)]; self.detail = [[DetailView alloc] initWithFrame:NSMakeRect(0,0,800,780)];
    self.detail.viewMode = self.viewMode;
    self.sidebar.autoresizingMask = NSViewHeightSizable;
    self.detail.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.split addArrangedSubview:self.sidebar]; [self.split addArrangedSubview:self.detail]; self.view = self.split;
    self.sidebar.tableView.delegate = self; self.sidebar.tableView.dataSource = self;
    self.detail.subtaskTable.delegate = self; self.detail.subtaskTable.dataSource = self;
    __weak typeof(self) weakSelf = self;
    self.sidebar.createTaskButton.handler = ^{ [weakSelf addEditableTask]; };
    self.sidebar.languageControl.changeHandler = ^(NSInteger index) { [weakSelf changeLanguage:(TodoLanguage)index]; };
    self.sidebar.refreshButton.handler = ^{ [weakSelf refreshFromDisk:nil]; };
    self.sidebar.toggleAllButton.handler = ^{ [weakSelf toggleAll]; };
    self.sidebar.filterMenuButton.handler = ^{ [weakSelf showFilterMenu]; };
    self.sidebar.managementButton.handler = ^{ [weakSelf showManagementMenu]; };
    self.detail.completeButton.handler = ^{ [weakSelf toggleCurrent]; };
    self.detail.completionResultDisclosure.handler = ^(BOOL expanded) { [weakSelf setCompletionResultExpanded:expanded remember:YES]; };
    self.detail.modeControl.changeHandler = ^(NSInteger index) { [weakSelf changeViewMode:index]; };
    self.detail.priorityControl.changeHandler = ^(NSInteger index) { [weakSelf changeCurrentPriority:(TodoPriority)index]; };
    self.detail.addSubtaskButton.handler = ^{ [weakSelf addSubtask]; };
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
- (void)changeCurrentPriority:(TodoPriority)priority {
    TodoPriority normalizedPriority = (TodoPriority)MAX(TodoPriorityLow, MIN(priority, TodoPriorityHigh));
    if (!self.currentTodo || !self.selectedID) {
        self.detail.priorityControl.selectedIndex = TodoPriorityLow;
        return;
    }

    TodoPriority previousPriority = TodoPriorityFromValue(self.currentTodo[@"priority"]);
    if (normalizedPriority == previousPriority) return;
    if (![self saveIfNeeded]) {
        self.detail.priorityControl.selectedIndex = previousPriority;
        return;
    }

    NSError *error = nil;
    NSDictionary *todo = BridgeCall(@{
        @"command": @"update",
        @"id": self.selectedID,
        @"priority": TodoPriorityValue(normalizedPriority),
    }, &error);
    if (!todo) {
        self.detail.priorityControl.selectedIndex = previousPriority;
        [self showError:error];
        return;
    }

    self.currentTodo = todo;
    self.detail.priorityControl.selectedIndex = normalizedPriority;
    [self reloadSummaries];
    [self updateSelection];
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
    self.detail.subtaskSectionVisible = available;
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
    self.sidebar.refreshButton.toolTip = TodoLocalized(self.language, @"刷新任务（⌘R）", @"Refresh tasks (⌘R)");
    self.sidebar.refreshButton.accessibilityLabel = TodoLocalized(self.language, @"刷新任务", @"Refresh tasks");
    self.sidebar.filterMenuButton.accessibilityLabel = TodoLocalized(self.language, @"筛选和排序", @"Filter and sort");
    self.sidebar.managementButton.title = TodoLocalized(self.language, @"管理…", @"Manage…");
    self.sidebar.managementButton.accessibilityLabel = TodoLocalized(self.language, @"管理任务", @"Manage tasks");

    self.detail.priorityLabel.stringValue = TodoLocalized(self.language, @"优先级", @"Priority");
    self.detail.priorityControl.accessibilityLabel = TodoLocalized(self.language, @"任务优先级", @"Task priority");
    self.detail.priorityControl.labels = english ? @[@"Low", @"Medium", @"High"] : @[@"低", @"中", @"高"];
    self.detail.addSubtaskButton.title = TodoLocalized(self.language, @"添加子任务", @"Add Subtask");
    self.detail.addSubtaskButton.accessibilityLabel = TodoLocalized(self.language, @"添加子任务", @"Add subtask");
    self.detail.modeControl.labels = english ? @[@"Edit", @"Split", @"Preview"] : @[@"编辑", @"分栏", @"预览"];
    self.detail.modeControl.selectedIndex = self.viewMode;
    self.detail.closeButton.title = TodoLocalized(self.language, @"关闭", @"Close");
    self.detail.placeholder.stringValue = TodoLocalized(self.language, @"从左侧选择一个任务", @"Select a task from the sidebar");
    self.detail.completionResultDisclosure.title = TodoLocalized(self.language, @"完成结果", @"Completion Result");
    self.detail.deleteButton.title = TodoLocalized(self.language, @"删除", @"Delete");
    self.detail.saveButton.title = TodoLocalized(self.language, @"保存", @"Save");

    [self updateCompletion];
    [self updateSubtaskPresentation];
    [self updateFilterMenuPresentation];
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
- (NSArray<NSDictionary *> *)currentSubtasks {
    id value = self.currentTodo[@"subtasks"];
    return [value isKindOfClass:NSArray.class] ? value : @[];
}
- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
    return tableView == self.detail.subtaskTable ? self.currentSubtasks.count : self.filtered.count;
}
- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
    if (tableView == self.detail.subtaskTable) {
        NSArray<NSDictionary *> *subtasks = self.currentSubtasks;
        if (row < 0 || row >= subtasks.count) return nil;
        NSDictionary *subtask = subtasks[row];
        SubtaskCellView *cell = [tableView makeViewWithIdentifier:@"SubtaskCell" owner:self];
        if (!cell) {
            cell = [[SubtaskCellView alloc] initWithFrame:NSZeroRect];
            cell.identifier = @"SubtaskCell";
        }
        NSNumber *subtaskID = subtask[@"id"];
        __weak typeof(self) weakSelf = self;
        [cell configure:subtask
                english:(self.language == TodoLanguageEnglish)
           toggleHandler:^(BOOL completed) { [weakSelf toggleSubtaskID:subtaskID completed:completed]; }
             editHandler:^(NSString *title) { [weakSelf renameSubtaskID:subtaskID title:title]; }
           deleteHandler:^{ [weakSelf deleteSubtaskID:subtaskID]; }];
        return cell;
    }

    if (row < 0 || row >= self.filtered.count) return nil;
    NSDictionary *summary = self.filtered[row];
    TaskCellView *cell = [tableView makeViewWithIdentifier:@"TaskCell" owner:self];
    if (!cell) {
        cell = [[TaskCellView alloc] initWithFrame:NSZeroRect];
        cell.identifier = @"TaskCell";
    }
    NSNumber *todoID = summary[@"id"];
    __weak typeof(self) weakSelf = self;
    [cell configure:summary handler:^(BOOL completed) { [weakSelf toggleID:todoID completed:completed]; } english:(self.language == TodoLanguageEnglish)];
    return cell;
}
- (void)tableViewSelectionDidChange:(NSNotification *)notification {
    if (notification.object != self.sidebar.tableView) return;
    NSInteger row = self.sidebar.tableView.selectedRow;
    if (row < 0 || row >= self.filtered.count) return;
    NSNumber *todoID = self.filtered[row][@"id"];
    if ([todoID isEqual:self.selectedID]) return;
    if (![self saveIfNeeded]) {
        [self updateSelection];
        return;
    }
    [self selectID:todoID];
}
- (void)reloadSummaries {
    NSError *error = nil; id value = BridgeCall(@{@"command":@"list"}, &error); if (!value) { [self showError:error]; return; }
    self.summaries = value; if (self.selectedID && ![self summaryForID:self.selectedID]) { self.selectedID = nil; [self clearCurrent]; }
    [self applyFilter];
}
- (void)refreshFromDisk:(id)sender {
    if (![self saveIfNeeded]) return;
    NSNumber *selectedID = self.selectedID;
    [self reloadSummaries];
    NSDictionary *summary = selectedID ? [self summaryForID:selectedID] : nil;
    if (summary && [summary[@"archived"] boolValue] == self.archiveView) {
        [self selectID:selectedID];
    } else if (selectedID) {
        self.selectedID = nil;
        [self clearCurrent];
    }
}
- (NSString *)statusFilterTitle {
    if (self.filterIndex == 1) return TodoLocalized(self.language, @"待办", @"Active");
    if (self.filterIndex == 2) return TodoLocalized(self.language, @"已完成", @"Done");
    return TodoLocalized(self.language, @"全部", @"All");
}
- (NSString *)dateFilterTitle {
    if (self.dateFilterMode == TodoDateFilterModeLast24Hours) {
        return TodoLocalized(self.language, @"过去 24 小时", @"Last 24 Hours");
    }
    if (self.dateFilterMode == TodoDateFilterModeLast7Days) {
        return TodoLocalized(self.language, @"过去 7 天", @"Last 7 Days");
    }
    if (self.dateFilterMode != TodoDateFilterModeCustom || !self.createdFromDate || !self.createdToExclusiveDate) {
        return TodoLocalized(self.language, @"全部时间", @"All Time");
    }

    NSDate *inclusiveEnd = [NSCalendar.currentCalendar dateByAddingUnit:NSCalendarUnitDay value:-1 toDate:self.createdToExclusiveDate options:0];
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:(self.language == TodoLanguageEnglish ? @"en_US" : @"zh_CN")];
    formatter.dateFormat = @"yyyy-MM-dd";
    return [NSString stringWithFormat:@"%@ – %@", [formatter stringFromDate:self.createdFromDate], [formatter stringFromDate:inclusiveEnd]];
}
- (NSString *)sortModeTitle {
    if (self.sortMode == TodoSortModeNewestFirst) return TodoLocalized(self.language, @"最新优先", @"Newest First");
    if (self.sortMode == TodoSortModePriorityFirst) return TodoLocalized(self.language, @"优先级优先", @"Priority First");
    return TodoLocalized(self.language, @"默认顺序", @"Original Order");
}
- (void)updateFilterMenuPresentation {
    NSInteger activeSettings = 0;
    if (self.filterIndex != 0) activeSettings++;
    if (self.dateFilterMode != TodoDateFilterModeAll) activeSettings++;
    if (self.sortMode != TodoSortModeOriginal) activeSettings++;

    NSString *baseTitle = TodoLocalized(self.language, @"筛选/排序", @"Filter / Sort");
    self.sidebar.filterMenuButton.title = activeSettings > 0
        ? [NSString stringWithFormat:@"%@ · %ld ▾", baseTitle, (long)activeSettings]
        : [NSString stringWithFormat:@"%@ ▾", baseTitle];
    NSString *summary = [NSString stringWithFormat:
        TodoLocalized(self.language, @"状态：%@ · 时间：%@ · 排序：%@", @"Status: %@ · Time: %@ · Sort: %@"),
        [self statusFilterTitle], [self dateFilterTitle], [self sortModeTitle]];
    self.sidebar.filterMenuButton.toolTip = summary;
    self.sidebar.filterMenuButton.accessibilityValue = summary;
    [self.sidebar setNeedsLayout:YES];
}
- (NSMenu *)buildFilterMenu {
    NSMenu *menu = [NSMenu new];
    menu.autoenablesItems = NO;

    NSMenuItem *statusHeading = [menu addItemWithTitle:TodoLocalized(self.language, @"状态", @"Status") action:nil keyEquivalent:@""];
    statusHeading.enabled = NO;
    NSArray<NSString *> *statusTitles = self.language == TodoLanguageEnglish
        ? @[@"All", @"Active", @"Done"]
        : @[@"全部", @"待办", @"已完成"];
    for (NSInteger index = 0; index < statusTitles.count; index++) {
        NSMenuItem *item = [menu addItemWithTitle:statusTitles[index] action:@selector(setStatusFilterFromMenu:) keyEquivalent:@""];
        item.target = self;
        item.tag = index;
        item.state = self.filterIndex == index ? NSControlStateValueOn : NSControlStateValueOff;
    }

    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *timeHeading = [menu addItemWithTitle:TodoLocalized(self.language, @"首次定义时间", @"Creation Time") action:nil keyEquivalent:@""];
    timeHeading.enabled = NO;
    NSArray<NSString *> *timeTitles = self.language == TodoLanguageEnglish
        ? @[@"All Time", @"Last 24 Hours", @"Last 7 Days", @"Custom Range…"]
        : @[@"全部时间", @"过去 24 小时", @"过去 7 天", @"自定义范围…"];
    for (NSInteger index = 0; index < timeTitles.count; index++) {
        NSMenuItem *item = [menu addItemWithTitle:timeTitles[index] action:@selector(setDateFilterFromMenu:) keyEquivalent:@""];
        item.target = self;
        item.tag = index;
        item.state = self.dateFilterMode == index ? NSControlStateValueOn : NSControlStateValueOff;
        if (index == TodoDateFilterModeCustom && self.dateFilterMode == TodoDateFilterModeCustom) {
            item.toolTip = [self dateFilterTitle];
        }
    }

    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *sortHeading = [menu addItemWithTitle:TodoLocalized(self.language, @"排序", @"Sort") action:nil keyEquivalent:@""];
    sortHeading.enabled = NO;
    NSArray<NSString *> *sortTitles = self.language == TodoLanguageEnglish
        ? @[@"Original Order", @"Newest First", @"Priority First"]
        : @[@"默认顺序", @"最新优先", @"优先级优先"];
    for (NSInteger index = 0; index < sortTitles.count; index++) {
        NSMenuItem *item = [menu addItemWithTitle:sortTitles[index] action:@selector(setSortModeFromMenu:) keyEquivalent:@""];
        item.target = self;
        item.tag = index;
        item.state = self.sortMode == index ? NSControlStateValueOn : NSControlStateValueOff;
    }
    return menu;
}
- (void)showFilterMenu {
    NSMenu *menu = [self buildFilterMenu];
    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, 0) inView:self.sidebar.filterMenuButton];
}
- (void)setStatusFilterFromMenu:(NSMenuItem *)sender {
    self.filterIndex = MAX(0, MIN(sender.tag, 2));
    [self updateFilterMenuPresentation];
    [self applyFilter];
}
- (void)setDateFilterFromMenu:(NSMenuItem *)sender {
    [self selectDateFilter:(TodoDateFilterMode)MAX(TodoDateFilterModeAll, MIN(sender.tag, TodoDateFilterModeCustom))];
}
- (void)setSortModeFromMenu:(NSMenuItem *)sender {
    self.sortMode = (TodoSortMode)MAX(TodoSortModeOriginal, MIN(sender.tag, TodoSortModePriorityFirst));
    [NSUserDefaults.standardUserDefaults setInteger:self.sortMode forKey:TodoSortModeDefaultsKey];
    [self updateFilterMenuPresentation];
    [self applyFilter];
}

- (void)showManagementMenu {
    NSInteger completedCount = 0;
    NSInteger archivedCount = 0;
    for (NSDictionary *summary in self.summaries) {
        if ([summary[@"archived"] boolValue]) archivedCount++;
        else if ([summary[@"completed"] boolValue]) completedCount++;
    }

    BOOL currentArchived = [self.currentTodo[@"archived"] boolValue];
    NSMenu *menu = [NSMenu new];
    menu.autoenablesItems = NO;

    NSString *archiveViewTitle = self.archiveView
        ? TodoLocalized(self.language, @"返回任务列表", @"Show Current Tasks")
        : [NSString stringWithFormat:TodoLocalized(self.language, @"查看归档（%ld）", @"Show Archive (%ld)"), (long)archivedCount];
    NSMenuItem *archiveViewItem = [menu addItemWithTitle:archiveViewTitle action:@selector(toggleArchiveView:) keyEquivalent:@""];
    archiveViewItem.target = self;
    archiveViewItem.enabled = self.archiveView || archivedCount > 0;
    archiveViewItem.state = self.archiveView ? NSControlStateValueOn : NSControlStateValueOff;

    [menu addItem:NSMenuItem.separatorItem];

    NSString *currentTitle = self.archiveView
        ? TodoLocalized(self.language, @"恢复当前任务", @"Restore Current Task")
        : TodoLocalized(self.language, @"归档当前任务", @"Archive Current Task");
    NSMenuItem *currentItem = [menu addItemWithTitle:currentTitle action:@selector(toggleArchiveCurrent:) keyEquivalent:@""];
    currentItem.target = self;
    currentItem.enabled = self.currentTodo != nil && currentArchived == self.archiveView;

    NSString *visibleTitle = self.archiveView
        ? [NSString stringWithFormat:TodoLocalized(self.language, @"恢复当前列表（%ld）", @"Restore Visible (%ld)"), (long)self.filtered.count]
        : [NSString stringWithFormat:TodoLocalized(self.language, @"归档当前列表（%ld）", @"Archive Visible (%ld)"), (long)self.filtered.count];
    NSMenuItem *visibleItem = [menu addItemWithTitle:visibleTitle action:@selector(toggleArchiveVisible:) keyEquivalent:@""];
    visibleItem.target = self;
    visibleItem.enabled = self.filtered.count > 0;

    NSMenuItem *archiveCompletedItem = [menu addItemWithTitle:
        [NSString stringWithFormat:TodoLocalized(self.language, @"归档已完成（%ld）", @"Archive Completed (%ld)"), (long)completedCount]
        action:@selector(archiveCompletedFromMenu:) keyEquivalent:@""];
    archiveCompletedItem.target = self;
    archiveCompletedItem.enabled = completedCount > 0;
    archiveCompletedItem.hidden = self.archiveView;

    NSMenuItem *restoreAllItem = [menu addItemWithTitle:
        [NSString stringWithFormat:TodoLocalized(self.language, @"恢复所有归档（%ld）", @"Restore All Archived (%ld)"), (long)archivedCount]
        action:@selector(restoreAllArchivedFromMenu:) keyEquivalent:@""];
    restoreAllItem.target = self;
    restoreAllItem.enabled = archivedCount > 0;

    [menu addItem:NSMenuItem.separatorItem];

    NSMenuItem *deleteCompletedItem = [menu addItemWithTitle:
        [NSString stringWithFormat:TodoLocalized(self.language, @"删除已完成（%ld）…", @"Delete Completed (%ld)…"), (long)completedCount]
        action:@selector(confirmClearCompleted:) keyEquivalent:@""];
    deleteCompletedItem.target = self;
    deleteCompletedItem.enabled = completedCount > 0;

    NSMenuItem *deleteArchivedItem = [menu addItemWithTitle:
        [NSString stringWithFormat:TodoLocalized(self.language, @"删除所有归档（%ld）…", @"Delete All Archived (%ld)…"), (long)archivedCount]
        action:@selector(confirmClearArchived:) keyEquivalent:@""];
    deleteArchivedItem.target = self;
    deleteArchivedItem.enabled = archivedCount > 0;

    [menu popUpMenuPositioningItem:nil atLocation:NSMakePoint(0, 0) inView:self.sidebar.managementButton];
}
- (void)toggleArchiveView:(id)sender {
    if (![self saveIfNeeded]) return;
    self.archiveView = !self.archiveView;
    if (self.currentTodo && [self.currentTodo[@"archived"] boolValue] != self.archiveView) {
        self.selectedID = nil;
        [self clearCurrent];
    }
    [self applyFilter];
}
- (BOOL)setArchivedForIDs:(NSArray<NSNumber *> *)todoIDs archived:(BOOL)archived {
    if (todoIDs.count == 0) return YES;
    if (![self saveIfNeeded]) return NO;
    NSError *error = nil;
    if (!BridgeCall(@{@"command": @"setArchived", @"ids": todoIDs, @"archived": @(archived)}, &error)) {
        [self showError:error];
        return NO;
    }
    if (self.selectedID && [todoIDs containsObject:self.selectedID]) {
        self.selectedID = nil;
        [self clearCurrent];
    }
    [self reloadSummaries];
    return YES;
}
- (void)toggleArchiveCurrent:(id)sender {
    if (!self.selectedID) return;
    [self setArchivedForIDs:@[self.selectedID] archived:!self.archiveView];
}
- (void)toggleArchiveVisible:(id)sender {
    NSMutableArray<NSNumber *> *todoIDs = [NSMutableArray arrayWithCapacity:self.filtered.count];
    for (NSDictionary *summary in self.filtered) {
        NSNumber *todoID = summary[@"id"];
        if (todoID) [todoIDs addObject:todoID];
    }
    [self setArchivedForIDs:todoIDs archived:!self.archiveView];
}
- (void)archiveCompletedFromMenu:(id)sender {
    if (![self saveIfNeeded]) return;
    BOOL selectedMoves = self.currentTodo && ![self.currentTodo[@"archived"] boolValue] && [self.currentTodo[@"completed"] boolValue];
    NSError *error = nil;
    if (!BridgeCall(@{@"command": @"archiveCompleted"}, &error)) {
        [self showError:error];
        return;
    }
    if (selectedMoves) {
        self.selectedID = nil;
        [self clearCurrent];
    }
    [self reloadSummaries];
}
- (void)restoreAllArchivedFromMenu:(id)sender {
    if (![self saveIfNeeded]) return;
    BOOL selectedMoves = [self.currentTodo[@"archived"] boolValue];
    NSError *error = nil;
    if (!BridgeCall(@{@"command": @"restoreArchived"}, &error)) {
        [self showError:error];
        return;
    }
    if (selectedMoves) {
        self.selectedID = nil;
        [self clearCurrent];
    }
    [self reloadSummaries];
}
- (BOOL)confirmDeletionTitle:(NSString *)title message:(NSString *)message {
    NSAlert *alert = [NSAlert new];
    alert.alertStyle = NSAlertStyleWarning;
    alert.messageText = title;
    alert.informativeText = message;
    [alert addButtonWithTitle:TodoLocalized(self.language, @"删除", @"Delete")];
    [alert addButtonWithTitle:TodoLocalized(self.language, @"取消", @"Cancel")];
    return [alert runModal] == NSAlertFirstButtonReturn;
}
- (void)performClearCompleted {
    if (![self saveIfNeeded]) return;
    BOOL selectedDeleted = self.currentTodo && ![self.currentTodo[@"archived"] boolValue] && [self.currentTodo[@"completed"] boolValue];
    NSError *error = nil;
    if (!BridgeCall(@{@"command": @"clearCompleted"}, &error)) {
        [self showError:error];
        return;
    }
    if (selectedDeleted) {
        self.selectedID = nil;
        [self clearCurrent];
    }
    [self reloadSummaries];
}
- (void)confirmClearCompleted:(id)sender {
    NSInteger count = 0;
    for (NSDictionary *summary in self.summaries) {
        if (![summary[@"archived"] boolValue] && [summary[@"completed"] boolValue]) count++;
    }
    if (count == 0) return;
    NSString *title = [NSString stringWithFormat:TodoLocalized(self.language, @"删除 %ld 个已完成任务？", @"Delete %ld completed tasks?"), (long)count];
    NSString *message = TodoLocalized(self.language, @"此操作无法撤销。归档任务不会被删除。", @"This cannot be undone. Archived tasks will not be deleted.");
    if ([self confirmDeletionTitle:title message:message]) [self performClearCompleted];
}
- (void)performClearArchived {
    if (![self saveIfNeeded]) return;
    BOOL selectedDeleted = [self.currentTodo[@"archived"] boolValue];
    NSError *error = nil;
    if (!BridgeCall(@{@"command": @"clearArchived"}, &error)) {
        [self showError:error];
        return;
    }
    if (selectedDeleted) {
        self.selectedID = nil;
        [self clearCurrent];
    }
    [self reloadSummaries];
}
- (void)confirmClearArchived:(id)sender {
    NSInteger count = 0;
    for (NSDictionary *summary in self.summaries) if ([summary[@"archived"] boolValue]) count++;
    if (count == 0) return;
    NSString *title = [NSString stringWithFormat:TodoLocalized(self.language, @"删除 %ld 个归档任务？", @"Delete %ld archived tasks?"), (long)count];
    NSString *message = TodoLocalized(self.language, @"归档中的任务将被永久删除，此操作无法撤销。", @"Archived tasks will be permanently deleted. This cannot be undone.");
    if ([self confirmDeletionTitle:title message:message]) [self performClearArchived];
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

    BOOL archiveView = self.archiveView;
    NSPredicate *predicate = [NSPredicate predicateWithBlock:^BOOL(NSDictionary *summary, NSDictionary *bindings) {
        BOOL archived = [summary[@"archived"] boolValue];
        if (archived != archiveView) return NO;
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

    NSArray<NSDictionary *> *filtered = [self.summaries filteredArrayUsingPredicate:predicate];
    if (self.sortMode != TodoSortModeOriginal) {
        TodoSortMode sortMode = self.sortMode;
        filtered = [filtered sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *left, NSDictionary *right) {
            if (sortMode == TodoSortModePriorityFirst) {
                TodoPriority leftPriority = TodoPriorityFromValue(left[@"priority"]);
                TodoPriority rightPriority = TodoPriorityFromValue(right[@"priority"]);
                if (leftPriority != rightPriority) {
                    return leftPriority > rightPriority ? NSOrderedAscending : NSOrderedDescending;
                }
            }

            NSNumber *leftTimestamp = [left[@"createdAtMs"] isKindOfClass:NSNumber.class] ? left[@"createdAtMs"] : @0;
            NSNumber *rightTimestamp = [right[@"createdAtMs"] isKindOfClass:NSNumber.class] ? right[@"createdAtMs"] : @0;
            NSComparisonResult timestampOrder = [rightTimestamp compare:leftTimestamp];
            if (timestampOrder != NSOrderedSame) return timestampOrder;

            NSNumber *leftID = [left[@"id"] isKindOfClass:NSNumber.class] ? left[@"id"] : @0;
            NSNumber *rightID = [right[@"id"] isKindOfClass:NSNumber.class] ? right[@"id"] : @0;
            return [rightID compare:leftID];
        }];
    }
    self.filtered = filtered;
    NSInteger active = 0;
    NSInteger currentCount = 0;
    NSInteger archivedCount = 0;
    for (NSDictionary *summary in self.summaries) {
        if ([summary[@"archived"] boolValue]) {
            archivedCount++;
        } else {
            currentCount++;
            if (![summary[@"completed"] boolValue]) active++;
        }
    }

    if (self.archiveView) {
        self.sidebar.countLabel.stringValue = self.language == TodoLanguageEnglish
            ? [NSString stringWithFormat:@"%ld shown · %ld archived", (long)self.filtered.count, (long)archivedCount]
            : [NSString stringWithFormat:@"%ld 项显示 · %ld 项归档", (long)self.filtered.count, (long)archivedCount];
    } else if (self.dateFilterMode != TodoDateFilterModeAll) {
        self.sidebar.countLabel.stringValue = self.language == TodoLanguageEnglish
            ? [NSString stringWithFormat:@"%ld shown · %ld tasks", (long)self.filtered.count, (long)currentCount]
            : [NSString stringWithFormat:@"%ld 项显示 · %ld 项任务", (long)self.filtered.count, (long)currentCount];
    } else {
        self.sidebar.countLabel.stringValue = self.language == TodoLanguageEnglish
            ? [NSString stringWithFormat:@"%ld active · %ld tasks", (long)active, (long)currentCount]
            : [NSString stringWithFormat:@"%ld 项待办 · %ld 项任务", (long)active, (long)currentCount];
    }
    self.sidebar.toggleAllButton.hidden = self.archiveView;
    self.sidebar.toggleAllButton.title = active == 0 && currentCount > 0
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
    [self updateFilterMenuPresentation];
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
            [strongSelf updateFilterMenuPresentation];
            return;
        }

        NSDate *start = [calendar startOfDayForDate:fromPicker.dateValue];
        NSDate *endDay = [calendar startOfDayForDate:toPicker.dateValue];
        NSDate *endExclusive = [calendar dateByAddingUnit:NSCalendarUnitDay value:1 toDate:endDay options:0];
        if ([start compare:endExclusive] != NSOrderedAscending) {
            [strongSelf updateFilterMenuPresentation];
            NSError *error = [NSError errorWithDomain:TodoErrorDomain code:6 userInfo:@{NSLocalizedDescriptionKey: TodoLocalized(strongSelf.language, @"开始日期不能晚于结束日期", @"The start date cannot be later than the end date")}];
            [strongSelf showError:error];
            return;
        }

        strongSelf.dateFilterMode = TodoDateFilterModeCustom;
        strongSelf.createdFromDate = start;
        strongSelf.createdToExclusiveDate = endExclusive;
        [strongSelf updateFilterMenuPresentation];
        [strongSelf applyFilter];
    }];
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
    self.detail.priorityControl.selectedIndex = TodoPriorityFromValue(todo[@"priority"]);
    [self updateCompletion];
    [self updateSubtaskPresentation];
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
    self.detail.priorityControl.enabled = available;
    self.detail.addSubtaskButton.enabled = available;
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
    self.detail.priorityControl.selectedIndex = TodoPriorityLow;
    self.detail.subtaskCount = 0;
    self.detail.subtaskSummaryLabel.stringValue = @"";
    [self.detail.subtaskTable reloadData];
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
    self.archiveView = NO;
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
- (NSString *)currentCompletionState {
    id value = self.currentTodo[@"subtasks"];
    NSArray *subtasks = [value isKindOfClass:NSArray.class] ? value : @[];
    if (subtasks.count == 0) return [self.currentTodo[@"completed"] boolValue] ? @"completed" : @"active";
    NSInteger completed = 0;
    for (NSDictionary *subtask in subtasks) if ([subtask[@"completed"] boolValue]) completed++;
    if (completed == 0) return @"active";
    if (completed == subtasks.count) return @"completed";
    return @"partial";
}
- (void)updateSubtaskPresentation {
    NSArray<NSDictionary *> *subtasks = self.currentSubtasks;
    NSInteger completed = 0;
    for (NSDictionary *subtask in subtasks) if ([subtask[@"completed"] boolValue]) completed++;
    self.detail.subtaskCount = subtasks.count;
    NSString *state = self.currentCompletionState;
    NSString *stateTitle = [state isEqualToString:@"completed"]
        ? TodoLocalized(self.language, @"已完成", @"Completed")
        : ([state isEqualToString:@"partial"]
            ? TodoLocalized(self.language, @"半完成", @"Partially completed")
            : TodoLocalized(self.language, @"未完成", @"Not completed"));
    self.detail.subtaskSummaryLabel.stringValue = subtasks.count > 0
        ? [NSString stringWithFormat:TodoLocalized(self.language, @"子任务 %ld/%ld · %@", @"Subtasks %ld/%ld · %@"), (long)completed, (long)subtasks.count, stateTitle]
        : TodoLocalized(self.language, @"子任务", @"Subtasks");
    [self.detail.subtaskTable reloadData];
    [self.detail setNeedsLayout:YES];
    [self.detail layoutSubtreeIfNeeded];
}
- (void)applySubtaskMutation:(NSDictionary *)todo {
    self.currentTodo = todo;
    [self updateSubtaskPresentation];
    [self updateCompletion];
    [self reloadSummaries];
    [self updateSelection];
}
- (void)addSubtask {
    if (!self.currentTodo || !self.selectedID) return;
    NSError *error = nil;
    NSDictionary *todo = BridgeCall(@{
        @"command": @"addSubtask",
        @"id": self.selectedID,
        @"title": TodoLocalized(self.language, @"新子任务", @"New Subtask"),
    }, &error);
    if (!todo) {
        [self showError:error];
        return;
    }
    [self applySubtaskMutation:todo];

    NSInteger row = self.currentSubtasks.count - 1;
    if (row < 0) return;
    [self.detail.subtaskTable scrollRowToVisible:row];
    SubtaskCellView *cell = (SubtaskCellView *)[self.detail.subtaskTable viewAtColumn:0
                                                                                row:row
                                                                    makeIfNecessary:YES];
    if ([self.view.window makeFirstResponder:cell.titleField]) {
        NSText *fieldEditor = [cell.titleField currentEditor];
        [fieldEditor setSelectedRange:NSMakeRange(0, cell.titleField.stringValue.length)];
    }
}
- (void)toggleSubtaskID:(NSNumber *)subtaskID completed:(BOOL)completed {
    if (!self.selectedID || !subtaskID) return;
    NSError *error = nil;
    NSDictionary *todo = BridgeCall(@{
        @"command": @"updateSubtask",
        @"id": self.selectedID,
        @"subtaskId": subtaskID,
        @"completed": @(completed),
    }, &error);
    if (!todo) {
        [self showError:error];
        [self.detail.subtaskTable reloadData];
        return;
    }
    [self applySubtaskMutation:todo];
}
- (void)renameSubtaskID:(NSNumber *)subtaskID title:(NSString *)title {
    if (!self.selectedID || !subtaskID) return;
    NSError *error = nil;
    NSDictionary *todo = BridgeCall(@{
        @"command": @"updateSubtask",
        @"id": self.selectedID,
        @"subtaskId": subtaskID,
        @"title": title,
    }, &error);
    if (!todo) {
        [self showError:error];
        [self.detail.subtaskTable reloadData];
        return;
    }
    [self applySubtaskMutation:todo];
}
- (void)deleteSubtaskID:(NSNumber *)subtaskID {
    if (!self.selectedID || !subtaskID) return;
    NSError *error = nil;
    NSDictionary *todo = BridgeCall(@{
        @"command": @"deleteSubtask",
        @"id": self.selectedID,
        @"subtaskId": subtaskID,
    }, &error);
    if (!todo) {
        [self showError:error];
        return;
    }
    [self applySubtaskMutation:todo];
}
- (void)toggleID:(NSNumber *)todoID completed:(BOOL)completed {
    if ([todoID isEqual:self.selectedID] && ![self saveIfNeeded]) {
        [self reloadSummaries];
        return;
    }
    NSError *error = nil;
    NSDictionary *todo = BridgeCall(@{
        @"command": @"update",
        @"id": todoID,
        @"completed": @(completed),
    }, &error);
    if (!todo) {
        [self showError:error];
        [self reloadSummaries];
        return;
    }
    [self reloadSummaries];
    if ([todoID isEqual:self.selectedID]) {
        self.currentTodo = todo;
        [self updateSubtaskPresentation];
        [self updateCompletion];
    }
}
- (void)toggleAll {
    if (![self saveIfNeeded]) return;
    BOOL complete = NO;
    for (NSDictionary *summary in self.summaries) {
        if (![summary[@"archived"] boolValue] && ![summary[@"completed"] boolValue]) {
            complete = YES;
            break;
        }
    }
    NSError *error = nil;
    id value = BridgeCall(@{@"command": @"setAllCompleted", @"completed": @(complete)}, &error);
    if (!value) {
        [self showError:error];
        return;
    }
    self.summaries = value;
    [self applyFilter];
    if (self.selectedID) [self selectID:self.selectedID];
}
- (void)toggleCurrent {
    if (![self saveIfNeeded] || !self.currentTodo) return;
    [self toggleID:self.selectedID completed:![self.currentCompletionState isEqualToString:@"completed"]];
}
- (void)updateCompletion {
    NSString *state = self.currentCompletionState;
    BOOL completed = [state isEqualToString:@"completed"];
    BOOL hasSubtasks = self.currentSubtasks.count > 0;
    if (completed) {
        self.detail.completeButton.title = TodoLocalized(self.language, @"恢复为待办", @"Restore to Active");
        self.detail.completeButton.foregroundColor = NSColor.systemGreenColor;
    } else if (hasSubtasks) {
        self.detail.completeButton.title = TodoLocalized(self.language, @"完成全部子任务", @"Complete All Subtasks");
        self.detail.completeButton.foregroundColor = [state isEqualToString:@"partial"] ? NSColor.systemOrangeColor : NSColor.secondaryLabelColor;
    } else {
        self.detail.completeButton.title = TodoLocalized(self.language, @"标记完成", @"Mark Complete");
        self.detail.completeButton.foregroundColor = NSColor.secondaryLabelColor;
    }
    [self.detail setNeedsLayout:YES];
    [self.detail layoutSubtreeIfNeeded];
}
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
    NSString *benchmarkStatusFilter = environment[@"TODO_BENCHMARK_STATUS_FILTER"];
    NSString *benchmarkDateFilter = environment[@"TODO_BENCHMARK_DATE_FILTER"];
    NSString *benchmarkFrom = environment[@"TODO_BENCHMARK_FROM_MS"];
    NSString *benchmarkTo = environment[@"TODO_BENCHMARK_TO_MS"];
    NSString *benchmarkSort = environment[@"TODO_BENCHMARK_SORT"];
    NSString *benchmarkArchiveView = environment[@"TODO_BENCHMARK_ARCHIVE_VIEW"];
    NSString *benchmarkManagementAction = environment[@"TODO_BENCHMARK_MANAGEMENT_ACTION"];
    NSString *benchmarkRefreshAfterMs = environment[@"TODO_BENCHMARK_REFRESH_AFTER_MS"];
    if ([benchmarkStatusFilter isEqualToString:@"active"]) {
        self.filterIndex = 1;
    } else if ([benchmarkStatusFilter isEqualToString:@"completed"]) {
        self.filterIndex = 2;
    } else if ([benchmarkStatusFilter isEqualToString:@"all"]) {
        self.filterIndex = 0;
    }
    if ([benchmarkDateFilter isEqualToString:@"24h"]) {
        self.dateFilterMode = TodoDateFilterModeLast24Hours;
    } else if ([benchmarkDateFilter isEqualToString:@"7d"]) {
        self.dateFilterMode = TodoDateFilterModeLast7Days;
    } else if (benchmarkFrom.length || benchmarkTo.length) {
        self.dateFilterMode = TodoDateFilterModeCustom;
        if (benchmarkFrom.length) self.createdFromDate = [NSDate dateWithTimeIntervalSince1970:benchmarkFrom.doubleValue / 1000.0];
        if (benchmarkTo.length) self.createdToExclusiveDate = [NSDate dateWithTimeIntervalSince1970:benchmarkTo.doubleValue / 1000.0];
    }
    if ([benchmarkSort isEqualToString:@"newest"]) {
        self.sortMode = TodoSortModeNewestFirst;
    } else if ([benchmarkSort isEqualToString:@"priority"]) {
        self.sortMode = TodoSortModePriorityFirst;
    } else if ([benchmarkSort isEqualToString:@"original"]) {
        self.sortMode = TodoSortModeOriginal;
    }
    if (benchmarkArchiveView.length) self.archiveView = benchmarkArchiveView.boolValue;
    if (benchmarkStatusFilter.length || benchmarkDateFilter.length || benchmarkFrom.length || benchmarkTo.length || benchmarkSort.length || benchmarkArchiveView.length) {
        [self updateFilterMenuPresentation];
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
    NSString *forcedPriority = environment[@"TODO_BENCHMARK_PRIORITY"];
    if (forcedPriority.length) {
        [self changeCurrentPriority:TodoPriorityFromValue(forcedPriority)];
    }

    if ([benchmarkManagementAction isEqualToString:@"archive_completed"]) {
        [self archiveCompletedFromMenu:nil];
    } else if ([benchmarkManagementAction isEqualToString:@"archive_visible"]) {
        [self toggleArchiveVisible:nil];
    } else if ([benchmarkManagementAction isEqualToString:@"restore_archived"]) {
        [self restoreAllArchivedFromMenu:nil];
    } else if ([benchmarkManagementAction isEqualToString:@"delete_completed"]) {
        [self performClearCompleted];
    } else if ([benchmarkManagementAction isEqualToString:@"delete_archived"]) {
        [self performClearArchived];
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

    double diagnosticsDelay = 0.25;
    if (benchmarkRefreshAfterMs.doubleValue > 0.0) {
        double refreshDelay = benchmarkRefreshAfterMs.doubleValue / 1000.0;
        diagnosticsDelay = refreshDelay + 0.35;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(refreshDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self refreshFromDisk:nil];
        });
    }

    if ([NSProcessInfo.processInfo.environment[@"TODO_LAYOUT_DIAGNOSTICS"] boolValue]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(diagnosticsDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self.detail layoutSubtreeIfNeeded];
            NSRect viewport = self.detail.editorScroll.contentView.bounds;
            NSRect editorUsed = [self.detail.editor.layoutManager usedRectForTextContainer:self.detail.editor.textContainer];
            NSRect resultUsed = [self.detail.completionResultEditor.layoutManager usedRectForTextContainer:self.detail.completionResultEditor.textContainer];
            NSRect previewUsed = self.detail.preview ? [self.detail.preview.layoutManager usedRectForTextContainer:self.detail.preview.textContainer] : NSZeroRect;
            NSRect resultPreviewUsed = self.detail.completionResultPreview ? [self.detail.completionResultPreview.layoutManager usedRectForTextContainer:self.detail.completionResultPreview.textContainer] : NSZeroRect;
            NSRect dividerHit = [self.detail dividerHitRect];
            CGFloat dividerY = NSMidY(dividerHit);
            NSArray<NSNumber *> *dividerFractions = @[@0.05, @0.5, @0.95];
            NSMutableArray<NSNumber *> *dividerOwnership = [NSMutableArray arrayWithCapacity:dividerFractions.count];
            for (NSNumber *fraction in dividerFractions) {
                NSPoint localPoint = NSMakePoint(NSMinX(dividerHit) + NSWidth(dividerHit) * fraction.doubleValue, dividerY);
                NSPoint superviewPoint = [self.detail convertPoint:localPoint toView:self.detail.superview];
                [dividerOwnership addObject:@([self.detail hitTest:superviewPoint] == self.detail)];
            }
            BOOL dividerOwnsLeft = dividerOwnership[0].boolValue;
            BOOL dividerOwnsCenter = dividerOwnership[1].boolValue;
            BOOL dividerOwnsRight = dividerOwnership[2].boolValue;
            __block NSUInteger resultPreviewLinks = 0;
            if (self.detail.completionResultPreview.textStorage.length > 0) {
                [self.detail.completionResultPreview.textStorage enumerateAttribute:NSLinkAttributeName
                                                                            inRange:NSMakeRange(0, self.detail.completionResultPreview.textStorage.length)
                                                                            options:0
                                                                         usingBlock:^(id value, NSRange range, BOOL *stop) {
                    if (value) resultPreviewLinks++;
                }];
            }
            NSNumber *firstFilteredID = self.filtered.count > 0 ? self.filtered[0][@"id"] : nil;
            NSNumber *secondFilteredID = self.filtered.count > 1 ? self.filtered[1][@"id"] : nil;
            NSNumber *thirdFilteredID = self.filtered.count > 2 ? self.filtered[2][@"id"] : nil;
            TaskCellView *firstCell = self.filtered.count > 0 ? (TaskCellView *)[self.sidebar.tableView viewAtColumn:0 row:0 makeIfNecessary:YES] : nil;
            NSArray<NSDictionary *> *diagnosticSubtasks = self.currentSubtasks;
            SubtaskCellView *firstSubtaskCell = diagnosticSubtasks.count > 0
                ? (SubtaskCellView *)[self.detail.subtaskTable viewAtColumn:0 row:0 makeIfNecessary:YES]
                : nil;
            NSInteger diagnosticCompletedSubtasks = 0;
            for (NSDictionary *subtask in diagnosticSubtasks) if ([subtask[@"completed"] boolValue]) diagnosticCompletedSubtasks++;
            NSMenu *filterMenu = [self buildFilterMenu];
            NSUInteger checkedFilterItems = 0;
            NSUInteger filterMenuHeadings = 0;
            for (NSMenuItem *item in filterMenu.itemArray) {
                if (item.state == NSControlStateValueOn) checkedFilterItems++;
                if (!item.enabled && !item.isSeparatorItem) filterMenuHeadings++;
            }
            fprintf(stderr,
                    "mode=%s viewMode=%s sortMode=%s filterStatus=%ld dateFilter=%ld archiveView=%d completionState=%s subtaskCount=%lu completedSubtasks=%ld subtaskRows=%ld subtaskSectionVisible=%d subtaskScrollHidden=%d subtaskScrollHeight=%.0f documentTop=%.0f subtaskSummary=%s firstSubtaskID=%s firstSubtaskTitle=%s firstSubtaskCheck=%ld parentCheck=%ld completeButton=%s filterMenuItems=%lu filterMenuChecked=%lu filterMenuHeadings=%lu filterButtonTitle=%s toggleX=%.0f toggleWidth=%.0f filterButtonX=%.0f filterButtonWidth=%.0f tableY=%.0f tableHeight=%.0f firstFilteredID=%s firstCellID=%s firstTitleX=%.0f firstTitleWidth=%.0f firstTitleY=%.0f firstIDY=%.0f secondFilteredID=%s thirdFilteredID=%s selectedID=%s selectedPriority=%s priorityControl=%ld resultExpanded=%d resultDisclosureHidden=%d resultDisclosure=%.0fx%.0f language=%s heading=%s createTask=%s managementTitle=%s managementHidden=%d todos=%lu filtered=%lu window=%.0fx%.0f split=%.0fx%.0f sidebarFrame=%.0f,%.0f,%.0f,%.0f detailFrame=%.0f,%.0f,%.0f,%.0f viewport=%.0fx%.0f editor=%.0fx%.0f editorContainer=%.0f editorUsed=%.0f editorChars=%lu result=%.0fx%.0f resultUsed=%.0fx%.0f resultChars=%lu preview=%.0fx%.0f previewContainer=%.0f previewUsed=%.0f previewChars=%lu resultPreviewExists=%d resultPreview=%.0fx%.0f resultPreviewContainer=%.0f resultPreviewUsed=%.0fx%.0f resultPreviewChars=%lu resultPreviewLinks=%lu resultEditorHidden=%d resultPreviewHidden=%d editorHidden=%d previewHidden=%d dividerHitHeight=%.0f dividerOwnsLeft=%d dividerOwnsCenter=%d dividerOwnsRight=%d\n",
                    mode.UTF8String,
                    self.viewMode == TodoViewModeEdit ? "edit" : (self.viewMode == TodoViewModeSplit ? "split" : "preview"),
                    self.sortMode == TodoSortModeNewestFirst ? "newest" : (self.sortMode == TodoSortModePriorityFirst ? "priority" : "original"),
                    (long)self.filterIndex,
                    (long)self.dateFilterMode,
                    self.archiveView,
                    self.currentCompletionState.UTF8String,
                    (unsigned long)diagnosticSubtasks.count,
                    (long)diagnosticCompletedSubtasks,
                    (long)self.detail.subtaskTable.numberOfRows,
                    self.detail.subtaskSectionVisible,
                    self.detail.subtaskScroll.hidden,
                    NSHeight(self.detail.subtaskScroll.frame),
                    NSMinY(self.detail.editorScroll.frame),
                    self.detail.subtaskSummaryLabel.stringValue.UTF8String,
                    diagnosticSubtasks.count > 0 ? [diagnosticSubtasks[0][@"id"] stringValue].UTF8String : "none",
                    firstSubtaskCell.titleField.stringValue.UTF8String ?: "none",
                    (long)firstSubtaskCell.check.checkState,
                    (long)firstCell.check.checkState,
                    self.detail.completeButton.title.UTF8String,
                    (unsigned long)filterMenu.itemArray.count,
                    (unsigned long)checkedFilterItems,
                    (unsigned long)filterMenuHeadings,
                    self.sidebar.filterMenuButton.title.UTF8String,
                    NSMinX(self.sidebar.toggleAllButton.frame),
                    NSWidth(self.sidebar.toggleAllButton.frame),
                    NSMinX(self.sidebar.filterMenuButton.frame),
                    NSWidth(self.sidebar.filterMenuButton.frame),
                    NSMinY(self.sidebar.scrollView.frame),
                    NSHeight(self.sidebar.scrollView.frame),
                    firstFilteredID.stringValue.UTF8String ?: "none",
                    firstCell.idLabel.stringValue.UTF8String ?: "none",
                    NSMinX(firstCell.titleLabel.frame),
                    NSWidth(firstCell.titleLabel.frame),
                    NSMinY(firstCell.titleLabel.frame),
                    NSMinY(firstCell.idLabel.frame),
                    secondFilteredID.stringValue.UTF8String ?: "none",
                    thirdFilteredID.stringValue.UTF8String ?: "none",
                    self.selectedID.stringValue.UTF8String ?: "none",
                    TodoPriorityValue(TodoPriorityFromValue(self.currentTodo[@"priority"])).UTF8String,
                    (long)self.detail.priorityControl.selectedIndex,
                    self.detail.resultExpanded,
                    self.detail.completionResultDisclosure.hidden,
                    NSWidth(self.detail.completionResultDisclosure.frame), NSHeight(self.detail.completionResultDisclosure.frame),
                    self.language == TodoLanguageEnglish ? "en" : "zh",
                    self.sidebar.headingLabel.stringValue.UTF8String,
                    self.sidebar.createTaskButton.title.UTF8String,
                    self.sidebar.managementButton.title.UTF8String,
                    self.sidebar.managementButton.hidden,
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
                    self.detail.previewScroll.hidden,
                    NSHeight(dividerHit),
                    dividerOwnsLeft,
                    dividerOwnsCenter,
                    dividerOwnsRight);
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
    NSMenuItem *refresh = [file addItemWithTitle:TodoLocalized(language, @"刷新任务", @"Refresh Tasks") action:@selector(refreshFromDisk:) keyEquivalent:@"r"];
    refresh.target = self.controller;
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
