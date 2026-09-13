//  DNPaging.m
//
//  Page-snapping for FastList, which DartNative does not provide.
//
//  FastList is a real UITableView, and UITableView is a UIScrollView, so UIKit
//  already knows how to page: `pagingEnabled` snaps by the scroll view's own
//  bounds height. Every row in this feed is exactly one viewport tall, so a
//  page and a row are the same thing and the flag is all that is needed.
//
//  This has to live in native code because the Dart surface cannot reach it.
//  `FastListController` is index-only (jumpToItem / scrollToItem /
//  animateToItem) with no way to set a fractional contentOffset, and for a
//  full-height row every `alignment` value resolves to the same offset — so a
//  finger-following pager cannot be built in Dart on top of FastList at all.
//
//  Exposed as a plain C symbol and looked up with DynamicLibrary.process().
//  The dartnative_video_player podspec already forces DEAD_CODE_STRIPPING=NO
//  and ENABLE_DEBUG_DYLIB=NO on the Runner target, which is what keeps an
//  otherwise-unreferenced symbol like this one present in Release builds.

#import <UIKit/UIKit.h>

/// The key window, across the scene-based and legacy paths.
static UIWindow *DNKeyWindow(void) {
  for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
    if (![scene isKindOfClass:UIWindowScene.class]) continue;
    if (scene.activationState != UISceneActivationStateForegroundActive) continue;
    for (UIWindow *w in ((UIWindowScene *)scene).windows) {
      if (w.isKeyWindow) return w;
    }
  }
  return UIApplication.sharedApplication.windows.firstObject;
}

/// Depth-first search for the feed's scroll view.
///
/// "The feed" is identified structurally rather than by class name: a vertical
/// scroll view at least as tall as most of the window, whose content is longer
/// than one screen. That avoids grabbing an incidental scroll view (an inner
/// text view, a horizontal rail) while staying agnostic about whether FastList
/// happens to be backed by UITableView or UICollectionView on a given axis.
static UIScrollView *DNFindFeedScrollView(UIView *view, CGFloat windowHeight) {
  if ([view isKindOfClass:UIScrollView.class]) {
    UIScrollView *sv = (UIScrollView *)view;
    BOOL tallEnough = sv.bounds.size.height >= windowHeight * 0.8;
    BOOL scrollsVertically = sv.contentSize.height > sv.bounds.size.height;
    if (tallEnough && scrollsVertically) return sv;
  }
  for (UIView *child in view.subviews) {
    UIScrollView *found = DNFindFeedScrollView(child, windowHeight);
    if (found) return found;
  }
  return nil;
}

/// Turn UIKit paging on (or off) for the feed's scroll view.
///
/// Returns 1 when paging was newly applied, 2 when it was already in the
/// requested state, or a negative code identifying which step failed:
/// -1 off the main thread, -2 no key window, -3 no matching scroll view yet.
/// Dart polls on this because the native list is not mounted on the first frame
/// and there is no "list attached" callback to hang the call off.
__attribute__((visibility("default"))) __attribute__((used))
int dn_paging_set_enabled(int enabled) {
  if (!NSThread.isMainThread) return -1;

  UIWindow *window = DNKeyWindow();
  if (window == nil) return -2;

  UIScrollView *feed = DNFindFeedScrollView(window, window.bounds.size.height);
  if (feed == nil) return -3;

  BOOL want = (enabled != 0);
  BOOL alreadyCorrect = (feed.isPagingEnabled == want) &&
                        (feed.contentInset.top == 0);
  feed.pagingEnabled = want;
  if (enabled) {
    // A paging scroll view should not also be sliding on momentum between
    // pages, and the feed is full-bleed so the inset adjustment UIKit applies
    // for safe areas would push every page off by the status-bar height.
    feed.showsVerticalScrollIndicator = NO;
    // pagingEnabled steps by exactly `bounds.height`, so a page boundary only
    // lines up with a row boundary when the content grid starts at offset 0.
    // Any safe-area inset shifts the rows down and leaves every page that far
    // short — a sliver of the previous video stays on screen. This feed is
    // full-bleed (rows are already the full window height), so both the
    // automatic adjustment and any explicit inset are cleared.
    feed.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    feed.contentInset = UIEdgeInsetsZero;
    feed.scrollIndicatorInsets = UIEdgeInsetsZero;
  }
  return alreadyCorrect ? 2 : 1;
}

/// Diagnostic: log every UIScrollView in the window with its geometry, so the
/// matching heuristic above can be checked against what FastList actually
/// builds instead of guessed at.
static void DNDumpScrollViews(UIView *view, int depth) {
  if ([view isKindOfClass:UIScrollView.class]) {
    UIScrollView *sv = (UIScrollView *)view;
    NSLog(@"##DNVIEW## depth=%d class=%@ bounds=%.0fx%.0f content=%.0fx%.0f paging=%d "
           "inset=(%.0f,%.0f) adjusted=(%.0f,%.0f) offset=%.1f behavior=%ld",
          depth, NSStringFromClass(view.class),
          sv.bounds.size.width, sv.bounds.size.height,
          sv.contentSize.width, sv.contentSize.height,
          (int)sv.isPagingEnabled,
          sv.contentInset.top, sv.contentInset.bottom,
          sv.adjustedContentInset.top, sv.adjustedContentInset.bottom,
          sv.contentOffset.y, (long)sv.contentInsetAdjustmentBehavior);
    // pagingEnabled is only advisory: a delegate that writes targetContentOffset
    // in scrollViewWillEndDragging wins, and so does a custom deceleration rate.
    id delegate = sv.delegate;
    NSLog(@"##DNVIEW## delegate=%@ overridesTarget=%d decelRate=%.3f "
           "panEnabled=%d scrollEnabled=%d",
          NSStringFromClass([delegate class]),
          (int)[delegate respondsToSelector:
                @selector(scrollViewWillEndDragging:withVelocity:targetContentOffset:)],
          sv.decelerationRate,
          (int)sv.panGestureRecognizer.isEnabled,
          (int)sv.isScrollEnabled);
  }
  for (UIView *child in view.subviews) {
    DNDumpScrollViews(child, depth + 1);
  }
}

__attribute__((visibility("default"))) __attribute__((used))
int dn_paging_dump(void) {
  if (!NSThread.isMainThread) return -1;
  UIWindow *window = DNKeyWindow();
  if (window == nil) return -2;
  NSLog(@"##DNVIEW## --- window %.0fx%.0f rootVC=%@ ---",
        window.bounds.size.width, window.bounds.size.height,
        NSStringFromClass(window.rootViewController.class));
  DNDumpScrollViews(window, 0);
  NSLog(@"##DNVIEW## --- end ---");
  return 1;
}
