#import "ArtistDownloadSession.h"
#import "ArtistMetadata.h"
#import "TrackDownload.h"
#import "TrackJournal.h"
#import "NativeOffline.h"
#import "WireProto.h"
#import "Deadline.h"
#include <math.h>

static NSString *const offlineService=@"spotify.offline_esperanto.proto.Offline";
static const NSUInteger inactiveStateCacheLimit=256;
#ifdef SAP_TESTING
static double workTimeoutSeconds=900;
static double repairTimeoutSeconds=30;
static double recoverySettleSeconds=2;
void SAPArtistSessionSetRecoverySettleForTesting(double seconds){recoverySettleSeconds=seconds;}
void SAPArtistSessionSetWorkTimeoutForTesting(double seconds){workTimeoutSeconds=seconds;}
void SAPArtistSessionSetRepairTimeoutForTesting(double seconds){repairTimeoutSeconds=seconds;}
#else
static const double workTimeoutSeconds=900;
static const double repairTimeoutSeconds=30;
static const double recoverySettleSeconds=2;
#endif
static NSArray *commandFields(NSData *data){
    NSArray *fields=SAPProtoFields(data);if(!fields)return nil;
    for(NSDictionary *field in fields)if([field[@"number"]unsignedIntValue]==1 && [field[@"wire"]unsignedIntValue]!=0)return nil;
    return fields;
}
static double clockNow(void) {return NSProcessInfo.processInfo.systemUptime;}
static double floatNumber(NSArray *fields,unsigned number) {
    for(NSDictionary *field in fields)if([field[@"number"]unsignedIntValue]==number && [field[@"wire"]unsignedIntValue]==5) {
        float value=0;NSData *data=field[@"value"];if(data.length==4)memcpy(&value,data.bytes,4);return isfinite(value)?value:0;
    }return 0;
}
static NSData *urisRequest(NSArray *uris,unsigned field) {
    NSMutableData *data=[NSMutableData data];for(NSString *uri in uris)[data appendData:SAPProtoBytes(field,[uri dataUsingEncoding:NSUTF8StringEncoding])];return data;
}
static NSData *contextRequest(NSArray *uris) {
    // State only: no track-list scan is needed for the native context state.
    NSMutableData *data=[SAPProtoBytes(1,SAPProtoInteger(1,0))mutableCopy];[data appendData:urisRequest(uris,3)];return data;
}
static NSNumber *exactContextState(NSData *data,NSString *uri) {
    NSArray *envelope=SAPProtoFields(data);if(!envelope)return nil;NSNumber *state=nil;
    for(NSDictionary *field in envelope){
        unsigned number=[field[@"number"]unsignedIntValue],wire=[field[@"wire"]unsignedIntValue];
        if(number==2 && (wire!=0 || [field[@"value"]unsignedLongLongValue]))return nil;
        if(number!=1)continue;if(wire!=2 || state)return nil;
        NSArray *entry=SAPProtoFields(field[@"value"]),*info=SAPProtoFields(SAPProtoData(entry,1));
        if(!entry || !info || ![SAPProtoString(info,1)isEqual:uri])return nil;
        NSUInteger stateFields=0;for(NSDictionary *part in info)if([part[@"number"]unsignedIntValue]==2){if([part[@"wire"]unsignedIntValue]!=0 || ++stateFields>1)return nil;}
        uint64_t code=SAPProtoNumber(info,2,0);if(code>5)return nil;state=@(code);
    }return state;
}
static BOOL activeNative(NSDictionary *state) {NSUInteger s=[state[@"native_state"]unsignedIntegerValue];return s==2 || s==4 || s==5;}
static BOOL validContextURI(NSString *uri){return SAPIsAlbumURI(uri) || SAPIsPlaylistURI(uri);}
static NSArray *contextCommandFields(NSData *data,NSString *uri,uint64_t *code){
    NSArray *fields=SAPIsPlaylistURI(uri)?SAPProtoFields(data):commandFields(data);
    if(SAPIsPlaylistURI(uri)){
        NSArray *status=SAPProtoFields(SAPProtoData(fields,1));if(!status || !SAPProtoNumber(status,1,0))return nil;
        uint64_t value=SAPProtoNumber(status,1,0);*code=value>=200&&value<300?0:value;
    }else *code=SAPProtoNumber(fields,1,0);
    return fields;
}
static void contextCommandWithDisposition(NSString *uri,BOOL enabled,void (^completion)(NSData *,NSString *,SAPCommandInvocationDisposition)){
    if(SAPIsPlaylistURI(uri))SAPSetPlaylistOfflineOnceWithDisposition(uri,enabled,completion);
    else SAPCallOfflineCommandOnceWithDisposition(enabled?@"AddDownload":@"RemoveDownload",SAPProtoBytes(2,[uri dataUsingEncoding:NSUTF8StringEncoding]),completion);
}
static void contextCommand(NSString *uri,BOOL enabled,void (^completion)(NSData *,NSString *)){
    contextCommandWithDisposition(uri,enabled,^(NSData *data,NSString *error,__unused SAPCommandInvocationDisposition disposition){completion(data,error);});
}
static id ownerKey(NSString *artist,NSString *token){return token.length?@[artist,token]:artist;}
static NSString *ownerArtist(id owner){return [owner isKindOfClass:NSArray.class]?[owner firstObject]:owner;}
static id releaseOwner(NSDictionary *release){
    NSString *artist=[release[@"artist_uri"]isKindOfClass:NSString.class]?release[@"artist_uri"]:nil;
    NSString *token=[release[@"owner_token"]isKindOfClass:NSString.class]?release[@"owner_token"]:nil;
    return artist.length?ownerKey(artist,token):(id)NSNull.null;
}

static NSComparisonResult compareQueueOrder(NSDictionary *a,NSDictionary *b){
    NSUInteger ar=[a[@"rank"]unsignedIntegerValue],br=[b[@"rank"]unsignedIntegerValue];
    if(ar!=br)return ar<br?NSOrderedAscending:NSOrderedDescending;
    NSUInteger ai=[a[@"ordinal"]unsignedIntegerValue],bi=[b[@"ordinal"]unsignedIntegerValue];
    return ai<bi?NSOrderedAscending:ai>bi?NSOrderedDescending:NSOrderedSame;
}


@class SAPArtistDownloadSession;
@interface SAPArtistAlbumOperation : NSObject
@property(nonatomic,weak) SAPArtistDownloadSession *session;
@property(nonatomic,strong) NSDictionary *item;
@property(nonatomic,copy) NSString *token;
@property(nonatomic,strong) NSDictionary *releaseGate;
@property(nonatomic,readonly) NSString *uri;
@property(nonatomic,copy) dispatch_block_t cancelRead;
@property(nonatomic,strong) dispatch_source_t retry,workDeadline;
@property(nonatomic) NSUInteger epoch,retryEpoch,workEpoch,readEpoch,sequence;
@property(nonatomic) BOOL downloadSent,stopped,commandPending,sawNativeActive,readyForDownload,hasTrustedCounts,paused,needsReadRepair,libraryAddSent;
@property(nonatomic) BOOL singlePairOccupied,playlistFeedOpen,discardStoppedIntent;
@property(nonatomic) BOOL countReadAttempted,completionReadAttempted;
@property(nonatomic) BOOL ownAddAcknowledged,recoveryAttempted,recoveryOwnZero;
@property(nonatomic,copy) NSString *recoveryStage;
@property(nonatomic,strong) dispatch_source_t recoveryTimer;
@property(nonatomic) NSUInteger recoveryEpoch;
- (BOOL)recoveryExclusive;
- (BOOL)recoveryEligible;
- (void)considerRecovery;
- (void)cancelRecoveryObservation;
- (void)haltRecovery:(NSString *)reason;
- (void)verifyRecoveryItems:(NSArray *)tracks offset:(NSUInteger)offset;
- (void)removeForRecovery;
- (void)confirmRecoveryZero;
@property(nonatomic) double libraryDeadline;
- (BOOL)isCurrent;
- (void)readService:(NSString *)service method:(NSString *)method payload:(NSData *)payload completion:(void (^)(NSData *,NSString *))completion;
- (void)cancel;
- (void)armWorkDeadline;
- (void)evaluate;
- (void)finish:(NSString *)error;
- (void)preflight;
- (void)readMembership:(NSUInteger)attempt until:(double)until;
- (void)requestDownload;
- (void)submitDownload;
- (void)resume;
- (void)reconcile;
@end

@interface SAPArtistDownloadSession : NSObject
@property(nonatomic,strong) NSMutableDictionary *states,*observers,*observerURIs,*initialCancels,*observedURIRefCounts,*initialReadURICounts,*initialReadURILists,*initialReadOwners,*observerArtists,*contextOwners,*artistContexts,*stopTokens,*stopReadCancels;
@property(nonatomic,strong) NSMutableDictionary<NSString *,SAPArtistAlbumOperation *> *operations;
@property(nonatomic,strong) SAPArtistAlbumOperation *lastSubmittedOperation;
@property(nonatomic,strong) NSMutableArray *queue,*watchCancels,*inactiveStateLRU;
@property(nonatomic,strong) NSMutableDictionary *stoppedItems,*readyItems,*externalWatchRefCounts,*batchTickets,*queueOrders,*leaseOrders;
@property(nonatomic,strong) NSMutableOrderedSet *stoppedOrder;
@property(nonatomic,strong) NSMutableSet *initialReads,*stopOperations,*stopSentURIs,*queuedURIs,*abandonedURIs,*forcedOfflineStops;
@property(nonatomic,copy) NSArray *watchURIs,*watchNativeURIs;
@property(nonatomic,copy) NSDictionary *watchOwners;
@property(nonatomic,strong) NSMutableOrderedSet *pendingCacheTouches;
@property(nonatomic,strong) dispatch_source_t watchDeadline;
@property(nonatomic,strong) dispatch_source_t repairDeadline;
@property(nonatomic,copy) dispatch_block_t cancelRepairRead;
@property(nonatomic,strong) NSMutableSet *watchPendingFirst;
@property(nonatomic) NSUInteger watchEpoch,stopBatchDepth,nextSequence,nextQueueRank;
@property(nonatomic) NSUInteger repairEpoch,repairAttempts,repairEpisodes;
@property(atomic) NSUInteger prepareEpoch;
@property(nonatomic) BOOL prepared,preparing,watchSuspended,filling,admitting;
@property(nonatomic) BOOL repairing,repairAwaitingStreams,watchNeedsRenewal,observationPaused;
@property(nonatomic,copy) NSString *error;
- (NSMutableDictionary *)stateFor:(NSString *)uri;
- (void)publish;
- (void)next;
- (void)enqueue:(NSDictionary *)item order:(NSDictionary *)order;
- (void)refreshQueuedURI:(NSString *)uri;
- (void)recordLease:(id)owner uri:(NSString *)uri order:(NSDictionary *)order;
- (NSUInteger)ticketOrdinal:(id)owner uri:(NSString *)uri;
- (NSUInteger)reserveTicket:(id)owner;
- (void)releaseTicket:(id)owner;
- (void)pumpAdmissions;
- (void)resumePausedOperationsExcept:(NSSet *)excluded;
- (void)startWatch;
- (NSArray *)desiredWatchURIs;
- (void)cancelWatch;
- (void)cancelRepair;
- (void)repairWatch:(NSString *)reason;
- (void)tryRepairWatch;
- (void)finishRepair;
- (void)suspendObservation:(NSString *)reason;
- (void)resumeObservation;
- (void)apply:(NSData *)data progress:(BOOL)progress;
- (void)apply:(NSData *)data progress:(BOOL)progress live:(BOOL)live;
- (void)apply:(NSData *)data progress:(BOOL)progress live:(BOOL)live owners:(NSDictionary *)owners;
- (void)stopURI:(NSString *)uri;
- (void)rememberStopped:(NSDictionary *)item;
- (void)refreshCacheTouches;
- (void)noteCacheTouch:(NSString *)uri;
- (void)trimInactiveStates;
- (void)registerOwner:(NSString *)artist uri:(NSString *)uri;
- (void)clearOwners:(NSString *)uri;
- (void)cancelInitialReads;
- (void)cancelInitialReadsForOwner:(NSString *)owner;
- (void)pauseWork:(NSString *)reason;
- (void)beginNativeStop:(NSString *)uri;
- (void)readStopURI:(NSString *)uri token:(NSString *)token completion:(void (^)(NSData *,NSString *))completion;
- (void)stopURIs:(NSSet<NSString *> *)uris;
@end
static SAPArtistDownloadSession *session;
@implementation SAPArtistDownloadSession
- (instancetype)init {
    if((self=[super init])) {_leaseOrders=[NSMutableDictionary dictionary];_batchTickets=[NSMutableDictionary dictionary];_queueOrders=[NSMutableDictionary dictionary];_externalWatchRefCounts=[NSMutableDictionary dictionary];_readyItems=[NSMutableDictionary dictionary];_stoppedItems=[NSMutableDictionary dictionary];_stoppedOrder=[NSMutableOrderedSet orderedSet];_states=[NSMutableDictionary dictionary];_observers=[NSMutableDictionary dictionary];_observerURIs=[NSMutableDictionary dictionary];_observedURIRefCounts=[NSMutableDictionary dictionary];_initialReadURICounts=[NSMutableDictionary dictionary];_initialReadURILists=[NSMutableDictionary dictionary];_initialReadOwners=[NSMutableDictionary dictionary];_observerArtists=[NSMutableDictionary dictionary];_contextOwners=[NSMutableDictionary dictionary];_artistContexts=[NSMutableDictionary dictionary];_abandonedURIs=[NSMutableSet set];_forcedOfflineStops=[NSMutableSet set];_pendingCacheTouches=[NSMutableOrderedSet orderedSet];_inactiveStateLRU=[NSMutableArray array];_queue=[NSMutableArray array];_watchCancels=[NSMutableArray array];_initialCancels=[NSMutableDictionary dictionary];_initialReads=[NSMutableSet set];_stopOperations=[NSMutableSet set];_stopSentURIs=[NSMutableSet set];_stopTokens=[NSMutableDictionary dictionary];_queuedURIs=[NSMutableSet set];_operations=[NSMutableDictionary dictionary];_stopReadCancels=[NSMutableDictionary dictionary];}return self;
}
- (void)enqueue:(NSDictionary *)item order:(NSDictionary *)order {
    NSString *uri=item[@"uri"];self.queueOrders[uri]=order;NSUInteger index=0;
    for(NSDictionary *queued in self.queue){if(compareQueueOrder(order,self.queueOrders[queued[@"uri"]])==NSOrderedAscending)break;index++;}
    [self.queue insertObject:[item copy] atIndex:index];
}
- (void)recordLease:(id)owner uri:(NSString *)uri order:(NSDictionary *)order {
    NSMutableDictionary *orders=self.leaseOrders[uri];if(!orders)self.leaseOrders[uri]=orders=[NSMutableDictionary dictionary];if(!orders[owner])orders[owner]=order;
}
- (void)refreshQueuedURI:(NSString *)uri {
    if(![self.queuedURIs containsObject:uri])return;
    NSUInteger index=[self.queue indexOfObjectPassingTest:^BOOL(NSDictionary *item,NSUInteger i,BOOL *stop){return [item[@"uri"]isEqual:uri];}];if(index==NSNotFound)return;
    NSMutableDictionary *ready=self.readyItems[uri];NSDictionary *item=self.queue[index],*readyOrder=nil;
    for(id owner in ready){NSDictionary *candidate=self.leaseOrders[uri][owner];if(!readyOrder || compareQueueOrder(candidate,readyOrder)==NSOrderedAscending){readyOrder=candidate;item=ready[owner];}}
    [self stateFor:uri][@"reserved"]=@(!ready.count);
    NSDictionary *order=nil;for(NSDictionary *candidate in [self.leaseOrders[uri]allValues])if(!order || compareQueueOrder(candidate,order)==NSOrderedAscending)order=candidate;
    // Removing a younger owner must not shift this release within its batch.
    if(!order || compareQueueOrder(order,self.queueOrders[uri])==NSOrderedSame){self.queue[index]=item;return;}
    [self.queue removeObjectAtIndex:index];[self enqueue:item order:order];
}
- (NSUInteger)ticketOrdinal:(id)owner uri:(NSString *)uri {
    NSMutableDictionary *ordinals=self.batchTickets[owner][@"ordinals"];
    NSNumber *ordinal=ordinals[uri];if(!ordinal)ordinals[uri]=ordinal=@(ordinals.count);return ordinal.unsignedIntegerValue;
}
- (NSUInteger)reserveTicket:(id)owner {
    NSDictionary *ticket=self.batchTickets[owner];
    if(ticket){if(!self.queueOrders[ticket[@"uri"]])[self enqueue:@{@"uri":ticket[@"uri"],@"reserved_batch_end":@YES} order:@{@"rank":ticket[@"rank"],@"ordinal":@(NSUIntegerMax)}];return [ticket[@"rank"]unsignedIntegerValue];}
    NSUInteger rank=++self.nextQueueRank;NSString *uri=[@"task-reservation:"stringByAppendingString:NSUUID.UUID.UUIDString];
    self.batchTickets[owner]=@{@"uri":uri,@"rank":@(rank),@"ordinals":[NSMutableDictionary dictionary]};
    [self enqueue:@{@"uri":uri,@"reserved_batch_end":@YES} order:@{@"rank":@(rank),@"ordinal":@(NSUIntegerMax)}];return rank;
}
- (void)releaseTicket:(id)owner {
    NSString *uri=self.batchTickets[owner][@"uri"];if(!uri)return;
    [self.queue filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *item,NSDictionary *bindings){return ![item[@"uri"]isEqual:uri];}]];
    [self.queueOrders removeObjectForKey:uri];[self.batchTickets removeObjectForKey:owner];
}
- (void)registerOwner:(id)artist uri:(NSString *)uri {
    if(![ownerArtist(artist) isKindOfClass:NSString.class] || ![ownerArtist(artist) length] || !validContextURI(uri))return;
    NSMutableSet *owners=self.contextOwners[uri];if(!owners)self.contextOwners[uri]=owners=[NSMutableSet set];[owners addObject:artist];
    NSMutableSet *contexts=self.artistContexts[artist];if(!contexts)self.artistContexts[artist]=contexts=[NSMutableSet set];[contexts addObject:uri];
}
- (void)clearOwners:(NSString *)uri {
    [self.readyItems removeObjectForKey:uri];[self.leaseOrders removeObjectForKey:uri];
    for(id artist in self.contextOwners[uri]){NSMutableSet *contexts=self.artistContexts[artist];[contexts removeObject:uri];if(!contexts.count)[self.artistContexts removeObjectForKey:artist];}[self.contextOwners removeObjectForKey:uri];
}
- (NSMutableDictionary *)stateFor:(NSString *)uri {
    NSMutableDictionary *state=self.states[uri];if(!state) {state=[NSMutableDictionary dictionary];self.states[uri]=state;}[self noteCacheTouch:uri];return state;
}
- (void)noteCacheTouch:(NSString *)uri {
    [self.pendingCacheTouches removeObject:uri];[self.pendingCacheTouches addObject:uri];
}
- (BOOL)isProtectedFromCache:(NSString *)uri {
    NSDictionary *raw=self.states[uri];
    if([self.queuedURIs containsObject:uri])return YES;
    if([self.observedURIRefCounts[uri]unsignedIntegerValue] || [self.initialReadURICounts[uri]unsignedIntegerValue] || [self.stopOperations containsObject:uri] || self.operations[uri]!=nil)return YES;
    return [raw[@"local_active"]boolValue] || activeNative(raw) || [raw[@"stopping"]boolValue];
}
- (void)refreshCacheTouches {
    for(NSString *uri in self.pendingCacheTouches) {
        [self.inactiveStateLRU removeObject:uri];
        if(self.states[uri] && ![self isProtectedFromCache:uri])[self.inactiveStateLRU addObject:uri];
    }
    [self.pendingCacheTouches removeAllObjects];
}
- (void)trimInactiveStates {
    [self refreshCacheTouches];
    while(self.inactiveStateLRU.count>inactiveStateCacheLimit) {
        NSString *uri=self.inactiveStateLRU.firstObject;[self.inactiveStateLRU removeObjectAtIndex:0];
        if(![self isProtectedFromCache:uri])[self.states removeObjectForKey:uri];
    }
}
- (void)cancelInitialReads {
    for(dispatch_block_t cancel in self.initialCancels.allValues)cancel();
    [self.initialCancels removeAllObjects];
    for(NSArray *uris in self.initialReadURILists.allValues)for(NSString *uri in uris) {
        NSUInteger count=[self.initialReadURICounts[uri]unsignedIntegerValue];
        if(count<=1)[self.initialReadURICounts removeObjectForKey:uri];else self.initialReadURICounts[uri]=@(count-1);
        [self noteCacheTouch:uri];
    }
    [self.initialReads removeAllObjects];
    [self.initialReadURILists removeAllObjects];[self.initialReadOwners removeAllObjects];
    [self trimInactiveStates];
}
- (void)cancelInitialReadsForOwner:(NSString *)owner {
    for(NSString *identifier in [self.initialReadOwners.allKeys copy])if([self.initialReadOwners[identifier]isEqual:owner]){
        dispatch_block_t cancel=self.initialCancels[identifier];[self finishInitialRead:identifier];if(cancel)cancel();
    }
}
- (void)finishInitialRead:(NSString *)identifier {
    NSArray *uris=self.initialReadURILists[identifier];if(!uris)return;
    [self.initialReads removeObject:identifier];[self.initialCancels removeObjectForKey:identifier];[self.initialReadOwners removeObjectForKey:identifier];
    for(NSString *uri in uris) {
        NSUInteger count=[self.initialReadURICounts[uri]unsignedIntegerValue];
        if(count<=1)[self.initialReadURICounts removeObjectForKey:uri];else self.initialReadURICounts[uri]=@(count-1);
        [self noteCacheTouch:uri];
    }
    [self.initialReadURILists removeObjectForKey:identifier];
}
- (NSDictionary *)publicState:(NSDictionary *)raw {
    BOOL full=[raw[@"native_state"]isEqual:@3] && ![raw[@"recovery_removal_pending"]boolValue];
    BOOL validTotals=[raw[@"totals_state"]unsignedIntegerValue]==2 && [raw[@"total"]unsignedIntegerValue]>0 && [raw[@"downloaded"]unsignedIntegerValue]<=[raw[@"total"]unsignedIntegerValue];
    double progress=validTotals?[raw[@"downloaded"]doubleValue]/[raw[@"total"]doubleValue]:[raw[@"percent"]doubleValue]/100.;
    BOOL active=[raw[@"local_active"]boolValue] || activeNative(raw) || [raw[@"stopping"]boolValue];
    NSString *phase=full?@"downloaded":[raw[@"stopping"]boolValue]?@"stopping":[raw[@"native_downloading"]boolValue]?@"downloading":raw[@"local_phase"];
    if([phase isEqual:@"idle"] && active)phase=@"waiting";
    if(!phase.length)phase=active?@"waiting":[raw[@"error"]length]?@"failed":@"idle";
    NSString *state=full?@"downloaded":progress>0 || active?@"partial":raw[@"native_state"]?@"not_downloaded":@"unknown";
    return @{@"state":state,@"phase":phase,@"active":@(active&&!full),@"stopping":raw[@"stopping"]?:@NO,@"progress":@(full?1:MIN(1,MAX(0,progress))),
        @"downloaded_tracks":validTotals?raw[@"downloaded"]:@0,@"total_tracks":validTotals?raw[@"total"]:@0,@"error":raw[@"error"]?:@"",
        @"native_cancelled":raw[@"native_cancelled"]?:@NO,@"native_ended":@([raw[@"native_cancelled"]boolValue] || [raw[@"native_state"]isEqual:@1]),@"reserved":raw[@"reserved"]?:@NO,@"native_downloading":raw[@"native_downloading"]?:@NO,@"queued_tracks":raw[@"queued_tracks"]?:@0,@"queued_bytes":raw[@"queued_bytes"]?:@0,@"downloaded_bytes":raw[@"downloaded_bytes"]?:@0};
}
- (void)publish {
    [self trimInactiveStates];
    BOOL globalActive=self.operations.count>0 || self.queue.count>0;
    if(!globalActive)for(NSDictionary *raw in self.states.allValues)if([[self publicState:raw][@"active"]boolValue]){globalActive=YES;break;}
    NSDictionary *observers=[self.observers copy],*observerURIs=[self.observerURIs copy];
    for(NSString *token in observers) {
        NSString *artist=self.observerArtists[token];BOOL hasOwner=NO;if(artist)for(id key in self.artistContexts)if([ownerArtist(key)isEqual:artist] && [self.artistContexts[key]count]){hasOwner=YES;break;}NSMutableDictionary *values=[NSMutableDictionary dictionary];BOOL active=NO,submitting=NO,resumable=NO;
        for(NSString *uri in observerURIs[token]) {
            NSDictionary *raw=self.states[uri];if(!raw)continue;NSMutableDictionary *value=[[self publicState:raw]mutableCopy];
            if([value[@"state"]isEqual:@"downloaded"]){[self.stoppedItems removeObjectForKey:uri];[self.stoppedOrder removeObject:uri];if(!self.operations[uri] && ![self.queuedURIs containsObject:uri])[self clearOwners:uri];}
            value[@"stop_pending"]=@(self.stopTokens[uri]!=nil || [self.stopOperations containsObject:uri] || (self.operations[uri] && self.operations[uri].stopped));
            if(self.stoppedItems[uri][@"stopped_visual"])value[@"stopped_visual"]=self.stoppedItems[uri][@"stopped_visual"];
            value[@"owned"]=@(self.operations[uri]!=nil);value[@"download_submitted"]=@(self.operations[uri].downloadSent);value[@"submission_pending"]=@(self.operations[uri].commandPending);
            value[@"can_continue"]=@(self.stoppedItems[uri]!=nil && (!artist || [self.contextOwners[uri]containsObject:artist]) && ![value[@"active"]boolValue] && !self.operations[uri] && ![self.stopOperations containsObject:uri]);values[uri]=value;resumable|=[value[@"can_continue"]boolValue];
            active|=[value[@"active"]boolValue];submitting|=[raw[@"local_active"]boolValue];
        }
        void (^observer)(NSDictionary *)=observers[token];
        observer(@{@"album_states":values,@"active":@(active),@"global_active":@(globalActive),@"can_continue":@(resumable),@"can_cancel":@(artist?hasOwner:active||resumable),@"submitting":@(submitting),@"error":self.error?:@""});
    }
    [self startWatch];
}
- (void)cancelWatch {
    if(self.watchCancels.count)SAPJournalNoteAction(@"artist_observation_watch_cancelled",@{@"generation":@(self.watchEpoch),@"streams":@(self.watchCancels.count),@"reason":self.watchSuspended?@"observation_suspended":@"no_pending_observation_work",@"queued_preserved":@(self.queue.count)});
    self.watchEpoch++;for(dispatch_block_t cancel in self.watchCancels)cancel();[self.watchCancels removeAllObjects];self.watchURIs=nil;self.watchNativeURIs=nil;self.watchOwners=nil;
    self.watchPendingFirst=nil;
    if(self.watchDeadline){dispatch_source_cancel(self.watchDeadline);self.watchDeadline=nil;}
}
- (void)cancelRepair {
    self.repairEpoch++;self.repairing=NO;self.repairAwaitingStreams=NO;
    if(self.cancelRepairRead){self.cancelRepairRead();self.cancelRepairRead=nil;}
    if(self.repairDeadline){dispatch_source_cancel(self.repairDeadline);self.repairDeadline=nil;}
}
- (void)suspendObservation:(NSString *)reason {
    [self cancelRepair];self.watchSuspended=YES;self.observationPaused=YES;self.error=reason;
    // Preserve unsent selections and uncertain native reservations. Pausing
    // observation must not invalidate a pending mutation's completion epoch.
    for(SAPArtistAlbumOperation *operation in self.operations.allValues){
        operation.paused=YES;[operation cancelRecoveryObservation];operation.hasTrustedCounts=NO;operation.needsReadRepair=!operation.downloadSent;
        if(!operation.downloadSent)operation.readyForDownload=NO;
        operation.readEpoch++;if(operation.cancelRead){operation.cancelRead();operation.cancelRead=nil;}
        operation.retryEpoch++;if(operation.retry){dispatch_source_cancel(operation.retry);operation.retry=nil;}
        operation.workEpoch++;if(operation.workDeadline){dispatch_source_cancel(operation.workDeadline);operation.workDeadline=nil;}
        [self stateFor:operation.uri][@"error"]=reason;
    }
    for(NSDictionary *item in self.queue)[self stateFor:item[@"uri"]][@"error"]=reason;
    [self cancelInitialReads];[self cancelWatch];
    SAPJournalNoteAction(@"artist_observation_repair_exhausted",@{@"reason":reason,@"attempts":@(self.repairAttempts),@"episodes_without_native_progress":@(self.repairEpisodes),@"queued_preserved":@(self.queue.count),@"reserved_albums":@(self.operations.count),@"automatic_replay":@NO});[self publish];
}
- (void)resumeObservation {
    self.repairEpisodes=0;BOOL retained=self.observationPaused;self.observationPaused=NO;self.watchSuspended=NO;
    if(!retained)return;
    NSString *reason=self.error;self.error=nil;
    for(NSMutableDictionary *raw in self.states.allValues)if([raw[@"error"]isEqual:reason])[raw removeObjectForKey:@"error"];
    [self repairWatch:@"Refreshing retained album status."];
}
- (void)repairWatch:(NSString *)reason {
    if(self.watchSuspended)return;
    if(self.repairing){if(self.repairAwaitingStreams){self.repairAwaitingStreams=NO;[self tryRepairWatch];}return;}
    // A first stream response proves observation health, not native work.
    // Repeated healthy-first/error cycles share a finite instability budget.
    if(self.repairEpisodes>=2){SAPJournalNoteAction(@"artist_observation_repair_budget_exhausted",@{@"episodes_without_native_progress":@(self.repairEpisodes),@"max_episodes_without_native_progress":@2,@"queued_preserved":@(self.queue.count),@"automatic_replay":@NO});[self suspendObservation:@"Spotify status streams repeatedly failed without native download progress. Selected albums are retained; reopen the list to refresh."];return;}
    self.repairEpisodes++;
    self.repairing=YES;self.repairAwaitingStreams=NO;self.repairAttempts=0;self.error=reason;
    for(SAPArtistAlbumOperation *operation in self.operations.allValues)operation.hasTrustedCounts=NO;
    NSUInteger epoch=++self.repairEpoch;__weak typeof(self) weak=self;
    self.repairDeadline=SAPScheduleDeadline(dispatch_get_main_queue(),repairTimeoutSeconds,^{
        typeof(self) s=weak;if(!s || !s.repairing || s.repairEpoch!=epoch)return;
        s.repairDeadline=nil;[s suspendObservation:@"Spotify status observation could not be repaired in time. Selected albums are retained; reopen the list to refresh."];
    });
    SAPJournalNoteAction(@"artist_observation_repair_started",@{@"reason":reason,@"queued_preserved":@(self.queue.count),@"reserved_albums":@(self.operations.count),@"max_attempts":@2,@"episodes_without_native_progress":@(self.repairEpisodes),@"max_episodes_without_native_progress":@2,@"automatic_replay":@NO});
    [self tryRepairWatch];[self publish];
}
- (void)tryRepairWatch {
    if(!self.repairing)return;
    if(self.cancelRepairRead){self.cancelRepairRead();self.cancelRepairRead=nil;}
    if(self.repairAttempts>=2){[self suspendObservation:@"Spotify status observation could not be repaired. Selected albums are retained; reopen the list to refresh."];return;}
    self.repairAttempts++;NSUInteger epoch=self.repairEpoch,attempt=self.repairAttempts;
    NSMutableOrderedSet *requested=[NSMutableOrderedSet orderedSetWithArray:self.operations.allKeys];
    [requested addObjectsFromArray:self.stopOperations.allObjects];
    if(!requested.count)for(NSDictionary *item in self.queue){if(![self.readyItems[item[@"uri"]]count] || [item[@"reserved_batch_end"]boolValue])continue;[requested addObject:item[@"uri"]];if(requested.count==2)break;}
    if(!requested.count){NSArray *desired=[self desiredWatchURIs];if(desired.count)[requested addObject:desired.firstObject];}
    if(!requested.count){[self cancelRepair];[self cancelWatch];return;}
    NSArray *uris=requested.array;__weak typeof(self) weak=self;__block BOOL finished=NO;
    SAPJournalNoteAction(@"artist_observation_repair_attempt",@{@"attempt":@(attempt),@"albums":@(uris.count),@"queued_preserved":@(self.queue.count),@"automatic_replay":@NO});
    dispatch_block_t cancel=SAPCallReadOnlyServiceCancellable(offlineService,@"GetContexts",contextRequest(uris),^(NSData *data,NSString *error){
        typeof(self) s=weak;if(!s || finished || !s.repairing || s.repairEpoch!=epoch || s.repairAttempts!=attempt)return;finished=YES;s.cancelRepairRead=nil;
        NSArray *fields=SAPProtoFields(data);NSMutableSet *seen=[NSMutableSet set];
        if(fields && !error.length && !SAPProtoNumber(fields,2,0))for(NSDictionary *field in fields)if([field[@"number"]unsignedIntValue]==1 && [field[@"wire"]unsignedIntValue]==2){NSArray *info=SAPProtoFields(SAPProtoData(SAPProtoFields(field[@"value"]),1));NSString *uri=SAPProtoString(info,1);if([uris containsObject:uri] && SAPProtoNumber(info,2,0)<=5)[seen addObject:uri];}
        if(seen.count!=uris.count){SAPJournalNoteAction(@"artist_observation_repair_read_failed",@{@"attempt":@(attempt),@"error":error?:@"missing_or_invalid_contexts"});[s tryRepairWatch];return;}
        // Keep admissions held while this exact snapshot fills the stream gap.
        [s apply:data progress:NO];if(!s.repairing || s.repairEpoch!=epoch)return;
        s.repairAwaitingStreams=YES;s.watchNeedsRenewal=YES;[s startWatch];
    });
    if(!finished && self.repairing && self.repairEpoch==epoch && cancel)self.cancelRepairRead=[^{finished=YES;cancel();} copy];
}
- (void)finishRepair {
    if(!self.repairing || !self.repairAwaitingStreams || self.watchPendingFirst.count)return;
    NSUInteger attempts=self.repairAttempts;[self cancelRepair];self.error=nil;
    SAPJournalNoteAction(@"artist_observation_repaired",@{@"attempts":@(attempts),@"queued_preserved":@(self.queue.count),@"reserved_albums":@(self.operations.count),@"automatic_replay":@NO});
    for(SAPArtistAlbumOperation *operation in self.operations.allValues){
        if(operation.paused || operation.commandPending)continue;
        if(operation.needsReadRepair){operation.needsReadRepair=NO;[operation preflight];}
        else if(operation.downloadSent)[operation reconcile];
    }
    [self next];[self pumpAdmissions];[self publish];
}
- (void)pauseWork:(NSString *)reason {
    [self cancelRepair];
    self.observationPaused=NO;
    self.watchSuspended=YES;self.error=reason;self.prepareEpoch++;self.preparing=NO;
    NSUInteger unsent=self.queue.count;NSMutableArray *items=[self.queue mutableCopy];
    for(SAPArtistAlbumOperation *operation in self.operations.allValues){
        [items addObject:operation.item];[operation cancel];
        // A cancelled callback cannot prove that its native mutation failed.
        if(operation.downloadSent){operation.paused=YES;operation.commandPending=NO;operation.hasTrustedCounts=NO;}
        else [self.operations removeObjectForKey:operation.uri];
    }
    for(dispatch_block_t cancel in self.stopReadCancels.allValues)cancel();[self.stopReadCancels removeAllObjects];
    for(NSString *uri in self.stopTokens.allKeys){NSMutableDictionary *raw=[self stateFor:uri];raw[@"stopping"]=@NO;raw[@"error"]=reason;}
    [self.stopTokens removeAllObjects];[self.stopOperations removeAllObjects];
    // Remember sent removals so a later explicit Stop cannot replay them.
    for(NSDictionary *item in items){if([item[@"reserved_batch_end"]boolValue])continue;NSMutableDictionary *raw=[self stateFor:item[@"uri"]];raw[@"native_downloading"]=@NO;raw[@"local_active"]=@NO;raw[@"local_phase"]=@"failed";raw[@"error"]=reason;}
    [self.queue removeAllObjects];[self.queueOrders removeAllObjects];[self.queuedURIs removeAllObjects];
    [self cancelInitialReads];[self cancelWatch];
    SAPJournalNoteAction(@"artist_album_queue_paused",@{@"reason":reason,@"unsent_albums":@(unsent),@"affected_albums":@(items.count),@"reserved_albums":@(self.operations.count),@"automatic_replay":@NO});[self publish];
}
- (void)apply:(NSData *)data progress:(BOOL)progress {[self apply:data progress:progress live:NO];}
- (void)apply:(NSData *)data progress:(BOOL)progress live:(BOOL)live {[self apply:data progress:progress live:live owners:nil];}
- (void)apply:(NSData *)data progress:(BOOL)progress live:(BOOL)live owners:(NSDictionary *)owners {
    NSArray *envelope=SAPProtoFields(data);if(!envelope)return;
    if(!progress && SAPProtoNumber(envelope,2,0)) {self.error=@"Spotify could not read the album download states.";[self publish];return;}
    BOOL changed=NO;NSMutableSet *advanced=[NSMutableSet set];
    for(NSDictionary *field in envelope)if([field[@"number"]unsignedIntValue]==1 && [field[@"wire"]unsignedIntValue]==2) {
        NSArray *entry=SAPProtoFields(field[@"value"]),*info=progress?SAPProtoFields(SAPProtoData(entry,2)):SAPProtoFields(SAPProtoData(entry,1));
        NSString *uri=progress?SAPProtoString(entry,1):SAPProtoString(info,1);if(!uri || !info || !self.states[uri])continue;
        SAPArtistAlbumOperation *operation=self.operations[uri];
        if(operation.paused || ([self.queuedURIs containsObject:uri] && ![self.readyItems[uri]count]) || (owners && operation && owners[uri]!=operation))continue;
        NSMutableDictionary *raw=[self stateFor:uri];NSDictionary *before=[raw copy];
        if(progress) {
            uint64_t done=SAPProtoNumber(info,3,0),bytes=SAPProtoNumber(info,4,0);
            BOOL gained=done>[raw[@"downloaded"]unsignedLongLongValue] || bytes>[raw[@"downloaded_bytes"]unsignedLongLongValue];
            raw[@"downloaded"]=@(done);raw[@"downloaded_bytes"]=@(bytes);raw[@"total_bytes"]=@(SAPProtoNumber(info,6,0));raw[@"total"]=@(SAPProtoNumber(info,5,0));raw[@"totals_state"]=@(SAPProtoNumber(info,11,0));
            raw[@"queued_tracks"]=@(SAPProtoNumber(info,1,0));raw[@"queued_bytes"]=@(SAPProtoNumber(info,2,0));
            raw[@"native_downloading"]=@(SAPProtoNumber(info,7,0)!=0);raw[@"percent"]=@(floatNumber(info,9));
            if(operation) {
                if(live && [raw[@"native_downloading"]boolValue])operation.sawNativeActive=YES;
                operation.hasTrustedCounts=[raw[@"totals_state"]unsignedIntegerValue]==2 && [raw[@"total"]unsignedLongLongValue]>0 && done<=[raw[@"total"]unsignedLongLongValue];
                if(gained) {
                    if(live && operation.downloadSent)self.repairEpisodes=0;
                    [operation armWorkDeadline];
                    for(SAPArtistAlbumOperation *peer in self.operations.allValues)if(peer!=operation && !peer.paused && !peer.stopped) {
                        NSDictionary *peerState=self.states[peer.uri];
                        BOOL heldPreparation=!peer.downloadSent && peer.readyForDownload && self.lastSubmittedOperation==operation;
                        BOOL waitingNative=peer.downloadSent && ![peerState[@"native_downloading"]boolValue];
                        if(heldPreparation || waitingNative)[peer armWorkDeadline];
                    }
                }
            }
        }else {
            uint64_t code=SAPProtoNumber(info,2,0);if(code>5)continue;
            if(code==3 && operation && !operation.downloadSent && SAPIsPlaylistURI(uri) && [operation.item[@"refresh_after_append"]boolValue])continue;
            if(operation && code==3 && ![before[@"native_state"]isEqual:@3])self.repairEpisodes=0;
            raw[@"native_state"]=@(code);raw[@"percent"]=@(floatNumber(info,3));
            if(code==3 || code==1 || code==0)raw[@"native_downloading"]=@NO;
            if(code==3 || code==2 || code==4 || code==5)[raw removeObjectForKey:@"native_cancelled"];
            BOOL forceDisable=[self.forcedOfflineStops containsObject:uri];
            if((code==3 && !forceDisable) || (code==1 && !forceDisable && ![self.queuedURIs containsObject:uri] && !(operation && !operation.downloadSent)) || (code==0 && [raw[@"stopping"]boolValue] && [self.stopSentURIs containsObject:uri])) {
                if(code==0)raw[@"stop_confirmed"]=@YES;
                raw[@"local_active"]=@NO;raw[@"stopping"]=@NO;raw[@"download_requested"]=@NO;
                raw[@"local_phase"]=code==1?@"failed":@"idle";
                if(code==1)raw[@"error"]=@"Spotify reported a download error. Tap to retry.";else[raw removeObjectForKey:@"error"];
                if(!operation){[self.stopOperations removeObject:uri];[self.stopTokens removeObjectForKey:uri];[self.stopSentURIs removeObject:uri];[self.forcedOfflineStops removeObject:uri];}
            }
            if(operation && live) {
                if(activeNative(raw))operation.sawNativeActive=YES;
                if(code==0 && operation.downloadSent && operation.sawNativeActive && !operation.stopped && !operation.recoveryOwnZero)raw[@"native_cancelled"]=@YES;
            }
        }
        if(![before isEqual:raw]) {
            changed=YES;SAPJournalNoteAction(@"artist_album_native_state",@{@"album_uri":uri,@"source":progress?@"native_progress":@"native_context",@"state":[self publicState:raw]});
        }
        if(operation)[advanced addObject:operation];
    }
    if(changed)[self publish];for(SAPArtistAlbumOperation *operation in advanced)[operation evaluate];[self pumpAdmissions];
}
- (NSArray *)desiredWatchURIs {
    if(self.watchSuspended)return @[];
    if(!self.observers.count && !self.operations.count && !self.queue.count && !self.stopOperations.count && !self.stopTokens.count)return @[];
    NSMutableOrderedSet *uris=[NSMutableOrderedSet orderedSet];BOOL readyQueued=NO;
    for(NSDictionary *item in self.queue)if([self.readyItems[item[@"uri"]]count]){readyQueued=YES;break;}
    BOOL needsEvents=self.operations.count>0 || readyQueued || self.stopOperations.count>0;
    for(NSString *uri in self.states){NSDictionary *raw=self.states[uri];if(activeNative(raw) || [raw[@"stopping"]boolValue] || ([raw[@"download_requested"]boolValue] && [raw[@"local_active"]boolValue])){needsEvents=YES;[uris addObject:uri];}}
    if(!needsEvents && !self.externalWatchRefCounts.count)return @[];
    if(self.operations.count || readyQueued || self.stopOperations.count)for(NSArray *list in self.observerURIs.allValues)[uris addObjectsFromArray:list];
    [uris addObjectsFromArray:self.externalWatchRefCounts.allKeys];
    [uris addObjectsFromArray:self.operations.allKeys];[uris addObjectsFromArray:self.stopOperations.allObjects];
    for(NSDictionary *item in self.queue)if(![self.readyItems[item[@"uri"]]count])[uris removeObject:item[@"uri"]];
    return [uris.array sortedArrayUsingSelector:@selector(compare:)];
}
- (void)startWatch {
    NSArray *uris=[self desiredWatchURIs];
    if(!uris.count){if(self.watchCancels.count)[self cancelWatch];if(self.repairing)[self cancelRepair];return;}
    NSMutableArray *ownedURIs=[NSMutableArray array];
    for(SAPArtistAlbumOperation *owned in self.operations.allValues)if(owned.downloadSent && !owned.paused)[ownedURIs addObject:owned.uri];
    [ownedURIs sortUsingSelector:@selector(compare:)];
    if(!self.watchNeedsRenewal && [self.watchURIs isEqual:uris] && [self.watchOwners isEqualToDictionary:self.operations] && [self.watchNativeURIs isEqual:ownedURIs] && self.watchCancels.count) {
        if(self.operations.count && self.watchDeadline){dispatch_source_cancel(self.watchDeadline);self.watchDeadline=nil;}
        if(!self.operations.count && !self.queue.count && !self.watchDeadline){NSUInteger generation=self.watchEpoch;__weak typeof(self) weak=self;self.watchDeadline=SAPScheduleDeadline(dispatch_get_main_queue(),900,^{typeof(self) s=weak;if(s && s.watchEpoch==generation)[s pauseWork:@"Live status updates stopped after 15 minutes. Reopen this list to refresh."];});}return;
    }
    // Queue replacement selection before releasing the old stream leases.
    // Changing the epoch first still rejects every previous callback, including
    // pre-Add snapshots when the URI/operation ownership set did not change.
    NSArray *oldCancels=[self.watchCancels copy];self.watchCancels=[NSMutableArray array];
    if(self.watchDeadline){dispatch_source_cancel(self.watchDeadline);self.watchDeadline=nil;}
    self.watchNeedsRenewal=NO;self.watchURIs=uris;self.watchNativeURIs=ownedURIs;NSUInteger epoch=++self.watchEpoch;NSDictionary *owners=[self.operations copy];self.watchOwners=owners;__weak typeof(self) weak=self;
    self.watchPendingFirst=[NSMutableSet set];
    // Submitted contexts use only the native page's default policy. Sending
    // a state-only context lease for the same URI can yield competing snapshots.
    NSMutableArray *passiveURIs=[uris mutableCopy];[passiveURIs removeObjectsInArray:ownedURIs];
    NSUInteger stateStreams=(passiveURIs.count+63)/64,regularStreams=stateStreams+(uris.count+63)/64;
    for(NSUInteger index=0;index<regularStreams+!!ownedURIs.count;index++)[self.watchPendingFirst addObject:@(index)];
    for(NSNumber *isProgress in @[@NO,@YES]) {
        BOOL progress=isProgress.boolValue;NSArray *watched=progress?uris:passiveURIs;
        for(NSUInteger offset=0;offset<watched.count;offset+=64) {
            NSArray *chunk=[watched subarrayWithRange:NSMakeRange(offset,MIN((NSUInteger)64,watched.count-offset))];
            NSNumber *identifier=@((progress?stateStreams:0)+offset/64);
            dispatch_block_t cancel=SAPSubscribeReadOnlyService(offlineService,progress?@"SubscribeContextsProgress":@"SubscribeContexts",progress?urisRequest(chunk,1):contextRequest(chunk),^(NSData *data,NSString *error){
                typeof(self) session=weak;if(!session || session.watchEpoch!=epoch)return;
                NSArray *fields=SAPProtoFields(data);
                if(error.length || !fields || (!progress && SAPProtoNumber(fields,2,0))){[session repairWatch:error.length?error:@"Spotify sent an invalid album status stream response."];return;}
                [session.watchPendingFirst removeObject:identifier];[session apply:data progress:progress live:YES owners:owners];
                if(session.watchEpoch==epoch)[session finishRepair];
            });if(cancel)[self.watchCancels addObject:cancel];
        }
    }
    if(ownedURIs.count){
        NSNumber *identifier=@(regularStreams);
        // Match the native album page's default-policy observation, only for
        // submitted contexts. Passive catalog entries remain state-only.
        dispatch_block_t cancel=SAPSubscribeReadOnlyService(offlineService,@"SubscribeContexts",urisRequest(ownedURIs,3),^(NSData *data,NSString *error){
            typeof(self) s=weak;if(!s || s.watchEpoch!=epoch)return;
            NSArray *fields=SAPProtoFields(data);
            if(error.length || !fields || SAPProtoNumber(fields,2,0)){[s repairWatch:error.length?error:@"Spotify sent an invalid active context response."];return;}
            [s.watchPendingFirst removeObject:identifier];[s apply:data progress:NO live:YES owners:owners];if(s.watchEpoch==epoch)[s finishRepair];
        });if(cancel)[self.watchCancels addObject:cancel];
        SAPJournalNoteAction(@"artist_native_context_observation",@{@"uris":ownedURIs,@"policy":@"native_default",@"max_owned_contexts":@2,@"mutations_sent":@0});
    }
    SAPJournalNoteAction(@"artist_observation_watch_replaced",@{@"generation":@(epoch),@"previous_streams":@(oldCancels.count),@"replacement_streams":@(self.watchCancels.count),@"reason":self.repairing?@"bounded_repair":@"ownership_or_submission_changed",@"selection_queued_before_cancel":@YES});
    for(dispatch_block_t cancel in oldCancels)cancel();
    if(!self.operations.count && !self.queue.count)self.watchDeadline=SAPScheduleDeadline(dispatch_get_main_queue(),900,^{
        typeof(self) s=weak;if(!s || s.watchEpoch!=epoch)return;
        [s pauseWork:@"Live status updates stopped after 15 minutes. Reopen this list to refresh."];
    });
}
- (void)loadStates:(NSArray *)uris owner:(NSString *)owner {
    // Those contexts already own a stream/preflight; modal reads cannot add evidence.
    NSMutableArray *passive=[NSMutableArray array];for(NSString *uri in uris)if(!self.operations[uri] && ![self.queuedURIs containsObject:uri])[passive addObject:uri];uris=passive;
    __weak typeof(self) weak=self;
    for(NSUInteger offset=0;offset<uris.count;offset+=64) {
        NSArray *chunk=[uris subarrayWithRange:NSMakeRange(offset,MIN((NSUInteger)64,uris.count-offset))];
        for(NSNumber *isProgress in @[@NO,@YES]) {
            BOOL progress=isProgress.boolValue;NSString *identifier=NSUUID.UUID.UUIDString;[self.initialReads addObject:identifier];
            self.initialReadURILists[identifier]=chunk;if(owner)self.initialReadOwners[identifier]=owner;
            for(NSString *uri in chunk)self.initialReadURICounts[uri]=@([self.initialReadURICounts[uri]unsignedIntegerValue]+1);
            dispatch_block_t cancel=SAPCallReadOnlyServiceCancellable(offlineService,progress?@"GetContextsProgress":@"GetContexts",progress?urisRequest(chunk,1):contextRequest(chunk),^(NSData *data,NSString *error){
                typeof(self) s=weak;if(!s || ![s.initialReads containsObject:identifier])return;[s finishInitialRead:identifier];
                if(error.length){s.error=error;[s publish];}else {
                    // Initial modal snapshots can predate an enqueued mutation.
                    // Owned work is updated only by its current live stream or
                    // explicit epoch-checked reconciliation, never this read.
                    NSMutableData *filtered=[NSMutableData data];
                    for(NSDictionary *field in SAPProtoFields(data)) {
                        if([field[@"number"]unsignedIntValue]!=1 || [field[@"wire"]unsignedIntValue]!=2){[filtered appendData:field[@"raw"]];continue;}
                        NSArray *entry=SAPProtoFields(field[@"value"]),*info=progress?nil:SAPProtoFields(SAPProtoData(entry,1));
                        NSString *uri=progress?SAPProtoString(entry,1):SAPProtoString(info,1);if(!uri)continue;NSDictionary *raw=s.states[uri];
                        if([s.queuedURIs containsObject:uri] || s.operations[uri]!=nil || [raw[@"local_active"]boolValue] || [raw[@"stopping"]boolValue] || [raw[@"download_requested"]boolValue])continue;
                        [filtered appendData:field[@"raw"]];
                    }
                    if(data && SAPProtoFields(data))[s apply:filtered progress:progress];
                }
                [s startWatch];
            });if([self.initialReads containsObject:identifier] && cancel)self.initialCancels[identifier]=cancel;
        }
    }
}
- (void)next {
    if(self.filling || self.stopBatchDepth || self.watchSuspended || self.repairing || self.preparing)return;
    // Preparation may overlap, but every submitted or uncertain album keeps
    // one of the two ownership slots until its native outcome is definite.
    self.filling=YES;
    while(self.operations.count<2 && self.queue.count && !self.watchSuspended && !self.repairing && !self.stopBatchDepth) {
        NSDictionary *first=self.queue.firstObject;
        // A selected future release owns its FIFO position, without a native slot.
        if([first[@"reserved_batch_end"]boolValue] || ![self.readyItems[first[@"uri"]]count])break;
        SAPArtistAlbumOperation *operation=[SAPArtistAlbumOperation new];operation.session=self;operation.item=first;operation.playlistFeedOpen=[operation.item[@"incremental_playlist"]boolValue];operation.token=NSUUID.UUID.UUIDString;operation.sequence=++self.nextSequence;
        [self.queue removeObjectAtIndex:0];[self.queueOrders removeObjectForKey:operation.uri];[self.queuedURIs removeObject:operation.uri];self.operations[operation.uri]=operation;
        [self stateFor:operation.uri][@"local_phase"]=@"preparing";[operation armWorkDeadline];[self publish];
        if(!self.prepared) {
            self.preparing=YES;NSUInteger generation=++self.prepareEpoch;__weak typeof(self) weak=self;
            SAPPrepareNativeOffline(^BOOL{typeof(self) s=weak;return s && s.prepareEpoch==generation;},^(BOOL ready,NSString *reason){
                typeof(self) s=weak;if(!s || s.prepareEpoch!=generation)return;s.preparing=NO;
                if(!ready){NSString *message=reason?:@"The native download manager is not ready.";if(s.repairing || s.observationPaused)[s suspendObservation:message];else[s pauseWork:message];return;}
                s.prepared=YES;for(SAPArtistAlbumOperation *owned in s.operations.allValues)[owned preflight];
                dispatch_async(dispatch_get_main_queue(),^{[s next];});
            });break;
        }
        [operation preflight];
    }
    self.filling=NO;
    if(!self.operations.count && !self.queue.count)[self publish];
}
- (void)resumePausedOperationsExcept:(NSSet *)excluded {
    for(SAPArtistAlbumOperation *operation in self.operations.allValues)if(operation.paused && ![excluded containsObject:operation.uri])[operation resume];
}
- (void)pumpAdmissions {
    if(self.admitting || self.stopBatchDepth || self.watchSuspended || self.repairing)return;
    // A recovery owns the original FIFO reservation through its deliberate zero.
    for(SAPArtistAlbumOperation *owned in self.operations.allValues)if(owned.recoveryStage.length)return;
    self.admitting=YES;
    // Two verified one-track releases may submit together. Other releases
    // retain near-tail admission and uncertain outcomes still reserve slots.
    NSArray *ordered=[self.operations.allValues sortedArrayUsingComparator:^NSComparisonResult(SAPArtistAlbumOperation *a,SAPArtistAlbumOperation *b){return a.sequence<b.sequence?NSOrderedAscending:a.sequence>b.sequence?NSOrderedDescending:NSOrderedSame;}];
    for(SAPArtistAlbumOperation *operation in ordered) {
        if(![operation isCurrent] || operation.paused || operation.downloadSent || !operation.readyForDownload)continue;
        BOOL earlierUnsent=NO;for(SAPArtistAlbumOperation *earlier in self.operations.allValues)if(earlier.sequence<operation.sequence && !earlier.downloadSent){earlierUnsent=YES;break;}
        if(earlierUnsent)break;
        SAPArtistAlbumOperation *predecessor=nil;
        // A completed newer operation must not hide an older native waiter.
        for(SAPArtistAlbumOperation *earlier in ordered)if(earlier.sequence<operation.sequence && earlier.downloadSent && [earlier isCurrent]){predecessor=earlier;break;}
        if(!predecessor)predecessor=self.lastSubmittedOperation;
        NSString *reason=@"first_album";NSMutableDictionary *facts=[NSMutableDictionary dictionary];
        if(predecessor && predecessor!=operation) {
            facts[@"predecessor_uri"]=predecessor.uri;facts[@"predecessor_token"]=predecessor.token;
            if([predecessor isCurrent]) {
                NSDictionary *raw=self.states[predecessor.uri];uint64_t total=[raw[@"total"]unsignedLongLongValue],done=[raw[@"downloaded"]unsignedLongLongValue];
                BOOL singlePair=[predecessor.item[@"track_count_verified"]boolValue] && [predecessor.item[@"verified_track_count"]unsignedIntegerValue]==1 && [operation.item[@"track_count_verified"]boolValue] && [operation.item[@"verified_track_count"]unsignedIntegerValue]==1;
                if(predecessor.paused)break;
                if(predecessor.singlePairOccupied)break;
                if(singlePair){
                    // Submit a real pair, then finish that pair before replacing
                    // its faster member. Otherwise newer contexts can repeatedly
                    // take priority over the first track still waiting in Spotify.
                    predecessor.singlePairOccupied=YES;operation.singlePairOccupied=YES;
                    reason=@"verified_single_pair";facts[@"predecessor_track_count"]=@1;facts[@"selected_track_count"]=@1;
                }
                else {
                    if(!predecessor.hasTrustedCounts || !total || done>total || total-done>1)break;
                    reason=@"one_track_remaining";facts[@"total_tracks"]=@(total);facts[@"downloaded_tracks"]=@(done);facts[@"remaining_tracks"]=@(total-done);
                }
            }else reason=@"predecessor_terminal";
        }
        facts[@"reason"]=reason;operation.releaseGate=facts;[operation submitDownload];
    }
    self.admitting=NO;
}
- (void)readStopURI:(NSString *)uri token:(NSString *)token completion:(void (^)(NSData *,NSString *))completion {
    dispatch_block_t previous=self.stopReadCancels[uri];if(previous)previous();[self.stopReadCancels removeObjectForKey:uri];
    __block BOOL finished=NO;
    dispatch_block_t cancel=SAPCallReadOnlyServiceCancellable(offlineService,@"GetContexts",contextRequest(@[uri]),^(NSData *data,NSString *error){
        if(finished || ![self.stopTokens[uri]isEqual:token])return;finished=YES;[self.stopReadCancels removeObjectForKey:uri];completion(data,error);
    });
    if(!finished && [self.stopTokens[uri]isEqual:token] && cancel)self.stopReadCancels[uri]=[^{finished=YES;cancel();} copy];
}
- (void)beginNativeStop:(NSString *)uri {
    if([self.stopOperations containsObject:uri])return;
    BOOL removalAlreadySent=[self.stopSentURIs containsObject:uri];
    NSMutableDictionary *raw=[self stateFor:uri];raw[@"stopping"]=@YES;[self.stopOperations addObject:uri];
    NSString *token=NSUUID.UUID.UUIDString;self.stopTokens[uri]=token;[self publish];
    [self readStopURI:uri token:token completion:^(NSData *data,NSString *error){
        if(![self.stopTokens[uri]isEqual:token])return;
        NSNumber *fresh=nil;NSArray *envelope=SAPProtoFields(data);
        if(envelope && !error.length && !SAPProtoNumber(envelope,2,0))for(NSDictionary *field in envelope)if([field[@"number"]unsignedIntValue]==1 && [field[@"wire"]unsignedIntValue]==2){NSArray *info=SAPProtoFields(SAPProtoData(SAPProtoFields(field[@"value"]),1));if([SAPProtoString(info,1)isEqual:uri] && SAPProtoNumber(info,2,0)<=5)fresh=@(SAPProtoNumber(info,2,0));}
        if(![self.forcedOfflineStops containsObject:uri] && ([raw[@"native_state"]isEqual:@3] || [fresh isEqual:@3])){raw[@"native_state"]=@3;raw[@"stopping"]=@NO;[self.stopOperations removeObject:uri];[self.stopTokens removeObjectForKey:uri];[self.stopSentURIs removeObject:uri];[self noteCacheTouch:uri];[self.operations[uri] evaluate];[self publish];return;}
        if(!fresh){raw[@"error"]=error?:@"Spotify did not confirm the current state. Stop was not sent; remaining albums are waiting.";[self.stopOperations removeObject:uri];[self.stopTokens removeObjectForKey:uri];[self publish];return;}
        if(removalAlreadySent) {
            // A previous Remove is never replayed, including after a pause.
            [self apply:data progress:NO];[self publish];return;
        }
        [self.stopSentURIs addObject:uri];
        SAPJournalNoteAction(@"artist_album_stop_requested",@{@"album_uri":uri,@"automatic_replay":@NO});
        contextCommand(uri,NO,^(NSData *reply,NSString *failure){
            if(![self.stopTokens[uri]isEqual:token])return;
            [self.stopOperations removeObject:uri];[self noteCacheTouch:uri];uint64_t code=0;NSArray *fields=contextCommandFields(reply,uri,&code);
            if(failure.length || !fields || code){raw[@"error"]=failure?:@"Spotify did not confirm the stop command. Waiting for native status.";[self publish];return;}
            // Removal acknowledgment is not a terminal native download state.
            // Reconcile once; subscriptions deliver any later transition.
            [self readStopURI:uri token:token completion:^(NSData *freshData,NSString *freshError){
                if(![self.stopTokens[uri]isEqual:token])return;
                if(!freshError.length)[self apply:freshData progress:NO];else raw[@"error"]=freshError;[self publish];
            }];
        });
    }];
}
- (void)rememberStopped:(NSDictionary *)item {
    NSString *uri=item[@"uri"];if(!uri || [self.abandonedURIs containsObject:uri] || [self.states[uri][@"native_state"]isEqual:@3])return;
    NSMutableDictionary *intent=[NSMutableDictionary dictionary];for(NSString *key in @[@"uri",@"name",@"category",@"type",@"artist_uri",@"owner_token",@"track_count_verified",@"verified_track_count"])if(item[key])intent[key]=item[key];
    NSDictionary *last=[self publicState:self.states[uri]];
    // A presentation snapshot is never used as evidence of available files.
    intent[@"stopped_visual"]=self.stoppedItems[uri][@"stopped_visual"]?:@{@"progress":last[@"progress"]?:@0,@"downloaded_tracks":last[@"downloaded_tracks"]?:@0,@"total_tracks":last[@"total_tracks"]?:@0};
    self.stoppedItems[uri]=intent;[self.stoppedOrder addObject:uri];
    while(self.stoppedOrder.count>4096){NSString *old=self.stoppedOrder.firstObject;[self.stoppedItems removeObjectForKey:old];[self.stoppedOrder removeObject:old];if(!self.operations[old])[self clearOwners:old];}
}
- (void)stopURI:(NSString *)uri {
    if(!validContextURI(uri))return;
    SAPArtistAlbumOperation *owned=self.operations[uri];if(owned.playlistFeedOpen || [self.states[uri][@"recovery_removal_pending"]boolValue])[self.forcedOfflineStops addObject:uri];
    for(NSDictionary *item in self.queue)if([item[@"uri"]isEqual:uri] && [item[@"incremental_playlist"]boolValue])[self.forcedOfflineStops addObject:uri];
    if(owned)[self rememberStopped:owned.item];
    for(NSDictionary *item in self.queue)if([item[@"uri"]isEqual:uri])[self rememberStopped:item];
    BOOL queued=[self.queuedURIs containsObject:uri];[self.queuedURIs removeObject:uri];[self.queueOrders removeObjectForKey:uri];[self.readyItems removeObjectForKey:uri];[self.leaseOrders removeObjectForKey:uri];
    [self.queue filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *item,NSDictionary *bindings){return ![item[@"uri"]isEqual:uri];}]];
    NSMutableDictionary *raw=[self stateFor:uri];
    if(queued){raw[@"reserved"]=@NO;raw[@"local_active"]=@NO;raw[@"local_phase"]=@"idle";[raw removeObjectForKey:@"error"];}
    SAPArtistAlbumOperation *operation=self.operations[uri];
    if(operation) {
        if(operation.paused){operation.paused=NO;[operation armWorkDeadline];}
        [operation cancelRecoveryObservation];
        operation.stopped=YES;raw[@"stopping"]=@YES;
        if(operation.commandPending){[self publish];return;}
        if(!operation.downloadSent && ![self.forcedOfflineStops containsObject:uri]){[operation finish:nil];return;}
        if([raw[@"native_state"]isEqual:@3] && ![self.forcedOfflineStops containsObject:uri]){[operation finish:nil];return;}
        [self beginNativeStop:uri];return;
    }
    if([self.forcedOfflineStops containsObject:uri] || (![raw[@"native_state"]isEqual:@3] && (activeNative(raw) || [raw[@"download_requested"]boolValue])))[self beginNativeStop:uri];
    [self publish];if(!self.stopBatchDepth)[self next];
}
- (void)stopURIs:(NSSet<NSString *> *)uris {
    // Remove every unsent item in the scope before a synchronous stop callback
    // can advance into a second selected item. Other artists stay queued.
    self.repairEpisodes=0;BOOL wasRepairing=self.repairing || self.observationPaused;self.observationPaused=NO;[self cancelRepair];
    // Invalidate the repair read before scoped Stop can remove or finish its
    // owners. A late verification reply cannot admit an abandoned selection.
    self.repairing=wasRepairing;self.stopBatchDepth++;[self resumePausedOperationsExcept:uris];
    NSArray *owned=[self.operations.allValues sortedArrayUsingComparator:^NSComparisonResult(SAPArtistAlbumOperation *a,SAPArtistAlbumOperation *b){return a.sequence<b.sequence?NSOrderedAscending:a.sequence>b.sequence?NSOrderedDescending:NSOrderedSame;}];
    for(SAPArtistAlbumOperation *operation in owned)if([uris containsObject:operation.uri])[self rememberStopped:operation.item];
    for(NSDictionary *item in self.queue)if([uris containsObject:item[@"uri"]])[self rememberStopped:item];
    for(NSString *uri in uris)[self stopURI:uri];
    self.stopBatchDepth--;self.repairing=NO;
    if(wasRepairing)self.watchNeedsRenewal=YES;
    BOOL remaining=self.queue.count>0;for(SAPArtistAlbumOperation *owned in self.operations.allValues)if(!owned.stopped)remaining=YES;
    if(wasRepairing && remaining)[self repairWatch:@"Refreshing status for the albums remaining after Stop."];
    [self publish];[self next];[self pumpAdmissions];
}
@end
@implementation SAPArtistAlbumOperation
- (NSString *)uri {return self.item[@"uri"];}
- (BOOL)isCurrent {return self.session.operations[self.uri]==self;}
- (void)readService:(NSString *)service method:(NSString *)method payload:(NSData *)payload completion:(void (^)(NSData *,NSString *))completion {
    if(self.cancelRead){self.cancelRead();self.cancelRead=nil;}
    NSUInteger generation=++self.readEpoch;__block BOOL finished=NO;
    dispatch_block_t cancel=SAPCallReadOnlyServiceCancellable(service,method,payload,^(NSData *data,NSString *error){
        if(finished || ![self isCurrent] || self.readEpoch!=generation)return;finished=YES;self.cancelRead=nil;completion(data,error);
    });
    if(!finished && [self isCurrent] && self.readEpoch==generation && cancel)self.cancelRead=[^{finished=YES;cancel();} copy];
}
- (void)cancel {
    [self cancelRecoveryObservation];
    self.epoch++;self.retryEpoch++;self.workEpoch++;self.readEpoch++;
    if(self.cancelRead){self.cancelRead();self.cancelRead=nil;}
    if(self.retry){dispatch_source_cancel(self.retry);self.retry=nil;}
    if(self.workDeadline){dispatch_source_cancel(self.workDeadline);self.workDeadline=nil;}
}
- (void)finish:(NSString *)error {
    if(![self isCurrent])return;SAPArtistDownloadSession *s=self.session;NSString *uri=self.uri;NSMutableDictionary *raw=[s stateFor:uri];
    [s.stopOperations removeObject:uri];[s.stopTokens removeObjectForKey:uri];[s.stopSentURIs removeObject:uri];
    dispatch_block_t cancel=s.stopReadCancels[uri];if(cancel)cancel();[s.stopReadCancels removeObjectForKey:uri];
    [raw removeObjectForKey:@"stop_confirmed"];[raw removeObjectForKey:@"recovery_removal_pending"];
    raw[@"local_active"]=@NO;raw[@"stopping"]=@NO;raw[@"download_requested"]=@NO;raw[@"local_phase"]=error.length?@"failed":@"idle";
    if(error.length)raw[@"error"]=error;else[raw removeObjectForKey:@"error"];
    SAPJournalNoteAction(@"artist_album_queue_advanced",@{@"album_uri":uri,@"native_state":raw[@"native_state"]?:@0,@"error":error?:@"",@"operation_token":self.token,@"owned_operations":@(s.operations.count-1),@"max_window":@2,@"queued_remaining":@(s.queue.count)});
    if(self.discardStoppedIntent || !self.stopped || [raw[@"native_state"]isEqual:@3]){[s clearOwners:uri];[s.stoppedItems removeObjectForKey:uri];[s.stoppedOrder removeObject:uri];}
    [s.abandonedURIs removeObject:uri];[s.forcedOfflineStops removeObject:uri];[self cancel];[s.operations removeObjectForKey:uri];[s publish];if(!s.stopBatchDepth){[s next];[s pumpAdmissions];}
}
- (void)armWorkDeadline {
    if(self.workDeadline){dispatch_source_cancel(self.workDeadline);self.workDeadline=nil;}
    if(![self isCurrent])return;
    NSUInteger epoch=self.epoch,generation=++self.workEpoch;__weak typeof(self) weak=self;
    self.workDeadline=SAPScheduleDeadline(dispatch_get_main_queue(),workTimeoutSeconds,^{
        typeof(self) s=weak;if(!s || ![s isCurrent] || s.epoch!=epoch || s.workEpoch!=generation)return;s.workDeadline=nil;
        NSString *reason=@"Spotify did not confirm progress for 15 minutes. Remaining albums were not started. Reopen the list to refresh the native state.";
        if(s.session.repairing)[s.session suspendObservation:reason];else[s.session pauseWork:reason];
    });
}
- (void)evaluate {
    if(![self isCurrent] || self.paused)return;
    if([self.recoveryStage isEqual:@"settling"] && ![self recoveryEligible])[self cancelRecoveryObservation];
    if(self.commandPending)return;
    NSString *uri=self.uri;NSDictionary *raw=self.session.states[uri];NSUInteger code=[raw[@"native_state"]unsignedIntegerValue];
    // An incremental playlist may receive an already-sent append after it was full.
    // Cancel must confirm native offlining is disabled before releasing ownership.
    if(self.stopped && [self.session.forcedOfflineStops containsObject:uri]){if(code==0 && [raw[@"stop_confirmed"]boolValue])[self finish:nil];return;}
    // A completion seen while Remove is pending cannot prove that the
    // destructive command will not take effect later. Keep the FIFO lease.
    if([raw[@"recovery_removal_pending"]boolValue] && !self.stopped)return;
    if([raw[@"native_state"]isEqual:@3]){if(!self.playlistFeedOpen || self.stopped)[self finish:nil];return;}
    if(!self.downloadSent)return;
    if(code==1){[self finish:@"Spotify reported a download error. Tap to retry."];return;}
    if(self.recoveryOwnZero && !self.stopped)return;
    if(code==0 && [raw[@"native_state"]isEqual:@0] && ((self.stopped && [raw[@"stop_confirmed"]boolValue]) || (!self.stopped && [raw[@"native_cancelled"]boolValue]))) {
        if(!self.stopped){self.stopped=YES;[self.session rememberStopped:self.item];}
        [self finish:nil];return;
    }
    [self considerRecovery];
    if(self.recoveryStage.length)return;
    // Full track totals are evidence to reconcile once, never album completion.
    if(code==5 && self.hasTrustedCounts && [raw[@"total"]unsignedLongLongValue]>0 && [raw[@"downloaded"]isEqual:raw[@"total"]] && !self.completionReadAttempted){self.completionReadAttempted=YES;[self reconcile];}
}
// A single native re-registration repairs an observed aggregate waiter. Remove
// has no preserve-cache flag: unreferenced files may need to download again.
// Item verification is a mutation gate, never a substitute for native state 3.
- (BOOL)recoveryExclusive {
    if(![self isCurrent] || self.paused || self.stopped || self.session.repairing || self.session.watchSuspended)return NO;
    id owner=releaseOwner(self.item);NSDictionary *ready=self.session.readyItems[self.uri],*leases=self.session.leaseOrders[self.uri];
    NSSet *owners=self.session.contextOwners[self.uri];
    if(ready.count!=1 || !ready[owner] || leases.count!=1 || !leases[owner] || (owner==NSNull.null?owners.count!=0:(owners.count!=1 || ![owners containsObject:owner])))return NO;
    for(SAPArtistAlbumOperation *peer in self.session.operations.allValues)if(peer!=self && peer.downloadSent)return NO;
    return YES;
}
- (BOOL)recoveryEligible {
    NSDictionary *raw=self.session.states[self.uri];uint64_t total=[raw[@"total"]unsignedLongLongValue],bytes=[raw[@"total_bytes"]unsignedLongLongValue];
    return self.ownAddAcknowledged && SAPIsAlbumURI(self.uri) && self.downloadSent && !self.commandPending && [self recoveryExclusive] &&
        [raw[@"native_state"]isEqual:@5] && self.hasTrustedCounts && total>0 && [raw[@"downloaded"]unsignedLongLongValue]==total &&
        bytes>0 && [raw[@"downloaded_bytes"]unsignedLongLongValue]==bytes && ![raw[@"queued_tracks"]unsignedLongLongValue] &&
        ![raw[@"queued_bytes"]unsignedLongLongValue] && ![raw[@"native_downloading"]boolValue];
}
- (void)cancelRecoveryObservation {
    self.recoveryEpoch++;
    if(self.recoveryTimer){dispatch_source_cancel(self.recoveryTimer);self.recoveryTimer=nil;}
    if([self.recoveryStage isEqual:@"settling"] || [self.recoveryStage isEqual:@"verifying"] || [self.recoveryStage isEqual:@"confirming_zero"]){
        self.readEpoch++;if(self.cancelRead){self.cancelRead();self.cancelRead=nil;}
    }
    self.recoveryStage=nil;
}
- (void)haltRecovery:(NSString *)reason {
    if(![self isCurrent])return;
    [self cancelRecoveryObservation];self.recoveryStage=@"halted";
    self.session.states[self.uri][@"error"]=reason;
    SAPJournalNoteAction(@"artist_native_reregistration_halted",@{@"album_uri":self.uri,@"reason":reason,@"attempts":@1,@"mutation_replay":@NO,@"native_state":self.session.states[self.uri][@"native_state"]?:@0});
    [self.session publish];[self evaluate];
}
- (void)considerRecovery {
    if(self.recoveryAttempted || self.recoveryStage.length || ![self recoveryEligible])return;
    self.recoveryStage=@"settling";NSUInteger generation=++self.recoveryEpoch;__weak typeof(self) weak=self;
    self.recoveryTimer=SAPScheduleDeadline(dispatch_get_main_queue(),recoverySettleSeconds,^{
        typeof(self) op=weak;if(!op || ![op isCurrent] || op.recoveryEpoch!=generation)return;op.recoveryTimer=nil;
        if(![op recoveryEligible]){op.recoveryStage=nil;return;}
        op.recoveryAttempted=YES;op.recoveryStage=@"verifying";
        SAPJournalNoteAction(@"artist_native_reregistration_verifying",@{@"album_uri":op.uri,@"original_add_acknowledged":@YES,@"trusted_full_progress":@YES,@"exclusive_owner":@YES,@"max_attempts":@1});
        [op readService:offlineService method:@"GetContexts" payload:urisRequest(@[op.uri],3) completion:^(NSData *data,NSString *error){
            if(op.stopped || op.paused || ![op.recoveryStage isEqual:@"verifying"])return;
            NSNumber *fresh=error.length?nil:exactContextState(data,op.uri);
            if(!fresh){[op haltRecovery:@"Spotify could not verify album finalization. No recovery command was sent; refresh or Stop this task."];return;}
            [op.session apply:data progress:NO];if(![op isCurrent])return;
            if(![fresh isEqual:@5] || ![op recoveryEligible]){[op haltRecovery:@"Album status changed during finalization verification. No recovery command was sent; refresh or Stop this task."];return;}
            [op readService:@"spotify.metadata_esperanto.proto.ClassicMetadataService" method:@"GetEntity" payload:SAPProtoBytes(1,[op.uri dataUsingEncoding:NSUTF8StringEncoding]) completion:^(NSData *metadata,NSString *failure){
                if(op.stopped || op.paused || ![op.recoveryStage isEqual:@"verifying"])return;
                NSString *reason=nil;NSArray *tracks=failure?nil:SAPParseArtistAlbumTrackURIs(metadata,op.uri,&reason);
                uint64_t total=[op.session.states[op.uri][@"total"]unsignedLongLongValue];
                if(!tracks.count || tracks.count>10000 || tracks.count!=total || [NSSet setWithArray:tracks].count!=tracks.count){[op haltRecovery:@"Spotify could not verify exact album membership. No recovery command was sent; refresh or Stop this task."];return;}
                for(id track in tracks)if(![track isKindOfClass:NSString.class] || ![track hasPrefix:@"spotify:track:"] || [track length]!=36){[op haltRecovery:@"Spotify returned invalid album tracks. No recovery command was sent; refresh or Stop this task."];return;}
                [op verifyRecoveryItems:tracks offset:0];
            }];
        }];
    });
}
- (void)verifyRecoveryItems:(NSArray *)tracks offset:(NSUInteger)offset {
    if(![self recoveryEligible] || tracks.count!=[self.session.states[self.uri][@"total"]unsignedLongLongValue]){[self haltRecovery:@"Album ownership or progress changed. No recovery command was sent; refresh or Stop this task."];return;}
    if(offset==tracks.count){
        SAPJournalNoteAction(@"artist_native_reregistration_verified",@{@"album_uri":self.uri,@"expected_tracks":@(tracks.count),@"downloaded_items":@(tracks.count),@"native_state":@5,@"cache_redownload_possible":@YES});[self removeForRecovery];return;
    }
    NSArray *chunk=[tracks subarrayWithRange:NSMakeRange(offset,MIN((NSUInteger)256,tracks.count-offset))];
    [self readService:offlineService method:@"GetItems" payload:urisRequest(chunk,1) completion:^(NSData *data,NSString *error){
        if(self.stopped || self.paused || ![self.recoveryStage isEqual:@"verifying"])return;
        NSArray *fields=SAPProtoFields(data);NSMutableSet *seen=[NSMutableSet set];BOOL valid=fields!=nil && !error.length;
        for(NSDictionary *field in fields)if([field[@"number"]unsignedIntValue]==1){
            if([field[@"wire"]unsignedIntValue]!=2){valid=NO;break;}
            NSArray *item=SAPProtoFields(field[@"value"]);NSString *uri=SAPProtoString(item,1);
            if(!item || ![chunk containsObject:uri] || [seen containsObject:uri] || SAPProtoNumber(item,2,0)!=3){valid=NO;break;}[seen addObject:uri];
        }
        if(!valid || seen.count!=chunk.count){[self haltRecovery:@"Spotify did not confirm every album track downloaded. No recovery command was sent; refresh or Stop this task."];return;}
        [self verifyRecoveryItems:tracks offset:offset+chunk.count];
    }];
}
- (void)removeForRecovery {
    if(![self recoveryEligible]){[self haltRecovery:@"Album ownership or progress changed before recovery. No recovery command was sent; refresh or Stop this task."];return;}
    self.recoveryStage=@"removing";self.recoveryOwnZero=YES;self.commandPending=YES;
    self.session.states[self.uri][@"recovery_removal_pending"]=@YES;
    [self.session.stopSentURIs addObject:self.uri];NSUInteger epoch=self.epoch;
    SAPJournalNoteAction(@"artist_native_reregistration_remove",@{@"album_uri":self.uri,@"max_attempts":@1,@"mutation_replay":@NO,@"cache_redownload_possible":@YES});
    contextCommandWithDisposition(self.uri,NO,^(NSData *data,NSString *error,SAPCommandInvocationDisposition disposition){
        if(![self isCurrent] || self.epoch!=epoch)return;self.commandPending=NO;
        uint64_t code=0;NSArray *fields=contextCommandFields(data,self.uri,&code);
        if(disposition==SAPCommandNotInvoked || (!error.length && fields && code)){
            [self.session.stopSentURIs removeObject:self.uri];
            [self.session.states[self.uri]removeObjectForKey:@"recovery_removal_pending"];self.recoveryOwnZero=NO;
        }
        if(self.stopped){self.recoveryStage=nil;[self.session beginNativeStop:self.uri];return;}
        if(disposition!=SAPCommandInvoked || error.length || !fields || code){[self haltRecovery:@"Spotify did not confirm the recovery Remove. It will not be retried; refresh or Stop this task."];return;}
        [self confirmRecoveryZero];
    });
}
- (void)confirmRecoveryZero {
    if(![self recoveryExclusive]){[self haltRecovery:@"Album ownership changed after recovery Remove. Recovery Add was not sent; refresh or Stop this task."];return;}
    self.recoveryStage=@"confirming_zero";
    [self readService:offlineService method:@"GetContexts" payload:urisRequest(@[self.uri],3) completion:^(NSData *data,NSString *error){
        if(self.stopped || self.paused || ![self.recoveryStage isEqual:@"confirming_zero"])return;
        NSNumber *fresh=error.length?nil:exactContextState(data,self.uri);
        if(!fresh){[self haltRecovery:@"Spotify did not confirm the recovery removal state. Recovery Add was not sent; refresh or Stop this task."];return;}
        [self.session apply:data progress:NO];if(![self isCurrent])return;
        if(![fresh isEqual:@0] || ![self recoveryExclusive]){[self haltRecovery:@"Spotify has not confirmed recovery removal. Recovery Add was not sent; refresh or Stop this task."];return;}
        self.recoveryStage=@"readding";self.commandPending=YES;self.recoveryOwnZero=NO;self.hasTrustedCounts=NO;
        // A new native activation must be observed before its zero can mean
        // external cancellation. Recovery's initial zero is expected.
        self.sawNativeActive=NO;
        [self.session.states[self.uri]removeObjectForKey:@"recovery_removal_pending"];
        [self.session.stopSentURIs removeObject:self.uri];[self.session.states[self.uri]removeObjectForKey:@"native_cancelled"];
        NSUInteger epoch=self.epoch;
        SAPJournalNoteAction(@"artist_native_reregistration_add",@{@"album_uri":self.uri,@"native_zero_confirmed":@YES,@"max_attempts":@1,@"mutation_replay":@NO});
        contextCommandWithDisposition(self.uri,YES,^(NSData *reply,NSString *failure,SAPCommandInvocationDisposition disposition){
            if(![self isCurrent] || self.epoch!=epoch)return;self.commandPending=NO;
            if(self.stopped){self.recoveryStage=nil;[self.session beginNativeStop:self.uri];return;}
            uint64_t code=0;NSArray *response=contextCommandFields(reply,self.uri,&code);
            if(disposition!=SAPCommandInvoked || failure.length || !response || code){self.recoveryOwnZero=YES;[self haltRecovery:@"Spotify did not confirm the recovery Add. It will not be retried; refresh or Stop this task."];return;}
            self.recoveryStage=@"awaiting_native";[self evaluate];[self.session publish];
        });
        if([self isCurrent] && self.epoch==epoch){self.session.watchNeedsRenewal=YES;[self.session startWatch];}
    }];
}
- (void)preflight {
    if(![self isCurrent])return;if(self.paused){self.needsReadRepair=YES;return;}self.readyForDownload=NO;NSUInteger epoch=self.epoch;NSString *uri=self.uri;
    [self readService:offlineService method:@"GetContexts" payload:contextRequest(@[uri]) completion:^(NSData *data,NSString *error){
        if(![self isCurrent] || epoch!=self.epoch)return;self.cancelRead=nil;
        NSArray *fields=SAPProtoFields(data);NSNumber *code=nil;
        if(fields && !error.length && !SAPProtoNumber(fields,2,0))for(NSDictionary *entry in fields)if([entry[@"number"]unsignedIntValue]==1 && [entry[@"wire"]unsignedIntValue]==2){NSArray *info=SAPProtoFields(SAPProtoData(SAPProtoFields(entry[@"value"]),1));if([SAPProtoString(info,1)isEqual:uri] && SAPProtoNumber(info,2,0)<=5)code=@(SAPProtoNumber(info,2,0));}
        if(!code){if(self.session.repairing){self.needsReadRepair=YES;return;}[self finish:error?:@"Spotify did not return a valid album state. The download was not sent."];return;}
        if(code.unsignedIntegerValue==3 && !(SAPIsPlaylistURI(uri) && [self.item[@"refresh_after_append"]boolValue])){if(self.playlistFeedOpen)self.downloadSent=YES;[self.session apply:data progress:NO];return;}
        if(code.unsignedIntegerValue==2 || code.unsignedIntegerValue==4 || code.unsignedIntegerValue==5){self.downloadSent=YES;self.sawNativeActive=YES;self.session.lastSubmittedOperation=self;[self.session stateFor:uri][@"local_phase"]=@"waiting";[self.session apply:data progress:NO];[self.session publish];return;}
        if(code.unsignedIntegerValue==3)[[self.session stateFor:uri]removeObjectForKey:@"native_state"];else[self.session stateFor:uri][@"native_state"]=code;
        if(SAPIsPlaylistURI(uri))[self requestDownload];else[self readMembership:0 until:0];
    }];
}
- (void)readMembership:(NSUInteger)attempt until:(double)until {
    if(![self isCurrent])return;if(self.paused){self.needsReadRepair=YES;return;}
    if(until && clockNow()>=until){[self finish:@"Spotify did not confirm the album in Your Library within 30 seconds."];return;}
    NSUInteger epoch=self.epoch;NSString *uri=self.uri;
    self.retryEpoch++;NSUInteger deadlineGeneration=self.retryEpoch;
    if(until){__weak typeof(self) weak=self;self.retry=SAPScheduleDeadline(dispatch_get_main_queue(),MAX(0,until-clockNow()),^{
        typeof(self) s=weak;if(!s || ![s isCurrent] || s.epoch!=epoch || s.retryEpoch!=deadlineGeneration)return;
        s.retry=nil;[s finish:@"Spotify did not confirm the album in Your Library within 30 seconds."];
    });}
    [self readService:@"spotify.your_library_esperanto.proto.YourLibraryService" method:@"Contains" payload:SAPProtoBytes(3,[uri dataUsingEncoding:NSUTF8StringEncoding]) completion:^(NSData *data,NSString *error){
        if(![self isCurrent] || epoch!=self.epoch)return;self.cancelRead=nil;self.retryEpoch++;if(self.retry){dispatch_source_cancel(self.retry);self.retry=nil;}
        if(until && clockNow()>=until){[self finish:@"Spotify did not confirm the album in Your Library within 30 seconds."];return;}
        NSArray *fields=SAPProtoFields(data);NSNumber *member=nil;
        if(fields && SAPProtoNumber(fields,98,0)==200 && !SAPProtoString(fields,99).length && !error.length)
            for(NSDictionary *field in fields)if([field[@"number"]unsignedIntValue]==2 && [field[@"wire"]unsignedIntValue]==2){NSArray *entity=SAPProtoFields(field[@"value"]);if([SAPProtoString(entity,1)isEqual:uri]){uint64_t v=SAPProtoNumber(entity,2,0);if(v<=1)member=@(v);}}
        if(member.boolValue){[self requestDownload];return;}
        if(attempt==0){
            if(self.session.repairing){self.needsReadRepair=YES;return;}
            if(!member){[self finish:error?:@"Spotify did not return a valid library state for this album."];return;}
            if(self.libraryAddSent){[self readMembership:1 until:self.libraryDeadline];return;}
            double deadline=clockNow()+30;
            self.libraryAddSent=YES;self.libraryDeadline=deadline;
            SAPAddAlbumToLibraryOnce(uri,^(NSData *reply,NSString *saveError){if(![self isCurrent] || epoch!=self.epoch)return;[self readMembership:1 until:deadline];});return;
        }
        double delay=MIN(3,attempt);self.retryEpoch++;NSUInteger retryEpoch=self.retryEpoch;__weak typeof(self) weak=self;
        self.retry=SAPScheduleDeadline(dispatch_get_main_queue(),MAX(0,MIN(delay,until-clockNow())),^{typeof(self) s=weak;if(!s || ![s isCurrent] || s.epoch!=epoch || s.retryEpoch!=retryEpoch)return;s.retry=nil;[s readMembership:attempt+1 until:until];});
    }];
}
- (void)reconcile {
    if(![self isCurrent])return;NSUInteger epoch=self.epoch;NSString *uri=self.uri;
    [self readService:offlineService method:@"GetContexts" payload:contextRequest(@[uri]) completion:^(NSData *data,NSString *error){
        if(![self isCurrent] || epoch!=self.epoch)return;self.cancelRead=nil;
        if(error.length){[self.session stateFor:uri][@"error"]=error;[self.session publish];return;}
        [self.session apply:data progress:NO];
    }];
}
- (void)resume {
    if(![self isCurrent] || !self.paused)return;self.paused=NO;[self armWorkDeadline];
    // Observation suspension never cancels a sent mutation. Its original ACK
    // or deadline still owns commandPending, including Stop-before-ACK.
    if(self.commandPending)return;
    if(!self.downloadSent && self.needsReadRepair){self.needsReadRepair=NO;[self preflight];return;}
    NSUInteger epoch=self.epoch;NSString *uri=self.uri;
    [self readService:offlineService method:@"GetContexts" payload:contextRequest(@[uri]) completion:^(NSData *data,NSString *error){
        if(![self isCurrent] || self.epoch!=epoch)return;
        NSArray *fields=SAPProtoFields(data);NSNumber *code=nil;
        if(fields && !error.length && !SAPProtoNumber(fields,2,0))for(NSDictionary *field in fields)if([field[@"number"]unsignedIntValue]==1 && [field[@"wire"]unsignedIntValue]==2){NSArray *info=SAPProtoFields(SAPProtoData(SAPProtoFields(field[@"value"]),1));if([SAPProtoString(info,1)isEqual:uri] && SAPProtoNumber(info,2,0)<=5)code=@(SAPProtoNumber(info,2,0));}
        if(!code){[self.session stateFor:uri][@"error"]=error?:@"Spotify did not return a valid state. This album still reserves its download slot.";[self.session publish];return;}
        // State zero without prior native activity still may precede startup;
        // a command ACK alone cannot release this reservation.
        if([code isEqual:@0]) {
            if([self.session.stopSentURIs containsObject:uri])[self.session stateFor:uri][@"stop_confirmed"]=@YES;
            else if(self.sawNativeActive)[self.session stateFor:uri][@"native_cancelled"]=@YES;
        }
        if(code.unsignedIntegerValue==2 || code.unsignedIntegerValue==4 || code.unsignedIntegerValue==5)self.sawNativeActive=YES;
        [self.session apply:data progress:NO];[self.session publish];
    }];
}
- (void)requestDownload {
    if(![self isCurrent] || self.downloadSent || self.paused)return;
    if(!self.countReadAttempted && SAPIsAlbumURI(self.uri) && [self.item[@"type"]unsignedIntValue]==2 && ![self.item[@"track_count_verified"]boolValue]) {
        self.countReadAttempted=YES;NSUInteger epoch=self.epoch;NSString *uri=self.uri;
        [self readService:@"spotify.metadata_esperanto.proto.ClassicMetadataService" method:@"GetEntity" payload:SAPProtoBytes(1,[uri dataUsingEncoding:NSUTF8StringEncoding]) completion:^(NSData *data,NSString *error){
            if(![self isCurrent] || epoch!=self.epoch)return;NSString *reason=nil;NSArray *tracks=error?nil:SAPParseArtistAlbumTrackURIs(data,uri,&reason);
            if(tracks){NSMutableDictionary *item=[self.item mutableCopy];item[@"track_count_verified"]=@YES;item[@"verified_track_count"]=@(tracks.count);self.item=item;}
            SAPJournalNoteAction(@"artist_single_membership_verified",@{@"album_uri":uri,@"verified":@(tracks!=nil),@"track_count":@(tracks.count),@"error":error?:reason?:@""});
            [self requestDownload];
        }];return;
    }
    self.readyForDownload=YES;
    [self.session publish];[self.session pumpAdmissions];
}
- (void)submitDownload {
    if(![self isCurrent] || self.downloadSent || self.paused)return;
    self.readyForDownload=NO;self.hasTrustedCounts=NO;self.session.lastSubmittedOperation=self;
    NSUInteger epoch=self.epoch;NSString *uri=self.uri;self.downloadSent=YES;self.commandPending=YES;
    NSMutableDictionary *raw=[self.session stateFor:uri];
    // A preflight error belongs to the previous attempt. Only fresh native
    // context events can terminate this newly submitted download as failed.
    if([raw[@"native_state"]isEqual:@1])[raw removeObjectForKey:@"native_state"];
    [raw removeObjectForKey:@"stop_confirmed"];[raw removeObjectForKey:@"native_cancelled"];[self.session.stopSentURIs removeObject:uri];raw[@"download_requested"]=@YES;raw[@"local_phase"]=@"waiting";[self.session publish];
    NSUInteger submitted=0;for(SAPArtistAlbumOperation *owned in self.session.operations.allValues)if(owned.downloadSent)submitted++;
    NSMutableDictionary *selectedRelease=[NSMutableDictionary dictionaryWithObject:uri forKey:@"uri"];
    for(NSString *key in @[@"name",@"category",@"type",@"year"]){id value=self.item[key];if([value isKindOfClass:NSString.class])selectedRelease[key]=[value length]<=512?value:[value substringToIndex:512];else if([value isKindOfClass:NSNumber.class])selectedRelease[key]=value;}
    SAPJournalNoteAction(@"artist_album_download_requested",@{@"album_uri":uri,@"selected_release":selectedRelease,@"automatic_replay":@NO,@"operation_token":self.token,@"owned_operations":@(self.session.operations.count),@"max_window":@2,@"queued_remaining":@(self.session.queue.count),@"submitted_operations":@(submitted),@"release_gate":self.releaseGate?:@{}});
    contextCommandWithDisposition(uri,YES,^(NSData *data,NSString *error,SAPCommandInvocationDisposition disposition){
        if(![self isCurrent] || epoch!=self.epoch || !self.commandPending)return;self.commandPending=NO;
        if(disposition==SAPCommandNotInvoked){
            self.downloadSent=NO;SAPJournalNoteAction(@"artist_album_not_sent",@{@"album_uri":uri,@"error":error?:@"No verified native transport.",@"automatic_replay":@NO});
            [self finish:self.stopped?nil:error?:@"Spotify did not start this download. Refresh the device state and try again."];return;
        }
        if([raw[@"native_state"]isEqual:@3]){if(self.stopped && [self.session.forcedOfflineStops containsObject:uri])[self.session beginNativeStop:uri];else[self evaluate];[self.session publish];return;}
        uint64_t code=0;NSArray *fields=contextCommandFields(data,uri,&code);
        // Empty protobuf data is a valid success reply. A missing/malformed
        // response or transport error cannot prove that the mutation failed.
        if(error.length || !fields){
            raw[@"error"]=error.length?error:@"Spotify did not confirm the download command. Waiting for native status; the command will not be sent again.";
            SAPJournalNoteAction(@"artist_album_ack_unconfirmed",@{@"album_uri":uri,@"error":raw[@"error"],@"automatic_replay":@NO});
            if(self.stopped)[self.session beginNativeStop:uri];else[self reconcile];[self.session publish];return;
        }
        if(code){[self finish:[NSString stringWithFormat:@"Spotify rejected the download (code %llu).",(unsigned long long)code]];return;}
        self.ownAddAcknowledged=YES;
        SAPJournalNoteAction(@"artist_album_submission_acknowledged",@{@"album_uri":uri,@"download_completion_confirmed":@NO});
        if(self.stopped){[self.session beginNativeStop:uri];return;}[self evaluate];[self.session publish];
    });
    // Start observations after the mutation was queued on the transport worker.
    // Old subscription callbacks cannot complete this new album attempt.
    if(epoch==self.epoch && [self isCurrent]){self.session.watchNeedsRenewal=YES;[self.session startWatch];}
}
@end
static SAPArtistDownloadSession *shared(void){if(!session)session=[SAPArtistDownloadSession new];return session;}
@interface SAPArtistSessionObservation ()
@property(nonatomic,copy) NSString *token;
@property(nonatomic,strong) NSMutableOrderedSet *uris,*externalURIs;
@property(nonatomic) BOOL detached;
@end
@implementation SAPArtistSessionObservation
- (void)extendReleases:(NSArray *)releases {
    NSCAssert(NSThread.isMainThread,@"Artist observation belongs to main");if(self.detached)return;SAPArtistDownloadSession *s=shared();NSMutableArray *added=[NSMutableArray array];
    for(NSDictionary *release in releases){NSString *uri=release[@"uri"];
        if(validContextURI(uri) && [release[@"follow_external_changes"]boolValue] && ![self.externalURIs containsObject:uri] && (self.uris.count<4096 || [self.uris containsObject:uri])){[self.externalURIs addObject:uri];s.externalWatchRefCounts[uri]=@([s.externalWatchRefCounts[uri]unsignedIntegerValue]+1);}
        if(validContextURI(uri) && ![self.uris containsObject:uri] && self.uris.count<4096){[self.uris addObject:uri];[added addObject:uri];s.observedURIRefCounts[uri]=@([s.observedURIRefCounts[uri]unsignedIntegerValue]+1);[s stateFor:uri];}}
    if(!added.count){[s startWatch];return;}s.observerURIs[self.token]=self.uris.array;[s resumeObservation];[s resumePausedOperationsExcept:nil];[s publish];[s loadStates:added owner:self.token];
}
- (void)refresh {
    NSCAssert(NSThread.isMainThread,@"Artist refresh belongs to main");if(self.detached)return;SAPArtistDownloadSession *s=shared();[s cancelInitialReadsForOwner:self.token];[s resumeObservation];[s resumePausedOperationsExcept:nil];[s publish];[s loadStates:self.uris.array owner:self.token];
}
- (void)invalidate {
    NSCAssert(NSThread.isMainThread,@"Artist UI detaches on main");if(self.detached)return;self.detached=YES;SAPArtistDownloadSession *s=shared();[s.observers removeObjectForKey:self.token];[s.observerURIs removeObjectForKey:self.token];[s.observerArtists removeObjectForKey:self.token];[s cancelInitialReadsForOwner:self.token];
    for(NSString *uri in self.uris){NSUInteger count=[s.observedURIRefCounts[uri]unsignedIntegerValue];if(count<=1)[s.observedURIRefCounts removeObjectForKey:uri];else s.observedURIRefCounts[uri]=@(count-1);[s noteCacheTouch:uri];}
    for(NSString *uri in self.externalURIs){NSUInteger count=[s.externalWatchRefCounts[uri]unsignedIntegerValue];if(count<=1)[s.externalWatchRefCounts removeObjectForKey:uri];else s.externalWatchRefCounts[uri]=@(count-1);}
    [self.externalURIs removeAllObjects];[self.uris removeAllObjects];[s trimInactiveStates];[s startWatch];
}
@end
static SAPArtistSessionObservation *observeSession(NSString *artist,NSArray *releases,void (^completion)(NSDictionary *)){
    NSCAssert(NSThread.isMainThread,@"Artist UI observation belongs to main");SAPArtistDownloadSession *s=shared();SAPArtistSessionObservation *observation=[SAPArtistSessionObservation new];observation.token=NSUUID.UUID.UUIDString;observation.uris=[NSMutableOrderedSet orderedSet];observation.externalURIs=[NSMutableOrderedSet orderedSet];
    if(completion)s.observers[observation.token]=[completion copy];s.observerURIs[observation.token]=@[];if(artist)s.observerArtists[observation.token]=artist;
    [observation extendReleases:releases];if(!observation.uris.count)[s publish];return observation;
}
SAPArtistSessionObservation *SAPObserveArtistSession(NSArray *releases,void (^completion)(NSDictionary *)){return observeSession(nil,releases,completion);}
SAPArtistSessionObservation *SAPObserveArtistSessionForArtist(NSString *artist,NSArray *releases,void (^completion)(NSDictionary *)){return observeSession(artist,releases,completion);}
void SAPClosePlaylistDownloadFeed(NSString *uri){
    NSCAssert(NSThread.isMainThread,@"Playlist feeds belong to main");SAPArtistAlbumOperation *op=shared().operations[uri];if(op && SAPIsPlaylistURI(uri)){op.playlistFeedOpen=NO;[op evaluate];[shared() publish];}
}
void SAPForgetPlaylistDownloadIntent(NSString *uri){
    if(!SAPIsPlaylistURI(uri))return;SAPArtistDownloadSession *s=shared();if(!s.operations[uri]){[s.stoppedItems removeObjectForKey:uri];[s.stoppedOrder removeObject:uri];}[s publish];
}
static BOOL cancelOwners(SAPArtistDownloadSession *s,NSSet *keys,NSString *artist){
    if(!keys.count)return NO;NSMutableSet *cancel=[NSMutableSet set];for(id key in keys)[s releaseTicket:key];
    for(id key in keys){for(NSString *uri in [s.artistContexts[key]copy]){
        NSMutableDictionary *ready=s.readyItems[uri];[ready removeObjectForKey:key];
        [s.leaseOrders[uri]removeObjectForKey:key];[s refreshQueuedURI:uri];
        NSMutableSet *owners=s.contextOwners[uri];[owners removeObject:key];if(!owners.count && !ready[NSNull.null]){[s.contextOwners removeObjectForKey:uri];[cancel addObject:uri];[s.abandonedURIs addObject:uri];s.operations[uri].discardStoppedIntent=YES;[s.stoppedItems removeObjectForKey:uri];[s.stoppedOrder removeObject:uri];}}[s.artistContexts removeObjectForKey:key];}
    if(cancel.count){s.watchSuspended=NO;[s stopURIs:cancel];}
    BOOL pending=NO;for(NSString *uri in cancel){BOOL live=s.operations[uri]!=nil || s.stopTokens[uri]!=nil;pending|=live;if(!live)[s.abandonedURIs removeObject:uri];}
    SAPJournalNoteAction(@"artist_cancel_requested",@{@"artist_uri":artist?:@"",@"exclusive_contexts":@(cancel.count),@"owner_count":@(keys.count),@"automatic_replay":@NO});[s publish];[s next];[s pumpAdmissions];return pending;
}
void SAPCancelArtistDownloadSession(NSString *artist){
    NSCAssert(NSThread.isMainThread,@"Artist cancellation belongs to main");if(!artist.length)return;SAPArtistDownloadSession *s=shared();NSMutableSet *keys=[NSMutableSet set];for(id key in s.artistContexts)if([ownerArtist(key)isEqual:artist])[keys addObject:key];for(id key in s.batchTickets)if([ownerArtist(key)isEqual:artist])[keys addObject:key];cancelOwners(s,keys,artist);
}
BOOL SAPCancelArtistDownloadOwner(NSString *artist,NSString *token){
    NSCAssert(NSThread.isMainThread,@"Task cancellation belongs to main");if(!artist.length || !token.length)return NO;id key=ownerKey(artist,token);if(![shared().artistContexts[key]count] && !shared().batchTickets[key])return NO;return cancelOwners(shared(),[NSSet setWithObject:key],artist);
}
void SAPStopArtistDownloadSessionReleasesForArtist(NSString *artist,NSArray *releases){
    NSCAssert(NSThread.isMainThread,@"Artist Stop belongs to main");if(!artist.length)return;SAPArtistDownloadSession *s=shared();NSMutableSet *exclusive=[NSMutableSet set];
    for(NSDictionary *release in releases){NSString *uri=release[@"uri"];NSMutableSet *owners=s.contextOwners[uri];if(![owners containsObject:artist])continue;
        if(owners.count>1){[owners removeObject:artist];NSMutableDictionary *ready=s.readyItems[uri];[ready removeObjectForKey:artist];[s.leaseOrders[uri]removeObjectForKey:artist];[s refreshQueuedURI:uri];NSMutableSet *contexts=s.artistContexts[artist];[contexts removeObject:uri];if(!contexts.count)[s.artistContexts removeObjectForKey:artist];}
        else[exclusive addObject:uri];
    }
    if(exclusive.count)[s stopURIs:exclusive];else[s publish];
}
BOOL SAPContinueArtistDownloads(NSString *artist,NSArray *releases,NSString **error){
    NSMutableArray *owned=[NSMutableArray array];for(NSDictionary *release in releases)if([shared().contextOwners[release[@"uri"]]containsObject:artist])[owned addObject:release];return SAPContinueArtistDownloadSessionReleases(owned,error);
}
dispatch_block_t SAPObserveArtistDownloadSession(NSArray *releases,void (^completion)(NSDictionary *)){
    SAPArtistSessionObservation *observation=SAPObserveArtistSession(releases,completion);return ^{[observation invalidate];};
}
BOOL SAPReserveArtistDownloadSessionReleases(NSArray<NSDictionary *> *releases,NSString **error){
    NSCAssert(NSThread.isMainThread,@"Artist reservations belong to main");SAPArtistDownloadSession *s=shared();
    if(![releases isKindOfClass:NSArray.class] || !releases.count || releases.count>4096){if(error)*error=@"No valid releases were selected.";return NO;}
    for(NSDictionary *release in releases)if(![release isKindOfClass:NSDictionary.class] || !validContextURI(release[@"uri"]) || ![release[@"artist_uri"]isKindOfClass:NSString.class] || ![release[@"artist_uri"]length] || ![release[@"owner_token"]isKindOfClass:NSString.class] || ![release[@"owner_token"]length]){if(error)*error=@"Invalid download reservation identity.";return NO;}
    for(NSDictionary *release in releases)if([s.abandonedURIs containsObject:release[@"uri"]]){if(error)*error=@"Spotify is still confirming the previous cancellation. Try again when it finishes.";return NO;}
    for(NSDictionary *release in releases){NSString *uri=release[@"uri"];NSUInteger rank=[s reserveTicket:releaseOwner(release)];NSDictionary *order=@{@"rank":@(rank),@"ordinal":@([s ticketOrdinal:releaseOwner(release) uri:uri])};[s recordLease:releaseOwner(release) uri:uri order:order];[s registerOwner:releaseOwner(release) uri:uri];
        if([s.queuedURIs containsObject:uri]){[s refreshQueuedURI:uri];continue;}if(s.operations[uri])continue;[s.readyItems removeObjectForKey:uri];
        NSMutableDictionary *raw=[s stateFor:uri];raw[@"local_active"]=@YES;raw[@"local_phase"]=@"queued";raw[@"reserved"]=@YES;
        for(NSString *key in @[@"native_state",@"total",@"downloaded",@"percent",@"totals_state",@"native_cancelled",@"error"])[raw removeObjectForKey:key];
        [s enqueue:release order:order];[s.queuedURIs addObject:uri];
    }
    [s publish];return YES;
}
BOOL SAPAppendArtistDownloadSessionReleases(NSArray<NSDictionary *> *releases,NSString **error) {
    NSCAssert(NSThread.isMainThread,@"Artist commands belong to main");SAPArtistDownloadSession *s=shared();
    if(![releases isKindOfClass:NSArray.class] || !releases.count || releases.count>4096){if(error)*error=@"No valid releases were selected.";return NO;}
    for(NSDictionary *release in releases)if(![release isKindOfClass:NSDictionary.class] || !validContextURI(release[@"uri"])){if(error)*error=@"Invalid download context identity.";return NO;}
    for(NSDictionary *release in releases)if([s.abandonedURIs containsObject:release[@"uri"]]){if(error)*error=@"Spotify is still confirming the previous cancellation. Try again when it finishes.";return NO;}
    NSUInteger appendRank=++s.nextQueueRank,appendOrdinal=0;
    for(NSDictionary *release in releases){NSString *uri=release[@"uri"];NSString *artist=[release[@"artist_uri"]isKindOfClass:NSString.class]?release[@"artist_uri"]:nil;NSString *token=[release[@"owner_token"]isKindOfClass:NSString.class]?release[@"owner_token"]:nil;[s registerOwner:artist.length?ownerKey(artist,token):nil uri:uri];
        NSMutableDictionary *ready=s.readyItems[uri];if(!ready)s.readyItems[uri]=ready=[NSMutableDictionary dictionary];ready[releaseOwner(release)]=[release copy];NSDictionary *ticket=s.batchTickets[releaseOwner(release)];NSDictionary *order=@{@"rank":ticket?ticket[@"rank"]:@(appendRank),@"ordinal":ticket?@([s ticketOrdinal:releaseOwner(release) uri:uri]):@(appendOrdinal)};appendOrdinal++;[s recordLease:releaseOwner(release) uri:uri order:order];
        if([s.queuedURIs containsObject:uri])[s refreshQueuedURI:uri];
        if([release[@"incremental_playlist"]boolValue] && s.operations[uri])s.operations[uri].playlistFeedOpen=YES;NSMutableDictionary *raw=[s stateFor:uri];raw[@"reserved"]=@NO;[raw removeObjectForKey:@"native_cancelled"];
        if(SAPIsPlaylistURI(uri) && [release[@"refresh_after_append"]boolValue] && [raw[@"native_state"]isEqual:@3] && !s.operations[uri] && ![s.queuedURIs containsObject:uri]){
            // A mutable playlist's old completed snapshot predates our append.
            // Discard that cache entry; do not reinterpret it as new evidence.
            for(NSString *key in @[@"native_state",@"total",@"downloaded",@"downloaded_bytes",@"percent",@"totals_state"])[raw removeObjectForKey:key];
        }
        if([s.queuedURIs containsObject:uri] || s.operations[uri]!=nil || [raw[@"local_active"]boolValue] || activeNative(raw) || [raw[@"stopping"]boolValue])continue;
        // An inactive cached context is not proof for a new user request.
        // Preflight reads Spotify again and completes without Add when still full.
        if([raw[@"native_state"]isEqual:@3])for(NSString *key in @[@"native_state",@"total",@"downloaded",@"percent",@"totals_state"])[raw removeObjectForKey:key];
        [s.stoppedItems removeObjectForKey:uri];[s.stoppedOrder removeObject:uri];
        raw[@"local_active"]=@YES;raw[@"local_phase"]=@"queued";[raw removeObjectForKey:@"error"];[s enqueue:release order:order];[s.queuedURIs addObject:uri];
        SAPJournalNoteAction(@"artist_album_queued",@{@"album_uri":uri,@"position":@(s.queue.count)});
    }
    [s resumeObservation];if(!s.repairing)s.error=nil;[s resumePausedOperationsExcept:nil];[s next];[s publish];return YES;
}
BOOL SAPContinueArtistDownloadSessionReleases(NSArray *releases,NSString **error){
    NSCAssert(NSThread.isMainThread,@"Continue belongs to main");SAPArtistDownloadSession *s=shared();NSMutableSet *scope=[NSMutableSet set];for(NSDictionary *release in releases)if(SAPIsAlbumURI(release[@"uri"]))[scope addObject:release[@"uri"]];
    NSMutableArray *pending=[NSMutableArray array];for(NSString *uri in [s.stoppedOrder.array copy])if([scope containsObject:uri] && !s.operations[uri] && ![s.queuedURIs containsObject:uri] && ![s.stopOperations containsObject:uri] && ![[s publicState:s.states[uri]][@"active"]boolValue])[pending addObject:s.stoppedItems[uri]];
    if(!pending.count)return YES;
    SAPJournalNoteAction(@"artist_continue_requested",@{@"release_count":@(pending.count),@"fresh_native_preflight":@YES});
    return SAPAppendArtistDownloadSessionReleases(pending,error);
}
void SAPStopArtistDownloadSessionRelease(NSString *uri){NSCAssert(NSThread.isMainThread,@"Artist commands belong to main");if(!validContextURI(uri))return;SAPArtistDownloadSession *s=shared();s.watchSuspended=NO;[s stopURIs:[NSSet setWithObject:uri]];}
void SAPStopArtistDownloadSessionReleases(NSArray<NSDictionary *> *releases){
    NSCAssert(NSThread.isMainThread,@"Artist commands belong to main");NSMutableSet *uris=[NSMutableSet set];
    for(NSDictionary *release in releases)if(validContextURI(release[@"uri"]))[uris addObject:release[@"uri"]];SAPArtistDownloadSession *s=shared();s.watchSuspended=NO;[s stopURIs:uris];
}
void SAPStopArtistDownloadSession(void){for(id owner in [shared().batchTickets.allKeys copy])[shared() releaseTicket:owner];NSCAssert(NSThread.isMainThread,@"Artist commands belong to main");SAPArtistDownloadSession *s=shared();s.watchSuspended=NO;[s stopURIs:[NSSet setWithArray:s.states.allKeys]];}
