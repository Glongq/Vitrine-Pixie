#import "ArtistDownloadsUI.h"
#import "ArtistMetadata.h"
#import "ArtistDownloadSession.h"
#import "PlaylistDownloads.h"
#import "PlaylistArtwork.h"
#import "TrackJournal.h"
#import "Diagnostics.h"
#import "TrackDownload.h"
#import "WireProto.h"
#import <UIKit/UIKit.h>
#import <CoreText/CoreText.h>
#import <ImageIO/ImageIO.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

static const NSUInteger SAPArtistArtworkMaximumBytes=1024*1024;
static const NSUInteger SAPArtistArtworkMaximumEntries=64;
static const NSUInteger SAPArtistArtworkMaximumPixels=128;
static const NSUInteger SAPArtistArtworkMaximumRequests=16;
static char SAPArtistArtworkURLKey;
#ifdef SAP_TESTING
static void (^SAPArtistArtworkDataProviderForTesting)(NSString *,void (^)(NSData *));
void SAPArtistArtworkSetDataProviderForTesting(void (^provider)(NSString *,void (^)(NSData *))) {SAPArtistArtworkDataProviderForTesting=[provider copy];}
#endif

static NSString *SAPArtistArtworkIdentifier(NSString *value) {
    if(![value isKindOfClass:NSString.class])return nil;
    NSURLComponents *parts=[NSURLComponents componentsWithString:value];
    NSString *path=parts.path;
    BOOL mosaic=[parts.host.lowercaseString isEqual:@"mosaic.scdn.co"];
    NSString *prefix=mosaic?@"/300/":@"/image/";
    if(![parts.scheme.lowercaseString isEqual:@"https"] || (!mosaic && ![parts.host.lowercaseString isEqual:@"i.scdn.co"]) || parts.query.length || parts.fragment.length || ![path hasPrefix:prefix])return nil;
    NSString *identifier=[path substringFromIndex:prefix.length];
    if(mosaic?(identifier.length<40 || identifier.length>160 || identifier.length%40):identifier.length!=40)return nil;
    NSCharacterSet *invalid=[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF"].invertedSet;
    if([identifier rangeOfCharacterFromSet:invalid].location!=NSNotFound)return nil;
    return mosaic?[@"mosaic:" stringByAppendingString:identifier.lowercaseString]:identifier.lowercaseString;
}

@interface SAPArtistArtworkConsumer : NSObject
@property(atomic) BOOL cancelled;
@property(nonatomic,copy) void (^completion)(UIImage *);
@end
@implementation SAPArtistArtworkConsumer @end

@interface SAPArtistArtworkRequest : NSObject
@property(nonatomic,copy) NSString *identifier;
@property(nonatomic,strong) NSMutableData *data;
@property(nonatomic,strong) NSMutableDictionary<NSString *,SAPArtistArtworkConsumer *> *completions;
@property(nonatomic,strong) NSURLSessionDataTask *task;
@property(nonatomic) BOOL allowed;
@property(nonatomic,copy) dispatch_block_t cancelNative;
@end
@implementation SAPArtistArtworkRequest @end

@interface SAPArtistArtworkLoader : NSObject <NSURLSessionDataDelegate>
@property(nonatomic) dispatch_queue_t queue;
@property(nonatomic,strong) NSOperationQueue *delegateQueue;
@property(nonatomic,strong) NSURLSession *session;
@property(nonatomic,strong) NSCache<NSString *,UIImage *> *cache;
@property(nonatomic,strong) NSMutableDictionary<NSNumber *,SAPArtistArtworkRequest *> *requests;
@property(nonatomic,strong) NSMutableDictionary<NSString *,SAPArtistArtworkRequest *> *inFlight;
+ (instancetype)shared;
- (dispatch_block_t)loadURL:(NSString *)value completion:(void (^)(UIImage *))completion;
- (UIImage *)thumbnailForData:(NSData *)data;
- (dispatch_block_t)loadPlaylistURI:(NSString *)uri completion:(void (^)(UIImage *))completion;
@end
@implementation SAPArtistArtworkLoader
+ (instancetype)shared {static SAPArtistArtworkLoader *loader;static dispatch_once_t once;dispatch_once(&once,^{loader=[self new];});return loader;}
- (instancetype)init {
    if((self=[super init])) {
        _queue=dispatch_queue_create("com.pixie.artist-artwork",DISPATCH_QUEUE_SERIAL);
        _delegateQueue=[NSOperationQueue new];_delegateQueue.maxConcurrentOperationCount=1;_delegateQueue.underlyingQueue=_queue;
        NSURLSessionConfiguration *configuration=[NSURLSessionConfiguration ephemeralSessionConfiguration];
        configuration.URLCache=nil;configuration.requestCachePolicy=NSURLRequestReloadIgnoringLocalCacheData;
        configuration.timeoutIntervalForRequest=8;configuration.timeoutIntervalForResource=12;
        configuration.HTTPMaximumConnectionsPerHost=4;configuration.HTTPShouldSetCookies=NO;
        _session=[NSURLSession sessionWithConfiguration:configuration delegate:self delegateQueue:_delegateQueue];
        _cache=[NSCache new];_cache.countLimit=SAPArtistArtworkMaximumEntries;_cache.totalCostLimit=4*1024*1024;
        _requests=[NSMutableDictionary dictionary];_inFlight=[NSMutableDictionary dictionary];
    }
    return self;
}
- (void)complete:(NSArray<SAPArtistArtworkConsumer *> *)consumers image:(UIImage *)image {
    for(SAPArtistArtworkConsumer *consumer in consumers)dispatch_async(dispatch_get_main_queue(),^{
        if(!consumer.cancelled && consumer.completion)consumer.completion(image);
    });
}
- (dispatch_block_t)loadPlaylistURI:(NSString *)uri completion:(void (^)(UIImage *))completion {
    if([uri hasPrefix:@"spotify:mosaic:"]){
        NSString *url=SAPPlaylistArtworkURL(uri);
        return [self loadURL:url completion:^(UIImage *image){SAPJournalNoteAction(@"playlist_artwork_result",@{@"uri":uri,@"route":@"spotify_mosaic_cdn",@"url":url,@"image_received":@(image!=nil),@"error":image?@"":@"Mosaic image unavailable"});if(completion)completion(image);}];
    }
    SAPArtistArtworkConsumer *consumer=[SAPArtistArtworkConsumer new];consumer.completion=completion;
    if(![uri isKindOfClass:NSString.class] || !uri.length || uri.length>4096 || (![uri hasPrefix:@"spotify:"] && ![uri hasPrefix:@"https://"])) {[self complete:@[consumer] image:nil];return ^{consumer.cancelled=YES;};}
    NSString *identifier=[@"native:" stringByAppendingString:uri],*token=NSUUID.UUID.UUIDString;
    dispatch_async(self.queue,^{
        if(consumer.cancelled)return;UIImage *cached=[self.cache objectForKey:identifier];if(cached){[self complete:@[consumer] image:cached];return;}
        SAPArtistArtworkRequest *request=self.inFlight[identifier];if(request){if(request.completions.count<64)request.completions[token]=consumer;else[self complete:@[consumer] image:nil];return;}
        if(self.inFlight.count>=SAPArtistArtworkMaximumRequests){[self complete:@[consumer] image:nil];return;}
        request=[SAPArtistArtworkRequest new];request.identifier=identifier;request.completions=[@{token:consumer}mutableCopy];self.inFlight[identifier]=request;
        // Verified es_image.proto: GetImageParams.uri=1, resolve.size=2.1;
        // ImageData.error=1, data=3. Spotify resolves mosaics and custom covers.
        NSMutableData *size=[SAPProtoInteger(1,128)mutableCopy];[size appendData:SAPProtoInteger(2,128)];
        NSMutableData *payload=[SAPProtoBytes(1,[uri dataUsingEncoding:NSUTF8StringEncoding])mutableCopy];[payload appendData:SAPProtoBytes(2,SAPProtoBytes(1,size))];
        request.cancelNative=SAPCallReadOnlyServiceCancellable(@"spotify.image.esperanto.proto.Image",@"GetImage",payload,^(NSData *data,NSString *error){
            dispatch_async(self.queue,^{
                if(self.inFlight[identifier]!=request)return;request.cancelNative=nil;[self.inFlight removeObjectForKey:identifier];
                NSArray *fields=data.length<=SAPArtistArtworkMaximumBytes+1024?SAPProtoFields(data):nil;uint64_t code=SAPProtoNumber(fields,1,0);
                UIImage *image=!error.length && fields && !code?[self thumbnailForData:SAPProtoData(fields,3)]:nil;
                if(image){NSUInteger cost=(NSUInteger)(image.size.width*image.scale)*(NSUInteger)(image.size.height*image.scale)*4;[self.cache setObject:image forKey:identifier cost:cost];}
                SAPJournalNoteAction(@"playlist_artwork_result",@{@"uri":uri,@"route":@"native_image_service",@"image_received":@(image!=nil),@"native_error_code":@(code),@"error":error?:(!fields?@"Invalid native image response":image?@"":@"Native image unavailable")});
                [self complete:request.completions.allValues image:image];
            });
        });
    });
    return ^{consumer.cancelled=YES;dispatch_async(self.queue,^{SAPArtistArtworkRequest *request=self.inFlight[identifier];[request.completions removeObjectForKey:token];if(request&&!request.completions.count){if(request.cancelNative)request.cancelNative();request.cancelNative=nil;[self.inFlight removeObjectForKey:identifier];}});};
}
- (dispatch_block_t)loadURL:(NSString *)value completion:(void (^)(UIImage *))completion {
    SAPArtistArtworkConsumer *consumer=[SAPArtistArtworkConsumer new];consumer.completion=completion;
    NSString *identifier=SAPArtistArtworkIdentifier(value),*token=NSUUID.UUID.UUIDString;
    if(!identifier)[self complete:@[consumer] image:nil];
    else dispatch_async(self.queue,^{
        if(consumer.cancelled)return;
        UIImage *cached=[self.cache objectForKey:identifier];
        if(cached){[self complete:@[consumer] image:cached];return;}
        SAPArtistArtworkRequest *existing=self.inFlight[identifier];
        if(existing){
            if(existing.completions.count<64)existing.completions[token]=consumer;
            else [self complete:@[consumer] image:nil];
            return;
        }
        if(self.inFlight.count>=SAPArtistArtworkMaximumRequests){[self complete:@[consumer] image:nil];return;}
        SAPArtistArtworkRequest *request=[SAPArtistArtworkRequest new];request.identifier=identifier;
        request.data=[NSMutableData data];request.completions=[@{token:consumer}mutableCopy];self.inFlight[identifier]=request;
#ifdef SAP_TESTING
        if(SAPArtistArtworkDataProviderForTesting) {
            SAPArtistArtworkDataProviderForTesting(value,^(NSData *data){dispatch_async(self.queue,^{
                if(self.inFlight[identifier]!=request)return;
                UIImage *image=[self thumbnailForData:data];
                if(image){NSUInteger cost=(NSUInteger)(image.size.width*image.scale)*(NSUInteger)(image.size.height*image.scale)*4;[self.cache setObject:image forKey:identifier cost:cost];}
                [self.inFlight removeObjectForKey:identifier];[self complete:request.completions.allValues image:image];
            });});return;
        }
#endif
        NSString *address=[identifier hasPrefix:@"mosaic:"]?[@"https://mosaic.scdn.co/300/" stringByAppendingString:[identifier substringFromIndex:7]]:[@"https://i.scdn.co/image/" stringByAppendingString:identifier];
        NSURL *url=[NSURL URLWithString:address];
        NSMutableURLRequest *http=[NSMutableURLRequest requestWithURL:url cachePolicy:NSURLRequestReloadIgnoringLocalCacheData timeoutInterval:8];
        [http setValue:@"image/jpeg,image/png,image/webp" forHTTPHeaderField:@"Accept"];
        request.task=[self.session dataTaskWithRequest:http];self.requests[@(request.task.taskIdentifier)]=request;[request.task resume];
    });
    return ^{
        consumer.cancelled=YES;
        if(!identifier)return;
        dispatch_async(self.queue,^{
            SAPArtistArtworkRequest *request=self.inFlight[identifier];
            [request.completions removeObjectForKey:token];
            if(request && !request.completions.count){
                [request.task cancel];if(request.cancelNative)request.cancelNative();request.cancelNative=nil;
                if(request.task)[self.requests removeObjectForKey:@(request.task.taskIdentifier)];
                [self.inFlight removeObjectForKey:identifier];
            }
        });
    };
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveResponse:(NSURLResponse *)response completionHandler:(void (^)(NSURLSessionResponseDisposition))completionHandler {
    SAPArtistArtworkRequest *request=self.requests[@(task.taskIdentifier)];NSHTTPURLResponse *http=[response isKindOfClass:NSHTTPURLResponse.class]?(id)response:nil;
    NSString *type=response.MIMEType.lowercaseString;
    request.allowed=http.statusCode==200 && [type hasPrefix:@"image/"] && (response.expectedContentLength<0 || response.expectedContentLength<=SAPArtistArtworkMaximumBytes);
    completionHandler(request.allowed?NSURLSessionResponseAllow: NSURLSessionResponseCancel);
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request completionHandler:(void (^)(NSURLRequest *))completionHandler {
    SAPArtistArtworkRequest *active=self.requests[@(task.taskIdentifier)];
    completionHandler(active && [SAPArtistArtworkIdentifier(request.URL.absoluteString)isEqual:active.identifier]?request:nil);
}
- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task didReceiveData:(NSData *)data {
    SAPArtistArtworkRequest *request=self.requests[@(task.taskIdentifier)];
    if(!request.allowed || data.length>SAPArtistArtworkMaximumBytes || request.data.length>SAPArtistArtworkMaximumBytes-data.length){[task cancel];return;}
    [request.data appendData:data];
}
- (UIImage *)thumbnailForData:(NSData *)data {
#ifdef SAP_TESTING
    NSCAssert(!NSThread.isMainThread,@"Artist artwork decoding must stay off the main thread");
#endif
    if(!data.length || data.length>SAPArtistArtworkMaximumBytes)return nil;
    CGImageSourceRef source=CGImageSourceCreateWithData((__bridge CFDataRef)data,NULL);if(!source)return nil;
    NSDictionary *options=@{(id)kCGImageSourceCreateThumbnailFromImageAlways:@YES,
        (id)kCGImageSourceThumbnailMaxPixelSize:@(SAPArtistArtworkMaximumPixels),
        (id)kCGImageSourceShouldCacheImmediately:@YES};
    CGImageRef image=CGImageSourceCreateThumbnailAtIndex(source,0,(__bridge CFDictionaryRef)options);CFRelease(source);
    if(!image)return nil;UIImage *thumbnail=[UIImage imageWithCGImage:image scale:1.0 orientation:UIImageOrientationUp];CFRelease(image);return thumbnail;
}
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    NSNumber *key=@(task.taskIdentifier);SAPArtistArtworkRequest *request=self.requests[key];if(!request)return;
    [self.requests removeObjectForKey:key];[self.inFlight removeObjectForKey:request.identifier];
    UIImage *image=error||!request.allowed?nil:[self thumbnailForData:request.data];
    if(image) {
        NSUInteger cost=(NSUInteger)(image.size.width*image.scale)*(NSUInteger)(image.size.height*image.scale)*4;
        [self.cache setObject:image forKey:request.identifier cost:cost];
    }
    [self complete:request.completions.allValues image:image];
}
@end

#ifdef SAP_TESTING
dispatch_block_t SAPArtistArtworkLoadForTesting(NSString *url,void (^completion)(UIImage *)) {
    return [[SAPArtistArtworkLoader shared]loadURL:url completion:completion];
}
#endif

static UIImage *SAPArtistArtworkPlaceholder(void) {
    static UIImage *image;static dispatch_once_t once;dispatch_once(&once,^{
        UIGraphicsImageRenderer *renderer=[[UIGraphicsImageRenderer alloc]initWithSize:CGSizeMake(52,52)];
        image=[renderer imageWithActions:^(UIGraphicsImageRendererContext *context){
            [[UIColor colorWithWhite:.20 alpha:1]setFill];[[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0,0,52,52) cornerRadius:8]fill];
            UIImage *glyph=[[UIImage systemImageNamed:@"music.note"]imageWithTintColor:UIColor.tertiaryLabelColor];
            [glyph drawInRect:CGRectMake(17,17,18,18)];
        }];
    });return image;
}

@interface SAPArtistProgressAccessory : UIView
- (instancetype)initWithDownloaded:(NSUInteger)downloaded total:(NSUInteger)total progress:(double)progress;
- (void)updateDownloaded:(NSUInteger)downloaded total:(NSUInteger)total progress:(double)progress;
@end
@implementation SAPArtistProgressAccessory { CAShapeLayer *_progressRing; }
- (instancetype)initWithDownloaded:(NSUInteger)downloaded total:(NSUInteger)total progress:(double)progress {
    if((self=[super initWithFrame:CGRectMake(0,0,40,40)])) {
        CGPoint center=CGPointMake(20,20);CGFloat radius=13.5;
        UIBezierPath *path=[UIBezierPath bezierPathWithArcCenter:center radius:radius startAngle:-M_PI_2 endAngle:M_PI*1.5 clockwise:YES];
        CAShapeLayer *track=[CAShapeLayer layer];track.path=path.CGPath;track.fillColor=UIColor.clearColor.CGColor;
        track.strokeColor=[UIColor colorWithWhite:.32 alpha:1].CGColor;track.lineWidth=2.5;[self.layer addSublayer:track];
        CAShapeLayer *ring=[CAShapeLayer layer];ring.path=path.CGPath;ring.fillColor=UIColor.clearColor.CGColor;
        ring.strokeColor=[UIColor colorWithRed:1 green:.66 blue:.18 alpha:1].CGColor;ring.lineWidth=2.5;ring.lineCap=kCALineCapRound;
        _progressRing=ring;[self.layer addSublayer:ring];
        UIImageSymbolConfiguration *arrowStyle=[UIImageSymbolConfiguration configurationWithPointSize:16 weight:UIImageSymbolWeightRegular];
        UIImageView *arrow=[[UIImageView alloc]initWithImage:[UIImage systemImageNamed:@"arrow.down" withConfiguration:arrowStyle]];arrow.preferredSymbolConfiguration=arrowStyle;arrow.tintColor=UIColor.systemOrangeColor;arrow.contentMode=UIViewContentModeScaleAspectFit;arrow.translatesAutoresizingMaskIntoConstraints=NO;[self addSubview:arrow];
        [NSLayoutConstraint activateConstraints:@[[arrow.widthAnchor constraintEqualToConstant:16],[arrow.heightAnchor constraintEqualToConstant:16],[arrow.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],[arrow.centerYAnchor constraintEqualToAnchor:self.centerYAnchor]]];
        self.isAccessibilityElement=YES;[self updateDownloaded:downloaded total:total progress:progress];
    }
    return self;
}
- (void)updateDownloaded:(NSUInteger)downloaded total:(NSUInteger)total progress:(double)progress {
    [CATransaction begin];[CATransaction setDisableActions:YES];_progressRing.strokeEnd=MIN(1,MAX(0,progress));[CATransaction commit];
    self.accessibilityLabel=[NSString stringWithFormat:@"Partially downloaded, %lu of %lu tracks",(unsigned long)downloaded,(unsigned long)total];
}
@end

static NSString *SAPArtistReleaseCategoryTitle(NSDictionary *release) {
    NSString *category=release[@"category"];
    if(![category isEqualToString:@"Appears on"])return category;
    NSString *type;
    switch([release[@"type"]unsignedIntegerValue]) {
        case 1:type=@"Album";break;
        case 2:type=@"Single";break;
        case 3:type=@"Compilation";break;
        case 4:type=@"EP";break;
        default:type=@"Unknown type";break;
    }
    return [NSString stringWithFormat:@"Appears on (%@)",type];
}

static NSString *SAPArtistTrackCounter(NSUInteger downloaded,NSUInteger total) {
    NSString *downloadedText=[NSString stringWithFormat:@"%lu",(unsigned long)downloaded];
    NSUInteger totalDigits=[NSString stringWithFormat:@"%lu",(unsigned long)total].length;
    if(downloadedText.length<totalDigits) {
        NSString *padding=[@"" stringByPaddingToLength:totalDigits-downloadedText.length withString:@" " startingAtIndex:0];
        downloadedText=[padding stringByAppendingString:downloadedText];
    }
    return [NSString stringWithFormat:@"%@ / %lu tracks",downloadedText,(unsigned long)total];
}

static UIImageView *SAPArtistStateIcon(NSString *symbol,UIColor *color,NSString *label) {
    UIImageView *view=[[UIImageView alloc]initWithImage:[UIImage systemImageNamed:symbol]];
    view.tintColor=color;view.contentMode=UIViewContentModeScaleAspectFit;view.frame=CGRectMake(0,0,32,32);
    view.isAccessibilityElement=YES;view.accessibilityLabel=label;return view;
}

@interface SAPArtistReleaseCell : UITableViewCell
@property(nonatomic,strong) UIView *indicatorHost;
@property(nonatomic,copy) NSArray<NSLayoutConstraint *> *indicatorConstraints,*indicatorChildConstraints;
@property(nonatomic,strong) UIView *downloadIndicator;
@property(nonatomic,strong) UIImageView *staticIndicator;
@property(nonatomic,strong) SAPArtistProgressAccessory *progressIndicator;
@property(nonatomic,copy) NSString *indicatorKind;
@property(nonatomic,copy) NSDictionary *renderedRelease,*renderedState;
@property(nonatomic) BOOL renderedSelecting,renderedSelected;
@property(nonatomic,copy) dispatch_block_t cancelArtwork;
- (void)cancelArtworkLoad;
- (UIView *)indicatorForState:(NSDictionary *)state;
- (void)installIndicatorLayout;
- (void)setDownloadIndicator:(UIView *)indicator;
@end
@implementation SAPArtistReleaseCell
- (void)cancelArtworkLoad {
    dispatch_block_t cancel=self.cancelArtwork;self.cancelArtwork=nil;
    if(cancel){cancel();objc_setAssociatedObject(self,&SAPArtistArtworkURLKey,nil,OBJC_ASSOCIATION_COPY_NONATOMIC);}
}
- (void)prepareForReuse {[super prepareForReuse];[self cancelArtworkLoad];self.renderedRelease=nil;self.renderedState=nil;}
- (void)dealloc {if(_cancelArtwork)_cancelArtwork();}
- (UIView *)indicatorForState:(NSDictionary *)state {
    NSString *kind=state[@"state"];
    NSDictionary *stopped=state[@"stopped_visual"];
    BOOL frozen=![kind isEqual:@"downloaded"] && stopped.count && ([state[@"can_continue"]boolValue] || [state[@"stopping"]boolValue] || [state[@"stop_pending"]boolValue]);
    if([kind isEqual:@"partial"] || frozen) {
        NSDictionary *display=frozen?stopped:state;
        NSUInteger done=[display[@"downloaded_tracks"]unsignedIntegerValue],total=[display[@"total_tracks"]unsignedIntegerValue];double value=[display[@"progress"]doubleValue];
        if(!self.progressIndicator)self.progressIndicator=[[SAPArtistProgressAccessory alloc]initWithDownloaded:done total:total progress:value];
        else [self.progressIndicator updateDownloaded:done total:total progress:value];
        if(frozen)self.progressIndicator.accessibilityLabel=[NSString stringWithFormat:@"Stopped. Last download progress: %.0f percent",MIN(1,MAX(0,value))*100];
        self.indicatorKind=frozen?@"stopped":kind;return self.progressIndicator;
    }
    if(!self.staticIndicator)self.staticIndicator=SAPArtistStateIcon(@"arrow.down.circle",UIColor.secondaryLabelColor,@"Not downloaded");
    if(![self.indicatorKind isEqual:kind]) {
        BOOL full=[kind isEqual:@"downloaded"],unknown=[kind isEqual:@"unknown"];
        self.staticIndicator.image=[UIImage systemImageNamed:full?@"checkmark.circle":unknown?@"questionmark.circle":@"arrow.down.circle"];
        self.staticIndicator.tintColor=full?UIColor.systemGreenColor:UIColor.secondaryLabelColor;
        self.staticIndicator.accessibilityLabel=full?@"Downloaded":unknown?@"Download state unavailable":@"Not downloaded";
        self.indicatorKind=kind;
    }
    return self.staticIndicator;
}
- (void)installIndicatorLayout {
    if(!self.indicatorHost) {
        self.indicatorHost=[UIView new];self.indicatorHost.translatesAutoresizingMaskIntoConstraints=NO;
        self.indicatorHost.userInteractionEnabled=NO;self.indicatorHost.accessibilityIdentifier=@"PixieAlbumStatus";
    }
    if(self.indicatorHost.superview==self.contentView)return;
    [NSLayoutConstraint deactivateConstraints:self.indicatorConstraints?:@[]];
    [self.indicatorHost removeFromSuperview];[self.contentView addSubview:self.indicatorHost];
    self.indicatorConstraints=@[
        [self.indicatorHost.widthAnchor constraintEqualToConstant:40],
        [self.indicatorHost.heightAnchor constraintEqualToConstant:40],
        [self.indicatorHost.trailingAnchor constraintEqualToAnchor:self.layoutMarginsGuide.trailingAnchor],
        [self.indicatorHost.centerYAnchor constraintEqualToAnchor:self.centerYAnchor]
    ];
    [NSLayoutConstraint activateConstraints:self.indicatorConstraints];
}
- (void)setDownloadIndicator:(UIView *)indicator {
    [self installIndicatorLayout];
    if(self.downloadIndicator==indicator)return;
    [NSLayoutConstraint deactivateConstraints:self.indicatorChildConstraints?:@[]];
    for(UIView *previous in self.indicatorHost.subviews)[previous removeFromSuperview];
    _downloadIndicator=indicator;
    CGSize size=[indicator isKindOfClass:SAPArtistProgressAccessory.class]?CGSizeMake(40,40):CGSizeMake(32,32);indicator.translatesAutoresizingMaskIntoConstraints=NO;
    [self.indicatorHost addSubview:indicator];
    self.indicatorChildConstraints=@[
        [indicator.widthAnchor constraintEqualToConstant:size.width],
        [indicator.heightAnchor constraintEqualToConstant:size.height],
        [indicator.centerXAnchor constraintEqualToAnchor:self.indicatorHost.centerXAnchor],
        [indicator.centerYAnchor constraintEqualToAnchor:self.indicatorHost.centerYAnchor]
    ];[NSLayoutConstraint activateConstraints:self.indicatorChildConstraints];
}
@end

@interface SAPArtistCategoryHeader : UITableViewHeaderFooterView
@property(nonatomic,strong) UILabel *categoryTitle,*catalogProgressLabel;
@property(nonatomic,strong) UIButton *selectionButton;
@end
@implementation SAPArtistCategoryHeader
- (instancetype)initWithReuseIdentifier:(NSString *)identifier {
    if((self=[super initWithReuseIdentifier:identifier])) {
        self.categoryTitle=[UILabel new];self.categoryTitle.translatesAutoresizingMaskIntoConstraints=NO;
        self.categoryTitle.font=[UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
        self.categoryTitle.adjustsFontForContentSizeCategory=YES;self.categoryTitle.textColor=UIColor.secondaryLabelColor;
        self.categoryTitle.numberOfLines=1;
        self.catalogProgressLabel=[UILabel new];self.catalogProgressLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];self.catalogProgressLabel.textColor=UIColor.secondaryLabelColor;self.catalogProgressLabel.adjustsFontSizeToFitWidth=YES;self.catalogProgressLabel.minimumScaleFactor=.7;self.catalogProgressLabel.hidden=YES;
        UIStackView *titles=[[UIStackView alloc]initWithArrangedSubviews:@[self.categoryTitle,self.catalogProgressLabel]];titles.axis=UILayoutConstraintAxisHorizontal;titles.alignment=UIStackViewAlignmentCenter;titles.spacing=8;titles.translatesAutoresizingMaskIntoConstraints=NO;
        self.selectionButton=[UIButton buttonWithType:UIButtonTypeCustom];self.selectionButton.translatesAutoresizingMaskIntoConstraints=NO;
        UIImageSymbolConfiguration *selectionSymbol=[UIImageSymbolConfiguration configurationWithPointSize:17.0*1.2 weight:UIImageSymbolWeightRegular];
        [self.selectionButton setImage:[UIImage systemImageNamed:@"circle" withConfiguration:selectionSymbol] forState:UIControlStateNormal];
        [self.selectionButton setImage:[UIImage systemImageNamed:@"checkmark.circle.fill" withConfiguration:selectionSymbol] forState:UIControlStateSelected];
        self.selectionButton.tintColor=UIColor.systemGreenColor;
        self.selectionButton.accessibilityIdentifier=@"PixieArtistCategorySelection";
        [self.contentView addSubview:titles];[self.contentView addSubview:self.selectionButton];
        UILayoutGuide *margins=self.contentView.layoutMarginsGuide;
        [NSLayoutConstraint activateConstraints:@[
            [titles.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
            [titles.centerYAnchor constraintEqualToAnchor:self.selectionButton.centerYAnchor],
            [titles.trailingAnchor constraintLessThanOrEqualToAnchor:self.selectionButton.leadingAnchor constant:-8],
            [titles.topAnchor constraintGreaterThanOrEqualToAnchor:self.contentView.topAnchor constant:8],
            [titles.bottomAnchor constraintLessThanOrEqualToAnchor:self.contentView.bottomAnchor constant:-8],
            [self.selectionButton.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
            [self.selectionButton.widthAnchor constraintEqualToConstant:44],
            [self.selectionButton.heightAnchor constraintEqualToConstant:44],
            [self.selectionButton.topAnchor constraintGreaterThanOrEqualToAnchor:self.contentView.topAnchor constant:4],
            [self.selectionButton.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-4]
        ]];
    }
    return self;
}
@end

static void SAPAfterDialogDismissal(UIAlertController *dialog,dispatch_block_t completion) {
    if(dialog.isBeingDismissed && dialog.transitionCoordinator){[dialog.transitionCoordinator animateAlongsideTransition:nil completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> context){completion();}];return;}
    if(dialog.presentingViewController && !dialog.isBeingDismissed){[dialog dismissViewControllerAnimated:YES completion:completion];return;}
    dispatch_async(dispatch_get_main_queue(),completion);
}

@interface SAPPlaylistPickerController : UITableViewController <UISearchResultsUpdating>
@property(nonatomic,strong) NSArray *playlists,*filtered;
@property(nonatomic,strong) UISearchController *search;
@property(nonatomic,strong) UILabel *statusLabel;
@property(nonatomic,strong) NSCache<NSString *,UIImage *> *knownCovers;
@property(nonatomic,strong) NSHashTable<SAPArtistReleaseCell *> *artworkCells;
@property(nonatomic,copy) dispatch_block_t cancelLoad;
@property(nonatomic,copy) void (^onChoose)(NSDictionary *,UIViewController *);
@property(nonatomic) NSUInteger generation;
@end
@implementation SAPPlaylistPickerController
- (instancetype)init {return [super initWithStyle:UITableViewStyleInsetGrouped];}
- (void)viewDidLoad {
    [super viewDidLoad];self.title=@"Existing playlist";self.knownCovers=[NSCache new];self.knownCovers.countLimit=64;self.knownCovers.totalCostLimit=4*1024*1024;self.artworkCells=[NSHashTable weakObjectsHashTable];self.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;self.tableView.backgroundColor=UIColor.blackColor;
    self.tableView.rowHeight=UITableViewAutomaticDimension;self.tableView.estimatedRowHeight=76;
    self.search=[[UISearchController alloc]initWithSearchResultsController:nil];self.search.searchResultsUpdater=self;self.search.obscuresBackgroundDuringPresentation=NO;self.search.searchBar.placeholder=@"Search playlists";self.navigationItem.searchController=self.search;self.definesPresentationContext=YES;
    self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc]initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh target:self action:@selector(loadPlaylists)];
    self.statusLabel=[UILabel new];self.statusLabel.numberOfLines=0;self.statusLabel.textAlignment=NSTextAlignmentCenter;self.statusLabel.textColor=UIColor.secondaryLabelColor;
    [self loadPlaylists];
}
- (void)viewWillAppear:(BOOL)animated {[super viewWillAppear:animated];[self.navigationController setToolbarHidden:YES animated:animated];}
- (void)dealloc {if(_cancelLoad)_cancelLoad();}
- (void)viewDidDisappear:(BOOL)animated {[super viewDidDisappear:animated];if(self.isMovingFromParentViewController || self.navigationController.isBeingDismissed){self.generation++;if(self.cancelLoad)self.cancelLoad();self.cancelLoad=nil;for(SAPArtistReleaseCell *cell in self.artworkCells)[cell cancelArtworkLoad];}}
- (void)loadPlaylists {
    if(self.cancelLoad)self.cancelLoad();NSUInteger generation=++self.generation;self.statusLabel.text=@"Loading playlists…";self.tableView.backgroundView=self.statusLabel;self.navigationItem.rightBarButtonItem.enabled=NO;
    __weak typeof(self) weak=self;self.cancelLoad=SAPFetchWritablePlaylists(^(NSArray *playlists,NSString *error){
        typeof(self) page=weak;if(!page || page.generation!=generation)return;page.cancelLoad=nil;page.playlists=playlists?:@[];page.navigationItem.rightBarButtonItem.enabled=YES;
        [page updateSearchResultsForSearchController:page.search];if(error.length){page.statusLabel.text=error;page.tableView.backgroundView=page.statusLabel;}
    });
}
- (void)updateSearchResultsForSearchController:(UISearchController *)search {
    NSString *text=search.searchBar.text?:@"";NSMutableArray *rows=[NSMutableArray array];for(NSDictionary *entry in self.playlists)if(!text.length || [entry[@"name"]localizedCaseInsensitiveContainsString:text])[rows addObject:entry];
    self.filtered=rows;self.statusLabel.text=self.playlists.count?@"No matching playlists.":@"No playlists you can add tracks to were found.";self.tableView.backgroundView=rows.count?nil:self.statusLabel;[self.tableView reloadData];
}
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {return self.filtered.count;}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    SAPArtistReleaseCell *cell=[table dequeueReusableCellWithIdentifier:@"PlaylistDestination"];if(!cell)cell=[[SAPArtistReleaseCell alloc]initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"PlaylistDestination"];
    [self.artworkCells addObject:cell];NSDictionary *playlist=self.filtered[path.row];NSString *uri=playlist[@"uri"],*imageURI=[playlist[@"cover_uri"]length]?playlist[@"cover_uri"]:playlist[@"cover_url"];
    NSString *identity=imageURI.length?[NSString stringWithFormat:@"%@|%@|%lu",uri,imageURI,(unsigned long)self.generation]:uri;BOOL same=[objc_getAssociatedObject(cell,&SAPArtistArtworkURLKey)isEqual:identity];
    UIImage *known=[self.knownCovers objectForKey:uri];if(!same)[cell cancelArtworkLoad];objc_setAssociatedObject(cell,&SAPArtistArtworkURLKey,identity,OBJC_ASSOCIATION_COPY_NONATOMIC);
    UIListContentConfiguration *old=(id)cell.contentConfiguration,*content=[UIListContentConfiguration subtitleCellConfiguration];content.text=playlist[@"name"];content.secondaryText=playlist[@"track_count"]?[NSString stringWithFormat:@"%@ tracks",playlist[@"track_count"]]:@"Playlist";content.image=known?:same?old.image:SAPArtistArtworkPlaceholder();content.imageProperties.maximumSize=CGSizeMake(52,52);content.imageProperties.reservedLayoutSize=CGSizeMake(52,52);content.imageProperties.cornerRadius=8;cell.contentConfiguration=content;cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
    if(!same && imageURI.length){__weak SAPArtistReleaseCell *weakCell=cell;__weak typeof(self) weak=self;cell.cancelArtwork=[[SAPArtistArtworkLoader shared]loadPlaylistURI:imageURI completion:^(UIImage *image){typeof(self) page=weak;SAPArtistReleaseCell *current=weakCell;if(!page || !current || ![objc_getAssociatedObject(current,&SAPArtistArtworkURLKey)isEqual:identity])return;current.cancelArtwork=nil;if(image){[page.knownCovers setObject:image forKey:uri cost:(NSUInteger)(image.size.width*image.scale)*(NSUInteger)(image.size.height*image.scale)*4];UIListContentConfiguration *updated=(id)current.contentConfiguration;updated.image=image;current.contentConfiguration=updated;}}];}
    return cell;
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {[table deselectRowAtIndexPath:path animated:YES];if(self.onChoose)self.onChoose(self.filtered[path.row],self);}
@end

@interface SAPArtistDownloadsController : UITableViewController
@property(nonatomic,copy) NSString *artistURI,*artistName,*loadError,*loadProgress;
@property(nonatomic,strong) NSDictionary *catalog,*sessionSnapshot,*playlistSnapshot,*playlistItemSnapshot;
@property(nonatomic) BOOL loading,selecting,pendingStateRefresh;
#ifdef SAP_TESTING
@property(nonatomic) NSUInteger stateRefreshCount;
#endif
@property(nonatomic,strong) NSMutableSet *selectedReleaseURIs;
@property(nonatomic,weak) UIAlertAction *nameConfirmation;
@property(nonatomic,copy) NSArray *catalogReleases;
@property(nonatomic,strong) UIBarButtonItem *downloadControl,*stopControl,*continueControl,*cancelControl,*retryControl,*toolbarSpace,*selectControl;
@property(nonatomic,strong) UILabel *loadingLabel,*footerLabel;
@property(nonatomic,strong) UIView *footerContainer,*loadingContainer;
@property(nonatomic,strong) UIActivityIndicatorView *loadingSpinner;
@property(nonatomic) BOOL itemsVisible;
@property(nonatomic) NSUInteger itemObservationGeneration;
@property(nonatomic,copy) NSString *footerText;
@property(nonatomic) CGFloat footerWidth;
@property(nonatomic,strong) NSHashTable<SAPArtistReleaseCell *> *artworkCells;
@property(nonatomic) NSUInteger loadGeneration,sessionObservationGeneration,loadCompleted,loadTotal;
@property(nonatomic,strong) NSDictionary *pendingCatalog;
@property(nonatomic,copy) dispatch_block_t cancelCatalog,detachPlaylistObserver;
@property(nonatomic,strong) SAPArtistSessionObservation *sessionObservation;
@property(nonatomic,strong) SAPReleaseItemObservation *itemObservation;
@property(nonatomic,strong) id foregroundObserver;
@end
@implementation SAPArtistDownloadsController
- (instancetype)init {return [super initWithStyle:UITableViewStyleInsetGrouped];}
- (void)viewDidLoad {
    [super viewDidLoad];self.title=self.artistName.length?self.artistName:@"Artist downloads";
    self.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;self.tableView.backgroundColor=UIColor.blackColor;
    self.tableView.rowHeight=UITableViewAutomaticDimension;self.tableView.estimatedRowHeight=76;
    if(@available(iOS 16.0,*))self.tableView.selfSizingInvalidation=UITableViewSelfSizingInvalidationEnabled;
    self.tableView.sectionHeaderHeight=UITableViewAutomaticDimension;self.tableView.estimatedSectionHeaderHeight=52;
    self.selectedReleaseURIs=[NSMutableSet set];self.artworkCells=[NSHashTable weakObjectsHashTable];
    self.downloadControl=[[UIBarButtonItem alloc]initWithTitle:@"Download selected" style:UIBarButtonItemStylePlain target:self action:@selector(downloadSelected)];
    __weak typeof(self) weakStopPage=self;
    self.stopControl=[[UIBarButtonItem alloc]initWithPrimaryAction:[UIAction actionWithTitle:@"Stop" image:nil identifier:@"pixie.artist.downloads.stop" handler:^(UIAction *action){
        typeof(self) page=weakStopPage;if(!page)return;
        BOOL senderMatches=action.sender==page.stopControl;
        BOOL visible=page.itemsVisible && page.viewIfLoaded.window!=nil && !page.navigationController.toolbarHidden && [page.toolbarItems containsObject:page.stopControl];
        BOOL top=page.navigationController.topViewController==page;
        BOOL modal=page.presentedViewController!=nil || page.navigationController.presentedViewController!=nil || page.isBeingDismissed || page.navigationController.isBeingDismissed;
        BOOL accepted=senderMatches && visible && top && !modal && page.stopControl.enabled;
        NSArray *scope=page.catalog[@"observation_releases"]?:page.allReleases;
        if(SAPDiagnosticsEnabled())SAPJournalNoteAction(accepted?@"artist_stop_all":@"artist_stop_all_ignored",@{@"artist_uri":page.artistURI?:@"",@"caller":@"Stop UIBarButtonItem primaryAction handler",@"action_origin":@"bar_button_primary_action",@"requested_reason":@"stop_artist_downloads",@"sender_matches":@(senderMatches),@"visible":@(visible),@"top_controller":@(top),@"presented_modal":@(modal),@"control_enabled":@(page.stopControl.enabled),@"selecting":@(page.selecting),@"release_count":@(scope.count),@"call_stack":NSThread.callStackSymbols});
        if(!accepted)return;
        SAPStopPlaylistReleaseDownloadsForArtist(page.artistURI,nil);SAPStopArtistDownloadSessionReleasesForArtist(page.artistURI,scope);
    }]];
    self.cancelControl=[[UIBarButtonItem alloc]initWithTitle:@"Cancel" style:UIBarButtonItemStylePlain target:self action:@selector(confirmCancelDownloads)];self.cancelControl.accessibilityLabel=@"Cancel downloads";
    self.continueControl=[[UIBarButtonItem alloc]initWithTitle:@"Continue" style:UIBarButtonItemStylePlain target:self action:@selector(continueDownloads)];
    self.selectControl=[[UIBarButtonItem alloc]initWithTitle:@"Select" style:UIBarButtonItemStylePlain target:self action:@selector(toggleSelection)];
    self.retryControl=[[UIBarButtonItem alloc]initWithTitle:@"Retry" style:UIBarButtonItemStylePlain target:self action:@selector(loadCatalog)];self.toolbarSpace=[UIBarButtonItem flexibleSpaceItem];
    self.loadingLabel=[UILabel new];self.loadingLabel.numberOfLines=0;self.loadingLabel.textAlignment=NSTextAlignmentCenter;self.loadingLabel.textColor=UIColor.secondaryLabelColor;
    self.loadingLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];self.loadingLabel.adjustsFontForContentSizeCategory=YES;
    self.loadingContainer=[UIView new];self.loadingSpinner=[[UIActivityIndicatorView alloc]initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];self.loadingSpinner.color=UIColor.whiteColor;self.loadingSpinner.hidesWhenStopped=YES;
    UIStackView *loadingStack=[[UIStackView alloc]initWithArrangedSubviews:@[self.loadingLabel,self.loadingSpinner]];loadingStack.axis=UILayoutConstraintAxisVertical;loadingStack.alignment=UIStackViewAlignmentCenter;loadingStack.spacing=12;loadingStack.translatesAutoresizingMaskIntoConstraints=NO;[self.loadingContainer addSubview:loadingStack];
    [NSLayoutConstraint activateConstraints:@[[loadingStack.centerXAnchor constraintEqualToAnchor:self.loadingContainer.centerXAnchor],[loadingStack.centerYAnchor constraintEqualToAnchor:self.loadingContainer.centerYAnchor],[loadingStack.widthAnchor constraintEqualToAnchor:self.loadingContainer.widthAnchor constant:-48],[self.loadingLabel.widthAnchor constraintEqualToAnchor:loadingStack.widthAnchor]]];
    self.footerLabel=[UILabel new];self.footerLabel.numberOfLines=0;self.footerLabel.textColor=UIColor.secondaryLabelColor;self.footerLabel.font=[UIFont preferredFontForTextStyle:UIFontTextStyleFootnote];
    self.footerContainer=[UIView new];[self.footerContainer addSubview:self.footerLabel];
    [self.navigationController setToolbarHidden:NO animated:NO];
    UIBarButtonItem *back=[[UIBarButtonItem alloc]initWithImage:[UIImage systemImageNamed:@"chevron.left"] style:UIBarButtonItemStylePlain target:self action:@selector(close)];
    back.tintColor=UIColor.whiteColor;back.accessibilityLabel=@"Back";self.navigationItem.leftBarButtonItem=back;
    __weak typeof(self) weak=self;
    self.foregroundObserver=[NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note){typeof(self) page=weak;if(page.itemsVisible && page.viewIfLoaded.window){[page detachItems];[page attachItems];if(page.sessionObservation)[page.sessionObservation refresh];else[page bindSession];}}];
    [self loadCatalog];
}
- (NSArray *)sections {return self.catalog[@"sections"]?:@[];}
- (NSArray *)allReleases {return self.catalogReleases?:@[];}
- (NSDictionary *)stateFor:(NSString *)uri {
    NSDictionary *native=self.sessionSnapshot[@"album_states"][uri]?:@{@"state":@"unknown"};
    NSDictionary *items=self.playlistItemSnapshot[@"album_states"][uri];
    BOOL registered=[native[@"state"]isEqual:@"downloaded"];
    if(registered){NSMutableDictionary *live=[(items?:native)mutableCopy];live[@"state"]=@"downloaded";live[@"phase"]=@"downloaded";live[@"progress"]=@1;live[@"active"]=@NO;return live;}
    if([native[@"active"]boolValue]){
        if(!items)return native;NSMutableDictionary *live=[native mutableCopy];
        for(NSString *key in @[@"progress",@"downloaded_tracks",@"total_tracks",@"known_tracks",@"playlist_download",@"playlist_uri",@"playlist_name"])if(items[key])live[key]=items[key];return live;
    }
    for(NSDictionary *job in [self.playlistSnapshot[@"jobs"]reverseObjectEnumerator])if([job[@"active"]boolValue] && ([job[@"queued"]boolValue] || ![job[@"submitted"]boolValue]) && [job[@"release_uris"]containsObject:uri])return @{@"state":@"partial",@"phase":[job[@"queued"]boolValue]?@"queued":@"preparing",@"active":@YES,@"progress":@0,@"playlist_name":job[@"playlist_name"]?:@"Playlist",@"playlist_download":@YES,@"download_source":@"playlist"};
    NSMutableDictionary *live=[(items?:native)mutableCopy];
    if([items[@"state"]isEqual:@"downloaded"]){
        // File availability is not the album's native offline registration.
        BOOL known=[native[@"state"]length] && ![native[@"state"]isEqual:@"unknown"];
        live[@"state"]=[items[@"active"]boolValue]?@"partial":known?@"not_downloaded":@"unknown";
        live[@"phase"]=[items[@"active"]boolValue]?@"registering":known?@"unregistered":@"unverified";
        if([native[@"phase"]isEqual:@"failed"]){live[@"phase"]=@"failed";live[@"error"]=native[@"error"]?:@"Album registration failed.";}
    }
    if([native[@"can_continue"]boolValue] || [native[@"stop_pending"]boolValue]){
        for(NSString *key in @[@"can_continue",@"stop_pending",@"stopped_visual"])if(native[key])live[key]=native[key];
    }
    // A stopped preparation may not yet have a native item membership lease.
    if(![live[@"active"]boolValue])for(NSDictionary *job in [self.playlistSnapshot[@"jobs"]reverseObjectEnumerator])if([job[@"can_continue"]boolValue] && [job[@"release_uris"]containsObject:uri]){
        live[@"can_continue"]=@YES;if(![live[@"stopped_visual"]count])live[@"stopped_visual"]=job[@"stopped_visuals"][uri]?:@{};break;
    }
    return live;
}
- (void)detach {self.sessionObservationGeneration++;self.pendingStateRefresh=NO;[self.sessionObservation invalidate];self.sessionObservation=nil;dispatch_block_t stop=self.detachPlaylistObserver;self.detachPlaylistObserver=nil;if(stop)stop();[self detachItems];}
- (void)cancelCatalogLoad {self.loadGeneration++;dispatch_block_t stop=self.cancelCatalog;self.cancelCatalog=nil;if(stop)stop();}
- (void)cancelArtworkLoads {for(SAPArtistReleaseCell *cell in self.artworkCells)[cell cancelArtworkLoad];}
- (void)close {[self cancelArtworkLoads];[self cancelCatalogLoad];[self detach];[self dismissViewControllerAnimated:YES completion:nil];}
- (void)viewDidDisappear:(BOOL)animated {[super viewDidDisappear:animated];self.itemsVisible=NO;[self.loadingSpinner stopAnimating];[self detachItems];if(self.navigationController.isBeingDismissed){[self cancelArtworkLoads];[self cancelCatalogLoad];[self detach];}}
- (void)dealloc {if(_foregroundObserver)[NSNotificationCenter.defaultCenter removeObserver:_foregroundObserver];for(SAPArtistReleaseCell *cell in _artworkCells)[cell cancelArtworkLoad];if(_cancelCatalog)_cancelCatalog();[_sessionObservation invalidate];if(_detachPlaylistObserver)_detachPlaylistObserver();[_itemObservation invalidate];}
- (void)bindSession {
    if(!self.allReleases.count)return;
    if(self.sessionObservation){[self.sessionObservation extendReleases:self.allReleases];return;}
    NSUInteger generation=++self.sessionObservationGeneration;__weak typeof(self) weak=self;
    self.sessionObservation=SAPObserveArtistSessionForArtist(self.artistURI,self.allReleases,^(NSDictionary *snapshot){typeof(self) page=weak;if(!page || page.sessionObservationGeneration!=generation)return;page.sessionSnapshot=snapshot;[page requestStateRefresh];});
}
- (void)requestStateRefresh {
    if(self.pendingStateRefresh)return;self.pendingStateRefresh=YES;__weak typeof(self) weak=self;
    dispatch_async(dispatch_get_main_queue(),^{[weak flushPendingStateRefresh];});
}
- (void)flushPendingStateRefresh {
    if(!self.pendingStateRefresh)return;self.pendingStateRefresh=NO;
    // Keep the newest evidence while hidden or covered by the destination picker.
    // UIKit work resumes from that evidence when this page becomes visible.
    if(!self.itemsVisible || !self.viewIfLoaded.window || self.navigationController.topViewController!=self)return;
#ifdef SAP_TESTING
    self.stateRefreshCount++;
#endif
    [self refreshVisibleStates];[self updateControls];
}
- (void)applyPendingCatalog {
    if(!self.pendingCatalog || !self.viewIfLoaded.window || self.navigationController.isBeingDismissed || self.isBeingDismissed || self.tableView.isTracking || self.tableView.isDragging || self.tableView.isDecelerating || self.presentedViewController || self.navigationController.topViewController!=self)return;
    NSDictionary *next=self.pendingCatalog;self.pendingCatalog=nil;NSIndexPath *top=[self.tableView.indexPathsForVisibleRows sortedArrayUsingSelector:@selector(compare:)].firstObject;
    NSString *anchor=top?self.sections[top.section][@"releases"][top.row][@"uri"]:nil;CGFloat relative=top?[self.tableView rectForRowAtIndexPath:top].origin.y-self.tableView.contentOffset.y:0;
    NSDictionary *old=self.catalog;
    // Retain the visible order. Newly resolved rows append within their
    // category instead of inserting a newer date above an existing row.
    NSMutableArray *merged=[NSMutableArray array];
    for(NSString *title in @[@"Albums",@"EPs",@"Singles",@"Singles & EPs",@"Compilations",@"Appears on"]){
        NSArray *existing=nil,*incoming=nil;for(NSDictionary *group in old[@"sections"])if([group[@"title"]isEqual:title])existing=group[@"releases"];for(NSDictionary *group in next[@"sections"])if([group[@"title"]isEqual:title])incoming=group[@"releases"];
        NSMutableArray *rows=[NSMutableArray arrayWithArray:existing?:@[]];NSMutableSet *seen=[NSMutableSet set];for(NSDictionary *row in rows)[seen addObject:row[@"uri"]];for(NSDictionary *row in incoming)if(![seen containsObject:row[@"uri"]]){[rows addObject:row];[seen addObject:row[@"uri"]];}
        if(rows.count)[merged addObject:@{@"title":title,@"releases":rows}];
    }
    NSMutableDictionary *display=[next mutableCopy];display[@"sections"]=merged;self.catalog=display;NSMutableArray *all=[NSMutableArray array];for(NSDictionary *section in self.sections)[all addObjectsFromArray:section[@"releases"]];self.catalogReleases=all;
    NSMutableSet *present=[NSMutableSet set];for(NSDictionary *release in all)[present addObject:release[@"uri"]];[self.selectedReleaseURIs intersectSet:present];
    BOOL changed=![old[@"sections"]isEqual:display[@"sections"]];
    if(changed)[UIView performWithoutAnimation:^{[self.tableView reloadData];[self.tableView layoutIfNeeded];if(anchor){for(NSUInteger section=0;section<self.sections.count;section++){NSArray *rows=self.sections[section][@"releases"];for(NSUInteger row=0;row<rows.count;row++)if([rows[row][@"uri"]isEqual:anchor]){CGFloat minimum=-self.tableView.adjustedContentInset.top,maximum=MAX(minimum,self.tableView.contentSize.height-self.tableView.bounds.size.height+self.tableView.adjustedContentInset.bottom);CGFloat target=[self.tableView rectForRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:section]].origin.y-relative;[self.tableView setContentOffset:CGPointMake(self.tableView.contentOffset.x,MIN(maximum,MAX(minimum,target))) animated:NO];return;}}}}];
    [self updateControls];__weak typeof(self) weak=self;
    NSArray *scope=self.catalog[@"observation_releases"]?:self.allReleases;
    if(!self.detachPlaylistObserver && scope.count)self.detachPlaylistObserver=SAPObservePlaylistReleaseDownloadsForArtist(self.artistURI,scope,^(NSDictionary *snapshot){typeof(self) page=weak;if(!page)return;page.playlistSnapshot=snapshot;[page requestStateRefresh];});
    if(changed)[self bindSession];[self attachItems];
}
- (void)loadCatalog {
    if(self.loading)return;[self detach];self.loading=YES;self.loadError=nil;self.loadProgress=nil;self.loadCompleted=self.loadTotal=0;self.catalog=nil;self.catalogReleases=@[];self.pendingCatalog=nil;[self.selectedReleaseURIs removeAllObjects];
    NSUInteger generation=++self.loadGeneration;[self.tableView reloadData];[self updateControls];__weak typeof(self) weak=self;
    SAPJournalNoteAction(@"artist_catalog_requested",@{@"artist_uri":self.artistURI?:@""});
    self.cancelCatalog=SAPFetchArtistMetadataProgressively(self.artistURI,^(NSUInteger completed,NSUInteger total){typeof(self) page=weak;if(!page || generation!=page.loadGeneration)return;page.loadCompleted=completed;page.loadTotal=total;page.loadProgress=total?[NSString stringWithFormat:@"Reading release details… %lu / %lu",(unsigned long)completed,(unsigned long)total]:nil;[page updateControls];},^(NSDictionary *catalog){typeof(self) page=weak;if(!page || generation!=page.loadGeneration)return;page.pendingCatalog=catalog;[page applyPendingCatalog];},^(NSDictionary *catalog,NSString *error){typeof(self) page=weak;if(!page || generation!=page.loadGeneration)return;page.cancelCatalog=nil;page.loading=NO;page.loadError=error;page.pendingCatalog=catalog?:@{};[page applyPendingCatalog];[page updateControls];SAPJournalNoteAction(@"artist_catalog_result",@{@"artist_uri":page.artistURI?:@"",@"release_count":catalog[@"release_count"]?:@0,@"error":error?:@""});});
}
- (void)viewWillAppear:(BOOL)animated {[super viewWillAppear:animated];[self updateControls];}
- (void)viewDidAppear:(BOOL)animated {[super viewDidAppear:animated];self.itemsVisible=YES;[self applyPendingCatalog];[self refreshVisibleStates];[self updateControls];[self attachItems];}
- (void)refreshSelectionViews {
    [UIView performWithoutAnimation:^{
        for(NSIndexPath *path in self.tableView.indexPathsForVisibleRows)[self configureCell:[self.tableView cellForRowAtIndexPath:path] release:self.sections[path.section][@"releases"][path.row]];
        for(NSUInteger section=0;section<self.sections.count;section++){SAPArtistCategoryHeader *header=(id)[self.tableView headerViewForSection:section];if(header)[self configureCategoryHeader:header section:section];}
    }];[self updateControls];
}
- (void)toggleSelection {self.selecting=!self.selecting;if(!self.selecting)[self.selectedReleaseURIs removeAllObjects];[self refreshSelectionViews];}
- (void)finishSelection {
    if(!self.selecting)return;self.selecting=NO;[self.selectedReleaseURIs removeAllObjects];[self refreshSelectionViews];
}
- (void)viewDidLayoutSubviews {[super viewDidLayoutSubviews];[self updateFooterLayout];}
- (void)detachItems {self.itemObservationGeneration++;[self.itemObservation invalidate];self.itemObservation=nil;self.playlistItemSnapshot=nil;}
- (void)refreshVisibleStates {
    if(self.tableView.isTracking || self.tableView.isDragging || self.tableView.isDecelerating)return;
    [UIView performWithoutAnimation:^{for(NSIndexPath *path in self.tableView.indexPathsForVisibleRows)[self configureCell:[self.tableView cellForRowAtIndexPath:path] release:self.sections[path.section][@"releases"][path.row]];}];
}
- (void)attachItems {
    if(!self.itemsVisible || !self.allReleases.count)return;
    if(self.itemObservation){[self.itemObservation updateReleases:self.allReleases];return;}
    NSUInteger generation=self.itemObservationGeneration;__weak typeof(self) weak=self;
    // One observation per open catalog. Scrolling never replaces native leases
    // or discards item states; only changed visible rows are rendered.
    NSArray *scope=[(self.catalog[@"observation_releases"]?:@[])arrayByAddingObjectsFromArray:self.allReleases];
    self.itemObservation=SAPObserveReleaseItems(scope,^(NSDictionary *snapshot){typeof(self) page=weak;if(!page || generation!=page.itemObservationGeneration || !page.itemsVisible)return;page.playlistItemSnapshot=snapshot;[page requestStateRefresh];});
}
- (void)scrollViewDidEndDecelerating:(UIScrollView *)scroll {[self applyPendingCatalog];[self refreshVisibleStates];[self updateFooterLayout];}
- (void)scrollViewDidEndDragging:(UIScrollView *)scroll willDecelerate:(BOOL)decelerate {if(!decelerate){[self applyPendingCatalog];[self refreshVisibleStates];[self updateFooterLayout];}}
- (void)updateFooterLayout {
    if(self.tableView.isTracking || self.tableView.isDragging || self.tableView.isDecelerating)return;
    if(!self.allReleases.count){if(self.tableView.tableFooterView)self.tableView.tableFooterView=nil;self.footerWidth=0;return;}
    CGFloat width=MAX(240,self.tableView.bounds.size.width-48);
    if(self.footerWidth==width && self.tableView.tableFooterView==self.footerContainer)return;
    self.footerWidth=width;CGSize size=[self.footerLabel sizeThatFits:CGSizeMake(width,CGFLOAT_MAX)];
    CGRect frame=CGRectMake(0,0,width+48,size.height+32);self.footerLabel.frame=CGRectMake(24,12,width,size.height);
    if(!CGRectEqualToRect(self.footerContainer.frame,frame) || self.tableView.tableFooterView!=self.footerContainer){self.footerContainer.frame=frame;self.tableView.tableFooterView=self.footerContainer;}
}
- (void)updateControls {
    BOOL active=[self.sessionSnapshot[@"active"]boolValue] || [self.playlistSnapshot[@"active"]boolValue];
    BOOL resumable=[self.sessionSnapshot[@"can_continue"]boolValue] || [self.playlistSnapshot[@"can_continue"]boolValue];
    // Older or unavailable producers may omit the summary flag.
    if(!self.sessionSnapshot[@"can_continue"])for(NSDictionary *value in [self.sessionSnapshot[@"album_states"]allValues])if([value[@"can_continue"]boolValue]){resumable=YES;break;}
    if(!self.playlistSnapshot[@"can_continue"])for(NSDictionary *job in self.playlistSnapshot[@"jobs"])if([job[@"can_continue"]boolValue]){resumable=YES;break;}
    self.selectControl.title=self.selecting?@"Cancel":@"Select";self.selectControl.enabled=self.allReleases.count>0;
    BOOL retry=!self.loading && !active && (self.loadError || [self.catalog[@"load_warning"]length]);
    BOOL cancelable=[self.sessionSnapshot[@"can_cancel"]boolValue] || [self.playlistSnapshot[@"can_cancel"]boolValue];
    self.cancelControl.enabled=cancelable;
    NSArray *right=retry?@[self.selectControl,self.retryControl]:@[self.selectControl];if(![self.navigationItem.rightBarButtonItems isEqual:right])self.navigationItem.rightBarButtonItems=right;
    NSUInteger selected=self.selectedReleaseURIs.count;self.downloadControl.title=[NSString stringWithFormat:@"Download selected · %lu",(unsigned long)selected];self.downloadControl.enabled=selected>0;
    NSMutableArray *items=[NSMutableArray array];
    if(self.selecting){if(active)[items addObject:self.stopControl];[items addObjectsFromArray:@[self.toolbarSpace,self.downloadControl]];}
    else {if(cancelable)[items addObject:self.cancelControl];[items addObject:self.toolbarSpace];if(resumable)[items addObject:self.continueControl];if(active)[items addObject:self.stopControl];}
    if(![self.toolbarItems isEqual:items])self.toolbarItems=items;
    if(self.navigationController.topViewController==self)[self.navigationController setToolbarHidden:!active&&!self.selecting&&!resumable&&!cancelable animated:NO];
    NSString *loading=self.allReleases.count?nil:self.loading?(self.loadProgress?:@"Loading releases…"):self.loadError?:@"Spotify returned no music releases for this artist.";
    if(![self.loadingLabel.text isEqual:loading])self.loadingLabel.text=loading;
    if(self.loading && !self.allReleases.count){if(!self.loadingSpinner.isAnimating)[self.loadingSpinner startAnimating];}else if(self.loadingSpinner.isAnimating)[self.loadingSpinner stopAnimating];
    UIView *background=loading?self.loadingContainer:nil;if(self.tableView.backgroundView!=background)self.tableView.backgroundView=background;
    NSString *text=@"Tap a release to download it or stop its download. Use Select to choose individual releases or whole categories, then download separately or through a new or existing playlist. Stop pauses downloads associated with this list. Continue resumes stopped work after a fresh Spotify status check. Cancel stops unfinished downloads for this artist. Downloads stay inside Spotify.";
    if(self.loading)text=[text stringByAppendingString:@" More releases are loading. Category selection applies to loaded releases."];
    if([self.sessionSnapshot[@"error"]length])text=[text stringByAppendingFormat:@"\n%@",self.sessionSnapshot[@"error"]];
    if([self.catalog[@"load_warning"]length])text=[text stringByAppendingFormat:@"\n%@",self.catalog[@"load_warning"]];
    for(NSDictionary *job in self.playlistSnapshot[@"jobs"])if([job[@"error"]length] || ([job[@"active"]boolValue] && ![job[@"context_state"]count]))text=[text stringByAppendingFormat:@"\n%@",job[@"message"]?:job[@"error"]];
    if(![self.footerText isEqual:text]) {self.footerText=text;self.footerLabel.text=text;self.footerWidth=0;}
    [self updateLoadingHeader];[self updateFooterLayout];
}
- (NSInteger)numberOfSectionsInTableView:(UITableView *)table {return self.sections.count;}
- (NSInteger)tableView:(UITableView *)table numberOfRowsInSection:(NSInteger)section {return [self.sections[section][@"releases"]count];}
- (NSString *)categoryTitleForSection:(NSUInteger)section {NSDictionary *group=self.sections[section];return [NSString stringWithFormat:@"%@ (%lu)",group[@"title"],(unsigned long)[group[@"releases"]count]];}
- (void)updateLoadingHeader {
    if(!self.sections.count)return;SAPArtistCategoryHeader *header=(id)[self.tableView headerViewForSection:0];if(!header)return;
    BOOL visible=self.loading && self.allReleases.count>0;header.catalogProgressLabel.hidden=!visible;header.catalogProgressLabel.text=visible?[NSString stringWithFormat:@"Loading %lu/%lu",(unsigned long)self.loadCompleted,(unsigned long)self.loadTotal]:nil;
}
- (void)configureCategoryHeader:(SAPArtistCategoryHeader *)header section:(NSUInteger)section {
    NSDictionary *group=self.sections[section];header.categoryTitle.text=[self categoryTitleForSection:section];
    BOOL progress=section==0 && self.loading;header.catalogProgressLabel.hidden=!progress;header.catalogProgressLabel.text=progress?[NSString stringWithFormat:@"Loading %lu/%lu",(unsigned long)self.loadCompleted,(unsigned long)self.loadTotal]:nil;
    UIButton *button=header.selectionButton;button.tag=section;button.hidden=!self.selecting;
    BOOL all=YES,any=NO;for(NSDictionary *release in group[@"releases"]){BOOL selected=[self.selectedReleaseURIs containsObject:release[@"uri"]];all&=selected;any|=selected;}button.selected=all;
    [button setImage:[UIImage systemImageNamed:any&&!all?@"minus.circle":@"circle" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:20.4 weight:UIImageSymbolWeightRegular]] forState:UIControlStateNormal];
    button.accessibilityLabel=[NSString stringWithFormat:self.loading?@"Select loaded %@":@"Select %@",group[@"title"]];
    button.accessibilityValue=button.selected?@"Selected":@"Not selected";
    button.accessibilityTraits=UIAccessibilityTraitButton|(button.selected?UIAccessibilityTraitSelected:0);
    [button removeTarget:self action:@selector(toggleCategory:) forControlEvents:UIControlEventTouchUpInside];
    [button addTarget:self action:@selector(toggleCategory:) forControlEvents:UIControlEventTouchUpInside];
}
- (UIView *)tableView:(UITableView *)table viewForHeaderInSection:(NSInteger)section {
    SAPArtistCategoryHeader *header=[table dequeueReusableHeaderFooterViewWithIdentifier:@"ArtistCategory"];
    if(!header)header=[[SAPArtistCategoryHeader alloc]initWithReuseIdentifier:@"ArtistCategory"];
    [self configureCategoryHeader:header section:section];return header;
}
- (void)toggleCategory:(UIButton *)button {
    NSUInteger section=(NSUInteger)button.tag;if(!self.selecting || section>=self.sections.count)return;NSArray *releases=self.sections[section][@"releases"];BOOL all=YES;
    for(NSDictionary *release in releases)all&=[self.selectedReleaseURIs containsObject:release[@"uri"]];
    for(NSDictionary *release in releases)if(all)[self.selectedReleaseURIs removeObject:release[@"uri"]];else[self.selectedReleaseURIs addObject:release[@"uri"]];
    [self refreshSelectionViews];
}
- (NSArray *)selectedReleases {NSMutableArray *releases=[NSMutableArray array];for(NSDictionary *release in self.allReleases)if([self.selectedReleaseURIs containsObject:release[@"uri"]])[releases addObject:release];return releases;}
- (void)configureCell:(UITableViewCell *)cell release:(NSDictionary *)release {
    SAPArtistReleaseCell *releaseCell=(id)cell;NSDictionary *renderState=[self stateFor:release[@"uri"]];BOOL renderSelected=[self.selectedReleaseURIs containsObject:release[@"uri"]];
    if([releaseCell.renderedRelease isEqual:release] && [releaseCell.renderedState isEqual:renderState] && releaseCell.renderedSelecting==self.selecting && releaseCell.renderedSelected==renderSelected)return;
    releaseCell.renderedRelease=release;releaseCell.renderedState=renderState;releaseCell.renderedSelecting=self.selecting;releaseCell.renderedSelected=renderSelected;
    if(!cell)return;
    NSString *coverURL=release[@"cover_url"],*coverID=SAPArtistArtworkIdentifier(coverURL);
    BOOL same=[objc_getAssociatedObject(cell,&SAPArtistArtworkURLKey)isEqual:coverID];
    UIListContentConfiguration *old=(id)cell.contentConfiguration;
    BOOL reuseContent=[old isKindOfClass:UIListContentConfiguration.class] && same && [old.text isEqual:release[@"name"]];
    UIListContentConfiguration *content=reuseContent?[old copy]:[UIListContentConfiguration subtitleCellConfiguration];
    if(!reuseContent){
        // Preserve native text styling and layout when only progress changes.
        NSDirectionalEdgeInsets margins=content.directionalLayoutMargins;margins.trailing+=52;content.directionalLayoutMargins=margins;
        content.text=release[@"name"];content.textProperties.numberOfLines=0;content.secondaryTextProperties.numberOfLines=0;
        UIFont *font=content.secondaryTextProperties.font?:[UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
        UIFontDescriptor *digits=[font.fontDescriptor fontDescriptorByAddingAttributes:@{UIFontDescriptorFeatureSettingsAttribute:@[@{UIFontFeatureTypeIdentifierKey:@(kNumberSpacingType),UIFontFeatureSelectorIdentifierKey:@(kMonospacedNumbersSelector)}]}];
        content.secondaryTextProperties.font=[UIFont fontWithDescriptor:digits size:font.pointSize];
        content.image=same&&old.image?old.image:SAPArtistArtworkPlaceholder();content.imageProperties.maximumSize=CGSizeMake(52,52);content.imageProperties.reservedLayoutSize=CGSizeMake(52,52);content.imageProperties.cornerRadius=8;
    }
    NSString *category=SAPArtistReleaseCategoryTitle(release);
    NSString *subtitle=[release[@"year"]integerValue]?[NSString stringWithFormat:@"%@ · %@",release[@"year"],category]:category;
    NSDictionary *state=renderState;NSString *kind=state[@"state"];
    BOOL selected=[self.selectedReleaseURIs containsObject:release[@"uri"]];
    UIView *indicator=self.selecting?SAPArtistStateIcon(selected?@"checkmark.circle.fill":@"circle",selected?UIColor.systemGreenColor:UIColor.secondaryLabelColor,selected?@"Selected":@"Not selected"):[(SAPArtistReleaseCell *)cell indicatorForState:state];
    cell.accessibilityTraits=UIAccessibilityTraitButton|(self.selecting&&selected?UIAccessibilityTraitSelected:0);
    NSString *phase=state[@"phase"];
    if([kind isEqual:@"downloaded"]) {subtitle=[subtitle stringByAppendingString:@" · Downloaded"];}
    else if([state[@"can_continue"]boolValue])subtitle=[subtitle stringByAppendingString:@" · Stopped"];
    else if([phase isEqual:@"failed"]){}
    else if([phase isEqual:@"unverified"])subtitle=[subtitle stringByAppendingString:@" · Checking album offline status…"];
    else if([phase isEqual:@"unregistered"])subtitle=[subtitle stringByAppendingString:@" · Tracks available; album not downloaded"];
    else if([phase isEqual:@"registering"])subtitle=[subtitle stringByAppendingString:@" · Registering album for offline…"];
    else if([phase isEqual:@"stopping"] || [state[@"stopping"]boolValue])subtitle=[subtitle stringByAppendingString:@" · Stopping…"];
    else if([phase isEqual:@"queued"])subtitle=[subtitle stringByAppendingString:@" · Queued"];
    else if([phase isEqual:@"preparing"])subtitle=[subtitle stringByAppendingString:@" · Preparing…"];
    else if([phase isEqual:@"waiting"])subtitle=[subtitle stringByAppendingString:@" · Waiting for Spotify…"];
    else if([kind isEqual:@"partial"]) {
        NSUInteger done=[state[@"downloaded_tracks"]unsignedIntegerValue],total=[state[@"total_tracks"]unsignedIntegerValue];
        if([phase isEqual:@"downloading"] || (!phase.length && [state[@"active"]boolValue])) {
            NSString *progress=total?[SAPArtistTrackCounter(done,total) stringByAppendingString:@" · Downloading…"]:@"Downloading…";
            subtitle=[subtitle stringByAppendingFormat:@" · %@",progress];
        } else {
            NSString *progress=total?[SAPArtistTrackCounter(done,total) stringByAppendingString:@" · Partially downloaded"]:@"Partially downloaded";
            subtitle=[subtitle stringByAppendingFormat:@" · %@",progress];
        }
    } else if([phase isEqual:@"downloading"] || (!phase.length && [state[@"active"]boolValue]))subtitle=[subtitle stringByAppendingString:@" · Downloading…"];
    if([state[@"playlist_download"]boolValue])subtitle=[subtitle stringByAppendingFormat:@" · In %@",state[@"playlist_name"]?:@"playlist"];
    if([state[@"error"]length])subtitle=[subtitle stringByAppendingFormat:@" · %@",state[@"error"]];
    if(!reuseContent || ![old.secondaryText isEqual:subtitle]){content.secondaryText=subtitle;cell.contentConfiguration=content;}
    cell.accessoryType=UITableViewCellAccessoryNone;cell.backgroundColor=UIColor.secondarySystemGroupedBackgroundColor;
    [(SAPArtistReleaseCell *)cell setDownloadIndicator:indicator];
    if(!same)[(SAPArtistReleaseCell *)cell cancelArtworkLoad];
    objc_setAssociatedObject(cell,&SAPArtistArtworkURLKey,coverID,OBJC_ASSOCIATION_COPY_NONATOMIC);
    if(coverID && !same) {
        __weak typeof(self) weak=self;__weak UITableViewCell *weakCell=cell;
        ((SAPArtistReleaseCell *)cell).cancelArtwork=[[SAPArtistArtworkLoader shared]loadURL:coverURL completion:^(UIImage *image){
            UITableViewCell *current=weakCell;if(!weak.viewIfLoaded.window || !current || ![objc_getAssociatedObject(current,&SAPArtistArtworkURLKey)isEqual:coverID])return;
            ((SAPArtistReleaseCell *)current).cancelArtwork=nil;
            if(!image){objc_setAssociatedObject(current,&SAPArtistArtworkURLKey,nil,OBJC_ASSOCIATION_COPY_NONATOMIC);return;}
            UIListContentConfiguration *updated=(id)current.contentConfiguration;updated.image=image;[UIView performWithoutAnimation:^{current.contentConfiguration=updated;[(SAPArtistReleaseCell *)current installIndicatorLayout];}];
        }];
    }
}
- (UITableViewCell *)tableView:(UITableView *)table cellForRowAtIndexPath:(NSIndexPath *)path {
    UITableViewCell *cell=[table dequeueReusableCellWithIdentifier:@"ArtistRelease"];if(!cell)cell=[[SAPArtistReleaseCell alloc]initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"ArtistRelease"];
    [self.artworkCells addObject:(SAPArtistReleaseCell *)cell];
    [self configureCell:cell release:self.sections[path.section][@"releases"][path.row]];return cell;
}
- (void)afterDialog:(UIAlertController *)dialog perform:(dispatch_block_t)action {
    __weak typeof(self) weak=self;SAPAfterDialogDismissal(dialog,^{typeof(self) page=weak;if(!page)return;[page applyPendingCatalog];if(action)action();});
}
- (void)startReleases:(NSArray *)releases {
    if(!releases.count)return;NSMutableArray *pending=[NSMutableArray array];for(NSDictionary *release in releases){NSString *uri=release[@"uri"];BOOL downloaded=[[self stateFor:uri][@"state"]isEqual:@"downloaded"];if(!downloaded){NSMutableDictionary *owned=[release mutableCopy];owned[@"artist_uri"]=self.artistURI;[pending addObject:owned];}}
    SAPJournalNoteAction(@"artist_separate_selection_filtered",@{@"selected":@(releases.count),@"already_downloaded":@(releases.count-pending.count),@"remaining":@(pending.count)});
    if(!pending.count){[self finishSelection];[self updateControls];return;}NSString *error=nil;if(SAPAppendArtistDownloadSessionReleases(pending,&error)){[self finishSelection];[self updateControls];return;}
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Could not start download" message:error preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];[self presentViewController:alert animated:YES completion:nil];
}
- (void)tableView:(UITableView *)table didSelectRowAtIndexPath:(NSIndexPath *)path {
    [table deselectRowAtIndexPath:path animated:YES];__weak typeof(self) weakPage=self;dispatch_async(dispatch_get_main_queue(),^{[weakPage applyPendingCatalog];});NSDictionary *release=self.sections[path.section][@"releases"][path.row];NSDictionary *state=[self stateFor:release[@"uri"]];
    if(self.selecting){NSString *uri=release[@"uri"];if([self.selectedReleaseURIs containsObject:uri])[self.selectedReleaseURIs removeObject:uri];else[self.selectedReleaseURIs addObject:uri];[self refreshSelectionViews];return;}
    if([state[@"stopping"]boolValue] || [state[@"state"]isEqual:@"downloaded"])return;
    if([state[@"active"]boolValue] && [state[@"playlist_download"]boolValue]){
        UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Stop playlist download?" message:[NSString stringWithFormat:@"This release is downloading through \"%@\". Other releases in that playlist will also stop.",state[@"playlist_name"]?:@"Playlist"] preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];[alert addAction:[UIAlertAction actionWithTitle:@"Stop" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action){if(SAPDiagnosticsEnabled())SAPJournalNoteAction(@"artist_playlist_row_stop",@{@"artist_uri":self.artistURI?:@"",@"release_uri":release[@"uri"]?:@"",@"caller":@"tableView:didSelectRowAtIndexPath:/Stop UIAlertAction handler",@"action_origin":@"alert_action_handler",@"requested_reason":@"stop_artist_playlist_tasks_containing_release",@"call_stack":NSThread.callStackSymbols});SAPStopPlaylistReleaseDownloadsForArtist(self.artistURI,@[release]);}]];[self presentViewController:alert animated:YES completion:nil];return;
    }
    if([state[@"active"]boolValue])SAPStopArtistDownloadSessionRelease(release[@"uri"]);else[self startReleases:@[release]];
}
- (void)continueDownloads {
    NSArray *scope=self.catalog[@"observation_releases"]?:self.allReleases;NSString *error=nil;
    if(!SAPContinueArtistDownloads(self.artistURI,scope,&error) || !SAPContinuePlaylistReleaseDownloadsForArtist(self.artistURI,scope,&error)){
        UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Could not continue" message:error?:@"Spotify has not confirmed that the previous operation stopped." preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];[self presentViewController:alert animated:YES completion:nil];
    }
    [self updateControls];
}
- (void)confirmCancelDownloads {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Cancel downloads?" message:@"Cancel all unfinished downloads for this artist?" preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Keep downloading" style:UIAlertActionStyleCancel handler:nil]];__weak typeof(self) weak=self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel downloads" style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action){typeof(self) page=weak;if(!page)return;SAPCancelPlaylistReleaseDownloadsForArtist(page.artistURI);SAPCancelArtistDownloadSession(page.artistURI);[page requestStateRefresh];}]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)showError:(NSString *)error {UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Could not start playlist download" message:error preferredStyle:UIAlertControllerStyleAlert];[alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];[self presentViewController:alert animated:YES completion:nil];}
- (void)startPlaylist:(NSArray *)releases uri:(NSString *)uri name:(NSString *)name {
    NSString *error=nil;if(!SAPStartPlaylistReleaseDownloadForArtist(self.artistURI,releases,uri,name,&error)){[self showError:error];return;}
    [self finishSelection];[self updateControls];[self attachItems];
}
- (void)playlistNameChanged:(UITextField *)field {NSString *name=[field.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];self.nameConfirmation.enabled=name.length>0 && name.length<=200;}
- (void)newPlaylist:(NSArray *)releases {
    UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"New playlist" message:[NSString stringWithFormat:@"Save %lu selected releases to Your Library, add their tracks in release order and download the playlist.",(unsigned long)releases.count] preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weak=self;[alert addTextFieldWithConfigurationHandler:^(UITextField *field){field.placeholder=@"Playlist name";field.autocapitalizationType=UITextAutocapitalizationTypeSentences;[field addTarget:weak action:@selector(playlistNameChanged:) forControlEvents:UIControlEventEditingChanged];}];
    __weak UIAlertController *weakAlert=alert;[alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *action){[weak afterDialog:weakAlert perform:nil];}]];
    UIAlertAction *confirm=[UIAlertAction actionWithTitle:@"Create and download" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action){NSString *name=[weakAlert.textFields.firstObject.text copy];[weak afterDialog:weakAlert perform:^{[weak startPlaylist:releases uri:nil name:name];}];}];confirm.enabled=NO;self.nameConfirmation=confirm;[alert addAction:confirm];[self presentViewController:alert animated:YES completion:nil];
}
- (void)existingPlaylist:(NSArray *)releases {
    SAPPlaylistPickerController *picker=[SAPPlaylistPickerController new];__weak typeof(self) weak=self;
    picker.onChoose=^(NSDictionary *playlist,UIViewController *presenter){
        UIAlertController *alert=[UIAlertController alertControllerWithTitle:@"Add and download?" message:[NSString stringWithFormat:@"Add %lu selected releases to \"%@\" and download this playlist? Existing tracks stay in place. Tracks already in the playlist will not be added again.",(unsigned long)releases.count,playlist[@"name"]] preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
        __weak UIAlertController *weakAlert=alert;[alert addAction:[UIAlertAction actionWithTitle:@"Add and download" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action){typeof(self) page=weak;if(!page)return;SAPAfterDialogDismissal(weakAlert,^{typeof(self) current=weak;if(!current)return;UINavigationController *navigation=current.navigationController;[navigation popToViewController:current animated:YES];dispatch_block_t start=^{if(navigation.topViewController==current && !navigation.isBeingDismissed)[current startPlaylist:releases uri:playlist[@"uri"] name:playlist[@"name"]];};if(navigation.transitionCoordinator)[navigation.transitionCoordinator animateAlongsideTransition:nil completion:^(__unused id<UIViewControllerTransitionCoordinatorContext> context){start();}];else start();});}]];[presenter presentViewController:alert animated:YES completion:nil];
    };[self.navigationController pushViewController:picker animated:YES];
}
- (void)downloadSelected {
    NSArray *releases=self.selectedReleases;if(!releases.count)return;__weak typeof(self) weak=self;
    UIAlertController *menu=[UIAlertController alertControllerWithTitle:@"Download selected" message:[NSString stringWithFormat:@"%lu releases selected",(unsigned long)releases.count] preferredStyle:UIAlertControllerStyleActionSheet];
    __weak UIAlertController *weakMenu=menu;[menu addAction:[UIAlertAction actionWithTitle:@"Download separately" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action){[weak afterDialog:weakMenu perform:^{[weak startReleases:releases];}];}]];
    [menu addAction:[UIAlertAction actionWithTitle:@"New playlist" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action){[weak afterDialog:weakMenu perform:^{[weak newPlaylist:releases];}];}]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Existing playlist" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action){[weak afterDialog:weakMenu perform:^{[weak existingPlaylist:releases];}];}]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *action){[weak afterDialog:weakMenu perform:nil];}]];menu.popoverPresentationController.barButtonItem=self.downloadControl;[self presentViewController:menu animated:YES completion:nil];
}
@end
void SAPShowArtistDownloads(NSString *artistURI,NSString *artistName,UIViewController *presenter) {
    if(!NSThread.isMainThread) {dispatch_async(dispatch_get_main_queue(),^{SAPShowArtistDownloads(artistURI,artistName,presenter);});return;}
    if(![presenter isKindOfClass:UIViewController.class] || !presenter.viewIfLoaded.window)return;
    while(presenter.presentedViewController && !presenter.presentedViewController.isBeingDismissed)presenter=presenter.presentedViewController;
    if([presenter isKindOfClass:SAPArtistDownloadsController.class])return;
    SAPArtistDownloadsController *page=[SAPArtistDownloadsController new];page.artistURI=artistURI;page.artistName=artistName;
    UINavigationController *navigation=[[UINavigationController alloc]initWithRootViewController:page];navigation.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;
    navigation.navigationBar.barStyle=UIBarStyleBlack;navigation.navigationBar.tintColor=UIColor.whiteColor;
    navigation.modalPresentationStyle=UIModalPresentationPageSheet;
    if(@available(iOS 15.0,*))navigation.sheetPresentationController.detents=@[UISheetPresentationControllerDetent.largeDetent];
    [presenter presentViewController:navigation animated:YES completion:nil];
}
