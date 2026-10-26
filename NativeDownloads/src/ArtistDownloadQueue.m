#import "ArtistDownloadQueue.h"
#import "ArtistMetadata.h"
#import "NativeOffline.h"
#import "TrackDownload.h"
#import "TrackJournal.h"
#import "WireProto.h"
#import "Deadline.h"
#include <float.h>

#ifdef SAP_TESTING
static double confirmationTimeout=.18,libraryTimeout=.12,batchTimeout=2,pollInterval=.015,firstPollDelay=.005;
#else
static const double confirmationTimeout=120,libraryTimeout=30,batchTimeout=900,pollInterval=2,firstPollDelay=.25;
#endif
static double now(void) {return NSProcessInfo.processInfo.systemUptime;}
static void cancelTimer(dispatch_source_t timer) {if(timer)dispatch_source_cancel(timer);}

@interface SAPArtistPendingRelease : NSObject
@property(nonatomic,copy) NSDictionary *releaseInfo;
@property(nonatomic) double deadline;
@property(nonatomic) NSUInteger attempts;
@property(nonatomic,strong) NSNumber *state;
@property(nonatomic,copy) NSString *error;
@end
@implementation SAPArtistPendingRelease @end

@interface SAPArtistReleaseBatch : NSObject
@property(nonatomic,copy) NSArray *releases;
@property(nonatomic,strong) NSMutableArray *results;
@property(nonatomic,strong) NSMutableDictionary *resultIndexes,*pending;
@property(nonatomic,strong) NSMutableArray *observationQueue;
@property(nonatomic,copy) void (^progress)(NSDictionary *);
@property(nonatomic,copy) dispatch_block_t cancelSubmissionRead,cancelObservation;
@property(nonatomic,strong) dispatch_source_t observationWake,submissionWake,deadline;
@property(nonatomic) NSUInteger next,downloadSubmissions;
@property(nonatomic) NSUInteger observationGeneration,submissionGeneration;
@property(nonatomic) BOOL finished,prepared,submissionBusy,observing;
// Native preparation reads cancellation on Spotify's scheduler queue.
@property(atomic) BOOL stopped;
@property(nonatomic,copy) NSString *failure;
- (void)submitNext;
- (void)publish;
- (void)finish:(NSString *)reason;
- (void)maybeFinish;
- (void)observe;
- (void)observeNextChunk;
- (void)armObservation:(double)delay;
- (void)cancelObservationWake;
- (void)cancelSubmissionWake;
- (void)setResult:(NSDictionary *)release outcome:(NSString *)outcome state:(NSNumber *)state detail:(NSString *)detail;
- (void)readLibrary:(NSDictionary *)release completion:(void (^)(NSNumber *,NSString *))completion;
- (void)saveRelease:(NSDictionary *)release;
- (void)verifyLibrary:(NSDictionary *)release deadline:(double)deadline attempt:(NSUInteger)attempt;
- (void)requestDownload:(NSDictionary *)release;
@end
static SAPArtistReleaseBatch *activeBatch;
@implementation SAPArtistReleaseBatch
- (void)cancelObservationWake {
    self.observationGeneration++;cancelTimer(self.observationWake);self.observationWake=nil;
}
- (void)cancelSubmissionWake {
    self.submissionGeneration++;cancelTimer(self.submissionWake);self.submissionWake=nil;
}
- (void)publish {
    NSUInteger accepted=0,rejected=0,unconfirmed=0;
    for(NSDictionary *result in self.results) {
        accepted+=[result[@"outcome"]isEqual:@"accepted"];
        rejected+=[result[@"outcome"]isEqual:@"rejected"];
        unconfirmed+=[result[@"outcome"]isEqual:@"unconfirmed"];
    }
    NSString *phase=self.finished?@"finished":!self.prepared?@"preparing":self.submissionBusy||self.next<self.releases.count?@"adding":@"checking";
    NSDictionary *snapshot=@{@"total":@(self.releases.count),@"submitted":@(self.downloadSubmissions),@"processed":@(self.results.count),
        @"accepted":@(accepted),@"rejected":@(rejected),@"unconfirmed":@(unconfirmed),@"pending":@(self.pending.count),@"phase":phase,
        @"finished":@(self.finished),@"stopped":@(self.stopped),@"error":self.failure?:@"",
        @"results":[self.results copy],@"completed_downloads_confirmed":@NO};
    if(self.progress)self.progress(snapshot);
}
- (void)setResult:(NSDictionary *)release outcome:(NSString *)outcome state:(NSNumber *)state detail:(NSString *)detail {
    NSString *uri=release[@"uri"];
    NSDictionary *result=@{@"uri":uri,@"name":release[@"name"]?:uri,@"outcome":outcome,
        @"native_context_state":state?:NSNull.null,@"detail":detail,@"completion_checked":@NO};
    NSNumber *index=self.resultIndexes[uri];
    if(index)self.results[index.unsignedIntegerValue]=result;
    else {self.resultIndexes[uri]=@(self.results.count);[self.results addObject:result];}
    SAPJournalNoteAction([outcome isEqual:@"pending"]?@"artist_release_pending":@"artist_release_native_result",result);
}
- (void)finish:(NSString *)reason {
    if(self.finished)return;self.finished=YES;
    [self cancelObservationWake];[self cancelSubmissionWake];
    cancelTimer(self.deadline);self.deadline=nil;
    dispatch_block_t cancel=self.cancelSubmissionRead;self.cancelSubmissionRead=nil;if(cancel)cancel();
    cancel=self.cancelObservation;self.cancelObservation=nil;if(cancel)cancel();
    self.observing=NO;self.observationQueue=nil;
    for(SAPArtistPendingRelease *entry in self.pending.allValues)
        [self setResult:entry.releaseInfo outcome:@"unconfirmed" state:entry.state detail:reason?:@"Queue confirmation ended. Check download progress in Spotify."];
    [self.pending removeAllObjects];
    SAPJournalNoteAction(@"artist_batch_finished",@{@"reason":reason?:@"all_results_resolved",@"stopped":@(self.stopped),
        @"selected":@(self.releases.count),@"started":@(self.next),@"submitted":@(self.downloadSubmissions),
        @"observation_active":@NO,@"automatic_command_replay":@NO});
    if(activeBatch==self)activeBatch=nil;
    [self publish];self.progress=nil;
}
- (void)maybeFinish {
    if(self.finished)return;
    if(!self.pending.count) {
        [self cancelObservationWake];
        dispatch_block_t cancel=self.cancelObservation;self.cancelObservation=nil;if(cancel)cancel();
        self.observing=NO;self.observationQueue=nil;
        if(self.prepared && !self.submissionBusy && self.next>=self.releases.count) {[self finish:nil];return;}
    }
    [self publish];
}
- (void)armObservation:(double)delay {
    if(self.finished || !self.pending.count)return;
    double earliest=DBL_MAX;for(SAPArtistPendingRelease *entry in self.pending.allValues)earliest=MIN(earliest,entry.deadline);
    [self cancelObservationWake];NSUInteger generation=self.observationGeneration;
    __weak typeof(self) weak=self;
    self.observationWake=SAPScheduleDeadline(dispatch_get_main_queue(),MAX(0,MIN(delay,earliest-now())),^{
        typeof(self) batch=weak;if(!batch || batch.finished || batch.observationGeneration!=generation)return;batch.observationWake=nil;[batch observe];
    });
}
- (void)observe {
    if(self.finished)return;
    double time=now();
    for(SAPArtistPendingRelease *entry in self.pending.allValues)if(time>=entry.deadline) {
        [self.pending removeObjectForKey:entry.releaseInfo[@"uri"]];
        [self setResult:entry.releaseInfo outcome:@"unconfirmed" state:entry.state detail:@"Spotify did not confirm the album within 120 seconds. Checks stopped; no download command was replayed."];
    }
    [self maybeFinish];if(self.finished || !self.pending.count)return;
    // During an unanswered read the only wake-up is the next entry's deadline.
    // The transport owns its separate, cancellable per-endpoint timeout.
    if(self.observing) {[self armObservation:DBL_MAX];return;}
    self.observationQueue=[NSMutableArray array];
    for(NSDictionary *release in self.releases)if(self.pending[release[@"uri"]])[self.observationQueue addObject:release[@"uri"]];
    [self observeNextChunk];
}
- (void)observeNextChunk {
    if(self.finished || !self.pending.count)return;
    NSMutableArray *uris=[NSMutableArray array];
    while(self.observationQueue.count && uris.count<64) {
        NSString *uri=self.observationQueue.firstObject;[self.observationQueue removeObjectAtIndex:0];
        if(self.pending[uri])[uris addObject:uri];
    }
    if(!uris.count) {[self armObservation:pollInterval];return;}
    NSMutableData *query=[SAPProtoBytes(1,SAPProtoInteger(1,1))mutableCopy];
    for(NSString *uri in uris) {
        [query appendData:SAPProtoBytes(3,[uri dataUsingEncoding:NSUTF8StringEncoding])];
        SAPArtistPendingRelease *entry=self.pending[uri];entry.attempts++;
    }
    self.observing=YES;[self armObservation:DBL_MAX];
    self.cancelObservation=SAPCallReadOnlyServiceCancellable(@"spotify.offline_esperanto.proto.Offline",@"GetContexts",query,^(NSData *data,NSString *error){
        if(self.finished)return;
        self.cancelObservation=nil;self.observing=NO;
        [self cancelObservationWake];
        NSArray *envelope=data?SAPProtoFields(data):nil;NSMutableDictionary *states=[NSMutableDictionary dictionary];NSMutableSet *conflicts=[NSMutableSet set];
        for(NSDictionary *field in envelope) {
            if([field[@"number"]unsignedIntValue]!=1 || [field[@"wire"]unsignedIntValue]!=2)continue;
            NSArray *info=SAPProtoFields(field[@"value"]),*context=SAPProtoFields(SAPProtoData(info,1));
            NSString *uri=SAPProtoString(context,1);if(!uri || ![uris containsObject:uri])continue;
            NSNumber *state=@(SAPProtoNumber(context,2,0));
            if(states[uri] && ![states[uri]isEqual:state])[conflicts addObject:uri];else states[uri]=state;
        }
        double time=now();
        for(NSString *uri in uris) {
            SAPArtistPendingRelease *entry=self.pending[uri];if(!entry)continue;
            NSNumber *state=[conflicts containsObject:uri]?nil:states[uri];entry.state=state;entry.error=error;
            SAPJournalNoteAction(@"artist_release_context_check",@{@"album_uri":uri,@"attempt":@(entry.attempts),@"state":state?:NSNull.null,
                @"response_received":@(data!=nil),@"read_error":error?:@"",@"batch_read_count":@(uris.count),@"automatic_command_replay":@NO});
            if(time>=entry.deadline) {
                [self.pending removeObjectForKey:uri];
                [self setResult:entry.releaseInfo outcome:@"unconfirmed" state:state detail:@"Spotify did not confirm the album within 120 seconds. Checks stopped; no download command was replayed."];
            }else if(!error.length && state && state.unsignedIntValue>=2 && state.unsignedIntValue<=5) {
                [self.pending removeObjectForKey:uri];
                [self setResult:entry.releaseInfo outcome:@"accepted" state:state detail:state.unsignedIntValue==3?@"Spotify reports this album as downloaded.":@"Spotify confirmed this album in its native download queue."];
            }else if(!error.length && state && state.unsignedIntValue==1) {
                [self.pending removeObjectForKey:uri];
                [self setResult:entry.releaseInfo outcome:@"rejected" state:state detail:@"Spotify reports an error for this album's download context."];
            }
        }
        [self maybeFinish];if(self.finished || !self.pending.count)return;
        if(self.observationQueue.count)[self observeNextChunk];else[self armObservation:pollInterval];
    });
}
- (void)readLibrary:(NSDictionary *)release completion:(void (^)(NSNumber *,NSString *))completion {
    NSString *uri=release[@"uri"];
    self.cancelSubmissionRead=SAPCallReadOnlyServiceCancellable(@"spotify.your_library_esperanto.proto.YourLibraryService",@"Contains",SAPProtoBytes(3,[uri dataUsingEncoding:NSUTF8StringEncoding]),^(NSData *data,NSString *error){
        if(self.finished)return;self.cancelSubmissionRead=nil;
        NSArray *fields=data?SAPProtoFields(data):nil;uint64_t status=SAPProtoNumber(fields,98,UINT64_MAX);
        NSNumber *member=nil;BOOL conflict=NO,matchedEntity=NO;
        // YourLibrary uses HTTP-style status codes. A missing status is not success.
        if(fields && status==200)for(NSDictionary *field in fields) {
            if([field[@"number"]unsignedIntValue]!=2 || [field[@"wire"]unsignedIntValue]!=2)continue;
            NSArray *entity=SAPProtoFields(field[@"value"]);if(![SAPProtoString(entity,1)isEqual:uri])continue;
            matchedEntity=YES;uint64_t value=SAPProtoNumber(entity,2,0);
            if(value>1)conflict=YES;else {NSNumber *observed=@(value!=0);if(member && ![member isEqual:observed])conflict=YES;member=observed;}
        }
        NSString *failure=error?:SAPProtoString(fields,99);
        if(!failure.length && fields && status!=200)failure=status==UINT64_MAX?@"Spotify omitted the library response status.":[NSString stringWithFormat:@"Spotify returned library status %llu.",(unsigned long long)status];
        if(!failure.length && fields && status==200 && !matchedEntity)failure=@"Spotify did not return library membership for the requested album.";
        if(conflict)failure=@"Spotify returned conflicting library state for this album.";
        if(failure.length)member=nil;
        SAPJournalNoteAction(@"artist_release_library_check",@{@"album_uri":uri,@"status_code":status==UINT64_MAX?NSNull.null:@(status),@"status_success":@(status==200),@"matched_entity":@(matchedEntity),@"in_library":member?:NSNull.null,
            @"response_received":@(data!=nil),@"response_valid":@(fields!=nil),@"error":failure?:@""});
        if(completion)completion(member,failure.length?failure:member?nil:@"Spotify did not return a valid library state for this album.");
    });
}
- (void)saveRelease:(NSDictionary *)release {
    if(self.finished)return;
    NSString *uri=release[@"uri"];double until=now()+libraryTimeout;
    SAPJournalNoteAction(@"artist_release_library_add_requested",@{@"album_uri":uri,@"automatic_replay":@NO});
    SAPAddAlbumToLibraryOnce(uri,^(NSData *data,NSString *error){
        if(self.finished)return;
        NSArray *fields=data?SAPProtoFields(data):nil,*status=SAPProtoFields(SAPProtoData(fields,1));
        SAPJournalNoteAction(@"artist_release_library_add_reply",@{@"album_uri":uri,@"response_received":@(data!=nil),
            @"status_code":status?@(SAPProtoNumber(status,1,0)):NSNull.null,@"reason":SAPProtoString(status,2)?:@"",@"transport_error":error?:@"",@"automatic_replay":@NO});
        // Readback can confirm a save even when its mutation reply was lost.
        // The save command itself is never repeated.
        [self verifyLibrary:release deadline:until attempt:1];
    });
}
- (void)verifyLibrary:(NSDictionary *)release deadline:(double)until attempt:(NSUInteger)attempt {
    if(self.finished)return;
    if(now()>=until) {
        [self setResult:release outcome:@"unconfirmed" state:nil detail:@"Spotify did not confirm this album in Your Library within 30 seconds. Checks stopped; no download command was sent."];
        self.submissionBusy=NO;[self submitNext];return;
    }
    [self cancelSubmissionWake];NSUInteger generation=self.submissionGeneration;
    __weak typeof(self) weak=self;
    self.submissionWake=SAPScheduleDeadline(dispatch_get_main_queue(),until-now(),^{
        typeof(self) batch=weak;if(!batch || batch.finished || batch.submissionGeneration!=generation)return;batch.submissionWake=nil;
        dispatch_block_t cancel=batch.cancelSubmissionRead;batch.cancelSubmissionRead=nil;if(cancel)cancel();
        [batch setResult:release outcome:@"unconfirmed" state:nil detail:@"Spotify did not confirm this album in Your Library within 30 seconds. Checks stopped; no download command was sent."];
        batch.submissionBusy=NO;[batch submitNext];
    });
    [self readLibrary:release completion:^(NSNumber *member,NSString *error){
        if(self.finished)return;[self cancelSubmissionWake];
        if(now()>=until) {[self verifyLibrary:release deadline:until attempt:attempt];return;}
        if(member.boolValue) {[self requestDownload:release];return;}
#ifdef SAP_TESTING
        double delay=.01;
#else
        double delay=attempt==1?.5:attempt==2?1:attempt==3?2:5;
#endif
        NSUInteger retryGeneration=self.submissionGeneration;
        self.submissionWake=SAPScheduleDeadline(dispatch_get_main_queue(),MAX(0,MIN(delay,until-now())),^{
            typeof(self) batch=weak;if(!batch || batch.finished || batch.submissionGeneration!=retryGeneration)return;batch.submissionWake=nil;
            [batch verifyLibrary:release deadline:until attempt:attempt+1];
        });
    }];
}
- (void)requestDownload:(NSDictionary *)release {
    if(self.finished)return;
    NSString *uri=release[@"uri"];self.downloadSubmissions++;
    SAPArtistPendingRelease *entry=[SAPArtistPendingRelease new];entry.releaseInfo=release;entry.deadline=now()+confirmationTimeout;self.pending[uri]=entry;
    [self setResult:release outcome:@"pending" state:nil detail:@"Waiting for Spotify to confirm this album in its download queue."];
    SAPJournalNoteAction(@"artist_release_download_requested",@{@"album_uri":uri,@"library_membership_confirmed":@YES,@"automatic_replay":@NO});
    [self publish];if(!self.observationWake && !self.observing)[self armObservation:firstPollDelay];
    SAPCallOfflineCommandOnce(@"AddDownload",SAPProtoBytes(2,[uri dataUsingEncoding:NSUTF8StringEncoding]),^(NSData *data,NSString *error){
        if(self.finished)return;
        NSArray *fields=data?SAPProtoFields(data):nil;uint64_t code=SAPProtoNumber(fields,1,0);
        SAPJournalNoteAction(@"artist_release_download_reply",@{@"album_uri":uri,@"response_valid":@(fields!=nil),@"code":@(code),@"error":error?:@""});
        if(fields && code && self.pending[uri]) {
            [self.pending removeObjectForKey:uri];
            [self setResult:release outcome:@"rejected" state:nil detail:[NSString stringWithFormat:@"Spotify rejected the download request (code %llu).",(unsigned long long)code]];
            [self maybeFinish];
        }
        self.submissionBusy=NO;[self submitNext];
    });
}
- (void)submitNext {
    if(self.finished)return;
    if(self.next>=self.releases.count) {self.submissionBusy=NO;[self maybeFinish];return;}
    NSDictionary *release=self.releases[self.next++];self.submissionBusy=YES;[self publish];
    SAPJournalNoteAction(@"artist_release_library_preflight",@{@"album_uri":release[@"uri"]});
    [self readLibrary:release completion:^(NSNumber *member,NSString *error){
        if(self.finished)return;
        if(!member) {
            [self setResult:release outcome:@"unconfirmed" state:nil detail:error?:@"The album's library state could not be verified. No command was sent."];
            self.submissionBusy=NO;[self submitNext];return;
        }
        if(member.boolValue)[self requestDownload:release];else[self saveRelease:release];
    }];
}
@end
BOOL SAPStartArtistReleaseDownloads(NSArray<NSDictionary *> *releases,void (^progress)(NSDictionary *),NSString **error) {
    NSCAssert(NSThread.isMainThread,@"Artist selection is submitted on the main thread");
    if(activeBatch) {if(error)*error=@"Another selection is still being added or checked in Spotify. Wait for it to finish or stop checking.";return NO;}
    if(![releases isKindOfClass:NSArray.class] || !releases.count || releases.count>4096) {if(error)*error=@"Select at least one release.";return NO;}
    NSMutableArray *unique=[NSMutableArray array];NSMutableSet *seen=[NSMutableSet set];
    for(id release in releases) {
        if(![release isKindOfClass:NSDictionary.class] || !SAPIsAlbumURI(release[@"uri"])) {if(error)*error=@"The selection contains an invalid album identity.";return NO;}
        if(![seen containsObject:release[@"uri"]]) {[seen addObject:release[@"uri"]];[unique addObject:[release copy]];}
    }
    SAPArtistReleaseBatch *batch=[SAPArtistReleaseBatch new];batch.releases=[unique copy];batch.results=[NSMutableArray array];batch.resultIndexes=[NSMutableDictionary dictionary];batch.pending=[NSMutableDictionary dictionary];batch.progress=progress;activeBatch=batch;
    __weak SAPArtistReleaseBatch *weak=batch;
    batch.deadline=SAPScheduleDeadline(dispatch_get_main_queue(),batchTimeout,^{
        SAPArtistReleaseBatch *current=weak;if(!current || current.finished)return;current.deadline=nil;current.stopped=YES;
        current.failure=@"The selection reached its 15-minute time limit. No further requests will be sent.";
        [current finish:current.failure];
    });
    SAPJournalNoteAction(@"artist_batch_started",@{@"selected":@(unique.count),@"queue_confirmation_timeout_seconds":@120,@"library_confirmation_timeout_seconds":@30,@"batch_timeout_seconds":@900});
    [batch publish];
    SAPPrepareNativeOffline(^BOOL{return !batch.stopped;},^(BOOL ready,NSString *reason){
        if(batch.finished)return;
        if(!ready) {batch.failure=reason?:@"The native downloader is not ready.";[batch finish:batch.failure];return;}
        batch.prepared=YES;[batch submitNext];
    });
    return YES;
}
void SAPStopAddingArtistReleases(void) {
    NSCAssert(NSThread.isMainThread,@"Artist selection is changed on the main thread");
    SAPArtistReleaseBatch *batch=activeBatch;if(!batch || batch.finished)return;
    batch.stopped=YES;
    SAPJournalNoteAction(@"artist_batch_stop_requested",@{@"started":@(batch.next),@"submitted":@(batch.downloadSubmissions),@"pending":@(batch.pending.count),@"native_downloads_removed":@NO});
    [batch finish:@"Checking stopped. Downloads already accepted by Spotify may continue in Spotify."];
}
