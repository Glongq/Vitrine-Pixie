#import "PlaylistDownloads.h"
#import "PlaylistArtwork.h"
#import "ArtistMetadata.h"
#import "ArtistDownloadSession.h"
#import "TrackDownload.h"
#import "WireProto.h"
#import "TrackJournal.h"
#import "Diagnostics.h"
#import "Deadline.h"

static NSString *const libraryService=@"spotify.your_library_esperanto.proto.YourLibraryService";
static NSString *const playlistDataService=@"spotify.playlist_esperanto.proto.PlaylistDataService";
static const NSUInteger pageSize=250,maximumPlaylistItems=10000;
static NSData *str(unsigned field,NSString *s){return SAPProtoBytes(field,[s dataUsingEncoding:NSUTF8StringEncoding]);}
static NSArray *messages(NSArray *fields,unsigned number){NSMutableArray *out=[NSMutableArray array];for(NSDictionary *f in fields)if([f[@"number"]unsignedIntValue]==number && [f[@"wire"]unsignedIntValue]==2)[out addObject:SAPProtoFields(f[@"value"])?:@[]];return out;}
static BOOL hasField(NSArray *fields,unsigned number){for(NSDictionary *f in fields)if([f[@"number"]unsignedIntValue]==number)return YES;return NO;}
static BOOL statusOK(NSArray *fields,NSString **error){
    NSArray *status=SAPProtoFields(SAPProtoData(fields,1));uint64_t code=SAPProtoNumber(status,1,0);
    if(!fields || !status || code<200 || code>=300){if(error)*error=SAPProtoString(status,2)?:@"Spotify did not confirm the playlist request.";return NO;}return YES;
}
NSDictionary *SAPParseWritablePlaylistPage(NSData *data,NSString **error){
    NSArray *fields=SAPProtoFields(data),*header=SAPProtoFields(SAPProtoData(fields,1));
    if(!fields || !header || SAPProtoNumber(fields,98,0)!=200 || SAPProtoString(fields,99).length){
        if(error)*error=SAPProtoString(fields,99)?:@"Spotify did not return a valid Your Library response.";return nil;
    }
    if(SAPProtoNumber(header,12,0)){if(error)*error=@"Playlist contents are still loading.";return nil;}
    NSMutableArray *entries=[NSMutableArray array];NSMutableSet *seen=[NSMutableSet set];NSUInteger consumed=0;
    for(NSNumber *field in @[@2,@3])for(NSArray *entry in messages(fields,field.unsignedIntValue)){
        consumed++;NSArray *info=SAPProtoFields(SAPProtoData(entry,1)),*extra=SAPProtoFields(SAPProtoData(entry,4));NSString *uri=SAPProtoString(info,3);
        if(!SAPIsPlaylistURI(uri) || !SAPProtoNumber(extra,9,0) || SAPProtoNumber(extra,5,0) || [seen containsObject:uri])continue;
        [seen addObject:uri];NSArray *kinds=messages(extra,12);NSUInteger count=0;for(NSArray *kind in kinds){uint64_t type=SAPProtoNumber(kind,1,0);if(type==4 || type==9)count+=SAPProtoNumber(kind,2,0);}
        NSMutableDictionary *row=[@{@"uri":uri,@"name":SAPProtoString(info,2)?:@"Playlist",@"cover_uri":SAPProtoString(info,6)?:@"",@"cover_url":SAPPlaylistArtworkURL(SAPProtoString(info,6))}mutableCopy];if(kinds.count)row[@"track_count"]=@(count);[entries addObject:row];
    }
    return @{@"playlists":entries,@"consumed":@(consumed),@"remaining":@(SAPProtoNumber(header,9,0))};
}
static NSData *contentsRequest(NSString *uri,NSUInteger start){
    NSMutableData *range=[SAPProtoInteger(1,start)mutableCopy];[range appendData:SAPProtoInteger(2,pageSize)];
    NSMutableData *query=[SAPProtoBytes(4,range)mutableCopy];[query appendData:SAPProtoInteger(8,1)];[query appendData:SAPProtoInteger(17,1)];
    NSMutableData *playlistPolicy=[NSMutableData data];for(NSNumber *field in @[@2,@3,@5,@9,@42])[playlistPolicy appendData:SAPProtoInteger(field.unsignedIntValue,1)];
    [playlistPolicy appendData:SAPProtoBytes(35,SAPProtoInteger(1,1))];
    NSMutableData *policy=[SAPProtoBytes(1,playlistPolicy)mutableCopy];[policy appendData:SAPProtoBytes(4,SAPProtoInteger(1,1))];
    NSMutableData *request=[str(1,uri)mutableCopy];[request appendData:SAPProtoBytes(2,query)];[request appendData:SAPProtoBytes(3,policy)];return request;
}
NSDictionary *SAPParsePlaylistContents(NSData *data,NSString *uri,NSString **error){
    NSArray *fields=SAPProtoFields(data);if(!statusOK(fields,error))return nil;
    NSArray *response=SAPProtoFields(SAPProtoData(fields,2)),*playlist=SAPProtoFields(SAPProtoData(response,2)),*metadata=SAPProtoFields(SAPProtoData(playlist,1));
    if(SAPProtoNumber(response,6,0) || ([SAPProtoString(metadata,1)isEqual:uri] && !SAPProtoNumber(metadata,17,0))){if(error)*error=@"Playlist contents are still loading.";return nil;}
    if(!SAPIsPlaylistURI(uri) || ![SAPProtoString(metadata,1)isEqual:uri]){
        if(error)*error=@"Spotify did not return a loaded playlist with the expected identity.";return nil;
    }
    NSUInteger total=hasField(response,4)?SAPProtoNumber(response,4,0):SAPProtoNumber(metadata,6,0);
    if(total>maximumPlaylistItems){if(error)*error=@"This playlist exceeds the supported 10,000-item limit.";return nil;}
    NSMutableArray *items=[NSMutableArray array];for(NSArray *entry in messages(response,1)){
        NSString *item=SAPProtoString(entry,18);if(!item.length){if(error)*error=@"Spotify returned a playlist item without its identity. Nothing was appended.";return nil;}[items addObject:item];
    }
    NSArray *allows=SAPProtoFields(SAPProtoData(metadata,18)),*caps=SAPProtoFields(SAPProtoData(response,24));
    return @{@"items":items,@"total":@(total),@"revision":@(SAPProtoNumber(response,7,0)),@"can_add":@(SAPProtoNumber(allows,1,0)||SAPProtoNumber(caps,5,0)),@"name":SAPProtoString(metadata,2)?:@"Playlist"};
}

@interface SAPPlaylistRead : NSObject
@property(nonatomic,strong) SAPPlaylistRead *keepAlive;
@property(nonatomic,strong) NSMutableArray *items;
@property(nonatomic,strong) NSMutableSet *seen;
@property(nonatomic,copy) NSString *uri;
@property(nonatomic,copy) dispatch_block_t cancelRead;
@property(nonatomic,strong) dispatch_source_t retry;
@property(nonatomic,copy) void (^completion)(id,NSString *);
@property(nonatomic) NSUInteger offset,initialOffset,epoch,pages,loadingAttempts;
@property(nonatomic,strong) NSDictionary *firstPage;
@property(nonatomic) BOOL finished;
- (void)next;
- (void)finish:(id)result error:(NSString *)error;
@end
@implementation SAPPlaylistRead
- (void)finish:(id)result error:(NSString *)error {
    if(self.finished)return;self.finished=YES;self.epoch++;dispatch_block_t cancel=self.cancelRead;self.cancelRead=nil;if(cancel)cancel();
    if(self.retry){dispatch_source_cancel(self.retry);self.retry=nil;}
    void (^reply)(id,NSString *)=self.completion;self.completion=nil;self.keepAlive=nil;if(reply)reply(result,error);
}
- (void)next {
    if(self.finished)return;if(++self.pages>64){[self finish:nil error:@"Spotify returned too many playlist pages."];return;}
    NSUInteger epoch=++self.epoch;NSData *request;NSString *service,*method=@"Get";
    if(self.uri){service=playlistDataService;request=contentsRequest(self.uri,self.offset);}
    else {
        service=libraryService;method=@"All";NSMutableData *header=[SAPProtoInteger(9,1)mutableCopy];
        for(NSArray *pair in @[@[@11,@(self.offset)],@[@12,@(pageSize)],@[@17,@1],@[@25,@1],@[@26,@1]])[header appendData:SAPProtoInteger([pair[0]unsignedIntValue],[pair[1]unsignedIntegerValue])];
        request=SAPProtoBytes(1,header);
    }
    dispatch_block_t cancel=SAPCallReadOnlyServiceCancellable(service,method,request,^(NSData *data,NSString *failure){
        if(self.finished || epoch!=self.epoch)return;self.cancelRead=nil;NSString *error=failure;NSDictionary *page=failure?nil:(self.uri?SAPParsePlaylistContents(data,self.uri,&error):SAPParseWritablePlaylistPage(data,&error));
        if(!page){
            if([error isEqual:@"Playlist contents are still loading."] && self.loadingAttempts<5){NSUInteger attempt=++self.loadingAttempts;self.retry=SAPScheduleDeadline(dispatch_get_main_queue(),MIN(3,attempt)*.5,^{self.retry=nil;if(!self.finished && self.epoch==epoch)[self next];});return;}
            [self finish:nil error:error?:@"Spotify did not return the playlist data."];return;
        }self.loadingAttempts=0;
        if(self.uri){
            if(!self.firstPage)self.firstPage=page;
            else if(![self.firstPage[@"total"]isEqual:page[@"total"]] || ![self.firstPage[@"revision"]isEqual:page[@"revision"]]){[self finish:nil error:@"The playlist changed while being read. Retry to use its current contents."];return;}
            [self.items addObjectsFromArray:page[@"items"]];self.offset=self.initialOffset+self.items.count;
            if(self.offset>[page[@"total"]unsignedIntegerValue]){[self finish:nil error:@"Spotify returned inconsistent playlist counts."];return;}
            if(self.offset==[page[@"total"]unsignedIntegerValue]){NSMutableDictionary *result=[self.firstPage mutableCopy];result[@"items"]=[self.items copy];[self finish:result error:nil];return;}
            if(![page[@"items"]count]){[self finish:nil error:@"Spotify returned an incomplete playlist page."];return;}
        }else{
            for(NSDictionary *entry in page[@"playlists"])if(![self.seen containsObject:entry[@"uri"]]){[self.seen addObject:entry[@"uri"]];[self.items addObject:entry];}
            self.offset+=[page[@"consumed"]unsignedIntegerValue];
            if(![page[@"remaining"]unsignedIntegerValue]){[self finish:[self.items copy] error:nil];return;}
            if(![page[@"consumed"]unsignedIntegerValue] || self.offset>maximumPlaylistItems){[self finish:nil error:@"Spotify returned an incomplete library page."];return;}
        }
        [self next];
    });
    if(!self.finished && epoch==self.epoch)self.cancelRead=cancel;else if(cancel)cancel();
}
@end
static dispatch_block_t readListFrom(NSString *uri,NSUInteger start,void (^completion)(id,NSString *)){
    SAPPlaylistRead *read=[SAPPlaylistRead new];read.uri=uri;read.offset=start;read.initialOffset=start;read.items=[NSMutableArray array];read.seen=[NSMutableSet set];read.completion=completion;read.keepAlive=read;
    dispatch_async(dispatch_get_main_queue(),^{[read next];});return ^{read.completion=nil;[read finish:nil error:nil];};
}
static dispatch_block_t readList(NSString *uri,void (^completion)(id,NSString *)){return readListFrom(uri,0,completion);}
dispatch_block_t SAPFetchWritablePlaylists(void (^completion)(NSArray *,NSString *)) {return readList(nil,completion);}

@class SAPPlaylistDownloadTask;
static NSMutableArray<SAPPlaylistDownloadTask *> *tasks;
static NSMutableDictionary *observers,*observerURIs,*observerSnapshots,*observerArtists;
static NSUInteger itemTaskRevision=1,itemScopeRevision=1;
static void publishTasks(void);
static void schedulePlaylistTasks(void);
static void reconcileItemObservers(void);
static NSDictionary *captureStoppedItemVisuals(NSSet *scope);
@interface SAPPlaylistDownloadTask : NSObject
@property(nonatomic,copy) NSString *token,*uri,*name,*message,*error,*artistURI;
@property(nonatomic,strong) NSArray *releases,*tracks,*baseline,*missing,*sourceURIList;
@property(nonatomic,strong) NSMutableOrderedSet *orderedTracks;
@property(nonatomic,strong) NSMutableDictionary *releaseTracks;
@property(nonatomic,strong) NSSet *sourceURIs;
@property(nonatomic) NSUInteger index,offset,addedCount,epoch;
@property(nonatomic) BOOL active,stopped,commandPending,submitted,queued,resumeBlocked,cancelled;
@property(nonatomic,copy) dispatch_block_t cancelRead,detachSession;
@property(nonatomic,strong) dispatch_source_t retry,deadline;
@property(nonatomic,strong) NSDictionary *contextState,*stoppedVisuals;
- (BOOL)reserve:(NSString **)error;
- (void)begin;
- (void)resolve;
- (void)save;
- (void)target;
- (void)readTarget;
- (void)append;
- (void)submit;
- (void)finish:(NSString *)error;
- (void)publishMessage:(NSString *)message;
- (void)stop;
- (void)stopRequestedBy:(NSString *)caller reason:(NSString *)reason;
- (void)cancel;
- (BOOL)isQueuedRelease:(NSString *)uri;
@end
static void ensureState(void){if(!tasks)tasks=[NSMutableArray array];if(!observers)observers=[NSMutableDictionary dictionary];if(!observerURIs)observerURIs=[NSMutableDictionary dictionary];if(!observerSnapshots)observerSnapshots=[NSMutableDictionary dictionary];if(!observerArtists)observerArtists=[NSMutableDictionary dictionary];}
static NSSet *releaseURIs(NSArray *releases){NSMutableSet *uris=[NSMutableSet set];for(NSDictionary *r in releases)if(SAPIsAlbumURI(r[@"uri"]))[uris addObject:r[@"uri"]];return uris;}
static void publishTasks(void){
    reconcileItemObservers();
    for(NSString *token in [observers.allKeys copy]){
        NSSet *scope=observerURIs[token];BOOL active=NO,resumable=NO;NSMutableArray *summaries=[NSMutableArray array];
        for(SAPPlaylistDownloadTask *task in tasks)if(observerArtists[token]?[task.artistURI isEqual:observerArtists[token]]:[task.sourceURIs intersectsSet:scope]){active|=task.active&&!task.cancelled;resumable|=task.stopped&&!task.active&&!task.resumeBlocked&&!task.cancelled;[summaries addObject:@{@"id":task.token,@"active":@(task.active&&!task.cancelled),@"artist_uri":task.artistURI?:@"",@"cancelled":@(task.cancelled),@"queued":@(task.queued),@"submitted":@(task.submitted),@"can_continue":@(task.stopped&&!task.active&&!task.resumeBlocked&&!task.cancelled),@"release_uris":task.sourceURIList,@"playlist_name":task.name?:@"Playlist",@"playlist_uri":task.uri?:@"",@"message":task.message?:@"",@"error":task.error?:@"",@"stopped_visuals":task.stoppedVisuals?:@{},@"context_state":task.contextState?:@{}}];}
        NSDictionary *snapshot=@{@"active":@(active),@"can_continue":@(resumable),@"can_cancel":@(active||resumable),@"jobs":summaries};
        if(![observerSnapshots[token]isEqual:snapshot]){observerSnapshots[token]=snapshot;void (^reply)(NSDictionary *)=observers[token];if(reply)reply(snapshot);}
    }
}
@implementation SAPPlaylistDownloadTask
- (BOOL)reserve:(NSString **)error {return YES;}
- (void)begin {
    if(!self.active || self.stopped || !self.queued)return;self.queued=NO;
    __weak typeof(self) weak=self;
    self.deadline=SAPScheduleDeadline(dispatch_get_main_queue(),1800,^{typeof(self) task=weak;if(task.active)[task finish:@"Playlist preparation timed out. Check Your Library for any confirmed additions before retrying."];});
    SAPJournalNoteAction(@"playlist_queue_started",@{@"operation":self.token,@"playlist_uri":self.uri?:@"",@"release_count":@(self.sourceURIs.count)});
    if(self.submitted){self.addedCount=0;[self submit];return;}
    self.index=self.offset=0;self.orderedTracks=[NSMutableOrderedSet orderedSet];[self resolve];
}
- (void)setMessage:(NSString *)message {if([_message isEqual:message])return;_message=[message copy];SAPJournalNoteAction(@"playlist_download_phase",@{@"operation":self.token?:@"",@"playlist_uri":self.uri?:@"",@"message":message?:@"",@"added_tracks":@(self.addedCount)});publishTasks();}
- (void)publishMessage:(NSString *)message {
    BOOL changed=![self.message isEqual:message];self.message=message;if(!changed)publishTasks();
}
- (void)stopRequestedBy:(NSString *)caller reason:(NSString *)reason {
    SAPJournalNoteAction(@"playlist_stop_task",@{@"operation":self.token?:@"",@"artist_uri":self.artistURI?:@"",@"playlist_uri":self.uri?:@"",@"caller":caller,@"requested_reason":reason,@"active":@(self.active),@"queued":@(self.queued),@"submitted":@(self.submitted),@"already_stopped":@(self.stopped)});
    [self stop];
}
- (BOOL)valid:(NSUInteger)epoch{return self.active && !self.stopped && self.epoch==epoch;}
- (void)finish:(NSString *)error {
    if(!self.active)return;self.active=NO;self.epoch++;self.error=error;itemTaskRevision++;
    dispatch_block_t cancel=self.cancelRead;self.cancelRead=nil;if(cancel)cancel();cancel=self.detachSession;self.detachSession=nil;if(cancel)cancel();
    if(self.retry){dispatch_source_cancel(self.retry);self.retry=nil;}if(self.deadline){dispatch_source_cancel(self.deadline);self.deadline=nil;}
    [self publishMessage:error?:self.cancelled?@"Canceled.":self.stopped?@"Stopped. Playlist and added tracks were kept.":@"Playlist downloaded."];
    self.tracks=nil;self.baseline=nil;self.missing=nil;self.orderedTracks=nil;if(!self.stopped || self.submitted || self.resumeBlocked)self.releases=nil;
    schedulePlaylistTasks();
}
- (void)resolve {
    if(!self.active || self.stopped)return;
    if(self.index==self.releases.count){self.tracks=self.orderedTracks.array;self.index=0;[self save];return;}
    self.message=[NSString stringWithFormat:@"Reading selected release %lu / %lu…",(unsigned long)self.index+1,(unsigned long)self.releases.count];
    NSString *uri=self.releases[self.index][@"uri"];NSUInteger epoch=self.epoch;
    self.cancelRead=SAPCallReadOnlyServiceCancellable(@"spotify.metadata_esperanto.proto.ClassicMetadataService",@"GetEntity",str(1,uri),^(NSData *data,NSString *error){
        if(![self valid:epoch])return;self.cancelRead=nil;NSString *reason=nil;NSArray *tracks=error?nil:SAPParseArtistAlbumTrackURIs(data,uri,&reason);
        SAPJournalNoteAction(@"playlist_release_tracks_read",@{@"operation":self.token,@"release_uri":uri,@"verified":@(tracks!=nil),@"track_count":@(tracks.count),@"reason":reason?:@"",@"error":tracks?@"":error?:reason?:@""});
        if(!tracks){[self finish:error?:[NSString stringWithFormat:@"Could not read all tracks of %@ (%@). No playlist changes were sent.",self.releases[self.index][@"name"]?:uri,reason?:@"missing metadata"]];return;}
        [self.orderedTracks addObjectsFromArray:tracks];if(self.orderedTracks.count>maximumPlaylistItems){[self finish:@"The selection exceeds 10,000 unique tracks. Choose fewer releases."];return;}
        self.releaseTracks[uri]=tracks;
        self.index++;[self resolve];
    });
}
- (void)verifyLibrary:(NSString *)uri attempt:(NSUInteger)attempt {
    if(!self.active || self.stopped)return;NSUInteger epoch=self.epoch;
    self.cancelRead=SAPCallReadOnlyServiceCancellable(libraryService,@"Contains",str(3,uri),^(NSData *data,NSString *error){
        if(![self valid:epoch])return;self.cancelRead=nil;NSArray *fields=SAPProtoFields(data);BOOL member=NO;
        if(fields && !error.length && SAPProtoNumber(fields,98,0)==200)for(NSArray *entry in messages(fields,2))if([SAPProtoString(entry,1)isEqual:uri] && SAPProtoNumber(entry,2,0)==1)member=YES;
        if(member){self.index++;[self save];return;}
        if(attempt>=5){[self finish:error?:@"Spotify did not confirm the selected release in Your Library. Playlist download was not started."];return;}
        self.retry=SAPScheduleDeadline(dispatch_get_main_queue(),MIN(5,attempt+1),^{self.retry=nil;if([self valid:epoch])[self verifyLibrary:uri attempt:attempt+1];});
    });
}
- (void)save {
    if(!self.active || self.stopped)return;
    if(self.index==self.releases.count){[self target];return;}
    NSString *uri=self.releases[self.index][@"uri"];NSUInteger epoch=self.epoch;
    self.message=[NSString stringWithFormat:@"Saving release %lu / %lu to Your Library…",(unsigned long)self.index+1,(unsigned long)self.releases.count];
    // Read membership first; save a missing album once, then verify read-only.
    self.cancelRead=SAPCallReadOnlyServiceCancellable(libraryService,@"Contains",str(3,uri),^(NSData *data,NSString *failure){
        if(![self valid:epoch])return;self.cancelRead=nil;NSArray *fields=SAPProtoFields(data);NSNumber *member=nil;
        if(fields && !failure.length && SAPProtoNumber(fields,98,0)==200)for(NSArray *entry in messages(fields,2))if([SAPProtoString(entry,1)isEqual:uri] && SAPProtoNumber(entry,2,0)<=1)member=@(SAPProtoNumber(entry,2,0));
        if(!member){[self finish:failure?:@"Spotify did not return a valid library membership state."];return;}
        if(member.boolValue){self.index++;[self save];return;}
        self.commandPending=YES;SAPAddAlbumToLibraryOnce(uri,^(__unused NSData *reply,__unused NSString *error){
            if(!self.active || epoch!=self.epoch)return;self.commandPending=NO;
            if(self.stopped){[self finish:nil];return;}[self verifyLibrary:uri attempt:0];
        });
    });
}
- (void)target {
    if(!self.active || self.stopped)return;if(self.uri){[self readTarget];return;}
    self.message=@"Creating playlist…";NSUInteger epoch=self.epoch;self.commandPending=YES;
    NSMutableData *create=[str(1,@"create")mutableCopy];[create appendData:str(4,self.name)];[create appendData:SAPProtoInteger(5,1)];[create appendData:SAPProtoInteger(12,1)];
    SAPCallPlaylistModificationOnce(YES,SAPProtoBytes(2,create),^(NSData *data,NSString *error){
        if(!self.active || epoch!=self.epoch)return;self.commandPending=NO;
        NSArray *fields=SAPProtoFields(data),*response=SAPProtoFields(SAPProtoData(fields,2));NSString *uri=SAPProtoString(response,2),*failure=error;
        SAPJournalNoteAction(@"playlist_create_reply",@{@"operation":self.token,@"playlist_uri":uri?:@"",@"response_received":@(data!=nil),@"success_field":@(SAPProtoNumber(response,1,0)),@"error":error?:@"",@"automatic_replay":@NO});
        if(error.length || !statusOK(fields,&failure) || !SAPProtoNumber(response,1,0) || !SAPIsPlaylistURI(uri)){
            self.resumeBlocked=YES;[self finish:failure?:@"Spotify did not confirm playlist creation. Check Your Library before retrying; the creation command was not repeated."];return;
        }
        self.uri=uri;if(self.stopped){[self finish:nil];return;}[self readTarget];
    });
}
- (void)readTarget {
    self.message=@"Reading playlist contents…";NSUInteger epoch=self.epoch;
    self.cancelRead=readList(self.uri,^(NSDictionary *contents,NSString *error){
        if(![self valid:epoch])return;self.cancelRead=nil;
        if(!contents || ![contents[@"can_add"]boolValue]){[self finish:error?:@"Spotify does not allow adding tracks to this playlist."];return;}
        self.baseline=contents[@"items"];NSSet *existing=[NSSet setWithArray:self.baseline];NSMutableArray *missing=[NSMutableArray array];
        for(NSString *track in self.tracks)if(![existing containsObject:track])[missing addObject:track];self.missing=missing;
        if(self.baseline.count+self.missing.count>maximumPlaylistItems){[self finish:@"The destination playlist would exceed 10,000 items. Choose another playlist."];return;}
        self.offset=0;[self append];
    });
}
- (void)append {
    if(!self.active || self.stopped)return;
    if(self.offset==self.missing.count){
        if(!self.offset){[self submit];return;}
        self.message=@"Verifying playlist order…";NSUInteger epoch=self.epoch;
        self.cancelRead=readList(self.uri,^(NSDictionary *contents,NSString *error){
            if(![self valid:epoch])return;self.cancelRead=nil;
            if(!contents || ![contents[@"items"]isEqual:[self.baseline arrayByAddingObjectsFromArray:self.missing]]){[self finish:error?:@"The playlist changed before download. Confirmed additions were kept; check its contents before retrying."];return;}[self submit];
        });return;
    }
    NSArray *batch=[self.missing subarrayWithRange:NSMakeRange(self.offset,MIN(100,self.missing.count-self.offset))];
    self.message=[NSString stringWithFormat:@"Adding tracks to %@… %lu / %lu",self.name?:@"playlist",(unsigned long)self.offset,(unsigned long)self.missing.count];
    NSMutableData *request=[str(1,@"add")mutableCopy];[request appendData:str(3,@"end")];for(NSString *uri in batch)[request appendData:str(7,uri)];
    NSMutableData *outer=[str(1,self.uri)mutableCopy];[outer appendData:SAPProtoBytes(2,request)];NSUInteger epoch=self.epoch;self.commandPending=YES;
    SAPCallPlaylistModificationOnce(NO,outer,^(NSData *data,NSString *error){
        if(!self.active || epoch!=self.epoch)return;self.commandPending=NO;
        if(self.stopped){[self finish:nil];return;}NSString *failure=error;BOOL confirmed=!error.length && statusOK(SAPProtoFields(data),&failure);
        SAPJournalNoteAction(@"playlist_append_reply",@{@"operation":self.token,@"playlist_uri":self.uri,@"offset":@(self.offset),@"batch_count":@(batch.count),@"reply_confirmed":@(confirmed),@"error":failure?:@"",@"automatic_replay":@NO});
        // Even an ACK is not proof of membership. An ambiguous mutation is
        // verified once by reading; the append command is never replayed.
        self.cancelRead=readListFrom(self.uri,self.baseline.count+self.offset,^(NSDictionary *contents,NSString *readError){
            if(![self valid:epoch])return;self.cancelRead=nil;
            SAPJournalNoteAction(@"playlist_append_verified",@{@"operation":self.token,@"playlist_uri":self.uri,@"offset":@(self.offset),@"expected_total":@(self.baseline.count+self.offset+batch.count),@"observed_total":contents[@"total"]?:@0,@"exact_tail_matches":@([contents[@"items"]isEqual:batch]),@"error":readError?:@""});
            if(!contents || [contents[@"total"]unsignedIntegerValue]!=self.baseline.count+self.offset+batch.count || ![contents[@"items"]isEqual:batch]){[self finish:readError?:confirmed?@"Spotify did not confirm the exact appended tracks and order. Existing additions were kept; download was not started.":failure?:@"The append result is uncertain. Check the playlist before retrying. The command was not repeated."];return;}
            self.offset+=batch.count;self.addedCount=self.offset;[self append];
        });
    });
}
- (void)submit {
    if(!self.active || self.stopped)return;self.submitted=YES;self.releases=nil;itemTaskRevision++;self.message=@"Waiting for Spotify…";
    if(self.deadline){dispatch_source_cancel(self.deadline);self.deadline=nil;}
    NSDictionary *context=@{@"uri":self.uri,@"name":self.name?:@"Playlist",@"category":@"Playlist",@"refresh_after_append":@(self.addedCount>0)};NSUInteger epoch=self.epoch;__weak typeof(self) weak=self;
    NSString *error=nil;if(!SAPAppendArtistDownloadSessionReleases(@[context],&error)){[self finish:error];return;}
    dispatch_block_t detach=SAPObserveArtistDownloadSession(@[context],^(NSDictionary *snapshot){
        typeof(self) s=weak;if(!s || !s.active || s.epoch!=epoch)return;s.contextState=snapshot[@"album_states"][s.uri];
        NSString *phase=s.contextState[@"phase"],*failure=s.contextState[@"error"];
        if([s.contextState[@"state"]isEqual:@"downloaded"]){[s finish:nil];return;}
        if([phase isEqual:@"failed"]){[s finish:failure?:@"Spotify could not download the playlist."];return;}
        if(s.stopped && ![s.contextState[@"active"]boolValue] && ![s.contextState[@"stop_pending"]boolValue]){[s finish:nil];return;}
        NSString *downloading=[s.contextState[@"total_tracks"]unsignedIntegerValue]?[NSString stringWithFormat:@"Downloading %@… %@ / %@ tracks",s.name?:@"playlist",s.contextState[@"downloaded_tracks"],s.contextState[@"total_tracks"]]:[NSString stringWithFormat:@"Downloading %@…",s.name?:@"playlist"];
        [s publishMessage:s.stopped?@"Stopping…":[phase isEqual:@"downloading"]?downloading:[phase isEqual:@"queued"]?@"Playlist queued":@"Waiting for Spotify…"];
    });
    if(self.active && self.epoch==epoch)self.detachSession=detach;else if(detach)detach();
    schedulePlaylistTasks();
}
- (void)stop {
    if(!self.active || self.stopped)return;self.stoppedVisuals=captureStoppedItemVisuals(self.sourceURIs);self.stopped=YES;itemTaskRevision++;self.message=@"Stopping…";
    if(self.submitted && !self.queued){SAPStopArtistDownloadSessionRelease(self.uri);return;}
    if(!self.commandPending)[self finish:nil];
}
- (BOOL)isQueuedRelease:(NSString *)uri {return NO;}
- (void)cancel {self.cancelled=YES;[self stop];self.resumeBlocked=YES;self.stoppedVisuals=nil;self.releases=nil;itemTaskRevision++;publishTasks();}

@end
@interface SAPIncrementalPlaylistTask : SAPPlaylistDownloadTask
@property(nonatomic,strong) NSArray *plan,*currentBatch,*batchSources,*releasePlan,*appendTracks;
@property(nonatomic,strong) NSDictionary *batchRelease,*batchState,*releasePositions,*albumContextState;
@property(nonatomic,copy) dispatch_block_t detachAlbum;
@property(nonatomic,strong) SAPReleaseItemObservation *releaseObservation;
@property(nonatomic,strong) NSMutableSet *completedTracks;
@property(nonatomic) NSUInteger releaseIndex,appendIndex;
@property(nonatomic,strong) NSMutableSet *verifiedSources,*targetTracks;
@property(nonatomic,strong) dispatch_source_t batchDeadline;
@property(nonatomic) NSUInteger batchEpoch,albumEpoch;
@property(nonatomic) BOOL streamReady,nativeStarted,nativeReady,batchCommitted,finishing,feedClosed,batchWatching,terminating,albumStarted,albumStopPending,sessionReserved;
- (void)advanceRelease;
- (void)detachAlbumContext;
- (void)submitPlaylist;
- (void)stopAlbum;
- (void)watchBatch;
- (void)checkBatch;
- (void)settleStop;
- (void)armBatchDeadline;
- (void)detachBatch;
@end
// Serialize preparation and each destination's mutations, but keep a busy
// destination from blocking a ready operation for another playlist.
static void schedulePlaylistTasks(void){
    static BOOL scheduled=NO;if(scheduled)return;scheduled=YES;
    dispatch_async(dispatch_get_main_queue(),^{
        scheduled=NO;
        for(SAPPlaylistDownloadTask *task in tasks)if(task.active&&!task.queued&&!task.submitted)return;
        for(SAPPlaylistDownloadTask *task in [tasks copy])if(task.active&&task.queued&&!task.stopped){
            BOOL blocked=NO;
            if(task.uri)for(SAPPlaylistDownloadTask *other in tasks)if(other!=task && other.active&&!other.queued && [other.uri isEqual:task.uri]){blocked=YES;break;}
            if(!blocked){[task begin];return;}
        }
    });
}
static BOOL startPlaylist(NSString *artist,NSArray *releases,NSString *playlistURI,NSString *newName,NSString **error){
    NSCAssert(NSThread.isMainThread,@"Playlist actions belong to main");ensureState();
    if(![releases isKindOfClass:NSArray.class] || (newName && ![newName isKindOfClass:NSString.class])){if(error)*error=@"Invalid playlist selection or name.";return NO;}
    NSString *name=[newName stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(!releases.count || releases.count>4096 || (playlistURI && !SAPIsPlaylistURI(playlistURI)) || (!playlistURI && (!name.length || name.length>200))){if(error)*error=@"Choose releases and a valid playlist or a name up to 200 characters.";return NO;}
    for(NSDictionary *r in releases)if(![r isKindOfClass:NSDictionary.class] || !SAPIsAlbumURI(r[@"uri"])){if(error)*error=@"The selection contains an invalid release.";return NO;}
    while(tasks.count>=32){NSUInteger index=[tasks indexOfObjectPassingTest:^BOOL(SAPPlaylistDownloadTask *t,NSUInteger i,BOOL *stop){return !t.active;}];if(index==NSNotFound){if(error)*error=@"Too many active playlist operations.";return NO;}[tasks removeObjectAtIndex:index];itemTaskRevision++;}
    SAPPlaylistDownloadTask *task=artist?[SAPIncrementalPlaylistTask new]:[SAPPlaylistDownloadTask new];task.artistURI=artist;task.token=NSUUID.UUID.UUIDString;task.uri=playlistURI;task.name=name;NSMutableArray *intent=[NSMutableArray arrayWithCapacity:releases.count];for(NSDictionary *release in releases)[intent addObject:@{@"uri":release[@"uri"],@"name":release[@"name"]?:@"Release"}];task.releases=intent;task.sourceURIs=releaseURIs(releases);task.sourceURIList=[task.sourceURIs.allObjects sortedArrayUsingSelector:@selector(compare:)];task.orderedTracks=[NSMutableOrderedSet orderedSet];task.releaseTracks=[NSMutableDictionary dictionary];task.active=YES;task.queued=YES;if(![task reserve:error])return NO;[tasks addObject:task];
    task.message=[NSString stringWithFormat:@"Queued: %@",name?:@"playlist"];
    SAPJournalNoteAction(@"playlist_queue_accepted",@{@"operation":task.token,@"playlist_uri":playlistURI?:@"",@"release_count":@(task.sourceURIs.count),@"queued_operations":@([[tasks filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(SAPPlaylistDownloadTask *entry,NSDictionary *bindings){return entry.active&&entry.queued;}]]count])});
    schedulePlaylistTasks();return YES;
}
BOOL SAPStartPlaylistReleaseDownload(NSArray *releases,NSString *uri,NSString *name,NSString **error){return startPlaylist(nil,releases,uri,name,error);}
BOOL SAPStartPlaylistReleaseDownloadForArtist(NSString *artist,NSArray *releases,NSString *uri,NSString *name,NSString **error){if(![artist isKindOfClass:NSString.class] || !artist.length){if(error)*error=@"Artist identity is unavailable.";return NO;}return startPlaylist(artist,releases,uri,name,error);}
static dispatch_block_t observePlaylists(NSString *artist,NSArray *releases,void (^completion)(NSDictionary *)){
    NSCAssert(NSThread.isMainThread,@"Playlist observation belongs to main");ensureState();NSString *token=NSUUID.UUID.UUIDString;
    observerURIs[token]=releaseURIs(releases);if(artist)observerArtists[token]=artist;if(completion)observers[token]=[completion copy];publishTasks();__block BOOL detached=NO;
    return ^{if(detached)return;detached=YES;[observers removeObjectForKey:token];[observerURIs removeObjectForKey:token];[observerSnapshots removeObjectForKey:token];[observerArtists removeObjectForKey:token];};
}
dispatch_block_t SAPObservePlaylistReleaseDownloads(NSArray *releases,void (^completion)(NSDictionary *)){return observePlaylists(nil,releases,completion);}
dispatch_block_t SAPObservePlaylistReleaseDownloadsForArtist(NSString *artist,NSArray *releases,void (^completion)(NSDictionary *)){return observePlaylists(artist,releases,completion);}
static BOOL continuePlaylists(NSString *artist,NSArray *releases,NSString **error){
    NSCAssert(NSThread.isMainThread,@"Playlist Continue belongs to main");NSSet *scope=releaseURIs(releases);
    for(SAPPlaylistDownloadTask *task in [tasks copy])if(task.stopped&&!task.cancelled&&!task.active&&!task.resumeBlocked && (artist?[task.artistURI isEqual:artist]:[task.sourceURIs intersectsSet:scope])){
        if(![task reserve:error])return NO;
        task.stopped=NO;task.active=YES;task.queued=YES;itemTaskRevision++;task.error=nil;task.contextState=nil;task.stoppedVisuals=nil;
        SAPJournalNoteAction(@"playlist_continue_requested",@{@"operation":task.token,@"playlist_uri":task.uri?:@"",@"resume_existing_context":@(task.submitted),@"replay_creation":@NO});
        task.message=@"Queued to continue…";
    }
    publishTasks();schedulePlaylistTasks();return YES;
}
BOOL SAPContinuePlaylistReleaseDownloads(NSArray *releases,NSString **error){return continuePlaylists(nil,releases,error);}
BOOL SAPContinuePlaylistReleaseDownloadsForArtist(NSString *artist,NSArray *releases,NSString **error){return continuePlaylists(artist,releases,error);}
void SAPCancelPlaylistReleaseDownloadsForArtist(NSString *artist){if(!artist.length)return;for(SAPPlaylistDownloadTask *task in [tasks copy])if([task.artistURI isEqual:artist] && !task.cancelled && (task.active||task.stopped))[task cancel];}
void SAPStopPlaylistReleaseDownloads(NSArray *releases){
    NSCAssert(NSThread.isMainThread,@"Playlist actions belong to main");NSSet *scope=releaseURIs(releases);
    if(SAPDiagnosticsEnabled())SAPJournalNoteAction(@"playlist_stop_requested",@{@"caller":@"SAPStopPlaylistReleaseDownloads",@"requested_reason":@"legacy_release_scope",@"release_uris":[scope.allObjects sortedArrayUsingSelector:@selector(compare:)],@"call_stack":NSThread.callStackSymbols});
    for(SAPPlaylistDownloadTask *task in [tasks copy])if([task.sourceURIs intersectsSet:scope])[task stopRequestedBy:@"SAPStopPlaylistReleaseDownloads" reason:@"legacy_release_scope"];
}
void SAPStopPlaylistReleaseDownloadsForArtist(NSString *artist,NSArray *releases){
    NSCAssert(NSThread.isMainThread,@"Playlist actions belong to main");if(!artist.length)return;NSSet *scope=releases?releaseURIs(releases):nil;
    NSString *reason=scope?@"artist_release_scope":@"artist_all_tasks";
    if(SAPDiagnosticsEnabled())SAPJournalNoteAction(@"playlist_stop_requested",@{@"artist_uri":artist,@"caller":@"SAPStopPlaylistReleaseDownloadsForArtist",@"requested_reason":reason,@"release_uris":scope?[scope.allObjects sortedArrayUsingSelector:@selector(compare:)]:@[],@"call_stack":NSThread.callStackSymbols});
    for(SAPPlaylistDownloadTask *task in [tasks copy])if([task.artistURI isEqual:artist] && (!scope || [task.sourceURIs intersectsSet:scope]))[task stopRequestedBy:@"SAPStopPlaylistReleaseDownloadsForArtist" reason:reason];
}

@interface SAPReleaseItemObservation ()
@property(nonatomic,strong) NSMutableSet *scope,*dirtyMemberships;
@property(nonatomic,strong) NSMutableDictionary *membership;
@property(nonatomic,strong) NSDictionary *flags,*taskMembership;
@property(nonatomic,strong) NSMutableDictionary *catalogMembership;
@property(nonatomic,strong) NSMutableSet *subscribedTracks;
@property(nonatomic,copy) NSString *token;
@property(nonatomic,strong) NSMutableDictionary *items,*states,*reverseIndex,*observationErrors;
@property(nonatomic,strong) NSMutableArray *cancellations;
@property(nonatomic,strong) dispatch_queue_t decodeQueue;
@property(nonatomic,copy) void (^completion)(NSDictionary *);
@property(nonatomic) NSUInteger generation,seenTaskRevision;
@property(nonatomic) BOOL detached,scopeDirty;
#ifdef SAP_TESTING
@property(nonatomic) NSUInteger validationWork,indexWork;
#endif
- (void)reconcile;
- (void)invalidate;
- (void)renderReleases:(NSSet *)uris;
@end
static NSMutableDictionary<NSString *,SAPReleaseItemObservation *> *itemObservers;
@implementation SAPReleaseItemObservation
- (void)invalidate {
    if(self.detached)return;self.detached=YES;[itemObservers removeObjectForKey:self.token];itemScopeRevision++;self.generation++;for(dispatch_block_t cancel in self.cancellations)cancel();[self.cancellations removeAllObjects];self.completion=nil;self.items=nil;self.states=nil;self.membership=nil;self.catalogMembership=nil;self.taskMembership=nil;self.reverseIndex=nil;self.observationErrors=nil;self.subscribedTracks=nil;self.scope=nil;[self.dirtyMemberships removeAllObjects];reconcileItemObservers();
}
- (void)renderReleases:(NSSet *)uris {
    BOOL changed=NO;
    for(NSString *uri in uris){
        NSArray *tracks=self.membership[uri];if(!tracks){if(self.states[uri]){[self.states removeObjectForKey:uri];changed=YES;}continue;}NSUInteger done=0,known=0;BOOL downloading=NO,failed=NO,pending=NO;double singleProgress=0;NSString *observationError=nil;
        for(NSString *track in tracks){if(self.observationErrors[track])observationError=self.observationErrors[track];NSDictionary *item=self.items[track];if(!item)continue;known++;NSUInteger code=[item[@"code"]unsignedIntegerValue];done+=code==3;downloading|=code==5;pending|=code==4||code==5||code==6;failed|=code==1||code==7;if(tracks.count==1 && code==5)singleProgress=[item[@"percent"]doubleValue]/100.;}
        BOOL full=tracks.count>0&&known==tracks.count&&done==tracks.count,owned=[self.flags[uri][@"active"]boolValue],stopping=[self.flags[uri][@"stopping"]boolValue];
        NSString *phase=full?@"downloaded":stopping?@"stopping":observationError?@"unknown":failed?@"failed":downloading?@"downloading":owned&&[self.flags[uri][@"queued"]boolValue]?@"queued":owned||pending?@"waiting":@"idle";
        NSString *kind=full?@"downloaded":observationError?@"unknown":done||owned||pending?@"partial":known==tracks.count?@"not_downloaded":@"unknown";
        NSDictionary *state=@{@"state":kind,@"phase":phase,@"stopping":@(stopping&&!full),@"can_continue":@(!full&&[self.flags[uri][@"can_continue"]boolValue]),@"stopped_visual":self.flags[uri][@"stopped_visual"]?:@{},@"active":@(owned&&!full),@"progress":@(full?1:tracks.count==1?singleProgress:tracks.count?(double)done/tracks.count:0),@"downloaded_tracks":@(done),@"total_tracks":@(tracks.count),@"known_tracks":@(known),@"playlist_download":@(self.flags[uri]!=nil),@"playlist_uri":self.flags[uri][@"uri"]?:@"",@"playlist_name":self.flags[uri][@"name"]?:@"Playlist",@"download_source":@"native_items",@"error":observationError?:failed?@"Spotify reported a track error or waiting limit.":@""};
        if(![self.states[uri]isEqual:state]){self.states[uri]=state;changed=YES;}
    }
    if(changed && self.completion)self.completion(@{@"album_states":[self.states copy]});
}
- (void)updateReleases:(NSArray *)releases {
    NSCAssert(NSThread.isMainThread,@"Item membership belongs to main");if(self.detached)return;
    for(NSDictionary *release in releases){NSString *uri=release[@"uri"];if(!SAPIsAlbumURI(uri))continue;
        if(![self.scope containsObject:uri]){[self.scope addObject:uri];self.scopeDirty=YES;itemScopeRevision++;}
        NSArray *tracks=release[@"track_uris"];if(![release[@"track_count_verified"]boolValue] || ![tracks isKindOfClass:NSArray.class] || !tracks.count || tracks.count>4096)continue;
        NSArray *previous=self.catalogMembership[uri];if(previous==tracks || [previous isEqual:tracks])continue;
#ifdef SAP_TESTING
        self.validationWork+=tracks.count;
#endif
        BOOL valid=YES;NSMutableSet *unique=[NSMutableSet set];for(id track in tracks){if(![track isKindOfClass:NSString.class] || ![track hasPrefix:@"spotify:track:"] || [track length]!=36){valid=NO;break;}[unique addObject:track];}
        if(valid && unique.count==tracks.count){self.catalogMembership[uri]=[tracks copy];[self.dirtyMemberships addObject:uri];}
    }
    [self reconcile];
}
- (void)reconcile {
    if(self.detached)return;NSMutableSet *affected=[NSMutableSet set];
    if(self.scopeDirty || self.seenTaskRevision!=itemTaskRevision){
        self.scopeDirty=NO;self.seenTaskRevision=itemTaskRevision;NSMutableDictionary *fallback=[NSMutableDictionary dictionary],*flags=[NSMutableDictionary dictionary];
        for(SAPPlaylistDownloadTask *task in [tasks reverseObjectEnumerator])if(task.submitted)for(NSString *uri in task.sourceURIs)if([self.scope containsObject:uri]){
            if(!fallback[uri] && [task.releaseTracks[uri]count])fallback[uri]=task.releaseTracks[uri];
            if(task.cancelled || (!task.active&&!task.stopped) || (flags[uri] && (!task.active || [flags[uri][@"active"]boolValue])))continue;
            flags[uri]=@{@"active":@(task.active),@"queued":@([task isQueuedRelease:uri]),@"stopping":@(task.active&&task.stopped),@"can_continue":@(task.stopped&&!task.active&&!task.resumeBlocked&&!task.cancelled),@"stopped_visual":task.stopped?task.stoppedVisuals[uri]?:@{}:@{},@"uri":task.uri?:@"",@"name":task.name?:@"Playlist"};
        }
        NSMutableSet *sources=[NSMutableSet setWithArray:self.taskMembership.allKeys?:@[]];[sources addObjectsFromArray:fallback.allKeys];
        for(NSString *uri in sources)if(!self.catalogMembership[uri] && ![self.taskMembership[uri]isEqual:fallback[uri]])[self.dirtyMemberships addObject:uri];
        self.taskMembership=fallback;
        sources=[NSMutableSet setWithArray:self.flags.allKeys?:@[]];[sources addObjectsFromArray:flags.allKeys];for(NSString *uri in sources)if(![self.flags[uri]isEqual:flags[uri]])[affected addObject:uri];self.flags=flags;
    }
    NSMutableOrderedSet *all=[NSMutableOrderedSet orderedSet];
    for(NSString *uri in self.dirtyMemberships){NSArray *old=self.membership[uri],*tracks=self.catalogMembership[uri]?:self.taskMembership[uri];if(old==tracks || [old isEqual:tracks])continue;
#ifdef SAP_TESTING
        self.indexWork+=old.count+tracks.count;
#endif
        for(NSString *track in old){NSMutableSet *sources=self.reverseIndex[track];[sources removeObject:uri];if(!sources.count)[self.reverseIndex removeObjectForKey:track];}
        if(tracks)self.membership[uri]=tracks;else[self.membership removeObjectForKey:uri];
        for(NSString *track in tracks){NSMutableSet *sources=self.reverseIndex[track];if(!sources)self.reverseIndex[track]=sources=[NSMutableSet set];[sources addObject:uri];if(![self.subscribedTracks containsObject:track])[all addObject:track];}
        [affected addObject:uri];
    }
    [self.dirtyMemberships removeAllObjects];[self.subscribedTracks addObjectsFromArray:all.array];NSUInteger generation=self.generation;
    [self renderReleases:affected];if(self.detached)return;
    // Reserve identities before delivering callbacks; extending a catalog never
    // rebuilds existing links or replaces a healthy native item stream.
    NSArray *uris=all.array;__weak typeof(self) weak=self;dispatch_queue_t decodeQueue=self.decodeQueue;
    for(NSUInteger offset=0;offset<uris.count;offset+=256){
        NSArray *chunk=[uris subarrayWithRange:NSMakeRange(offset,MIN(256,uris.count-offset))];NSSet *requested=[NSSet setWithArray:chunk];NSMutableData *payload=[NSMutableData data];for(NSString *uri in chunk)[payload appendData:str(1,uri)];
        dispatch_block_t cancel=SAPSubscribeReadOnlyService(@"spotify.offline_esperanto.proto.Offline",@"SubscribeItems",payload,^(NSData *data,NSString *error){
            // Preserve native event order while decoding away from UIKit.
            dispatch_async(decodeQueue,^{
                NSArray *fields=error?nil:SAPProtoFields(data);NSMutableDictionary *updates=[NSMutableDictionary dictionary];
                if(fields)for(NSArray *item in messages(fields,1)){NSString *uri=SAPProtoString(item,1);uint64_t code=SAPProtoNumber(item,2,0);if([requested containsObject:uri] && code<=7)updates[uri]=@{@"code":@(code),@"percent":@(MIN(100,SAPProtoNumber(item,4,0)))};}
                dispatch_async(dispatch_get_main_queue(),^{
                    typeof(self) observer=weak;if(!observer || observer.detached || observer.generation!=generation)return;NSMutableSet *affected=[NSMutableSet set];
                    if(!fields){for(NSString *track in requested){[observer.items removeObjectForKey:track];observer.observationErrors[track]=error?:@"Invalid native item response";[affected unionSet:observer.reverseIndex[track]?:[NSSet set]];}SAPJournalNoteAction(@"playlist_item_observation_failed",@{@"tracks":@(requested.count),@"error":error?:@"Invalid native item response"});}
                    for(NSString *track in updates)if(![observer.items[track]isEqual:updates[track]]){observer.items[track]=updates[track];[observer.observationErrors removeObjectForKey:track];[affected unionSet:observer.reverseIndex[track]?:[NSSet set]];}
                    [observer renderReleases:affected];
                });
            });
        });
        if(cancel)[self.cancellations addObject:cancel];
    }
}
@end
static NSDictionary *captureStoppedItemVisuals(NSSet *scope){
    NSMutableDictionary *result=[NSMutableDictionary dictionary];
    for(NSString *uri in scope){NSDictionary *last=nil;
        for(SAPReleaseItemObservation *observer in itemObservers.allValues){NSDictionary *candidate=observer.states[uri];if(candidate && (!last || [candidate[@"known_tracks"]unsignedIntegerValue]>[last[@"known_tracks"]unsignedIntegerValue]))last=candidate;}
        result[uri]=@{@"progress":last[@"progress"]?:@0,@"downloaded_tracks":last[@"downloaded_tracks"]?:@0,@"total_tracks":last[@"total_tracks"]?:@0};
    }
    return result;
}
static void reconcileItemObservers(void){
    static NSUInteger lastTasks=0,lastScopes=0;
    if(lastTasks==itemTaskRevision && lastScopes==itemScopeRevision)return;
    // Keep recent completed membership bounded; visible rows and active jobs
    // retain the exact track identities needed for their live item stream.
    NSUInteger retained=0;
    for(SAPPlaylistDownloadTask *task in [tasks reverseObjectEnumerator]){
        NSUInteger references=0;for(NSArray *tracks in task.releaseTracks.allValues)references+=tracks.count;
        BOOL visible=NO;for(SAPReleaseItemObservation *observer in itemObservers.allValues)if([observer.scope intersectsSet:task.sourceURIs]){visible=YES;break;}
        if(!task.active&&!visible && retained+references>16384 && references){[task.releaseTracks removeAllObjects];itemTaskRevision++;}else if(!task.active)retained+=references;
    }
    lastTasks=itemTaskRevision;lastScopes=itemScopeRevision;
    for(SAPReleaseItemObservation *observer in [itemObservers.allValues copy])[observer reconcile];
}
SAPReleaseItemObservation *SAPObserveReleaseItems(NSArray *releases,void (^completion)(NSDictionary *)){
    NSCAssert(NSThread.isMainThread,@"Item observations belong to main");ensureState();if(!itemObservers)itemObservers=[NSMutableDictionary dictionary];
    SAPReleaseItemObservation *observer=[SAPReleaseItemObservation new];observer.token=NSUUID.UUID.UUIDString;observer.scope=[NSMutableSet set];observer.dirtyMemberships=[NSMutableSet set];observer.membership=[NSMutableDictionary dictionary];observer.reverseIndex=[NSMutableDictionary dictionary];itemScopeRevision++;observer.completion=completion;observer.catalogMembership=[NSMutableDictionary dictionary];observer.subscribedTracks=[NSMutableSet set];observer.items=[NSMutableDictionary dictionary];observer.states=[NSMutableDictionary dictionary];observer.observationErrors=[NSMutableDictionary dictionary];observer.cancellations=[NSMutableArray array];observer.decodeQueue=dispatch_queue_create("local.pixie.native-item-decode",dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL,QOS_CLASS_USER_INITIATED,0));itemObservers[observer.token]=observer;[observer updateReleases:releases];return observer;
}
dispatch_block_t SAPObservePlaylistReleaseItems(NSArray *releases,void (^completion)(NSDictionary *)){
    SAPReleaseItemObservation *observer=SAPObserveReleaseItems(releases,completion);return ^{[observer invalidate];reconcileItemObservers();};
}

@implementation SAPIncrementalPlaylistTask
- (BOOL)reserve:(NSString **)error {
    NSArray *sources=self.releasePlan?:self.releases;NSMutableArray *reserved=[NSMutableArray arrayWithCapacity:sources.count];
    for(NSDictionary *release in sources)[reserved addObject:@{@"uri":release[@"uri"],@"name":release[@"name"]?:@"Release",@"artist_uri":self.artistURI,@"owner_token":self.token}];
    if(!SAPReserveArtistDownloadSessionReleases(reserved,error))return NO;self.sessionReserved=YES;return YES;
}
- (void)detachAlbumContext {self.albumEpoch++;dispatch_block_t detach=self.detachAlbum;self.detachAlbum=nil;if(detach)detach();self.albumContextState=nil;}
- (void)stopAlbum {
    if(!self.sessionReserved && !self.albumStarted)return;self.albumStopPending=YES;
    BOOL pending=SAPCancelArtistDownloadOwner(self.artistURI,self.token);self.sessionReserved=NO;
    if(self.active)self.albumStopPending=pending;
}
- (BOOL)isQueuedRelease:(NSString *)uri {NSNumber *position=self.releasePositions[uri];return position && position.unsignedIntegerValue>self.releaseIndex;}
- (void)detachBatch {
    self.batchWatching=NO;[self.releaseObservation invalidate];self.releaseObservation=nil;self.batchState=nil;self.batchEpoch++;
    if(self.batchDeadline){dispatch_source_cancel(self.batchDeadline);self.batchDeadline=nil;}
}
- (void)armBatchDeadline {
    if(self.batchDeadline)dispatch_source_cancel(self.batchDeadline);__weak typeof(self) weak=self;NSUInteger epoch=self.batchEpoch;
    self.batchDeadline=SAPScheduleDeadline(dispatch_get_main_queue(),900,^{typeof(self) task=weak;if(!task || !task.active || task.batchEpoch!=epoch)return;task.batchDeadline=nil;
        if(!task.cancelled)task.stopped=YES;[task finish:@"Spotify did not confirm the current release. Later tracks were not added. Continue to retry after checking the connection."];
    });
}
- (void)begin {
    if(!self.active || self.stopped || !self.queued)return;self.queued=NO;self.submitted=NO;self.nativeStarted=self.nativeReady=self.streamReady=self.finishing=self.feedClosed=NO;self.albumStarted=self.albumStopPending=NO;self.offset=self.index=self.releaseIndex=0;self.completedTracks=[NSMutableSet set];self.verifiedSources=[NSMutableSet set];
    __weak typeof(self) weak=self;self.deadline=SAPScheduleDeadline(dispatch_get_main_queue(),1800,^{[weak finish:@"Playlist preparation timed out. Confirmed additions were kept."];});
    if(self.plan){self.tracks=self.plan;[self target];}else{self.orderedTracks=[NSMutableOrderedSet orderedSet];[self resolve];}
}
- (void)save {
    if(!self.active || self.stopped)return;
    if(!self.streamReady){
        self.plan=[self.tracks copy];NSMutableArray *releases=[NSMutableArray array];
        for(NSDictionary *release in self.releases){NSArray *tracks=self.releaseTracks[release[@"uri"]];if(tracks.count)[releases addObject:@{@"uri":release[@"uri"],@"name":release[@"name"]?:@"Release",@"tracks":tracks}];}self.releasePlan=releases;NSMutableDictionary *positions=[NSMutableDictionary dictionary];for(NSUInteger i=0;i<releases.count;i++)positions[releases[i][@"uri"]]=@(i);self.releasePositions=positions;
        self.releases=nil;[self target];return;
    }
    if(self.index==self.batchSources.count){[self append];return;}
    NSString *uri=self.batchSources[self.index];if([self.verifiedSources containsObject:uri]){self.index++;[self save];return;}
    self.message=@"Preparing current tracks…";NSUInteger epoch=self.epoch;
    self.cancelRead=SAPCallReadOnlyServiceCancellable(libraryService,@"Contains",str(3,uri),^(NSData *data,NSString *error){
        if(![self valid:epoch])return;self.cancelRead=nil;NSArray *fields=SAPProtoFields(data);NSNumber *member=nil;
        if(!error.length && SAPProtoNumber(fields,98,0)==200)for(NSArray *entry in messages(fields,2))if([SAPProtoString(entry,1)isEqual:uri] && SAPProtoNumber(entry,2,0)<=1)member=@(SAPProtoNumber(entry,2,0));
        if(!member){self.stopped=YES;[self finish:error?:@"Spotify did not confirm library membership."];return;}
        if(member.boolValue){[self.verifiedSources addObject:uri];self.index++;[self save];return;}
        self.commandPending=YES;SAPAddAlbumToLibraryOnce(uri,^(__unused NSData *reply,__unused NSString *failure){if(!self.active || self.epoch!=epoch)return;self.commandPending=NO;if(self.stopped){[self settleStop];return;}[self verifyLibrary:uri attempt:0];});
    });
}
- (void)verifyLibrary:(NSString *)uri attempt:(NSUInteger)attempt {
    if(!self.active || self.stopped)return;NSUInteger epoch=self.epoch;
    self.cancelRead=SAPCallReadOnlyServiceCancellable(libraryService,@"Contains",str(3,uri),^(NSData *data,NSString *error){
        if(![self valid:epoch])return;self.cancelRead=nil;BOOL member=NO;NSArray *fields=SAPProtoFields(data);
        if(!error.length && SAPProtoNumber(fields,98,0)==200)for(NSArray *entry in messages(fields,2))if([SAPProtoString(entry,1)isEqual:uri] && SAPProtoNumber(entry,2,0)==1)member=YES;
        if(member){[self.verifiedSources addObject:uri];self.index++;[self save];return;}
        if(attempt>=5){self.stopped=YES;[self finish:error?:@"Spotify did not confirm this release in Your Library."];return;}
        self.retry=SAPScheduleDeadline(dispatch_get_main_queue(),MIN(5,attempt+1),^{self.retry=nil;if([self valid:epoch])[self verifyLibrary:uri attempt:attempt+1];});
    });
}
- (void)readTarget {
    self.message=@"Reading playlist contents…";NSUInteger epoch=self.epoch;
    self.cancelRead=readList(self.uri,^(NSDictionary *contents,NSString *error){
        if(![self valid:epoch])return;self.cancelRead=nil;
        if(!contents || ![contents[@"can_add"]boolValue]){[self finish:error?:@"Spotify does not allow adding tracks to this playlist."];return;}
        self.name=contents[@"name"]?:self.name;self.baseline=contents[@"items"];self.targetTracks=[NSMutableSet setWithArray:self.baseline];NSUInteger missing=0;for(NSString *track in self.plan)missing+=![self.targetTracks containsObject:track];
        if(self.baseline.count+missing>maximumPlaylistItems){[self finish:@"The destination playlist would exceed 10,000 items."];return;}
        self.streamReady=YES;[self advanceRelease];
    });
}
- (void)advanceRelease {
    if(!self.active || self.stopped)return;[self detachBatch];[self detachAlbumContext];self.albumStarted=self.albumStopPending=NO;self.currentBatch=nil;self.batchCommitted=NO;
    if(self.releaseIndex>=self.releasePlan.count){
        self.finishing=YES;NSUInteger epoch=self.epoch;self.message=@"Checking completed playlist…";
        self.cancelRead=readList(self.uri,^(NSDictionary *contents,NSString *error){
            if(![self valid:epoch])return;self.cancelRead=nil;
            if(!contents || ![contents[@"items"]isEqual:self.baseline]){self.stopped=YES;[self finish:error?:@"The playlist order changed. Confirmed additions were kept."];return;}
            [self submitPlaylist];
        });return;
    }
    self.batchRelease=self.releasePlan[self.releaseIndex];self.currentBatch=self.batchRelease[@"tracks"];self.batchSources=@[self.batchRelease[@"uri"]];self.index=0;itemTaskRevision++;
    SAPJournalNoteAction(@"playlist_release_prepared",@{@"operation":self.token,@"artist_uri":self.artistURI?:@"",@"release_uri":self.batchRelease[@"uri"],@"release_index":@(self.releaseIndex),@"track_count":@(self.currentBatch.count)});[self save];
}
- (void)append {
    if(!self.active || self.stopped)return;NSMutableArray *add=[NSMutableArray array];for(NSString *track in self.currentBatch)if(![self.targetTracks containsObject:track])[add addObject:track];self.appendTracks=add;self.appendIndex=0;[self appendChunk];
}
- (void)appendChunk {
    if(!self.active || self.stopped)return;
    if(self.appendIndex==self.appendTracks.count){self.batchCommitted=YES;[self submit];return;}
    NSArray *add=[self.appendTracks subarrayWithRange:NSMakeRange(self.appendIndex,MIN((NSUInteger)100,self.appendTracks.count-self.appendIndex))];
    NSUInteger start=self.baseline.count,epoch=self.epoch;NSMutableData *request=[str(1,@"add")mutableCopy];[request appendData:str(3,@"end")];for(NSString *track in add)[request appendData:str(7,track)];NSMutableData *outer=[str(1,self.uri)mutableCopy];[outer appendData:SAPProtoBytes(2,request)];self.commandPending=YES;self.message=@"Adding current release…";
    SAPCallPlaylistModificationOnce(NO,outer,^(NSData *reply,NSString *error){
        if(!self.active || self.epoch!=epoch)return;self.commandPending=NO;NSString *failure=error;BOOL acknowledged=!error.length && statusOK(SAPProtoFields(reply),&failure);
        // Only settle the already-sent chunk after cancellation; never replay it.
        self.cancelRead=readListFrom(self.uri,start,^(NSDictionary *contents,NSString *readError){
            if(!self.active || self.epoch!=epoch)return;self.cancelRead=nil;BOOL exact=contents && [contents[@"total"]unsignedIntegerValue]==start+add.count && [contents[@"items"]isEqual:add];
            SAPJournalNoteAction(@"playlist_release_append_verified",@{@"operation":self.token,@"playlist_uri":self.uri,@"release_uri":self.batchRelease[@"uri"],@"chunk_offset":@(self.appendIndex),@"appended":add,@"verified":@(exact),@"acknowledged":@(acknowledged),@"error":readError?:failure?:@"",@"automatic_replay":@NO});
            if(!exact){self.stopped=YES;[self finish:readError?:failure?:@"Spotify did not confirm the appended release. No append was repeated."];return;}
            self.baseline=[self.baseline arrayByAddingObjectsFromArray:add];[self.targetTracks addObjectsFromArray:add];self.addedCount+=add.count;self.appendIndex+=add.count;
            if(self.stopped){[self settleStop];return;}[self appendChunk];
        });
    });
}
- (void)submit {
    if(!self.active || self.stopped || self.albumStarted)return;
    self.albumStarted=YES;self.submitted=YES;self.message=@"Registering album for offline…";itemTaskRevision++;
    if(self.deadline){dispatch_source_cancel(self.deadline);self.deadline=nil;}
    NSDictionary *album=@{@"uri":self.batchRelease[@"uri"],@"name":self.batchRelease[@"name"]?:@"Release",@"artist_uri":self.artistURI,@"owner_token":self.token,@"track_count_verified":@YES,@"verified_track_count":@(self.currentBatch.count),@"follow_external_changes":@YES};NSString *error=nil;
    if(!SAPAppendArtistDownloadSessionReleases(@[album],&error)){self.stopped=YES;[self finish:error?:@"Spotify did not accept the album download."];return;}
    NSUInteger epoch=self.albumEpoch;__weak typeof(self) weak=self;
    dispatch_block_t detach=SAPObserveArtistDownloadSession(@[album],^(NSDictionary *snapshot){
        typeof(self) task=weak;if(!task || !task.active || task.terminating || task.albumEpoch!=epoch)return;
        NSDictionary *state=snapshot[@"album_states"][task.batchRelease[@"uri"]];if([task.albumContextState isEqual:state])return;task.albumContextState=state;
        if(task.stopped){[task settleStop];return;}
        if([task.albumContextState[@"phase"]isEqual:@"failed"]){task.stopped=YES;[task finish:task.albumContextState[@"error"]?:@"Spotify could not register this album for offline playback."];return;}
        [task checkBatch];
    });
    if(self.active && self.albumEpoch==epoch)self.detachAlbum=detach;else if(detach)detach();
    if(self.active&&!self.stopped)[self watchBatch];schedulePlaylistTasks();
}
- (void)submitPlaylist {
    if(!self.active || self.stopped || self.nativeStarted)return;
    // Album registrations have finished and released their shared queue slots.
    // The playlist now gets its own native offline registration as well.
    self.nativeStarted=YES;self.message=@"Registering playlist for offline…";
    NSDictionary *context=@{@"uri":self.uri,@"name":self.name?:@"Playlist",@"category":@"Playlist",@"refresh_after_append":@(self.addedCount>0),@"artist_uri":self.artistURI,@"owner_token":self.token,@"follow_external_changes":@YES};NSString *error=nil;
    if(!SAPAppendArtistDownloadSessionReleases(@[context],&error)){self.stopped=YES;[self finish:error?:@"Spotify did not accept the playlist download."];return;}
    NSUInteger epoch=self.epoch;__weak typeof(self) weak=self;
    dispatch_block_t detach=SAPObserveArtistDownloadSession(@[context],^(NSDictionary *snapshot){
        typeof(self) task=weak;if(!task || !task.active || task.terminating || task.epoch!=epoch)return;NSDictionary *state=snapshot[@"album_states"][task.uri];if([task.contextState isEqual:state])return;task.contextState=state;
        if(task.stopped){[task settleStop];return;}
        if([task.contextState[@"phase"]isEqual:@"failed"]){task.stopped=YES;[task finish:task.contextState[@"error"]?:@"Spotify could not register this playlist for offline playback."];return;}
        [task checkBatch];
    });
    if(self.active && self.epoch==epoch)self.detachSession=detach;else if(detach)detach();[self armBatchDeadline];schedulePlaylistTasks();
}
- (void)watchBatch {
    if(!self.active || !self.currentBatch.count || self.batchWatching || self.stopped || !self.albumStarted)return;
    self.batchWatching=YES;NSUInteger generation=++self.batchEpoch;__weak typeof(self) weak=self;
    NSDictionary *release=@{@"uri":self.batchRelease[@"uri"],@"track_count_verified":@YES,@"track_uris":self.currentBatch};
    SAPReleaseItemObservation *observation=SAPObserveReleaseItems(@[release],^(NSDictionary *snapshot){
        typeof(self) task=weak;if(!task || !task.active || task.batchEpoch!=generation || task.stopped)return;
        NSDictionary *state=snapshot[@"album_states"][task.batchRelease[@"uri"]];if(!state)return;BOOL changed=![task.batchState isEqual:state];task.batchState=state;if(changed)[task armBatchDeadline];[task checkBatch];
    });
    if(self.active && self.batchEpoch==generation)self.releaseObservation=observation;else[observation invalidate];[self armBatchDeadline];
}
- (void)checkBatch {
    if(!self.active)return;
    if(self.stopped){[self settleStop];return;}
    if(self.finishing){
        if(self.nativeStarted && ![self.contextState[@"owned"]boolValue] && ![self.contextState[@"submission_pending"]boolValue] && [self.contextState[@"state"]isEqual:@"downloaded"])[self finish:nil];
        else if([self.contextState[@"native_cancelled"]boolValue])[self publishMessage:@"Stopped in Spotify. Waiting for restart…"];
        return;
    }
    if(!self.albumStarted || !self.batchCommitted)return;
    if([self.albumContextState[@"native_cancelled"]boolValue]){[self publishMessage:@"Stopped in Spotify. Waiting for restart…"];return;}
    if([self.batchState[@"error"]length]){self.stopped=YES;[self finish:self.batchState[@"error"]];return;}
    NSUInteger done=[self.batchState[@"downloaded_tracks"]unsignedIntegerValue];
    if([self.albumContextState[@"state"]isEqual:@"downloaded"] && ![self.albumContextState[@"owned"]boolValue] && ![self.albumContextState[@"submission_pending"]boolValue] && [self.batchState[@"state"]isEqual:@"downloaded"] && [self.batchState[@"known_tracks"]unsignedIntegerValue]==self.currentBatch.count){
        [self.completedTracks addObjectsFromArray:self.currentBatch];self.offset=self.completedTracks.count;self.releaseIndex++;[self detachBatch];SAPJournalNoteAction(@"playlist_release_completed",@{@"operation":self.token,@"release_uri":self.batchRelease[@"uri"],@"completed_releases":@(self.releaseIndex),@"selected_releases":@(self.releasePlan.count)});[self advanceRelease];
    }else [self publishMessage:[NSString stringWithFormat:@"Downloading release %lu / %lu… %lu / %lu tracks",(unsigned long)self.releaseIndex+1,(unsigned long)self.releasePlan.count,(unsigned long)done,(unsigned long)self.currentBatch.count]];
}
- (void)settleStop {
    if(!self.active || self.terminating || !self.stopped || self.commandPending || self.cancelRead)return;
    if(self.albumStopPending && ([self.albumContextState[@"owned"]boolValue] || [self.albumContextState[@"stop_pending"]boolValue] || [self.albumContextState[@"submission_pending"]boolValue]))return;
    if(!self.nativeStarted){[self finish:nil];return;}
    if(![self.contextState[@"active"]boolValue] && ![self.contextState[@"stop_pending"]boolValue] && ![self.contextState[@"owned"]boolValue] && ![self.contextState[@"submission_pending"]boolValue])[self finish:nil];
}
- (void)stop {
    if(!self.active || self.stopped)return;self.stoppedVisuals=captureStoppedItemVisuals(self.sourceURIs);self.stopped=YES;itemTaskRevision++;self.message=@"Stopping…";[self detachBatch];
    if(!self.commandPending){dispatch_block_t cancel=self.cancelRead;self.cancelRead=nil;if(cancel)cancel();}
    [self stopAlbum];if(!self.active)return;if(self.nativeStarted)SAPStopArtistDownloadSessionRelease(self.uri);[self settleStop];
}
- (void)cancel {
    if(self.cancelled)return;BOOL wasStopped=self.stopped;self.cancelled=YES;self.resumeBlocked=YES;self.stoppedVisuals=nil;itemTaskRevision++;
    if(!self.active){SAPCancelArtistDownloadOwner(self.artistURI,self.token);self.stopped=NO;self.plan=nil;self.releasePlan=nil;self.releasePositions=nil;self.batchRelease=nil;self.completedTracks=nil;self.appendTracks=nil;self.releases=nil;SAPForgetPlaylistDownloadIntent(self.uri);publishTasks();return;}
    self.stopped=YES;self.message=@"Canceling…";[self detachBatch];
    if(!self.commandPending){dispatch_block_t cancel=self.cancelRead;self.cancelRead=nil;if(cancel)cancel();}
    // Disable the native offline context, retaining the playlist and its rows.
    // The shared session waits for its original Add ACK before sending Stop.
    if(!wasStopped){[self stopAlbum];if(!self.active)return;if(self.nativeStarted)SAPStopArtistDownloadSessionRelease(self.uri);}
    [self settleStop];publishTasks();
}
- (void)finish:(NSString *)error {
    if(!self.active || self.terminating)return;self.terminating=YES;[self detachBatch];if(self.sessionReserved || self.albumStarted)SAPCancelArtistDownloadOwner(self.artistURI,self.token);self.sessionReserved=NO;[self detachAlbumContext];if(self.nativeStarted && !self.feedClosed){self.feedClosed=YES;SAPClosePlaylistDownloadFeed(self.uri);}
    if(self.cancelled)SAPForgetPlaylistDownloadIntent(self.uri);
    if(!self.stopped || self.cancelled){self.plan=nil;self.releasePlan=nil;self.releasePositions=nil;self.batchRelease=nil;self.completedTracks=nil;self.appendTracks=nil;self.currentBatch=nil;self.batchSources=nil;self.targetTracks=nil;self.verifiedSources=nil;}
    [super finish:error];self.terminating=NO;
}
@end

#ifdef SAP_TESTING
void SAPPlaylistForgetInactiveMembershipForTesting(void){
    for(SAPPlaylistDownloadTask *task in tasks)if(!task.active)[task.releaseTracks removeAllObjects];itemTaskRevision++;reconcileItemObservers();
}
#endif
