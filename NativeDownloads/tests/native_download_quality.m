// Regression: wrong native enum, repeated reads, streaming-quality confusion,
// lost terminal persistence, broken setter forwarding, or navigation before save.
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <assert.h>
#import "NativeDownloadQuality.h"

static NSString *const decisionKey=@"pixie.nativeDownloadQualityHint.v1";
static NSUserDefaults *isolated;
static NSUInteger bridgeReads,getterReads,setterCalls,routeCalls,notifications;
static NSInteger level=2;
static BOOL ready=YES, routeResult=YES;
static IMP originalStandard;
static id fixtureStandard(id cls,SEL sel){return isolated;}
@interface _TtC31Preferences_CorePreferencesImpl28SPTPreferencesImplementation:NSObject
- (NSInteger)audioSyncBitrate;
- (void)setAudioSyncBitrate:(NSInteger)value;
@end
@implementation _TtC31Preferences_CorePreferencesImpl28SPTPreferencesImplementation
- (NSInteger)audioSyncBitrate {getterReads++;return level;}
- (void)setAudioSyncBitrate:(NSInteger)value {setterCalls++;level=value;}
@end
static id preferences;
__attribute__((visibility("default"))) id SGSpotifyPreferences(void){bridgeReads++;return ready?preferences:nil;}
__attribute__((visibility("default"))) BOOL SGOpenSpotifyURI(NSURL *url){
    routeCalls++;assert([url.absoluteString isEqual:@"spotify:settings:quality"]);
    assert([[isolated objectForKey:decisionKey]isEqual:@"suppressed"]);
    assert(!SAPShouldOfferNativeDownloadQuality());return routeResult;
}
static void stable(BOOL offered){NSUInteger reads=getterReads,bridges=bridgeReads;for(int i=0;i<20;i++)assert(SAPShouldOfferNativeDownloadQuality()==offered);assert(getterReads==reads&&bridgeReads==bridges);}
static void runCase(NSString *name){
    preferences=[_TtC31Preferences_CorePreferencesImpl28SPTPreferencesImplementation new];
    id observer=[NSNotificationCenter.defaultCenter addObserverForName:SAPNativeDownloadQualityOfferDidChangeNotification object:nil queue:nil usingBlock:^(__unused NSNotification *n){assert(NSThread.isMainThread);notifications++;}];
    if([name isEqual:@"normal"]){SAPInstallNativeDownloadQualityObservation();assert(SAPShouldOfferNativeDownloadQuality());assert(getterReads==1&&bridgeReads==1);stable(YES);assert([[isolated objectForKey:decisionKey]isEqual:@"offer"]);}
    else if([name isEqual:@"offer-restart"]){level=5;assert(SAPShouldOfferNativeDownloadQuality());assert(getterReads==0&&bridgeReads==0);stable(YES);}
    else if([name isEqual:@"tap"]||[name isEqual:@"tap-fails"]){routeResult=![name isEqual:@"tap-fails"];assert(SAPShouldOfferNativeDownloadQuality());assert(SAPDismissNativeDownloadQualityOfferAndOpenSettings()==routeResult);assert(routeCalls==1);stable(NO);}
    else if([name isEqual:@"suppressed-restart"]){level=2;SAPInstallNativeDownloadQualityObservation();stable(NO);assert(getterReads==0&&bridgeReads==0);[preferences setAudioSyncBitrate:3];assert(setterCalls==1);stable(NO);}
    else if([name hasPrefix:@"high"]){level=[[name substringFromIndex:4]integerValue];assert(!SAPShouldOfferNativeDownloadQuality());assert(getterReads==1);stable(NO);assert([[isolated objectForKey:decisionKey]isEqual:@"suppressed"]);}
    else if([name isEqual:@"low"]){level=1;assert(!SAPShouldOfferNativeDownloadQuality());assert(getterReads==1);level=2;stable(NO);assert([[isolated objectForKey:decisionKey]isEqual:@"quiet"]);}
    else if([name isEqual:@"quiet-restart"]){level=2;stable(NO);assert(getterReads==0&&bridgeReads==0);}
    else if([name isEqual:@"deferred"]){ready=NO;assert(!SAPShouldOfferNativeDownloadQuality());assert(getterReads==0&&bridgeReads==1);ready=YES;level=0;assert(!SAPShouldOfferNativeDownloadQuality());level=99;assert(!SAPShouldOfferNativeDownloadQuality());level=2;assert(SAPShouldOfferNativeDownloadQuality());assert(getterReads==3);stable(YES);}
    else if([name isEqual:@"setter-before-read"]){SAPInstallNativeDownloadQualityObservation();[preferences setAudioSyncBitrate:3];assert(setterCalls==1&&level==3);stable(NO);assert(getterReads==0&&bridgeReads==0);assert([[isolated objectForKey:decisionKey]isEqual:@"suppressed"]);}
    else if([name isEqual:@"setter-after-offer"]){assert(SAPShouldOfferNativeDownloadQuality());NSUInteger prior=notifications;[preferences setAudioSyncBitrate:4];assert(setterCalls==1&&level==4);assert(notifications==prior+1);stable(NO);[preferences setAudioSyncBitrate:2];assert(setterCalls==2);stable(NO);}
    else if([name isEqual:@"setter-low-normal"]){SAPInstallNativeDownloadQualityObservation();[preferences setAudioSyncBitrate:1];[preferences setAudioSyncBitrate:2];assert(setterCalls==2);assert(SAPShouldOfferNativeDownloadQuality());stable(YES);}
    else assert(!"unknown case");
    [NSNotificationCenter.defaultCenter removeObserver:observer];
}
int main(int argc,const char *argv[]){@autoreleasepool{
    if(argc==3){isolated=[[NSUserDefaults alloc]initWithSuiteName:@(argv[2])];Method method=class_getClassMethod(NSUserDefaults.class,@selector(standardUserDefaults));originalStandard=method_setImplementation(method,(IMP)fixtureStandard);runCase(@(argv[1]));method_setImplementation(method,originalStandard);return 0;}
    NSArray *groups=@[@[@"normal",@"offer-restart",@"tap",@"suppressed-restart"],@[@"normal",@"tap-fails",@"suppressed-restart"],@[@"high3",@"suppressed-restart"],@[@"high4"],@[@"high5"],@[@"low",@"quiet-restart"],@[@"deferred"],@[@"setter-before-read",@"suppressed-restart"],@[@"setter-after-offer"],@[@"setter-low-normal"]];
    for(NSArray *group in groups){NSString *suite=[@"org.pixie.fixture.native-quality." stringByAppendingString:NSUUID.UUID.UUIDString];NSUserDefaults *cleanup=[[NSUserDefaults alloc]initWithSuiteName:suite];for(NSString *scenario in group){NSTask *task=NSTask.new;task.executableURL=[NSURL fileURLWithPath:NSProcessInfo.processInfo.arguments[0]];task.arguments=@[scenario,suite];NSError *error=nil;assert([task launchAndReturnError:&error]);[task waitUntilExit];if(task.terminationStatus!=0){fprintf(stderr,"native_download_quality FAIL %s\n",scenario.UTF8String);[cleanup removePersistentDomainForName:suite];return 1;}}[cleanup removePersistentDomainForName:suite];}
    puts("native_download_quality PASS (18 isolated process scenarios)");return 0;
}}
