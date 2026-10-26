#import <Foundation/Foundation.h>
#import "ArtistDownloadQueue.h"
#import "TrackDownload.h"
#import "WireProto.h"
#include <assert.h>

static NSUInteger preparationCalls, containsCalls, libraryAddCalls, offlineAddCalls, contextCalls;
static NSUInteger readCancellationCalls;
static BOOL preparationIsPending, containsIsPending, contextIsPending;
static BOOL saveChangesMembership;
static void (^pendingPreparation)(BOOL, NSString *);
static BOOL (^pendingRequested)(void);
static NSMutableDictionary<NSString *, NSNumber *> *libraryMembership;
static NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *contextSequences;
static NSMutableDictionary<NSString *, NSNumber *> *contextReadCounts;
static NSMutableArray<NSString *> *events;
static NSMutableArray<NSDictionary *> *libraryCheckNotes;
static NSMutableArray<NSDictionary *> *progressSnapshots;
static NSDictionary *lastProgress;
static NSData *containsResponseOverride, *contextResponseOverride;
static NSString *contextError, *containsError, *libraryAddError, *offlineAddError;
static NSString *containsEntityURIOverride;
static NSString *containsPendingURI;
static NSArray<NSString *> *pendingContextURIs;
static uint64_t containsStatus, libraryAddStatus, offlineAddCode;
static BOOL containsStatusPresent;

@interface FakeRead : NSObject
@property(nonatomic) BOOL cancelled, delivered;
@property(nonatomic,copy) void (^reply)(NSData *, NSString *);
- (void)deliver:(NSData *)data error:(NSString *)error;
@end
@implementation FakeRead
- (void)deliver:(NSData *)data error:(NSString *)error {
    if(self.cancelled || self.delivered)return;
    self.delivered=YES;if(self.reply)self.reply(data,error);
}
@end
static FakeRead *pendingContains, *pendingContexts;

static NSString *albumURI(NSUInteger n) { return [NSString stringWithFormat:@"spotify:album:%022lu", (unsigned long)n]; }
BOOL SAPIsAlbumURI(NSString *uri) {
    return [uri isKindOfClass:NSString.class] && [uri hasPrefix:@"spotify:album:"] && uri.length == 36;
}
void SAPPrepareNativeOffline(BOOL (^stillRequested)(void), void (^completion)(BOOL, NSString *)) {
    assert(NSThread.isMainThread); preparationCalls++;
    assert(stillRequested());
    if(preparationIsPending) {assert(!pendingPreparation);pendingPreparation=[completion copy];pendingRequested=[stillRequested copy];return;}
    dispatch_async(dispatch_get_main_queue(),^{completion(YES,nil);});
}
static NSString *requestURI(NSData *payload, unsigned fieldNumber) {
    NSArray *fields=SAPProtoFields(payload);assert(fields.count==1);
    NSDictionary *field=fields.firstObject;assert([field[@"number"]unsignedIntValue]==fieldNumber && [field[@"wire"]unsignedIntValue]==2);
    return [[NSString alloc]initWithData:field[@"value"] encoding:NSUTF8StringEncoding];
}
static NSArray<NSString *> *contextRequestURIs(NSData *payload) {
    NSArray *fields=SAPProtoFields(payload);assert(fields.count>=2);
    assert([fields[0][@"number"]unsignedIntValue]==1 && [fields[0][@"wire"]unsignedIntValue]==2);
    NSArray *policy=SAPProtoFields(fields[0][@"value"]);
    assert(policy.count==1 && [policy[0][@"number"]unsignedIntValue]==1 && SAPProtoNumber(policy,1,0)==1);
    NSMutableArray *uris=[NSMutableArray array];
    for(NSUInteger i=1;i<fields.count;i++) {
        NSDictionary *field=fields[i];assert([field[@"number"]unsignedIntValue]==3 && [field[@"wire"]unsignedIntValue]==2);
        NSString *uri=[[NSString alloc]initWithData:field[@"value"] encoding:NSUTF8StringEncoding];assert(SAPIsAlbumURI(uri));[uris addObject:uri];
    }
    return uris;
}
static NSData *libraryResponse(NSString *uri, NSString *entityURI, NSNumber *member,
                               BOOL statusPresent, uint64_t status, NSString *error) {
    NSMutableArray<NSData *> *parts=[NSMutableArray arrayWithObject:SAPProtoBytes(1,[NSData data])];
    if(member) {
        NSMutableData *entity=[NSMutableData data];[entity appendData:SAPProtoBytes(1,[(entityURI?:uri)dataUsingEncoding:NSUTF8StringEncoding])];
        if(member.boolValue)[entity appendData:SAPProtoInteger(2,1)];
        [parts addObject:SAPProtoBytes(2,entity)];
    }
    if(statusPresent)[parts addObject:SAPProtoInteger(98,status)];
    if(error.length)[parts addObject:SAPProtoBytes(99,[error dataUsingEncoding:NSUTF8StringEncoding])];
    NSMutableData *response=[NSMutableData data];for(NSData *part in parts)[response appendData:part];return response;
}
static NSData *contextState(NSString *uri, unsigned state) {
    NSMutableData *context=[NSMutableData data];
    [context appendData:SAPProtoBytes(1,[uri dataUsingEncoding:NSUTF8StringEncoding])];
    [context appendData:SAPProtoInteger(2,state)];
    return SAPProtoBytes(1,SAPProtoBytes(1,context));
}
static NSData *contextResponse(NSArray<NSString *> *uris) {
    if(contextResponseOverride)return contextResponseOverride;
    NSMutableData *response=[NSMutableData data];
    for(NSString *uri in uris) {
        NSUInteger count=[contextReadCounts[uri]unsignedIntegerValue]+1;contextReadCounts[uri]=@(count);
        NSArray<NSNumber *> *sequence=contextSequences[uri];
        unsigned state=sequence.count?sequence[MIN(count-1,sequence.count-1)].unsignedIntValue:2;
        [response appendData:contextState(uri,state)];
    }
    return response;
}
static dispatch_block_t pendingRead(FakeRead *request) {
    return ^{if(!request.cancelled){request.cancelled=YES;readCancellationCalls++;}};
}
dispatch_block_t SAPCallReadOnlyServiceCancellable(NSString *service, NSString *method, NSData *payload,
                                                   void (^completion)(NSData *, NSString *)) {
    assert(NSThread.isMainThread);
    FakeRead *request=[FakeRead new];request.reply=[completion copy];
    NSData *response=nil;NSString *error=nil;
    if([service isEqual:@"spotify.your_library_esperanto.proto.YourLibraryService"] && [method isEqual:@"Contains"]) {
        NSString *uri=requestURI(payload,3);assert(SAPIsAlbumURI(uri));containsCalls++;
        [events addObject:[@"contains:" stringByAppendingString:uri]];
        NSNumber *member=containsError.length||!containsStatusPresent||containsStatus!=200?nil:libraryMembership[uri];
        response=containsResponseOverride;containsResponseOverride=nil;
        if(!response)response=libraryResponse(uri,containsEntityURIOverride,member?:@NO,containsStatusPresent,containsStatus,containsError);
        error=containsError;
        if(containsIsPending || [uri isEqual:containsPendingURI]){assert(!pendingContains);pendingContains=request;}
        else dispatch_async(dispatch_get_main_queue(),^{[request deliver:response error:error];});
    } else {
        assert([service isEqual:@"spotify.offline_esperanto.proto.Offline"] && [method isEqual:@"GetContexts"]);
        NSArray<NSString *> *uris=contextRequestURIs(payload);contextCalls++;
        [events addObject:[NSString stringWithFormat:@"contexts:%@",[uris componentsJoinedByString:@","]]];
        // Capture per-URI state at send time, as the native transport would.
        response=contextResponse(uris);error=contextError;
        if(contextIsPending){assert(!pendingContexts);pendingContexts=request;pendingContextURIs=uris;}
        else dispatch_async(dispatch_get_main_queue(),^{[request deliver:response error:error];});
    }
    return pendingRead(request);
}
void SAPCallReadOnlyService(NSString *service, NSString *method, NSData *payload,
                            void (^completion)(NSData *, NSString *)) {
    (void)SAPCallReadOnlyServiceCancellable(service,method,payload,completion);
}
void SAPAddAlbumToLibraryOnce(NSString *uri, void (^completion)(NSData *, NSString *)) {
    assert(NSThread.isMainThread && SAPIsAlbumURI(uri));libraryAddCalls++;
    [events addObject:[@"library-add:" stringByAppendingString:uri]];
    if(saveChangesMembership)libraryMembership[uri]=@YES;
    NSData *response=[NSData data];
    if(libraryAddStatus||libraryAddError.length) {
        NSMutableData *status=[NSMutableData data];if(libraryAddStatus)[status appendData:SAPProtoInteger(1,libraryAddStatus)];
        if(libraryAddError.length)[status appendData:SAPProtoBytes(2,[libraryAddError dataUsingEncoding:NSUTF8StringEncoding])];
        response=SAPProtoBytes(1,status);
    }
    NSString *error=libraryAddError;
    dispatch_async(dispatch_get_main_queue(),^{completion(response,error);});
}
void SAPCallOfflineCommandOnce(NSString *method, NSData *payload, void (^completion)(NSData *, NSString *)) {
    assert(NSThread.isMainThread && [method isEqual:@"AddDownload"]);
    NSString *uri=requestURI(payload,2);assert(SAPIsAlbumURI(uri));offlineAddCalls++;
    [events addObject:[@"offline-add:" stringByAppendingString:uri]];
    NSData *response=offlineAddCode?SAPProtoInteger(1,offlineAddCode):[NSData data];NSString *error=offlineAddError;
    dispatch_async(dispatch_get_main_queue(),^{completion(response,error);});
}
void SAPJournalNoteAction(NSString *name, NSDictionary *facts) {
    if([name isEqual:@"artist_release_library_check"])[libraryCheckNotes addObject:facts];
}
static void progress(NSDictionary *snapshot) {
    assert(NSThread.isMainThread);lastProgress=snapshot;[progressSnapshots addObject:snapshot];
}
static void waitFor(BOOL (^ready)(void)) {
    NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:3];
    while(!ready() && deadline.timeIntervalSinceNow>0)[NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.001]];
    assert(ready());
}
static void pump(double seconds) {
    NSDate *until=[NSDate dateWithTimeIntervalSinceNow:seconds];while(until.timeIntervalSinceNow>0)[NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:.002]];
}
static void awaitFinished(void) {waitFor(^BOOL{return [lastProgress[@"finished"]boolValue];});}
static void resetFixture(void) {
    SAPStopAddingArtistReleases();
    preparationCalls=containsCalls=libraryAddCalls=offlineAddCalls=contextCalls=readCancellationCalls=0;
    preparationIsPending=containsIsPending=contextIsPending=NO;saveChangesMembership=YES;
    pendingPreparation=nil;pendingRequested=nil;pendingContains=nil;pendingContexts=nil;pendingContextURIs=nil;containsPendingURI=nil;
    libraryMembership=[NSMutableDictionary dictionary];contextSequences=[NSMutableDictionary dictionary];contextReadCounts=[NSMutableDictionary dictionary];
    events=[NSMutableArray array];libraryCheckNotes=[NSMutableArray array];progressSnapshots=[NSMutableArray array];lastProgress=nil;
    containsResponseOverride=nil;contextResponseOverride=nil;contextError=nil;containsError=nil;libraryAddError=nil;offlineAddError=nil;
    containsEntityURIOverride=nil;containsStatus=200;containsStatusPresent=YES;libraryAddStatus=offlineAddCode=0;
}
static NSDictionary *release(NSString *uri) {return @{@"uri":uri,@"name":@"Fixture album"};}
static void start(NSArray *releases) {
    NSString *error=nil;assert(SAPStartArtistReleaseDownloads(releases,^(NSDictionary *snapshot){progress(snapshot);},&error));assert(!error);
}
static void assertOutcome(NSString *outcome, NSUInteger count) {
    assert([lastProgress[outcome]unsignedIntegerValue]==count);
    assert([lastProgress[@"completed_downloads_confirmed"]isEqual:@NO]);
}
static void resolvePreparation(BOOL ready, NSString *error) {
    void (^reply)(BOOL,NSString *)=pendingPreparation;pendingPreparation=nil;pendingRequested=nil;assert(reply);dispatch_async(dispatch_get_main_queue(),^{reply(ready,error);});
}
static void resolveContains(NSString *uri, BOOL member, BOOL statusPresent, uint64_t status, NSString *error) {
    FakeRead *request=pendingContains;pendingContains=nil;assert(request);
    NSData *data=libraryResponse(uri,nil,@(member),statusPresent,status,error);
    dispatch_async(dispatch_get_main_queue(),^{[request deliver:data error:error];});
}
static void resolveContextsState(unsigned state) {
    FakeRead *request=pendingContexts;pendingContexts=nil;assert(request);
    NSArray *uris=pendingContextURIs;pendingContextURIs=nil;NSMutableData *data=[NSMutableData data];
    for(NSString *uri in uris)[data appendData:contextState(uri,state)];
    dispatch_async(dispatch_get_main_queue(),^{[request deliver:data error:nil];});
}
static void resolveContexts(void) { resolveContextsState(2); }
static void testSaveBeforeDownloadAndWireFields(void) {
    resetFixture();start(@[release(albumURI(1))]);awaitFinished();
    assert(preparationCalls==1 && containsCalls==2 && libraryAddCalls==1 && offlineAddCalls==1 && contextCalls>=1);
    assert([events[0]hasPrefix:@"contains:"] && [events[1]hasPrefix:@"library-add:"] && [events[2]hasPrefix:@"contains:"] && [events[3]hasPrefix:@"offline-add:"]);
    assertOutcome(@"accepted",1);
}
static NSData *observedLog23ContainsResponse(void) {
    static const uint8_t bytes[]={0x0a,0x00,0x12,0x26,0x0a,0x24,'s','p','o','t','i','f','y',':','a','l','b','u','m',':','6','K','B','J','A','x','M','X','D','V','T','b','i','i','d','1','q','M','M','Z','F','N',0x90,0x06,0xc8,0x01};
    return [NSData dataWithBytes:bytes length:sizeof(bytes)];
}
static void testObservedStatus200FalseWireFixture(void) {
    resetFixture();NSString *uri=@"spotify:album:6KBJAxMXDVTbiid1qMMZFN";containsResponseOverride=observedLog23ContainsResponse();
    assert(containsResponseOverride.length==46);start(@[release(uri)]);awaitFinished();
    assert(containsCalls==2 && libraryAddCalls==1 && offlineAddCalls==1 && contextCalls>=1);
    assert([libraryCheckNotes[0][@"status_code"]isEqual:@200] && [libraryCheckNotes[0][@"status_success"]isEqual:@YES]);
    assert([libraryCheckNotes[0][@"matched_entity"]isEqual:@YES] && [libraryCheckNotes[0][@"in_library"]isEqual:@NO]);assertOutcome(@"accepted",1);
}
static void testAlreadySavedSkipsLibraryAdd(void) {
    resetFixture();libraryMembership[albumURI(1)]=@YES;start(@[release(albumURI(1))]);awaitFinished();
    assert(containsCalls==1 && libraryAddCalls==0 && offlineAddCalls==1 && contextCalls>=1);assertOutcome(@"accepted",1);
}
static void testLibraryReadFailuresDoNotMutate(void) {
    for(NSNumber *status in @[@0,@403]) {resetFixture();containsStatus=status.unsignedLongLongValue;start(@[release(albumURI(1))]);awaitFinished();
        assert(containsCalls==1 && libraryAddCalls==0 && offlineAddCalls==0 && contextCalls==0);assertOutcome(@"unconfirmed",1);}
    resetFixture();containsStatusPresent=NO;start(@[release(albumURI(1))]);awaitFinished();assert(libraryAddCalls==0 && offlineAddCalls==0);
    resetFixture();containsEntityURIOverride=albumURI(2);start(@[release(albumURI(1))]);awaitFinished();assert(libraryAddCalls==0 && offlineAddCalls==0);
    resetFixture();containsResponseOverride=[NSData dataWithBytes:(uint8_t[]){0x0a,0x05,0x00} length:3];start(@[release(albumURI(1))]);awaitFinished();assert(libraryAddCalls==0 && offlineAddCalls==0);
    resetFixture();containsError=@"transport error";start(@[release(albumURI(1))]);awaitFinished();assert(libraryAddCalls==0 && offlineAddCalls==0);
}
static void testLibraryReadbackRetriesAreBoundedAndNoMutationReplay(void) {
    resetFixture();saveChangesMembership=NO;start(@[release(albumURI(1))]);awaitFinished();
    assert(containsCalls>=2 && containsCalls<20 && libraryAddCalls==1 && offlineAddCalls==0 && contextCalls==0);assertOutcome(@"unconfirmed",1);
    resetFixture();libraryAddError=@"reply timeout";start(@[release(albumURI(1))]);awaitFinished();
    assert(containsCalls>=2 && libraryAddCalls==1 && offlineAddCalls==1 && contextCalls>=1);assertOutcome(@"accepted",1);
}
static void testContextPollingBeyondThreeAndSameResultSlot(void) {
    resetFixture();NSString *uri=albumURI(1);contextSequences[uri]=@[@0,@0,@0,@0,@0,@5];
    start(@[release(uri)]);awaitFinished();
    assert(contextCalls>=6 && [contextReadCounts[uri]unsignedIntegerValue]>=6 && offlineAddCalls==1);
    assert([lastProgress[@"results"]count]==1);assertOutcome(@"accepted",1);
    BOOL sawPending=NO;for(NSDictionary *snapshot in progressSnapshots) {
        NSArray *results=snapshot[@"results"];
        if(results.count==1 && [results[0][@"outcome"]isEqual:@"pending"])sawPending=YES;
    }
    assert(sawPending && [lastProgress[@"results"][0][@"outcome"]isEqual:@"accepted"]);
    NSUInteger snapshots=[progressSnapshots count],reads=contextCalls;NSString *lastOutcome=lastProgress[@"results"][0][@"outcome"];
    assert([lastOutcome isEqual:@"accepted"]);pump(.06);assert(contextCalls==reads && progressSnapshots.count==snapshots);
}
static void testSecondAlbumSubmitsWhileFirstObservationPendingAndBatchesReads(void) {
    resetFixture();NSString *a=albumURI(1),*b=albumURI(2);libraryMembership[a]=@YES;libraryMembership[b]=@YES;contextIsPending=YES;containsPendingURI=b;
    start(@[release(a),release(b)]);waitFor(^BOOL{return pendingContexts!=nil && pendingContains!=nil;});
    assert(offlineAddCalls==1 && contextCalls==1);
    resolveContains(b,YES,YES,200,nil);waitFor(^BOOL{return offlineAddCalls==2 && [lastProgress[@"pending"]unsignedIntegerValue]==2;});
    assert(contextCalls==1 && pendingContexts!=nil);
    contextIsPending=NO;resolveContextsState(0);
    awaitFinished();assert(offlineAddCalls==2 && contextCalls>=2 && [lastProgress[@"results"]count]==2);assertOutcome(@"accepted",2);
    BOOL batched=NO;for(NSString *event in events)if([event containsString:@"," ])batched=YES;assert(batched);
}
static void testPermanentZeroTimesOutAndStopsAllReads(void) {
    resetFixture();contextSequences[albumURI(1)]=@[@0];start(@[release(albumURI(1))]);awaitFinished();
    assert(offlineAddCalls==1 && contextCalls>=5 && [contextReadCounts[albumURI(1)]unsignedIntegerValue]==contextCalls);
    assertOutcome(@"unconfirmed",1);NSUInteger reads=contextCalls,snapshots=progressSnapshots.count;NSArray *results=[lastProgress[@"results"]copy];pump(.08);
    assert(contextCalls==reads && progressSnapshots.count==snapshots && [lastProgress[@"results"]isEqual:results]);
}
static void testEmptyContextReplyTimesOutAndExplicitErrorRejects(void) {
    resetFixture();libraryMembership[albumURI(1)]=@YES;contextResponseOverride=[NSData data];
    start(@[release(albumURI(1))]);awaitFinished();assert(contextCalls>=5 && offlineAddCalls==1);assertOutcome(@"unconfirmed",1);
    resetFixture();libraryMembership[albumURI(1)]=@YES;contextSequences[albumURI(1)]=@[@1];
    start(@[release(albumURI(1))]);awaitFinished();assert(contextCalls==1 && offlineAddCalls==1);assertOutcome(@"rejected",1);
}
static void testHeldContextReadCanceledAtDeadlineAndLateReplyIgnored(void) {
    resetFixture();libraryMembership[albumURI(1)]=@YES;contextIsPending=YES;start(@[release(albumURI(1))]);
    waitFor(^BOOL{return pendingContexts!=nil;});FakeRead *held=pendingContexts;awaitFinished();
    assert(held.cancelled && readCancellationCalls>=1 && offlineAddCalls==1 && contextCalls==1);assertOutcome(@"unconfirmed",1);
    NSUInteger reads=contextCalls,snapshots=progressSnapshots.count;resolveContexts();pump(.08);
    assert(contextCalls==reads && progressSnapshots.count==snapshots && [lastProgress[@"results"]count]==1);
}
static void testOfflineErrorAndEmptyRepliesAreObservedWithoutReplay(void) {
    resetFixture();libraryMembership[albumURI(1)]=@YES;offlineAddCode=9;start(@[release(albumURI(1))]);awaitFinished();
    assert(offlineAddCalls==1 && contextCalls==0);assertOutcome(@"rejected",1);
    resetFixture();libraryMembership[albumURI(1)]=@YES;offlineAddError=@"timeout";start(@[release(albumURI(1))]);awaitFinished();
    assert(offlineAddCalls==1 && contextCalls>=1);assertOutcome(@"accepted",1);
}
static void testStopCancelsHeldReadAndLateReplyCannotRestart(void) {
    resetFixture();libraryMembership[albumURI(1)]=@YES;contextIsPending=YES;start(@[release(albumURI(1))]);waitFor(^BOOL{return pendingContexts!=nil;});
    FakeRead *held=pendingContexts;SAPStopAddingArtistReleases();awaitFinished();assert(held.cancelled && readCancellationCalls>=1);
    NSUInteger reads=contextCalls,snapshots=progressSnapshots.count;resolveContexts();pump(.06);assert(contextCalls==reads && progressSnapshots.count==snapshots);
}
static void testStopBeforePreparationAndPreflightRead(void) {
    resetFixture();preparationIsPending=YES;start(@[release(albumURI(1))]);assert(pendingPreparation && pendingRequested);
    SAPStopAddingArtistReleases();awaitFinished();assert(!pendingRequested());resolvePreparation(YES,nil);pump(.04);
    assert(containsCalls==0 && libraryAddCalls==0 && offlineAddCalls==0 && contextCalls==0);

    resetFixture();containsIsPending=YES;start(@[release(albumURI(1))]);waitFor(^BOOL{return pendingContains!=nil;});
    FakeRead *held=pendingContains;SAPStopAddingArtistReleases();awaitFinished();assert(held.cancelled);
    resolveContains(albumURI(1),NO,YES,200,nil);pump(.04);assert(libraryAddCalls==0 && offlineAddCalls==0 && contextCalls==0);
}
static void testStopDuringLibraryRetryAndRestartFreshBatch(void) {
    resetFixture();saveChangesMembership=NO;start(@[release(albumURI(1))]);waitFor(^BOOL{return containsCalls>=2;});
    NSUInteger seen=containsCalls;SAPStopAddingArtistReleases();awaitFinished();pump(.05);assert(containsCalls==seen && offlineAddCalls==0);
    resetFixture();libraryMembership[albumURI(2)]=@YES;start(@[release(albumURI(2))]);awaitFinished();assertOutcome(@"accepted",1);assert([lastProgress[@"results"][0][@"uri"]isEqual:albumURI(2)]);
}
static void testBatchDeadlineCancelsStalledPreparation(void) {
    resetFixture();preparationIsPending=YES;start(@[release(albumURI(1))]);assert(pendingPreparation);awaitFinished();
    assert(containsCalls==0 && libraryAddCalls==0 && offlineAddCalls==0 && contextCalls==0);
    NSUInteger snapshots=progressSnapshots.count;resolvePreparation(YES,nil);pump(.06);assert(containsCalls==0 && progressSnapshots.count==snapshots);
}
static void testPreparationAndConcurrentDedup(void) {
    resetFixture();preparationIsPending=YES;start(@[release(albumURI(1)),release(albumURI(1)),release(albumURI(2))]);
    assert(preparationCalls==1 && containsCalls==0);NSString *error=nil;
    assert(!SAPStartArtistReleaseDownloads(@[release(albumURI(3))],^(NSDictionary *snapshot){progress(snapshot);},&error));
    assert([error containsString:@"Another selection"] && preparationCalls==1);resolvePreparation(YES,nil);awaitFinished();
    assert(preparationCalls==1 && libraryAddCalls==2 && offlineAddCalls==2);
    assert([lastProgress[@"total"]unsignedIntegerValue]==2 && [lastProgress[@"submitted"]unsignedIntegerValue]==2);
}

int main(void) {@autoreleasepool {
    resetFixture();testSaveBeforeDownloadAndWireFields();testObservedStatus200FalseWireFixture();testAlreadySavedSkipsLibraryAdd();
    testLibraryReadFailuresDoNotMutate();testLibraryReadbackRetriesAreBoundedAndNoMutationReplay();
    testContextPollingBeyondThreeAndSameResultSlot();testSecondAlbumSubmitsWhileFirstObservationPendingAndBatchesReads();
    testPermanentZeroTimesOutAndStopsAllReads();testEmptyContextReplyTimesOutAndExplicitErrorRejects();testHeldContextReadCanceledAtDeadlineAndLateReplyIgnored();
    testOfflineErrorAndEmptyRepliesAreObservedWithoutReplay();testStopCancelsHeldReadAndLateReplyCannotRestart();
    testStopBeforePreparationAndPreflightRead();testStopDuringLibraryRetryAndRestartFreshBatch();
    testBatchDeadlineCancelsStalledPreparation();testPreparationAndConcurrentDedup();
    puts("PASS: cancellable library-first artist queue, batched bounded context observation, cancellation, timeouts, and single-shot mutations");return 0;
}}
