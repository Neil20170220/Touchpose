// Copyright 2012 Todd Reed
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
// http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.


#import "QTouchposeApplication.h"
#import <QuartzCore/QuartzCore.h>

#import <objc/runtime.h>


@interface QTouchposeApplication ()

- (void)keyWindowChanged:(UIWindow *)window;
- (void)bringTouchViewToFront;

@end

/// The QTouchposeTouchesView is an overlay view that is used as the superview for
/// QTouchposeFingerView instances.
@interface QTouchposeTouchesView : UIView
@end

@implementation QTouchposeTouchesView
@end


/// The QTouchposeFingerView is used to render a finger touches on the screen.
@interface QTouchposeFingerView : UIView

- (id)initWithPoint:(CGPoint)point
              color:(UIColor *)color
touchEndAnimationDuration:(NSTimeInterval)touchEndAnimationDuration
  touchEndTransform:(CATransform3D)touchEndTransform
   customTouchImage:(UIImage *)customTouchImage
   customTouchPoint:(CGPoint)customtouchPoint;

- (instancetype)initWithFrame:(CGRect)frame NS_UNAVAILABLE;

@end

@implementation QTouchposeFingerView {
    CATransform3D _touchEndTransform;
    CGFloat _touchEndAnimationDuration;
}

#pragma mark - QTouchposeFingerView

- (id)initWithPoint:(CGPoint)point
              color:(UIColor *)color
touchEndAnimationDuration:(NSTimeInterval)touchEndAnimationDuration
  touchEndTransform:(CATransform3D)touchEndTransform
   customTouchImage:(UIImage *)customTouchImage
   customTouchPoint:(CGPoint)customtouchPoint {
    if (customTouchImage) {
        CGRect frame = CGRectMake(point.x - customtouchPoint.x,
                                  point.y - customtouchPoint.y,
                                  customTouchImage.size.width,
                                  customTouchImage.size.height);
        
        if (self = [super initWithFrame:frame]) {
            self.opaque = NO;
            
            UIImageView *iv = [[UIImageView alloc] initWithImage:customTouchImage];
            [self addSubview:iv];
            
            _touchEndAnimationDuration = touchEndAnimationDuration;
            _touchEndTransform = touchEndTransform;
        }
        
        return self;
    } else {
        const CGFloat kFingerRadius = 22.0f;
        
        CGRect frame = CGRectMake(point.x - kFingerRadius,
                                  point.y - kFingerRadius,
                                  2 * kFingerRadius,
                                  2 * kFingerRadius);
        if ((self = [super initWithFrame:frame])) {
            self.opaque = NO;
            self.layer.borderColor = [color colorWithAlphaComponent:0.6f].CGColor;
            self.layer.cornerRadius = kFingerRadius;
            self.layer.borderWidth = 2.0f;
            self.layer.backgroundColor = [color colorWithAlphaComponent:0.4f].CGColor;
            
            _touchEndAnimationDuration = touchEndAnimationDuration;
            _touchEndTransform = touchEndTransform;
        }
        
        return self;
    }
}

@end


@interface QTouchToFingerViewItem : NSObject

@property (nonatomic, strong) NSString *key;
@property (nonatomic, strong) UITouch *touch;
@property (nonatomic, strong) QTouchposeFingerView *view;

- (instancetype)initWithKey:(NSString *)key
                      touch:(UITouch *)touch
                       view:(QTouchposeFingerView *)view;

@end

@implementation QTouchToFingerViewItem

- (instancetype)initWithKey:(NSString *)key
                      touch:(UITouch *)touch
                       view:(QTouchposeFingerView *)view {
    self = [super init];
    if (self) {
        self.key = key;
        self.touch = touch;
        self.view = view;
    }
    return self;
}

@end


static inline NSString *QKeyForTouch(UITouch *touch) {
    return [NSString stringWithFormat:@"%p", touch];
}


IMP SwizzleMethod(Class c, SEL sel, IMP newImplementation) {
    Method method = class_getInstanceMethod(c, sel);
    IMP originalImplementation = method_getImplementation(method);
    if (!class_addMethod(c, sel, newImplementation, method_getTypeEncoding(method)))
        method_setImplementation(method, newImplementation);
    return originalImplementation;
}

static void (*UIWindow_orig_becomeKeyWindow)(UIWindow *, SEL);

// This method replaces -[UIWindow becomeKeyWindow] (but calls the original -becomeKeyWindow). This
// is used to move the overlay to the current key window.
static void UIWindow_new_becomeKeyWindow(UIWindow *window, SEL _cmd) {
    QTouchposeApplication *application = (QTouchposeApplication *)[UIApplication sharedApplication];
    [application keyWindowChanged:window];
    (*UIWindow_orig_becomeKeyWindow)(window, _cmd);
}

static void (*UIWindow_orig_didAddSubview)(UIWindow *, SEL, UIView *);

// This method replaces -[UIWindow didAddSubview:] (but calls the original -didAddSubview:). This is
// used to keep the overlay view the top-most view of the window.
static void UIWindow_new_didAddSubview(UIWindow *window, SEL _cmd, UIView *view) {
    if (![view isKindOfClass:[QTouchposeFingerView class]]) {
        QTouchposeApplication *application = (QTouchposeApplication *)[UIApplication sharedApplication];
        [application bringTouchViewToFront];
    }
    (*UIWindow_orig_didAddSubview)(window, _cmd, view);
}


@implementation QTouchposeApplication {
    NSMutableDictionary<NSString *, QTouchToFingerViewItem *> *_touchDictionary;
    UIView *_touchView;
}

#pragma mark - NSObject

+ (NSUInteger)majorSystemVersion {
    NSArray *versionComponents = [[[UIDevice currentDevice] systemVersion] componentsSeparatedByString:@"."];
    return [[versionComponents objectAtIndex:0] integerValue];
}

- (id)init {
    if ((self = [super init])) {
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(applicationDidFinishLaunching:)
                                                     name:UIApplicationDidFinishLaunchingNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(screenDidConnectNotification:)
                                                     name:UIScreenDidConnectNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(screenDidDisonnectNotification:)
                                                     name:UIScreenDidDisconnectNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(keyboardDidShowNotification:)
                                                     name:UIKeyboardDidShowNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(keyboardDidHideNotification:)
                                                     name:UIKeyboardDidHideNotification
                                                   object:nil];
        
        _touchDictionary = [NSMutableDictionary dictionary];
        _alwaysShowTouches = NO;
        _touchColor = [UIColor colorWithRed:0.251f green:0.424f blue:0.502f alpha:1.0f];
        _touchEndAnimationDuration = 0.5f;
        _touchEndTransform = CATransform3DMakeScale(1.5, 1.5, 1);
        
        _customTouchImage = nil;
        _customTouchPoint = CGPointZero;
        
        // In my experience, the keyboard performance is crippled when showing touches on a
        // device running iOS < 5, so by default, disable touches when the keyboard is
        // present.
        _showTouchesWhenKeyboardShown = [[self class] majorSystemVersion] >= 5;
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}


#pragma mark - UIApplication

- (void)sendEvent:(UIEvent *)event {
    if (_showTouches) {
        [self updateTouches:[event allTouches]];
    }
    [super sendEvent:event];
}

#pragma mark - QApplication

- (void)removeTouchesActiveTouches:(NSSet *)activeTouches {
    NSArray<QTouchToFingerViewItem *> *allValues = [_touchDictionary.allValues copy];
    [allValues enumerateObjectsUsingBlock:^(QTouchToFingerViewItem *_Nonnull obj,
                                            NSUInteger idx,
                                            BOOL *_Nonnull stop) {
        if (activeTouches == nil || ![activeTouches containsObject:obj.touch]) {
            [obj.view removeFromSuperview];
            [_touchDictionary removeObjectForKey:obj.key];
        }
    }];
}

- (void)updateTouches:(NSSet *)touches {
    for (UITouch *touch in touches) {
        CGPoint point = [touch locationInView:_touchView];
        NSString *key = QKeyForTouch(touch);
        QTouchposeFingerView *fingerView = _touchDictionary[key].view;
        
        if (touch.phase == UITouchPhaseCancelled || touch.phase == UITouchPhaseEnded) {
            // Note that there seems to be a bug in iOS: we won't observe all UITouches
            // in the UITouchPhaseEnded phase, resulting in some finger views being left
            // on the screen when they shouldn't be. See
            // https://discussions.apple.com/thread/1507669?start=0&tstart=0 for other's
            // comments about this issue. No workaround is implemented here.
            
            
            if (fingerView != NULL) {
                // Remove the touch from the
                [_touchDictionary removeObjectForKey:key];
                CATransform3D transform = _touchEndTransform;
                [UIView animateWithDuration:_touchEndAnimationDuration animations:^{
                    fingerView.alpha = 0.0f;
                    fingerView.layer.transform = transform;
                } completion:^(BOOL completed) {
                    [fingerView removeFromSuperview];
                }];
            }
        } else {
            if (fingerView == NULL) {
                fingerView = [[QTouchposeFingerView alloc] initWithPoint:point
                                                                   color:_touchColor
                                               touchEndAnimationDuration:_touchEndAnimationDuration
                                                       touchEndTransform:_touchEndTransform
                                                        customTouchImage:self.customTouchImage
                                                        customTouchPoint:self.customTouchPoint];
                [_touchView addSubview:fingerView];
                QTouchToFingerViewItem *item = [[QTouchToFingerViewItem alloc] initWithKey:key
                                                                                     touch:touch
                                                                                      view:fingerView];
                _touchDictionary[key] = item;
            } else {
                if (self.customTouchImage) {
                    CGPoint newCenter = point;
                    newCenter.x += (self.customTouchImage.size.width / 2) - self.customTouchPoint.x;
                    newCenter.y += (self.customTouchImage.size.height / 2) - self.customTouchPoint.y;
                    
                    fingerView.center = newCenter;
                } else {
                    fingerView.center = point;
                }
            }
        }
    }
    
    [self removeTouchesActiveTouches:touches];
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    // We intercept calls to -becomeKeyWindow and -didAddSubview of UIWindow to manage the
    // overlay view QTouchposeTouchesView and ensure it remains the top-most window.
    UIWindow_orig_didAddSubview = (void (*)(UIWindow *, SEL, UIView *))SwizzleMethod([UIWindow class], @selector(didAddSubview:), (IMP)UIWindow_new_didAddSubview);
    UIWindow_orig_becomeKeyWindow = (void (*)(UIWindow *, SEL))SwizzleMethod([UIWindow class], @selector(becomeKeyWindow), (IMP)UIWindow_new_becomeKeyWindow);
    
    self.showTouches = _alwaysShowTouches || [self hasMirroredScreen];
}

- (void)screenDidConnectNotification:(NSNotification *)notification {
    self.showTouches = _alwaysShowTouches || [self hasMirroredScreen];
}

- (void)screenDidDisonnectNotification:(NSNotification *)notification {
    self.showTouches = _alwaysShowTouches || [self hasMirroredScreen];
}

- (void)keyboardDidShowNotification:(NSNotification *)notification {
    self.showTouches = _showTouchesWhenKeyboardShown && (_alwaysShowTouches || [self hasMirroredScreen]);
}

- (void)keyboardDidHideNotification:(NSNotification *)notification {
    self.showTouches = _alwaysShowTouches || [self hasMirroredScreen];
}

- (void)keyWindowChanged:(UIWindow *)window {
    if (_touchView) {
        [window addSubview:_touchView];
    }
}

- (void)bringTouchViewToFront {
    if (_touchView) {
        [_touchView.window bringSubviewToFront:_touchView];
    }
}

- (BOOL)hasMirroredScreen {
    BOOL hasMirroredScreen = NO;
    NSArray *screens = [UIScreen screens];
    
    if ([screens count] > 1) {
        for (UIScreen *screen in screens) {
            if (screen.mirroredScreen != nil) {
                hasMirroredScreen = YES;
                break;
            }
        }
    }
    return hasMirroredScreen;
}

- (void)setShowTouches:(BOOL)showTouches {
    if (showTouches) {
        if (_touchView == nil && self.keyWindow) {
            UIWindow *window = self.keyWindow;
            _touchView = [[QTouchposeTouchesView alloc] initWithFrame:window.bounds];
            _touchView.backgroundColor = [UIColor clearColor];
            _touchView.opaque = NO;
            _touchView.userInteractionEnabled = NO;
            [window addSubview:_touchView];
        }
    } else {
        [self removeTouchesActiveTouches:nil];
        if (_touchView) {
            [_touchView removeFromSuperview];
            _touchView = nil;
        }
    }
    _showTouches = showTouches;
}

@end
