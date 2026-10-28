#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#include <assert.h>
#include <dlfcn.h>

void SGArtistUpdateDownloads(UIView *header);
static NSUInteger fixtureViewVisits;
static NSUInteger fixtureViewVisitCount(void) { return fixtureViewVisits; }

void SGForEachView(UIView *view, void (^fn)(UIView *)) {
    if (!view || !fn) return;
    fixtureViewVisits++;
    fn(view);
    for (UIView *child in view.subviews) SGForEachView(child, fn);
}

// The real Encore factory is supplied by Spotify on device. This fixture only
// validates that the native download glyph is requested, plus layout and actions.
UIView *SGTabIconView(NSString *name, BOOL symbol, UIColor *color) {
    assert([name isEqualToString:@"download"] && !symbol);
    UIImageView *view = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"arrow.down.circle"]];
    view.tintColor = color;view.contentMode = UIViewContentModeScaleAspectFit;
    return view;
}

static BOOL fixtureNativeUI = YES;
BOOL SGNativeUI(void) { return fixtureNativeUI; }

static NSString *shownURI;
static NSString *shownName;
static UIViewController *shownPresenter;
__attribute__((visibility("default")))
void SAPShowArtistDownloads(NSString *uri, NSString *name, UIViewController *presenter) {
    shownURI = [uri copy];
    shownName = [name copy];
    shownPresenter = presenter;
}

@interface FixturePageController : UIViewController
@property(nonatomic, copy) NSString *fixturePageURI;
@property(nonatomic) NSUInteger fixturePageURIReadCount;
@end
@implementation FixturePageController
- (NSURL *)spt_pageURI {
    self.fixturePageURIReadCount++;
    return self.fixturePageURI ? [NSURL URLWithString:self.fixturePageURI] : nil;
}
@end

static void check(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        abort();
    }
}

static UIView *findView(UIView *root, NSString *identifier) {
    if ([root.accessibilityIdentifier isEqualToString:identifier]) return root;
    for (UIView *child in root.subviews) {
        UIView *found = findView(child, identifier);
        if (found) return found;
    }
    return nil;
}

static NSUInteger countDownloads(UIView *root) {
    NSUInteger count = [root.accessibilityIdentifier isEqualToString:@"PixieNativeArtistDownload"] ? 1 : 0;
    for (UIView *child in root.subviews) count += countDownloads(child);
    return count;
}

static NSString *artistButtonID(NSString *artistID) {
    return [@"Components.UI.ContextMenuButton-" stringByAppendingString:artistID];
}

static void tapDownload(UIButton *button) {
    check(button != nil, @"download button exists before tap");
    [button sendActionsForControlEvents:UIControlEventTouchUpInside];
}

static void finish(NSString *message, UIView *screenView) {
    NSURL *documents = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    [message writeToURL:[documents URLByAppendingPathComponent:@"native-artist-downloads-result.log"]
                atomically:YES encoding:NSUTF8StringEncoding error:nil];
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithBounds:screenView.bounds];
    UIImage *image = [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [screenView drawViewHierarchyInRect:screenView.bounds afterScreenUpdates:YES];
    }];
    [UIImagePNGRepresentation(image) writeToURL:[documents URLByAppendingPathComponent:@"native-artist-downloads.png"]
                                       atomically:YES];
}

@interface NativeArtistDownloadsFixtureScene : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation NativeArtistDownloadsFixtureScene
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    FixturePageController *page = [FixturePageController new];
    page.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    page.view.backgroundColor = UIColor.systemBackgroundColor;
    page.view.accessibilityIdentifier = @"creator-page";
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:page];
    nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];

    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *header = [[UIView alloc] initWithFrame:CGRectMake(16, 140, 330, 72)];
        header.backgroundColor = UIColor.secondarySystemBackgroundColor;
        header.accessibilityIdentifier = @"fixture-artist-header";
        [page.view addSubview:header];

        UIStackView *controls = [[UIStackView alloc] initWithFrame:CGRectMake(30, 12, 264, 48)];
        controls.axis = UILayoutConstraintAxisHorizontal;
        controls.alignment = UIStackViewAlignmentCenter;
        controls.spacing = 48;
        [header addSubview:controls];

        UIButton *more = [UIButton buttonWithType:UIButtonTypeSystem];
        more.accessibilityIdentifier = artistButtonID(@"0000000000000000000001");
        more.frame = CGRectMake(0, 2, 44, 44);
        [more setTitle:@"•••" forState:UIControlStateNormal];
        UIButton *shuffle = [UIButton buttonWithType:UIButtonTypeSystem];
        shuffle.accessibilityIdentifier = @"Components.UI.ShuffleButton";
        shuffle.frame = CGRectMake(120, 2, 44, 44);
        [shuffle setTitle:@"↻" forState:UIControlStateNormal];
        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 100, 36)];
        title.accessibilityIdentifier = @"Encore.AdaptiveTitle";
        title.text = @"Fixture artist";
        [controls addArrangedSubview:title];
        [controls addArrangedSubview:more];
        [controls addArrangedSubview:shuffle];

        [page.view layoutIfNeeded];
        [header layoutIfNeeded];

        CGRect originalHeaderFrame = header.frame;
        CGRect originalControlsFrame = controls.frame;
        CGRect originalMoreFrame = more.frame;
        CGRect originalShuffleFrame = shuffle.frame;
        NSArray *originalArranged = [controls.arrangedSubviews copy];

        fixtureNativeUI = NO;
        page.fixturePageURI = @"spotify:artist:0000000000000000000001";
        SGArtistUpdateDownloads(header);
        check(countDownloads(header) == 0, @"SGNativeUI false creates no button");
        fixtureNativeUI = YES;

        SGArtistUpdateDownloads(header);
        check(countDownloads(header) == 1, @"one native download button added");
        UIButton *download = (UIButton *)findView(header, @"PixieNativeArtistDownload");
        check(download != nil && download.superview == controls, @"button joins the existing action row as a non-arranged child");
        [controls layoutIfNeeded];
        [download layoutIfNeeded];
        CGRect buttonFrame = [controls convertRect:download.bounds fromView:download];
        CGRect moreFrame = [controls convertRect:more.bounds fromView:more];
        CGRect shuffleFrame = [controls convertRect:shuffle.bounds fromView:shuffle];
        check(fabs(buttonFrame.size.width - 44) < 0.5 && fabs(buttonFrame.size.height - 44) < 0.5,
              @"native button measures 44 by 44");
        check(fabs(CGRectGetMinX(buttonFrame) - CGRectGetMaxX(moreFrame)) < 0.5,
              @"button begins at the trailing edge of more");
        check(fabs(CGRectGetMidY(buttonFrame) - CGRectGetMidY(moreFrame)) < 0.5,
              @"button is vertically centered on more");
        check(!CGRectIntersectsRect(buttonFrame, shuffleFrame), @"button does not overlap shuffle");

        NSUInteger steadyVisits = fixtureViewVisitCount();
        NSUInteger steadyURIReads = page.fixturePageURIReadCount;
        for (NSUInteger i = 0; i < 4; i++) SGArtistUpdateDownloads(header);
        check(fixtureViewVisitCount() == steadyVisits,
              @"steady valid layouts reuse cached menu, shuffle, title, and row anchors without subtree scans");
        check(page.fixturePageURIReadCount == steadyURIReads + 4,
              @"steady layouts still read the current page URI instead of caching artist identity");

        UIImageView *glyph = (UIImageView *)download.subviews.firstObject;
        check(glyph && glyph.image && glyph.tintColor, @"native glyph is installed once with a tint color");
        UIImage *glyphImage = glyph.image;
        UIColor *glyphTint = glyph.tintColor;
        more.alpha = 0;
        SGArtistUpdateDownloads(header);
        check(!download.hidden && download.enabled && fabs(download.alpha - 1) < 0.001,
              @"fading more does not hide or fade its neighboring download button");
        more.alpha = 1;
        controls.alpha = 0.5;
        SGArtistUpdateDownloads(header);
        check(!download.hidden && download.enabled && fabs(download.alpha - 1) < 0.001,
              @"row alpha does not mutate the button's own visible state");
        controls.alpha = 1;
        controls.hidden = YES;
        SGArtistUpdateDownloads(header);
        check(!download.hidden && download.enabled, @"hidden action row carries its button without toggling button state");
        controls.hidden = NO;
        CGRect originalBounds = header.bounds;
        CGAffineTransform originalTransform = controls.transform;
        header.bounds = CGRectMake(originalBounds.origin.x, originalBounds.origin.y,
                                   originalBounds.size.width, 28);
        controls.transform = CGAffineTransformMakeTranslation(0, -18);
        SGArtistUpdateDownloads(header);
        check(!download.hidden && download.enabled && glyph == download.subviews.firstObject &&
              glyph.image == glyphImage && [glyph.tintColor isEqual:glyphTint],
              @"scroll-like header changes preserve button state and the same glyph image and tint");
        controls.transform = originalTransform;
        header.bounds = originalBounds;
        SGArtistUpdateDownloads(header);

        for (NSUInteger i = 0; i < 4; i++) SGArtistUpdateDownloads(header);
        check(countDownloads(header) == 1, @"repeated updates keep exactly one button");
        check(CGRectEqualToRect(header.frame, originalHeaderFrame) &&
              CGRectEqualToRect(controls.frame, originalControlsFrame) &&
              CGRectEqualToRect(more.frame, originalMoreFrame) &&
              CGRectEqualToRect(shuffle.frame, originalShuffleFrame),
              @"original header and control frames remain unchanged");
        check([controls.arrangedSubviews isEqualToArray:originalArranged],
              @"original arranged subviews remain unchanged");

        void (*showDownloads)(NSString *, NSString *, UIViewController *) =
            (void (*)(NSString *, NSString *, UIViewController *))dlsym(RTLD_DEFAULT, "SAPShowArtistDownloads");
        check(showDownloads != NULL, @"picker entry point is exported for dlsym");
        tapDownload(download);
        check([shownURI isEqualToString:@"spotify:artist:0000000000000000000001"] &&
              [shownName isEqualToString:@"Fixture artist"] && shownPresenter == page,
              @"tap invokes the picker with verified URI, title, and presenter");

        NSString *lastShownURI = shownURI;
        page.fixturePageURI = @"spotify:artist:0000000000000000000002";
        tapDownload(download);
        check((download.hidden || !download.enabled) && [shownURI isEqualToString:lastShownURI],
              @"tap re-reads a changed page URI and refuses a stale header identity");
        SGArtistUpdateDownloads(header);
        check(download.hidden || !download.enabled, @"page URI conflicting with header identity fails closed");
        page.fixturePageURI = @"spotify:artist:0000000000000000001";
        more.accessibilityIdentifier = artistButtonID(@"0000000000000000000003");
        page.fixturePageURI = @"spotify:artist:0000000000000000000003";
        SGArtistUpdateDownloads(header);
        check(!download.hidden && download.enabled, @"reused header updates to a matching new page identity");
        tapDownload(download);
        check([shownURI isEqualToString:@"spotify:artist:0000000000000000000003"],
              @"reused header action follows the new matching URI");

        page.fixturePageURI = nil;
        more.accessibilityIdentifier = artistButtonID(@"bad-id");
        SGArtistUpdateDownloads(header);
        check(download.hidden || !download.enabled, @"malformed artist identity fails closed");
        more.accessibilityIdentifier = @"Components.UI.ContextMenuButton-";
        SGArtistUpdateDownloads(header);
        check(download.hidden || !download.enabled, @"missing artist ID fails closed");

        page.view.accessibilityIdentifier = @"album-page";
        more.accessibilityIdentifier = artistButtonID(@"0000000000000000000001");
        page.fixturePageURI = @"spotify:artist:0000000000000000001";
        SGArtistUpdateDownloads(header);
        check(download.hidden || !download.enabled, @"unrelated page is closed");
        page.view.accessibilityIdentifier = @"creator-page";
        check(countDownloads(header) == 1, @"invalid states reuse the single native button");

        UIView *lateHeader = [[UIView alloc] initWithFrame:CGRectMake(16, 240, 330, 72)];
        lateHeader.accessibilityIdentifier = @"fixture-late-header";
        [page.view addSubview:lateHeader];
        page.fixturePageURI = @"spotify:artist:0000000000000000000004";
        SGArtistUpdateDownloads(lateHeader);
        check(countDownloads(lateHeader) == 0, @"missing controls do not create a button");
        UIButton *lateMore = [UIButton buttonWithType:UIButtonTypeSystem];
        lateMore.accessibilityIdentifier = artistButtonID(@"0000000000000000000004");
        lateMore.frame = CGRectMake(34, 12, 44, 44);
        UIButton *lateShuffle = [UIButton buttonWithType:UIButtonTypeSystem];
        lateShuffle.accessibilityIdentifier = @"Components.UI.ShuffleButton";
        lateShuffle.frame = CGRectMake(122, 12, 44, 44);
        UIView *lateRow = [[UIView alloc] initWithFrame:lateHeader.bounds];
        [lateHeader addSubview:lateRow];
        [lateRow addSubview:lateMore];
        [lateRow addSubview:lateShuffle];
        UILabel *lateTitle = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 100, 24)];
        lateTitle.accessibilityIdentifier = @"Encore.AdaptiveTitle";
        lateTitle.text = @"Late artist";
        [lateRow addSubview:lateTitle];
        SGArtistUpdateDownloads(lateHeader);
        check(countDownloads(lateHeader) == 1, @"late controls attach the button on a later lifecycle call");
        UIButton *lateDownload = (UIButton *)findView(lateHeader, @"PixieNativeArtistDownload");
        check(lateDownload.superview == lateRow && lateDownload.enabled && !lateDownload.hidden,
              @"late controls use their shared action row as their button host");

        lateMore.alpha = 0;
        SGArtistUpdateDownloads(lateHeader);
        check(!lateDownload.hidden && lateDownload.enabled && fabs(lateDownload.alpha - 1) < 0.001,
              @"fading a more control does not alter the sibling download button");
        lateMore.alpha = 1;
        lateShuffle.frame = CGRectMake(110, 12, 44, 44);
        SGArtistUpdateDownloads(lateHeader);
        check(lateDownload.hidden && lateDownload.enabled, @"narrow gap hides the button while preserving valid identity state");
        lateShuffle.frame = CGRectMake(122, 12, 44, 44);
        SGArtistUpdateDownloads(lateHeader);
        check(!lateDownload.hidden && lateDownload.enabled, @"valid row restores its existing button");

        NSUInteger lateSteadyVisits = fixtureViewVisitCount();
        for (NSUInteger i = 0; i < 4; i++) SGArtistUpdateDownloads(lateHeader);
        check(fixtureViewVisitCount() == lateSteadyVisits,
              @"steady late-control layouts reuse cached anchors without rescanning the header");

        UIView *replacementRow = [[UIView alloc] initWithFrame:lateHeader.bounds];
        [lateHeader addSubview:replacementRow];
        UIButton *replacementMore = [UIButton buttonWithType:UIButtonTypeSystem];
        replacementMore.accessibilityIdentifier = artistButtonID(@"0000000000000000000004");
        replacementMore.frame = CGRectMake(34, 12, 44, 44);
        UIButton *replacementShuffle = [UIButton buttonWithType:UIButtonTypeSystem];
        replacementShuffle.accessibilityIdentifier = @"Components.UI.ShuffleButton";
        replacementShuffle.frame = CGRectMake(122, 12, 44, 44);
        UILabel *replacementTitle = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, 100, 24)];
        replacementTitle.accessibilityIdentifier = @"Encore.AdaptiveTitle";
        replacementTitle.text = @"Late artist";
        [replacementRow addSubview:replacementMore];
        [replacementRow addSubview:replacementShuffle];
        [replacementRow addSubview:replacementTitle];
        [lateRow removeFromSuperview];
        SGArtistUpdateDownloads(lateHeader);
        check(findView(lateHeader, @"PixieNativeArtistDownload") == lateDownload && lateDownload.superview == replacementRow &&
              countDownloads(lateHeader) == 1,
              @"replacing the action row reuses the same button and reanchors it in the new row");
        NSUInteger replacementSteadyVisits = fixtureViewVisitCount();
        for (NSUInteger i = 0; i < 4; i++) SGArtistUpdateDownloads(lateHeader);
        check(fixtureViewVisitCount() == replacementSteadyVisits,
              @"the replacement row is cached after its first valid layout");

        UIView *otherHeader = [[UIView alloc] initWithFrame:CGRectMake(16, 330, 330, 72)];
        [page.view addSubview:otherHeader];
        UIButton *otherMore = [UIButton buttonWithType:UIButtonTypeSystem];
        otherMore.accessibilityIdentifier = artistButtonID(@"0000000000000000000005");
        otherMore.frame = CGRectMake(34, 12, 44, 44);
        [otherHeader addSubview:otherMore];
        page.fixturePageURI = @"spotify:artist:0000000000000000000005";
        SGArtistUpdateDownloads(otherHeader);
        check(countDownloads(otherHeader) == 0, @"shuffle control is required to attach the button");

        page.fixturePageURI = @"spotify:artist:0000000000000000000003";
        more.accessibilityIdentifier = artistButtonID(@"0000000000000000000003");
        SGArtistUpdateDownloads(header);
        [lateHeader removeFromSuperview];
        [otherHeader removeFromSuperview];
        [page.view layoutIfNeeded];
        finish(@"PASS: native artist button gating, exact and fresh identity, cached layout anchors, late controls, row replacement, uniqueness, placement, scroll stability, unchanged Spotify frames and arrangement, and picker dispatch", page.view);
    });
}
@end

@interface NativeArtistDownloadsFixtureDelegate : UIResponder <UIApplicationDelegate>
@end
@implementation NativeArtistDownloadsFixtureDelegate
@end

int main(int argc, char **argv) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(NativeArtistDownloadsFixtureDelegate.class));
    }
}
