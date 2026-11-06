#import "NativeDownloadQuality.h"
#import <objc/runtime.h>
#import <objc/message.h>
#import <dlfcn.h>
#import <stdatomic.h>
#import <string.h>

NSString *const SAPNativeDownloadQualityOfferDidChangeNotification=@"SAPNativeDownloadQualityOfferDidChangeNotification";
static NSString *const decisionKey=@"pixie.nativeDownloadQualityHint.v1";
static NSString *const preferencesClassName=@"_TtC31Preferences_CorePreferencesImpl28SPTPreferencesImplementation";
typedef NS_ENUM(NSUInteger,SAPQualityDecision){SAPQualityUnknown,SAPQualityOffer,SAPQualityQuiet,SAPQualitySuppressed};
static NSLock *policyLock;
static NSUserDefaults *defaults;
static SAPQualityDecision decision;
static atomic_bool terminal,observationInstalled;

static void loadPolicy(void){
    static dispatch_once_t once;dispatch_once(&once,^{
        policyLock=NSLock.new;defaults=NSUserDefaults.standardUserDefaults;
        id saved=[defaults objectForKey:decisionKey];
        if([saved isEqual:@"offer"])decision=SAPQualityOffer;
        else if([saved isEqual:@"quiet"])decision=SAPQualityQuiet;
        else if([saved isEqual:@"suppressed"])decision=SAPQualitySuppressed;
        atomic_store_explicit(&terminal,decision==SAPQualitySuppressed,memory_order_release);
    });
}
static void notifyChange(void){
    dispatch_block_t notify=^{[NSNotificationCenter.defaultCenter postNotificationName:SAPNativeDownloadQualityOfferDidChangeNotification object:nil];};
    if(NSThread.isMainThread)notify();else dispatch_async(dispatch_get_main_queue(),notify);
}
// Called with policyLock held. Never invokes a native API or posts notifications.
static void saveDecision(SAPQualityDecision next){
    decision=next;
    if(next==SAPQualitySuppressed)atomic_store_explicit(&terminal,true,memory_order_release);
    NSString *saved=next==SAPQualityOffer?@"offer":next==SAPQualityQuiet?@"quiet":@"suppressed";
    [defaults setObject:saved forKey:decisionKey];
}
// Spotify 9.1.90 raw download enum: 1 Low, 2 Normal, 3 High,
// 4 Very high, 5 Lossless. Exact labels proven by stock Settings' formatter
// 0x10434e0ec and SPTStrings _i18n.KEYS/_i18n.en (research report).
static BOOL highQuality(NSInteger value){return value==3||value==4||value==5;}
static void observeHigh(NSInteger value){
    // After a terminal decision the hook forwards the original IMP and exits:
    // no lock, defaults access, getter, queued work, or notification.
    if(atomic_load_explicit(&terminal,memory_order_acquire)||!highQuality(value))return;
    [policyLock lock];BOOL changed=decision!=SAPQualitySuppressed;
    if(changed)saveDecision(SAPQualitySuppressed);
    [policyLock unlock];if(changed)notifyChange();
}
static BOOL methodABI(Method method,const char *result,BOOL setter){
    if(!method||method_getNumberOfArguments(method)!=(setter?3u:2u))return NO;
    char type[32]={0};method_getReturnType(method,type,sizeof(type));if(strcmp(type,result))return NO;
    method_getArgumentType(method,0,type,sizeof(type));if(strcmp(type,"@"))return NO;
    method_getArgumentType(method,1,type,sizeof(type));if(strcmp(type,":"))return NO;
    if(setter){method_getArgumentType(method,2,type,sizeof(type));if(strcmp(type,@encode(NSInteger)))return NO;}
    return YES;
}
void SAPInstallNativeDownloadQualityObservation(void){
    loadPolicy();if(atomic_load_explicit(&terminal,memory_order_acquire)||atomic_load_explicit(&observationInstalled,memory_order_acquire))return;
    Class cls=NSClassFromString(preferencesClassName);SEL setter=NSSelectorFromString(@"setAudioSyncBitrate:");
    Method method=cls?class_getInstanceMethod(cls,setter):NULL;
    // Missing startup classes may become available by the next explicit entry.
    // Do not consume installation once until the exact native ABI is available.
    if(!methodABI(method,"v",YES))return;
    static dispatch_once_t once;dispatch_once(&once,^{
        IMP original=method_getImplementation(method);
        IMP replacement=imp_implementationWithBlock(^(id object,NSInteger value){
            ((void(*)(id,SEL,NSInteger))original)(object,setter,value);
            observeHigh(value);
        });
        if(!class_addMethod(cls,setter,replacement,method_getTypeEncoding(method)))
            method_setImplementation(class_getInstanceMethod(cls,setter),replacement);
        atomic_store_explicit(&observationInstalled,true,memory_order_release);
    });
}
BOOL SAPShouldOfferNativeDownloadQuality(void){
    NSCAssert(NSThread.isMainThread,@"Download quality UI decisions require the main thread");
    SAPInstallNativeDownloadQualityObservation();if(atomic_load_explicit(&terminal,memory_order_acquire))return NO;
    [policyLock lock];SAPQualityDecision current=decision;[policyLock unlock];
    if(current!=SAPQualityUnknown)return current==SAPQualityOffer;
    typedef id(*PreferencesProvider)(void);static PreferencesProvider provider;
    if(!provider)provider=(PreferencesProvider)dlsym(RTLD_DEFAULT,"SGSpotifyPreferences");
    // Vitrine's existing weak capture returns nil until playbackSpeed>0 proves
    // native user preferences loaded. It never changes the download preference.
    id preferences=provider?provider():nil;Class cls=NSClassFromString(preferencesClassName);
    SEL getter=NSSelectorFromString(@"audioSyncBitrate");
    if(!preferences||!cls||![preferences isKindOfClass:cls]||!methodABI(class_getInstanceMethod(object_getClass(preferences),getter),@encode(NSInteger),NO))return NO;
    NSInteger quality=((NSInteger(*)(id,SEL))objc_msgSend)(preferences,getter);
    SAPQualityDecision next=quality==2?SAPQualityOffer:quality==1?SAPQualityQuiet:highQuality(quality)?SAPQualitySuppressed:SAPQualityUnknown;
    if(next==SAPQualityUnknown)return NO; // Future values remain unknown, never guessed.
    [policyLock lock];BOOL changed=decision==SAPQualityUnknown;
    if(changed)saveDecision(next);
    BOOL offered=decision==SAPQualityOffer;[policyLock unlock];
    if(changed)notifyChange();return offered;
}
BOOL SAPDismissNativeDownloadQualityOfferAndOpenSettings(void){
    NSCAssert(NSThread.isMainThread,@"Download quality navigation requires the main thread");
    loadPolicy();[policyLock lock];BOOL changed=decision!=SAPQualitySuppressed;
    if(changed)saveDecision(SAPQualitySuppressed);
    [policyLock unlock];if(!changed)return NO;
    notifyChange();
    typedef BOOL(*OpenSpotifyURI)(NSURL *);static OpenSpotifyURI open;static dispatch_once_t once;
    dispatch_once(&once,^{open=(OpenSpotifyURI)dlsym(RTLD_DEFAULT,"SGOpenSpotifyURI");});
    return open?open([NSURL URLWithString:@"spotify:settings:quality"]):NO;
}
