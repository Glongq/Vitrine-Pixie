# How it works 2 — Pixie downloading and export at code level

This guide follows a Pixie function call into a Spotify internal command and through response handling. Excerpts come from the project's implementation. Blocks identified as schemas show message structures in readable form. Their numbers are actual Protobuf field numbers. Quoted source retains its original code, including bilingual UI strings.

## 1. The interface Pixie uses to call Spotify

The basic interface is an Objective-C method on a Spotify transport object.

```objective-c
callSingle:method:payload:onResponse:
```

It takes four arguments — the internal service name, method name, binary Protobuf payload, and response callback. The shared implementation calls it through `objc_msgSend` with an explicit function signature.

`NativeDownloads/src/Spotify/SpotifyServiceCalls.m`, lines 259–265.

```objective-c
    @try {
        SAPTraceWithOperation(call.traceOperation,^{
            // From this point a failed response cannot prove the command was unsent.
            call.invoked=YES;
            call.lifetime=((id (*)(id,SEL,id,id,id,id))objc_msgSend)(endpoint,selector,call.serviceName,call.method,call.payload,responseBlock);
        });
        SAPAcquireTransportHandle(call.lifetime);
```

At this point, `endpoint` is an existing app transport object. Pixie remembers instances observed in calls to `SPTEsperantoTransportBridgeImpl` and `SPTEsperantoCosmosTransport`. It also captures an `SPTEsperantoPlayer` object to read the current track.

This is an internal RPC between app components. Spotify's implementation handles subsequent network requests to servers and audio sources. The receiver in the calls below is a transport object inside the process.

`NativeDownloads/src/Spotify/SpotifyTransportHooks.m`, lines 70–81.

```objective-c
        for (NSString *name in @[@"SPTEsperantoTransportBridgeImpl", @"SPTEsperantoCosmosTransport"]) {
            cls = NSClassFromString(name);
            for (NSString *commandName in @[@"callSingle:method:payload:onResponse:", @"callStream:method:payload:onResponse:"]) {
                SEL command = NSSelectorFromString(commandName);
                if (!SAPTransportSignature(cls, command, 6, '@', &method)) continue;
                IMP original = method_getImplementation(method);
                putHook(cls, command, method, ^id(id self, id serviceName, id methodName, id payload, id callback) {
                    SAPRememberTransport(self, NO, NO);
#ifdef SAP_RUNTIME_TESTING
                    SAPRememberNativeCall(self, serviceName, methodName);
#endif
                    BOOL offline=[serviceName isKindOfClass:NSString.class] && [serviceName isEqual:SAPOfflineService];
```

Subscriptions use another Objective-C method.

```objective-c
callStream:method:payload:onResponse:
```

Its callback runs repeatedly as updates arrive. Pixie retains the subscription lifetime and releases it when observation is cancelled or replaced.

`NativeDownloads/src/Spotify/SpotifyServiceCalls.m`, lines 112–122.

```objective-c
    SEL selector=NSSelectorFromString(@"callStream:method:payload:onResponse:");
    BOOL (^responseBlock)(NSData *)=^BOOL(NSData *response){
        dispatch_async(SAPTransportWorker(),^{if(!stream.finished && stream.attempt==attempt)deliverReadOnlyStreamResponse(stream,response);});
        return !stream.isCancelled;
    };
    noteStream(stream,@"subscribe",nil);
    @try {
        stream.lifetime=((id (*)(id,SEL,id,id,id,id))objc_msgSend)(stream.endpoint,selector,stream.serviceName,stream.method,stream.payload,responseBlock);
        if(!stream.lifetime){tryReadOnlyStream(stream,@"stream_lifetime_missing");return;}
        SAPAcquireTransportHandle(stream.lifetime);
    } @catch(__unused NSException *exception){tryReadOnlyStream(stream,@"stream_exception");return;}
```

## 2. How the payload is actually constructed

The project has a small Protobuf codec. `SAPProtoBytes(number, value)` writes a field tag with wire type 2, the value length, and the bytes themselves. `SAPProtoInteger(number, value)` writes a wire type 0 tag followed by an integer encoded as a varint.

`NativeDownloads/src/Spotify/WireProto.m`, lines 45–50.

```objective-c
NSData *SAPProtoBytes(unsigned number, NSData *value) {
    NSMutableData *data = [NSMutableData data];
    appendInteger(data, ((uint64_t)number << 3) | 2); appendInteger(data, value.length); [data appendData:value]; return data;
}
NSData *SAPProtoInteger(unsigned number, uint64_t value) {
    NSMutableData *data = [NSMutableData data]; appendInteger(data, (uint64_t)number << 3); appendInteger(data, value); return data;
```

The expression below

```objective-c
SAPProtoBytes(2, [uri dataUsingEncoding:NSUTF8StringEncoding])
```

creates a message containing one string field numbered 2. Strings and nested messages share the length-delimited wire type. The schema of the particular method determines the field's meaning.

The example URI `spotify:track:0123456789012345678901` is 36 UTF-8 bytes long. Field 2 therefore begins with hexadecimal bytes `12 24`. `0x12` is the tag `(2 << 3) | 2`, and `0x24` is the length 36. The URI's ASCII bytes follow.

The same URI in field 1 begins with `0a 24`. This is the wire-level difference between the track registration request and its state read.

## 3. The exact Download Current Track path

The entry function is `SAPDownloadCurrentTrack`. It first reads `player.state.track.URI` and `trackTitle`, then checks the music URI and transport availability.

`NativeDownloads/src/Downloads/ManualTrackDownload.m`, lines 366–378.

```objective-c
void SAPDownloadCurrentTrack(void (^message)(NSString *)) {
    SAPInstallTrackDownloader();
    SAPTraceID trace=SAPTraceCurrentOperation();if(!trace&&SAPTraceIsActive())trace=SAPTraceBegin(@"download_current_track",@"pixie_api",@{});
    if(SAPDiagnosticsEnabled())SAPJournalRefresh(@"download button");
    if (atomic_load(&active)) { if (message) message(SAPTrackDownloadSummary()); return; }
    id state = SAPTransportObject(SAPTransportPlayer(), @"state"), track = SAPTransportObject(state, @"track"), uri = SAPTransportObject(track, @"URI");
    NSString *urlString = [uri isKindOfClass:NSURL.class] ? [uri absoluteString] : [uri isKindOfClass:NSString.class] ? uri : nil;
    NSString *trackTitle = SAPTransportObject(track, @"trackTitle");
    NSString *identifier = [urlString hasPrefix:@"spotify:track:"] ? [urlString substringFromIndex:14] : nil;
    NSCharacterSet *invalid = [NSCharacterSet characterSetWithCharactersInString:@"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"].invertedSet;
    if (identifier.length != 22 || [identifier rangeOfCharacterFromSet:invalid].location != NSNotFound) {
        SAP_JOURNAL_ACTION(@"single_track_rejected",@{@"reason":@"current_track_uri_unavailable"});
        if (message) message(SAPL(@"Не удалось определить текущий музыкальный трек. Запусти его на этом iPhone и повтори.",@"Could not identify the current music track. Start it on this iPhone and try again.")); return;
```

After initializing local state and the timer, it calls `SAPPrepareNativeOffline`. Successful preparation starts working-transport selection through `selectNextCandidate`.

`NativeDownloads/src/Downloads/ManualTrackDownload.m`, lines 403–413.

```objective-c
        NSUInteger expected = generation;
        atomic_store(&preparationGeneration, expected);
        SAPTraceWithOperation(jobTraceOperation,^{SAPPrepareNativeOffline(^BOOL{
            return atomic_load(&active) && atomic_load(&preparationGeneration) == expected;
        }, ^(BOOL ready, NSString *reason) {
            dispatch_async(SAPTransportWorker(), ^{
                if (!atomic_load(&active) || generation != expected) return;
                if (!ready) { finish(@"native_preparation_failed", reason); return; }
                selectNextCandidate();
            });
        });});
```

### GetItems comes first

Pixie calls the `spotify.offline_esperanto.proto.Offline` service's `GetItems` method. The payload places the URI in field 1.

`NativeDownloads/src/Downloads/ManualTrackDownload.m`, lines 338–344.

```objective-c
    jobTransport = jobCandidates[candidateIndex++]; candidateStarted = CFAbsoluteTimeGetCurrent();
    phase = @"probing_transport"; detail = SAPL(@"Проверяю доступ к загрузчику через GetItems",@"Checking downloader access through GetItems"); publish();
    single(@"GetItems", SAPProtoBytes(1, [jobURL.absoluteString dataUsingEncoding:NSUTF8StringEncoding]), ^(NSArray *fields) {
        if (!fields) { selectNextCandidate(); return; }
        routeVerified = YES; SAPRememberTransport(jobTransport, NO, YES); polls++; readItem(fields);
        started = CFAbsoluteTimeGetCurrent(); startRequest();
    });
```

The request schema is shown below.

```text
service = "spotify.offline_esperanto.proto.Offline"
method  = "GetItems"
payload = {
  1: "spotify:track:0123456789012345678901"
}
```

A valid response establishes that the selected transport instance answers the offline service request. `readItem` then extracts the specific URI's state, and `startRequest` decides whether another command is needed.

`NativeDownloads/src/Downloads/ManualTrackDownload.m`, lines 323–330.

```objective-c
static void startRequest(void) {
    startDiagnosticObservers();
    if (itemFound && (nativeState == 3 || nativeState == 4 || nativeState == 5 || nativeState == 6)) {
        existingDownload = YES; watchItems = YES;
        consecutiveComplete = nativeState == 3 ? 1 : 0;
        phase = @"checking_existing"; detail = SAPL(@"Трек уже скачан или находится в загрузке. Проверяю состояние без повторной команды",@"The track is already downloaded or downloading. Checking its status without sending another command");
        publish();
    } else addDownload();
```

When the track is already ready or in an active state, Pixie observes it. Otherwise, it calls `addDownload`.

### AddDownload is sent next

`NativeDownloads/src/Downloads/ManualTrackDownload.m`, lines 283–294.

```objective-c
static void addDownload(void) {
    commandSentAt=CFAbsoluteTimeGetCurrent();
    sentRequest = YES; phase = @"requesting"; publish();
    single(@"AddDownload", SAPProtoBytes(2, [jobURL.absoluteString dataUsingEncoding:NSUTF8StringEncoding]), ^(NSArray *fields) {
        if (!fields) { finish(@"invalid_response", SAPL(@"Получен некорректный ответ Offline.AddDownload. Скачивание не подтверждено.",@"Invalid Offline.AddDownload response. Downloading is not confirmed.")); return; }
        responseCode = @(SAPProtoNumber(fields, 1, 0));
        if (responseCode.unsignedLongLongValue) {
            finish(@"rejected", [NSString stringWithFormat:SAPL(@"Offline.AddDownload вернул %@ (%@). Это реальный код загрузчика; трек не отмечен как скачанный.",@"Offline.AddDownload returned %@ (%@). This is the actual downloader code; the track has not been marked as downloaded."), errorName(responseCode.unsignedLongLongValue), responseCode]); return;
        }
        watchItems = YES; phase = @"accepted"; detail = SAPL(@"Offline.AddDownload вернул SUCCESS. Проверяю полное скачивание трека",@"Offline.AddDownload returned SUCCESS. Checking that the track is fully downloaded");
        publish(); sendMessage(detail); queryItem();
    });
```

The actual request uses the same service name, method `AddDownload`, and URI in field 2.

```text
service = "spotify.offline_esperanto.proto.Offline"
method  = "AddDownload"
payload = {
  2: "spotify:track:0123456789012345678901"
}
```

The code reads varint field 1 from the response. Value `0` means the command was acknowledged successfully. An empty, existing `NSData` can also be a valid protobuf response with default-valued fields. `nil` indicates that a usable response is missing.

After acknowledgement, Pixie sets `watchItems = YES` and calls `queryItem` again. Spotify's core handles network downloading and storage at this stage.

## 4. Which response fields determine readiness

`readItem` iterates repeated messages in field 1 of the `GetItems` response. Each message supplies a URI in field 1, state in field 2, and progress in field 4.

`NativeDownloads/src/Downloads/ManualTrackDownload.m`, lines 216–223.

```objective-c
static void readItem(NSArray *fields) {
    itemFound = NO; nativeState = progress = 0;
    for (NSDictionary *field in fields) {
        if ([field[@"number"] unsignedIntValue] != 1 || [field[@"wire"] unsignedIntValue] != 2) continue;
        NSArray *item = SAPProtoFields(field[@"value"]);
        if (![SAPProtoString(item, 1) isEqual:jobURL.absoluteString]) continue;
        itemFound = YES; nativeState = SAPProtoNumber(item, 2, 0); progress = SAPProtoNumber(item, 4, 0); break;
    }
```

The relevant response schema is shown below.

```text
GetItemsResponse = {
  1: {
    1: "spotify:track:0123456789012345678901",
    2: state,
    4: sync_progress
  },
  1: { ... next item ... }
}
```

`queryItem` makes the completion decision.

`NativeDownloads/src/Downloads/ManualTrackDownload.m`, lines 225–238.

```objective-c
static void queryItem(void) {
    if (polling) return; polling = YES;
    single(@"GetItems", SAPProtoBytes(1, [jobURL.absoluteString dataUsingEncoding:NSUTF8StringEncoding]), ^(NSArray *fields) {
        polling = NO; polls++;
        if (!fields) { finish(@"invalid_response", SAPL(@"Не получен корректный ответ GetItems. Скачивание не подтверждено.",@"No valid GetItems response. Downloading is not confirmed.")); return; }
        readItem(fields);
        if(!itemFound || nativeState!=1)errorStateSince=0;
        if (itemFound && nativeState == 3) {
            phase = @"verifying"; detail = SAPL(@"Spotify сообщил, что трек скачан. Повторно проверяю состояние",@"Spotify reported the track as downloaded. Checking its status again");
            if (++consecutiveComplete >= 2) {
                finish(@"completed", [NSString stringWithFormat:SAPL(@"Spotify дважды сообщил, что «%@» скачан. Офлайн-воспроизведение не проверено. Отдельный файл не создан.",@"Spotify twice reported “%@” as downloaded. Offline playback has not been tested. No separate audio file was created."), title]); return;
            }
        } else {
            consecutiveComplete = 0;
```

It requires two consecutive observations of `state == 3`. Normal builds poll once per second. Another state resets the confirmation count. The AddDownload response and the ready state have separate roles in this sequence.

States from other APIs, including UI icons, have their own interpretation. Numeric values must be associated with the method that returned them.

## 5. What offline-manager preparation changes

### Client attributes

During hook installation, Pixie creates a dictionary of targeted attributes.

`NativeDownloads/src/Spotify/OfflineFlags.m`, lines 47–52.

```objective-c
void SAPInstallOfflineFlags(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        flags = @{@"offline": @"1", @"can-use-offline": @"1",
                  @"max-offline-downloads-per-device": @(SAPMinimumTrackLimit).stringValue, @"max-offline-tracks": @(SAPMinimumTrackLimit).stringValue};
        NSMutableArray *list = [NSMutableArray array];
```

The `SPTCoreProductState.stringForKey:` getter returns values from this dictionary for the selected keys.

`NativeDownloads/src/Spotify/OfflineFlags.m`, lines 60–67.

```objective-c
                if ([name isEqual:@"stringForKey:"]) coreRead = (void *)original;
                replace(cls, sel, method, ^id(id self, NSString *key) {
                    SAPTraceHookCalled(object_getClass(self),sel);
                    coreState = self;
                    NSString *forced = [key isKindOfClass:NSString.class] ? flags[key] : nil;
                    if (forced) { atomic_fetch_add(&forcedReads, 1);SAP_TRACE("flags","getter_override_returned",SAPTraceCurrentOperation(),@{@"key":key,@"returned":forced,@"original_getter_called":@NO,@"server_origin_proven":@NO});return forced; }
                    return ((id (*)(id, SEL, id))original)(self, sel, key);
                }, list);
```

Equivalent handlers cover boolean/integer getters and attribute dictionaries. `OfflineConfig.m` also inserts these attributes into recognized bootstrap/customize messages. Exact paths through the nested protobuf fields are defined in the code.

`NativeDownloads/src/Spotify/OfflineConfig.m`, lines 99–107.

```objective-c
NSData *SAPRewriteOfflineConfig(NSData *data, BOOL bootstrap) {
    // Account.pb.swift: Bootstrap[2][1][1].Customize[1].Ucs[3].Attributes(map[1]).
    const unsigned bootstrapPath[] = {2, 1, 1, 1, 3}, customizePath[] = {1, 3};
    BOOL found = NO;
    NSData *result = rewritePath(data, bootstrap ? bootstrapPath : customizePath, bootstrap ? 5 : 2, &found);
    SAP_TRACE("config","transform_result",SAPTraceCurrentOperation(),@{@"schema":bootstrap?@"bootstrap":@"customize",@"path_found":@(found),
        @"before":observedFlags(data,bootstrap),@"after":observedFlags(found&&result?result:data,bootstrap),@"bytes_changed":@(found&&result&&![result isEqual:data]),
        @"origin":@"input_at_transform_boundary",@"server_origin_proven":@NO,@"native_consumption_confirmed":@NO});
    return found && result ? result : data;
```

For `bootstrap`, the path is `2 → 1 → 1 → 1 → 3`. For `customize`, it is `1 → 3`. Targeted attribute-map entries are rewritten at the final level.

### The native restriction setter

`SAPPrepareNativeOffline` obtains the manager queue through `scheduler`, then submits `postBlock:` to it. The block checks the manager object, its vtable, and the expected executable image.

After reading the fields, it makes the following call.

`NativeDownloads/src/Spotify/NativeOfflineAdapter.m`, lines 454–463.

```objective-c
        const int32_t desiredDurationSeconds=SAPMinimumMusicDurationSeconds, desiredTrackLimit=SAPMinimumTrackLimit;
        BOOL changed=[before[@"music_limit"] intValue]<desiredTrackLimit || [before[@"music_duration_seconds"] longLongValue]<desiredDurationSeconds;
        if(changed) {
            int32_t newDuration=(int32_t)MAX([before[@"music_duration_seconds"] longLongValue],(long long)desiredDurationSeconds);
            int32_t newTrackLimit=(int32_t)MAX([before[@"music_limit"] intValue],desiredTrackLimit);
            ((void(*)(void *,int32_t,int32_t,int32_t,int32_t,int32_t))(image+setterOffset))(manager,newDuration,newTrackLimit,[before[@"episode_duration_seconds"] intValue],[before[@"episode_limit"] intValue],[before[@"abp_duration_seconds"] intValue]);
        }
        NSMutableDictionary *after=[NSMutableDictionary dictionary];
        BOOL stateValid=nativeState(wrapper,&manager,&image,after);
        NSDictionary *assessment=SAPAssessNativeSetup(after,stateValid);
```

The actual call signature is a function taking a `manager` pointer and five `int32_t` arguments. The first two numeric arguments are music duration and track count. The remaining values come from the manager state read earlier.

The builder declares the target minimums.

`NativeDownloads/tools/patch_native_restrictions.py`, lines 16–18.

```python
MINIMUM_TRACKS = 1_000_000
# The setter accepts signed int32 seconds even though its stored field is int64.
MINIMUM_MUSIC_DURATION_SECONDS = (1 << 31) - 1
```

A trampoline at the setter entry also clamps ordinary music values to these minimums. The following schema expresses its equivalent argument-handling logic.

```c
// Simplified equivalent of the ARM64 trampoline logic.
if (duration < 0 || tracks < 0) {
    original_setter(manager, duration, tracks, other_arguments);
} else {
    original_setter(
        manager,
        max(duration, 2147483647),
        max(tracks, 1000000),
        other_arguments
    );
}
```

After the call, Pixie reads the fields again and assesses readiness. Preparation therefore depends on the state read back from the manager.

## 6. How key request mode is set

The build calls `patch_key_request_mode.patch` with `runtime_selectable=False`. After verifying the original instructions, it writes ARM64 instruction `mov w2, #0` at the argument setup site.

`NativeDownloads/tools/patch_key_request_mode.py`, lines 123–134.

```python
    for address, expected in ((WINDOW, ORIGINAL), (PROVIDER, PROVIDER_HEAD),
                              (MAPPING, MAPPING_BYTES), (DLSYM_STUB, DLSYM_STUB_HEAD)):
        at = _offset(segments, address, len(expected))
        if data[at:at + len(expected)] != expected:
            raise ValueError(f'Key requester code differs at {address:#x}')
    call = _offset(segments, CALL_SITE, 4)
    if not runtime_selectable:
        out=bytearray(data)
        struct.pack_into('<I',out,call,0x52800002)
        return bytes(out), {'caller':hex(CALL_SITE),'original_mode':1,'initial_mode':0,
            'runtime_selectable':False,'implementation':'direct mov w2, #0; recovery rollback',
            'native_callbacks_and_persistence_unchanged':True}
```

The request-observation trampoline is installed next. For Request, it zeros the x2 slot in its saved register frame.

`NativeDownloads/tools/patch_native_trace.py`, lines 54–74.

```python
_trace_boundary:
 sub sp, sp, #320
{stores}
{vectors}
 mrs x17, nzcv
 str x17, [sp, #288]
 mrs x17, fpcr
 str x17, [sp, #296]
 mrs x17, fpsr
 str x17, [sp, #304]
 {'str xzr, [sp, #16]' if kind==0 else ''}
 movn x0, #1
 adr x1, Lname
 .long 0x90000010
 add x16, x16, #0
 blr x16
 cbz x0, Ldone
 mov x16, x0
 mov w0, #{kind}
 mov x1, sp
 blr x16
```

For `kind == 0`, the generator inserts `str xzr, [sp, #16]`. Registers occupy eight-byte slots, so offset 16 corresponds to x2. Restoring the registers before the original virtual call produces argument `x2 == 0`.

Here `w2` is the lower 32-bit half of x2, the register used by the ARM64 ABI for the third ordinary function argument. The original mode at the verified call site is `1`. The precise server-side names of these enums remain a subject for further investigation. The code directly establishes the argument replacement and the corresponding native-provider branch selection.

## 7. How album and playlist commands are sent

In the selected-release queue, `contextCommandWithDisposition` chooses the command based on URI kind.

`NativeDownloads/src/Downloads/ArtistSessionPrivate.h`, lines 76–81.

```objective-c
static inline void contextCommandWithDisposition(NSString *uri,BOOL enabled,void (^completion)(NSData *,NSString *,SAPCommandInvocationDisposition)){
    if(SAPIsPlaylistURI(uri))SAPSetPlaylistOfflineOnceWithDisposition(uri,enabled,completion);
    else SAPCallOfflineCommandOnceWithDisposition(enabled?@"AddDownload":@"RemoveDownload",SAPProtoBytes(2,[uri dataUsingEncoding:NSUTF8StringEncoding]),completion);
}
static inline void contextCommand(NSString *uri,BOOL enabled,void (^completion)(NSData *,NSString *)){
    contextCommandWithDisposition(uri,enabled,^(NSData *data,NSString *error,__unused SAPCommandInvocationDisposition disposition){completion(data,error);});
```

This produces two concrete paths.

| Object | Service and method | Payload |
| --- | --- | --- |
| Album release | `Offline.AddDownload` or `Offline.RemoveDownload` | Field 2 containing the album URI |
| Playlist | `PlaylistService.SetOfflineState` | Field 1 containing the playlist URI and varint field 3 set to 1 or 2 |

The full playlist service name and payload construction appear in the implementation.

`NativeDownloads/src/Spotify/SpotifyCommands.m`, lines 58–64.

```objective-c
void SAPSetPlaylistOfflineOnceWithDisposition(NSString *uri,BOOL enabled,
    void (^completion)(NSData *,NSString *,SAPCommandInvocationDisposition)) {
    NSString *identifier=[uri hasPrefix:@"spotify:playlist:"]?[uri substringFromIndex:17]:nil;
    NSCharacterSet *invalid=[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"].invertedSet;
    if(identifier.length!=22 || [identifier rangeOfCharacterFromSet:invalid].location!=NSNotFound){if(completion)dispatch_async(dispatch_get_main_queue(),^{completion(nil,@"Invalid playlist identity.",SAPCommandNotInvoked);});return;}
    NSMutableData *payload=[SAPProtoBytes(1,[uri dataUsingEncoding:NSUTF8StringEncoding])mutableCopy];[payload appendData:SAPProtoInteger(3,enabled?1:2)];
    SAPInvokeServiceOnce(@"spotify.playlist_esperanto.proto.PlaylistService",@"SetOfflineState",payload,completion);
```

The schema for enabling playlist downloading is shown below.

```text
service = "spotify.playlist_esperanto.proto.PlaylistService"
method  = "SetOfflineState"
payload = {
  1: "spotify:playlist:0123456789012345678901",
  3: 1
}
```

Disabling changes field 3 to `2`. For this URI, the string field begins with `0a 27`, because a playlist URI is 39 bytes long. The simplest enable request ends with bytes `18 01`.

### Checking library membership before registering an album

`preflight` first calls `Offline.GetContexts`. If a new registration is required, `readMembership` checks the album through `YourLibraryService.Contains`.

`NativeDownloads/src/Downloads/ReleaseDownloadOperation.m`, lines 217–230.

```objective-c
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
```

The exact messages for this part of the sequence have the following schemas.

```text
service = "spotify.your_library_esperanto.proto.YourLibraryService"
method  = "Contains"
payload = { 3: album_uri }

service = "spotify.collection_esperanto.proto.CollectionService"
method  = "Add"
payload = {
  2: {
    1: album_uri
  }
}
```

The nested Collection.Add payload is constructed as follows.

`NativeDownloads/src/Spotify/SpotifyCommands.m`, lines 69–74.

```objective-c
void SAPAddAlbumToLibraryOnce(NSString *albumURI,void (^completion)(NSData *,NSString *)) {
    if(!explicitAlbumURI(albumURI)) {if(completion)dispatch_async(dispatch_get_main_queue(),^{completion(nil,@"Invalid album identity for Collection.Add.");});return;}
    // collection_add_remove_items_request.proto: items=2, item.uri=1. This
    // matches the 40-byte request made by the normal album button in log 22.
    NSData *payload=SAPProtoBytes(2,SAPProtoBytes(1,[albumURI dataUsingEncoding:NSUTF8StringEncoding]));
    callExplicitServiceOnce(@"spotify.collection_esperanto.proto.CollectionService",@"Add",payload,completion);
```

Contains is repeated after Add. The response checks include field 98 equal to `200`, an absent error message in field 99, and the matching album entry. It then calls `requestDownload`, which hands the ready operation to the scheduler, and `submitDownload` sends the selected command.

## 8. Requests used to read album state

In the release queue, `contextRequest` constructs a nested policy field and a URI list.

`NativeDownloads/src/Downloads/ArtistSessionPrivate.h`, lines 47–53.

```objective-c
static inline NSData *urisRequest(NSArray *uris,unsigned field) {
    NSMutableData *data=[NSMutableData data];for(NSString *uri in uris)[data appendData:SAPProtoBytes(field,[uri dataUsingEncoding:NSUTF8StringEncoding])];return data;
}
static inline NSData *contextRequest(NSArray *uris) {
    // State only: no track-list scan is needed for the native context state.
    NSMutableData *data=[SAPProtoBytes(1,SAPProtoInteger(1,0))mutableCopy];[data appendData:urisRequest(uris,3)];return data;
}
```

The state-only read has the following schema.

```text
service = "spotify.offline_esperanto.proto.Offline"
method  = "GetContexts"
payload = {
  1: { 1: 0 },
  3: album_uri_1,
  3: album_uri_2
}
```

Field 3 repeats for each URI. In the separate album-before-export check, the nested varint is `1`.

`NativeDownloads/src/Export/TrackExport.m`, lines 318–321.

```objective-c
- (void)pollNativeAlbumContext {
    NSMutableData *request=[SAPProtoBytes(1,SAPProtoInteger(1,1))mutableCopy];
    [request appendData:SAPProtoBytes(3,[self.targetURI dataUsingEncoding:NSUTF8StringEncoding])];
    SAPCallReadOnlyService(@"spotify.offline_esperanto.proto.Offline",@"GetContexts",request,^(NSData *data,NSString *error){
```

The response is parsed as repeated field 1. Inside each entry, the code reads nested message 1, then its URI in field 1 and state in field 2.

`NativeDownloads/src/Export/TrackExport.m`, lines 325–339.

```objective-c
        BOOL found=NO;uint64_t state=0;
        for(NSDictionary *field in fields) {
            if([field[@"number"]unsignedIntValue]!=1 || [field[@"wire"]unsignedIntValue]!=2)continue;
            NSArray *info=SAPProtoFields(field[@"value"]),*context=SAPProtoFields(SAPProtoData(info,1));
            if(![SAPProtoString(context,1)isEqualToString:self.targetURI])continue;
            found=YES;state=SAPProtoNumber(context,2,0);break;
        }
        BOOL complete=found&&state==3,active=found&&(state==2||state==4||state==5);
        if(complete||active)self.startObserved=YES;
        SAP_TRACE("export","native_download_context_state",0,@{@"uri":self.targetURI,@"context_found":@(found),@"context_state":@(state),@"complete":@(complete),@"in_progress":@(active),@"download_command_requested":@(self.commandRequested)});
        if(found&&(state==1||state==7)) {
            [self finish:nil error:[NSString stringWithFormat:@"Spotify reported album download state %llu. No audio was exported.",state]];return;
        }
        if(complete) {
            if(++self.completeSamples>=2){[self status:@"Spotify reports the album downloaded. Exporting audio…"];[self beginWrite];return;}
```

For live observation, the queue opens `SubscribeContexts` and `SubscribeContextsProgress`. Progress uses repeated URI field 1. Passive context observation uses `contextRequest`. Already submitted albums use repeated field 3 with the native default policy.

`NativeDownloads/src/Downloads/ArtistSessionObservation.m`, lines 222–233.

```objective-c
    for(NSNumber *isProgress in @[@NO,@YES]) {
        BOOL progress=isProgress.boolValue;NSArray *watched=progress?uris:passiveURIs;
        for(NSUInteger offset=0;offset<watched.count;offset+=64) {
            NSArray *chunk=[watched subarrayWithRange:NSMakeRange(offset,MIN((NSUInteger)64,watched.count-offset))];
            NSNumber *identifier=@((progress?stateStreams:0)+offset/64);
            dispatch_block_t cancel=SAPSubscribeReadOnlyService(offlineService,progress?@"SubscribeContextsProgress":@"SubscribeContexts",progress?urisRequest(chunk,1):contextRequest(chunk),^(NSData *data,NSString *error){
                typeof(self) session=weak;if(!session || session.watchEpoch!=epoch)return;
                NSArray *fields=SAPProtoFields(data);
                if(error.length || !fields || (!progress && SAPProtoNumber(fields,2,0))){[session repairWatch:error.length?error:@"Spotify sent an invalid album status stream response."];return;}
                [session.watchPendingFirst removeObject:identifier];[session apply:data progress:progress live:YES owners:owners epoch:epoch];
                if(session.watchEpoch==epoch)[session finishRepair];
            });if(cancel)[self.watchCancels addObject:cancel];
```

`NativeDownloads/src/Downloads/ArtistSessionObservation.m`, lines 236–245.

```objective-c
    for(NSUInteger offset=0;offset<ownedURIs.count;offset+=64){
        NSArray *ownedChunk=[ownedURIs subarrayWithRange:NSMakeRange(offset,MIN((NSUInteger)64,ownedURIs.count-offset))];
        NSNumber *identifier=@(regularStreams+offset/64);
        // Match the native album page's default-policy observation, only for
        // submitted contexts. Passive catalog entries remain state-only.
        dispatch_block_t cancel=SAPSubscribeReadOnlyService(offlineService,@"SubscribeContexts",urisRequest(ownedChunk,3),^(NSData *data,NSString *error){
            typeof(self) s=weak;if(!s || s.watchEpoch!=epoch)return;
            NSArray *fields=SAPProtoFields(data);
            if(error.length || !fields || SAPProtoNumber(fields,2,0)){[s repairWatch:error.length?error:@"Spotify sent an invalid active context response."];return;}
            [s.watchPendingFirst removeObject:identifier];[s apply:data progress:NO live:YES owners:owners epoch:epoch];if(s.watchEpoch==epoch)[s finishRepair];
```

## 9. Why mutations are sent once

The shared `SAPInvokeServiceOnce` selects a verified transport and stores it as the only element in the endpoints array.

`NativeDownloads/src/Spotify/SpotifyServiceCalls.m`, lines 318–326.

```objective-c
    dispatch_async(SAPTransportWorker(),^{
        id endpoint=SAPProvenTransport();
        if(!endpoint){if(completion)dispatch_async(dispatch_get_main_queue(),^{completion(nil,@"No verified Spotify transport. Refresh the device state first.",SAPCommandNotInvoked);});return;}
        SAPReadOnlyCall *call=[SAPReadOnlyCall new];
        call.serviceName=serviceName;call.method=method;call.payload=payload;call.endpoints=@[endpoint];
        call.traceOperation=parent;
        call.commandCompletion=^(NSData *data,NSString *error,SAPCommandInvocationDisposition disposition){
            SAP_JOURNAL_ACTION(replyEvent,@{@"service":serviceName,@"method":method,@"response_received":@(data!=nil),@"response_bytes":@(data.length),@"error":error?:@"",@"automatic_replay":@NO,@"transport_invoked":@(disposition==SAPCommandInvoked)});
            if(completion)completion(data,error,disposition);
```

Immediately before entering `objc_msgSend`, it sets `call.invoked = YES`. An exception or timeout after entry is therefore classified as an ambiguous outcome of an invoked command. When `tryReadOnlyCall` exhausts the single-element array, the operation finishes with an error.

For ordinary reads, the array can contain multiple eligible endpoints. For a mutation, this list contains one element. After an ambiguous outcome, the code relies on GetItems/GetContexts and subscriptions.

Album cancellation also reads context state first. When necessary, it sends the corresponding RemoveDownload or SetOfflineState and reconciles state again.

## 10. A significant difference between the two album paths

The release queue actually passes an album URI to Offline.AddDownload through `contextCommandWithDisposition`. Album preparation for export uses a different entry point — a direct call to `makeEntityAvailableOfflineWithURL:trackURLs:`.

`NativeDownloads/src/Export/TrackExport.m`, lines 233–246.

```objective-c
        if([self.targetURI hasPrefix:@"spotify:album:"]) {
            // Offline.AddDownload's wire message (DownloadRequest: uri +
            // music_video_uris) has no context field — it only actually queues
            // individual items. Sending it an album/context URI is acknowledged
            // (SUCCESS) but the context never leaves state 0: confirmed on-device
            // in the 2026-10-30 export7 log (native_download_context_state stayed
            // context_state=0 for the full 30s after a code:0 reply). Spotify's own
            // playlist/album "Download" row instead calls
            // -[SPTOfflineManagerImplementation makeEntityAvailableOfflineWithURL:trackURLs:]
            // with the context URL and every track URL — call that directly.
            NSMutableArray<NSString *> *trackURIs=[NSMutableArray arrayWithCapacity:self.resolved.count];
            for(NSDictionary *track in self.resolved) if([track[@"uri"] isKindOfClass:NSString.class])[trackURIs addObject:track[@"uri"]];
            SAP_TRACE("export","native_download_requested",0,@{@"uri":self.targetURI,@"automatic_replay":@NO,@"source":@"native_entity_make_available_offline",@"track_count":@(trackURIs.count)});
            SAPMakeEntityAvailableOffline(self.targetURI,trackURIs,^(BOOL attempted,NSString *reason){
```

The comment records an earlier device observation where AddDownload with an album URI returned success while context state stayed at zero. The export path therefore collects every track URI and invokes the native album handler.

The actual invocation is in `SAPInvokeNativeAlbumCommand`.

`NativeDownloads/src/Spotify/NativeAlbumCommand.m`, lines 22–35.

```objective-c
    SEL selector=NSSelectorFromString(@"makeEntityAvailableOfflineWithURL:trackURLs:");
    Method method=class_getInstanceMethod(object_getClass(manager),selector);char type[16]={0};
    if(!method || method_getNumberOfArguments(method)!=4) {if(reason)*reason=@"Spotify's native album download handler is unavailable.";return NO;}
    method_getReturnType(method,type,sizeof(type));BOOL valid=type[0]=='v';
    for(unsigned i=2;i<4;i++) {method_getArgumentType(method,i,type,sizeof(type));valid=valid && type[0]=='@';}
    if(!valid) {if(reason)*reason=@"Spotify's native album handler signature does not match.";return NO;}
    @try {
        // Dispatch through the current implementation, preserving other mods'
        // hooks and Spotify's own scheduler/context registration behavior.
        ((void(*)(id,SEL,id,id))objc_msgSend)(manager,selector,[NSURL URLWithString:albumURI],[urls copy]);
    }@catch(NSException *exception) {
        if(reason)*reason=[NSString stringWithFormat:@"The native handler raised %@. Its result is unconfirmed; the command was not retried.",exception.name];return NO;
    }
    return YES;
```

In Objective-C terms, the call is equivalent to the following.

```objective-c
[manager makeEntityAvailableOfflineWithURL:albumURL
                                trackURLs:allTrackURLs];
```

Spotify receives the context URL and the complete track URL array. The call goes through the method's current implementation, including its installed hooks.

Both album paths exist in the current code. Their equivalence needs a separate check against actual context and item transitions. The historical observation in the comment indicates a potential problem in the album RPC path, while outcomes in another build or session still require observation.

## 11. Export starts with a specific GetEntity

`resolveNext` obtains track metadata through `ClassicMetadataService.GetEntity`.

`NativeDownloads/src/Export/TrackExport.m`, lines 127–140.

```objective-c
- (void)resolveNext {
    if(self.finished)return;
    while(self.resolved.count<self.tracks.count&&[self.tracks[self.resolved.count][@"audio_files"] count]&&[self.tracks[self.resolved.count][@"metadata_complete"]boolValue]){NSMutableDictionary *track=[self.tracks[self.resolved.count]mutableCopy];track[@"files"]=track[@"audio_files"];[self.resolved addObject:track];}
    if(self.resolved.count==self.tracks.count){[self prepareNextArtwork];return;}
    NSString *uri=self.tracks[self.resolved.count][@"uri"];
    SAPCallReadOnlyService(@"spotify.metadata_esperanto.proto.ClassicMetadataService",@"GetEntity",SAPProtoBytes(1,[uri dataUsingEncoding:NSUTF8StringEncoding]),^(NSData *response,NSString *error){
        if(self.finished)return;
        NSDictionary *track=response?trackMetadata(response,uri):nil;if(!track){[self finish:nil error:error?:@"Track metadata is unavailable; nothing was exported."];return;}
        NSMutableDictionary *merged=[self.tracks[self.resolved.count]mutableCopy];
        [track enumerateKeysAndObjectsUsingBlock:^(id key,id value,BOOL *stop){
            BOOL albumIdentity=[self.targetURI hasPrefix:@"spotify:album:"]&&[@[@"album_name",@"album_uri",@"artist_name",@"year"]containsObject:key]&&merged[key]!=nil;
            if(!albumIdentity&&(![value isKindOfClass:NSString.class]||[value length]))merged[key]=value;
        }];
        [self.resolved addObject:merged];[self resolveNext];
```

The request schema is shown below.

```text
service = "spotify.metadata_esperanto.proto.ClassicMetadataService"
method  = "GetEntity"
payload = {
  1: track_uri
}
```

`trackMetadata` extracts envelope field 1, checks the nested item's status in field 1, and reads the track message from field 4. Within the track, it reads the title from field 2, duration as a ZigZag integer from field 7, and repeated audio-file messages from field 12.

`NativeDownloads/src/Export/TrackExport.m`, lines 40–49.

```objective-c
static NSArray *fileIDs(NSArray *fields){NSMutableArray *ids=[NSMutableArray array];for(NSDictionary *f in fields)if([f[@"number"]unsignedIntValue]==12&&[f[@"wire"]unsignedIntValue]==2){NSData *d=SAPProtoData(SAPProtoFields(f[@"value"]),1);if(d.length==20&&![ids containsObject:d])[ids addObject:d];}return ids;}
static NSDictionary *trackMetadata(NSData *data,NSString *uri) {
    NSArray *envelope=SAPProtoFields(data),*item=SAPProtoFields(SAPProtoData(envelope,1));
    if(SAPProtoNumber(item,1,0))return nil;NSArray *track=SAPProtoFields(SAPProtoData(item,4));NSString *name=SAPProtoString(track,2);int64_t duration=SAPProtoSInt(track,7,0);NSArray *ids=fileIDs(track);
    if(!name.length||!ids.count||duration<=0||duration>86400000)return nil;
    NSArray *album=SAPProtoFields(SAPProtoData(track,3));
    return @{@"uri":uri,@"name":name,@"duration_ms":@(duration),@"files":ids,
        @"cover_image_uri":SAPExportAlbumCoverURI(album)?:@"",@"album_uri":SAPExportAlbumURI(album)?:@"",
        @"artist_name":SAPExportArtistName(track,4)?:SAPExportArtistName(album,3)?:@"Unknown artist",
        @"album_name":SAPProtoString(album,2)?:name,@"year":@(SAPProtoSInt(SAPProtoFields(SAPProtoData(album,6)),1,0)),@"number":@(MAX(1,SAPProtoSInt(track,5,1))),@"disc":@(MAX(1,SAPProtoSInt(track,6,1)))};
```

Each audio-file message contributes a 20-byte value from field 1. These values become the `track[@"files"]` array used for key and cache lookup. The track's Spotify URI and its binary file IDs serve different stages.

## 12. Commands export sends when audio still needs downloading

For a track, `pollNativeDownload` sends GetItems. The payload contains repeated field 1 with the unique URIs of all required tracks. Two readiness confirmations lead to `beginWrite`.

When registration is needed for the current track, `requestNativeDownload` makes the following call.

`NativeDownloads/src/Export/TrackExport.m`, lines 256–267.

```objective-c
        SAP_TRACE("export","native_download_requested",0,@{@"uri":self.targetURI,@"automatic_replay":@NO,@"source":@"ordinary_spotify_offline_AddDownload"});
        SAPCallOfflineCommandOnce(@"AddDownload",SAPProtoBytes(2,[self.targetURI dataUsingEncoding:NSUTF8StringEncoding]),^(NSData *data,NSString *error){
            NSArray *fields=data?SAPProtoFields(data):nil;
            self.nativeAddInFlight=NO;self.temporaryOutcomeUnknown=fields==nil;
            if(fields&&SAPProtoNumber(fields,1,0)==0)self.temporaryAddAccepted=YES;
            if(self.finished){[self completeTemporaryFinish];return;}
            if(!fields){[self finish:nil error:error?:@"Spotify did not confirm the download request. It was not sent again."];return;}
            uint64_t code=SAPProtoNumber(fields,1,0);
            SAP_TRACE("export","native_download_reply",0,@{@"uri":self.targetURI,@"code":@(code),@"download_completion_verified":@NO});
            if(code){[self finish:nil error:[NSString stringWithFormat:@"Spotify rejected the download request (code %llu). No audio was exported.",code]];return;}
            [self status:@"Spotify is downloading the audio for export…"];
            [self schedulePoll];
```

For an album, it uses the `makeEntityAvailableOfflineWithURL:trackURLs:` call shown earlier, followed by GetContexts polling. The export path polls every 1.5 seconds. Writing requires two confirmations of the ready state. Previously prepared and validated export files can also be reused.

## 13. How a hook passes observations to the exporter

Export-observation trampolines create register snapshots and resolve `SAPObserveExportBoundaryV2` through dlsym. They pass a numeric kind and a pointer to the saved frame. The dispatcher checks the image UUID and directs events to the appropriate module.

`NativeDownloads/src/Export/ExportObservation.m`, lines 34–49.

```objective-c
        if(kind==0){atomic_fetch_add(&cacheBoundaries,1);SAPNativeCacheObserve(registers,image);}
        else if(kind==1){atomic_fetch_add(&streamBoundaries,1);SAPExportObserveStreamSuccess(registers,image);}
        else if(kind<4)SAPObserveCacheStorageKey(registers,image);
        else if(kind==4)SAPObserveMediaKeyPath(registers,image);
        else if(kind==5){atomic_fetch_add(&blobBoundaries,1);SAPExportObserveMediaKeyBlob(registers,image);}
        else if(kind==6)SAPObserveMediaContext(registers,image);
        else if(kind==7){atomic_fetch_add(&recordBoundaries,1);SAPObserveMediaRecord(registers,image);}
        else if(kind==10)SAPExportObserveUnsealedMediaKey((const SAPExportRegisterFrame *)registers,image);
    }@catch(__unused NSException *exception){/* Observation must not change native execution. */}}
}
__attribute__((visibility("default"))) void SAPObserveExportBoundaryV2(unsigned kind,const SAPExportRegisterFrame *frame) {
    Dl_info info={0};
    if(!frame||!dladdr(__builtin_return_address(0),&info))return;
    dispatchBoundary(kind,frame->x,(uintptr_t)info.dli_fbase);
}
// Compatibility with historical entry thunks only. Mid-function probes with
```

In particular, `kind == 0` goes to `SAPNativeCacheObserve`, cipher-setup events go to `SAPObserveCacheStorageKey`, and `kind == 10` goes to `SAPExportObserveUnsealedMediaKey`.

The unsealed-key observer verifies the call site, reads the saved file-ID address from the caller frame, copies 16 bytes from `q0`, and calls `storeKeyWithOrigin(file, key, YES)`.

`NativeDownloads/src/Export/ExportKeyStore.m`, lines 41–51.

```objective-c
    // The unsealing function saves caller x20 at [fp-16] and caller LR at [fp+8].
    // Only the native key-store call at SAPMediaUnsealCallerOffset has a proven file-ID x20;
    // its return address is SAPExportUnsealCallerReturnOffset.
    uintptr_t fp=(uintptr_t)frame->x[29],caller=0,fileAddress=0;
    uint8_t file[20]={0},key[16]={0};
    if(fp<16||fp>UINTPTR_MAX-8||!readMemory(fp+8,&caller,8)||caller!=image+SAPExportUnsealCallerReturnOffset||
       !readMemory(fp-16,&fileAddress,8)||!readMemory(fileAddress,file,sizeof(file))) {
        atomic_fetch_add(&unsealedScopeRejections,1);return;
    }
    memcpy(key,frame->q[0],sizeof(key));
    storeKeyWithOrigin(file,key,YES);atomic_fetch_add(&unsealedKeyCaptures,1);
```

This supplies concrete data used later by export — an association between a file ID and the native unsealing result. Callback observations and opaque key-material records are stored separately. An already observed unsealed key has precedence over subsequent updates.

## 14. How the physical cache filename is calculated

`SAPNativeCacheObserve` reads 20 namespace bytes from the owner object and a 24-byte descriptor. It extracts file ID, kind, and index from the descriptor, builds a 44-byte material buffer, and calculates two SHA1 hashes.

`NativeDownloads/src/Export/NativeCacheMap.m`, lines 42–55.

```objective-c
    uint8_t material[44]={0},descriptor[24]={0};
    uintptr_t owner=(uintptr_t)registers[0];
    if(owner>UINTPTR_MAX-SAPExportCacheNamespaceOffset||!readMemory(owner+SAPExportCacheNamespaceOffset,material,20)||
       !readMemory((uintptr_t)registers[1],descriptor,sizeof(descriptor))) {
        clearMemory(material,sizeof(material));clearMemory(descriptor,sizeof(descriptor));
        os_unfair_lock_lock(&mappingLock);guardVerified=YES;readFailures++;os_unfair_lock_unlock(&mappingLock);return;
    }
    SAPCacheMapping entry={0};memcpy(entry.fileID,descriptor,20);
    entry.kind=descriptor[20];entry.index=(uint16_t)(descriptor[22]|((uint16_t)descriptor[23]<<8));
    memcpy(material+20,descriptor,21);material[41]=0;memcpy(material+42,descriptor+22,2);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CC_SHA1(material,sizeof(material),entry.cacheID);
    CC_SHA1(material,20,entry.namespaceID);
```

The material is assembled according to the following exact schema.

```text
material[0..19]   = namespace_bytes[0..19]
material[20..39]  = descriptor.file_id[0..19]
material[40]     = descriptor.kind
material[41]     = 0
material[42..43] = descriptor.index_bytes

cacheID     = SHA1(material[0..43])
namespaceID = SHA1(namespace_bytes[0..19])
```

`SAPExportCacheNamespaceOffset` comes from a generated header based on verified instructions in the target binary. The mapping is retained in memory and an index. Later, `SAPNativeCacheCandidates(fileID)` returns candidates for that audio file.

The physical file is read through the following code.

`NativeDownloads/src/Export/TrackCacheExport.m`, lines 315–335.

```objective-c
    for(NSData *identifier in track[@"files"]) {
        if(exportWasCancelled(cancelled,failure))return NO;
        NSString *idHex=hex(identifier);lastID=idHex;
        NSArray *observed=SAPNativeCacheCandidates(identifier);
        if(tryChunkAssembly(identifier,observed,folder,number,track,result,failure,cancelled))return YES;
        if(exportWasCancelled(cancelled,failure))return NO;
        NSArray *candidates=orderedCandidates(observed,idHex);
        NSUInteger lookupCount=0,openFailureCount=0;NSMutableArray *lookupFailures=SAPTraceIsActive()?[NSMutableArray array]:nil;
        for(NSDictionary *candidate in candidates) {
        if(exportWasCancelled(cancelled,failure))return NO;
        NSString *cacheID=candidate[@"cache_id_hex"];
        if(cacheID.length!=40)continue;
        for(NSString *cacheRoot in @[@"Library/Application Support/PersistentCache/Storage",@"Library/Caches/VolatileCache"]) {
            if(exportWasCancelled(cancelled,failure))return NO;
        NSString *path=[[NSHomeDirectory() stringByAppendingPathComponent:cacheRoot] stringByAppendingPathComponent:[NSString stringWithFormat:@"%@/%@.file",[cacheID substringToIndex:2],cacheID]];
        // Reject symlinks, non-regular files and unreasonable sizes before reading.
        int descriptor=open(path.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW);lookupCount++;
        if(descriptor<0){int saved=errno;openFailureCount++;if(lookupFailures&&lookupFailures.count<32)[lookupFailures addObject:@{@"cache_id_hex":cacheID,@"root":cacheRoot,@"errno":@(saved)}];continue;}struct stat before;
        if(fstat(descriptor,&before)||!S_ISREG(before.st_mode)||before.st_size<30||before.st_size>1024LL*1024*1024){close(descriptor);continue;}cacheSeen=YES;openedCount++;
        SAP_TRACE("export","cache_candidate_opened",0,@{@"file_identifier":idHex,@"cache_root":cacheRoot,@"cache_id_hex":cacheID,@"native_mapping":@(candidate[@"namespace_id_hex"]!=nil),@"descriptor_kind":candidate[@"descriptor_kind"]?:NSNull.null,@"descriptor_index":candidate[@"index"]?:NSNull.null,@"bytes":@(before.st_size)});
        FILE *physical=fdopen(descriptor,"rb");if(!physical){close(descriptor);continue;}
```

The resulting path pattern is `<cacheRoot>/<first two cacheID characters>/<cacheID>.file`. The code checks file type, allowed size, and source stability during processing. Fragmented storage is handled by `tryChunkAssembly`.

## 15. How the storage envelope is extracted

For a candidate with a namespace, the exporter first looks for a storage key in memory through `SAPCopyCacheStorageKey`, then consults `SAPVaultCopyStorage` when needed. The constructed descriptor and key are passed to `SAPExtractCacheEnvelopeCancellable`.

`NativeDownloads/src/Export/TrackCacheExport.m`, lines 336–350.

```objective-c
        FILE *input=physical,*payload=NULL;uint8_t key[16]={0},storageKey[16]={0},nativeDescriptor[24]={0};
        BOOL haveKey=SAPExportKeyStoreCopyKey(identifier,key);BOOL nativeUnsealed=haveKey&&SAPExportKeyStoreIsUnsealed(identifier);
        if(!nativeUnsealed&&SAPVaultCopyMedia(identifier,candidate[@"namespace_id_hex"],key)){haveKey=YES;nativeUnsealed=YES;}
        keySeen|=haveKey;
        BOOL haveStorageKey=SAPCopyCacheStorageKey(candidate[@"namespace_id_hex"],storageKey);
        if(!haveStorageKey)haveStorageKey=SAPVaultCopyStorage(candidate[@"namespace_id_hex"],storageKey);
        NSURL *payloadURL=[folder URLByAppendingPathComponent:@".cache-payload"];
        if(candidate[@"namespace_id_hex"] && identifier.length==20) {
            memcpy(nativeDescriptor,identifier.bytes,20);
            nativeDescriptor[20]=[candidate[@"descriptor_kind"]unsignedIntValue];
            unsigned index=[candidate[@"index"]unsignedIntValue];
            nativeDescriptor[22]=(uint8_t)index;nativeDescriptor[23]=(uint8_t)(index>>8);
            payload=fopen(payloadURL.path.fileSystemRepresentation,"w+b");
            SAPCacheEnvelopeDetails envelope={0};
            BOOL decoded=payload && SAPExtractCacheEnvelopeCancellable(physical,payload,haveStorageKey?storageKey:NULL,nativeDescriptor,&envelope,exportContinue,(__bridge void *)cancelled);
```

`CacheEnvelope.c` checks the header or footer, magic value, Adler checksum, payload length, and block table. One incomplete-file indicator is a block-table entry equal to `UINT32_MAX`.

`NativeDownloads/src/Export/CacheEnvelope.c`, lines 60–76.

```c
        uint64_t headerOffset=tail?(uint64_t)total-64:0;
        if(!readAt(input,headerOffset,head,sizeof(head),useKey,descriptor))return reject(details,"header_read_failed");
        if(le32(head+4)!=0x617233ab || le32(head)!=adler(head+4,60))continue;
        uint64_t size=le32(head+8);
        if(!size || size>1024ULL*1024*1024 || head[32]!=descriptor[20] || head[33])
            return reject(details,"invalid_header");
        uint64_t count=(size+16383)/16384,metadata=64+4*count;
        uint64_t padding=(uint64_t)head[34]|(uint64_t)head[35]<<8|(uint64_t)head[44]<<16;
        if(metadata>(uint64_t)total || padding>(uint64_t)total-metadata ||
           (uint64_t)total-metadata-padding!=size)return reject(details,"inconsistent_size");
        uint64_t table=tail?(uint64_t)total-metadata:64;
        for(uint64_t at=0;at<count;) {
            if(!SAPExportMayContinue(keepGoing,context))return reject(details,"cancelled");
            size_t n=(size_t)(count-at);if(n>sizeof(buffer)/4)n=sizeof(buffer)/4;
            if(!readAt(input,table+at*4,buffer,n*4,useKey,descriptor))return reject(details,"block_table_read_failed");
            for(size_t i=0;i<n;i++)if(le32(buffer+i*4)==UINT32_MAX)return reject(details,"incomplete_blocks");
            at+=n;
```

Supported encrypted variants use CommonCrypto AES-CTR. The payload is extracted into a temporary file and becomes the media layer's input.

## 16. How a usable media interpretation is selected

The exporter first checks for an already readable payload. With keys or key-material records available, it then considers a bounded set of interpretations. `SAPMediaBuildVariants` includes callback-key choices and several slices of an opaque blob. Additional data comes from observed native records.

The quick `SAPMediaPreview` check looks for a recognizable Vorbis beginning. A candidate passing the preview is processed fully into a temporary file.

`NativeDownloads/src/Export/TrackCacheExport.m`, lines 409–415.

```objective-c
                    if(cancelled&&cancelled())break;
                    if(!SAPMediaPreview(input,&rv,128*1024))continue;
                    rewind(input);FILE *rtmp=fopen(scratch.path.fileSystemRepresentation,"w+b");if(!rtmp)break;
                    BOOL rcopied=SAPMediaDecryptFileCancellable(input,rtmp,&rv,exportContinue,(__bridge void *)cancelled);uint64_t rstart=0,rlength=0;
                    BOOL rdiagnosing=SAPTraceIsActive();uint64_t rgeneration=rdiagnosing?SAPTraceGeneration():0;SAPOggExportDiagnostics rdetails={0};
                    BOOL rvalid=rcopied&&SAPValidateOggExportDetailedCancellable(rtmp,[track[@"duration_ms"]unsignedLongLongValue],&rstart,&rlength,rdiagnosing?&rdetails:NULL,exportContinue,(__bridge void *)cancelled);
                    if(rcopied&&rdiagnosing)SAPTraceOggValidationCancellable(rtmp,&rdetails,[track[@"duration_ms"]unsignedLongLongValue],@{@"track_uri":track[@"uri"]?:@"",@"file_identifier":idHex,@"cache_id_hex":cacheID,@"route":@"cached_media_record",@"skip":@(rv.skip),@"counter":@(rv.counter),@"counter_endian":rv.little_endian?@"little":@"big",@"key_source":@(rv.keyLabel),@"iv_source":@(rv.ivLabel)},rgeneration,exportContinue,(__bridge void *)cancelled);
```

Success requires `SAPValidateOggExportDetailedCancellable`. Full validation covers Ogg structure, CRC, page ordering, Vorbis headers, packet completeness, EOS, and expected duration.

The algorithm applies data acquired from native code and checks several interpretations of its format. An interpretation is accepted after validating the resulting audio. The opaque nature of some internal records is reflected in the bounded variant list and separate failure reasons.

## 17. Commands sent during key refresh

`refreshKeysForTracks` prepares the URI list. `removeNext` then sends RemoveDownload sequentially.

`NativeDownloads/src/Export/TrackExport.m`, lines 409–419.

```objective-c
- (void)removeNext:(NSUInteger)index {
    if(self.finished)return;
    if(index>=self.refreshURIs.count){[self waitRemoved];return;}
    NSString *uri=self.refreshURIs[index];
    SAPCallOfflineCommandOnce(@"RemoveDownload",SAPProtoBytes(2,[uri dataUsingEncoding:NSUTF8StringEncoding]),^(NSData *data,NSString *error){
        if(self.finished)return;
        NSArray *fields=data?SAPProtoFields(data):nil;
        SAP_TRACE("export","key_refresh_rpc_remove",0,@{@"uri":uri,@"reply_received":@(fields!=nil),@"code":fields?@(SAPProtoNumber(fields,1,0)):NSNull.null,@"error":error?:NSNull.null});
        if(!fields || SAPProtoNumber(fields,1,0)!=0){[self finish:nil error:error?:@"Spotify did not confirm removal of the offline copy. Nothing was downloaded again."];return;}
        [self removeNext:index+1];
    });
```

Each removal request has the following schema.

```text
service = "spotify.offline_esperanto.proto.Offline"
method  = "RemoveDownload"
payload = { 2: track_uri }
```

Next, `waitRemoved` reads GetItems with field 1 for each URI. It waits until the entries have left completed or active states, then proceeds to `addNext`.

`NativeDownloads/src/Export/TrackExport.m`, lines 455–464.

```objective-c
- (void)addNext:(NSUInteger)index {
    if(self.finished)return;
    if(index>=self.refreshURIs.count){self.commandRequested=YES;self.refreshStarted=NSDate.timeIntervalSinceReferenceDate;self.completeSamples=0;[self status:@"Waiting for Spotify to finish the requested downloads…"];[self waitKeys];return;}
    NSString *uri=self.refreshURIs[index];
    SAPCallOfflineCommandOnce(@"AddDownload",SAPProtoBytes(2,[uri dataUsingEncoding:NSUTF8StringEncoding]),^(NSData *data,NSString *error){
        if(self.finished)return;
        NSArray *fields=data?SAPProtoFields(data):nil;uint64_t code=fields?SAPProtoNumber(fields,1,0):1000;
        SAP_TRACE("export","key_refresh_rpc_add",0,@{@"uri":uri,@"reply_received":@(fields!=nil),@"code":@(code),@"error":error?:NSNull.null});
        if(code){[self finish:nil error:[NSString stringWithFormat:@"Spotify did not accept the repeated download of a track (code %llu). No files were shared.",code]];return;}
        [self addNext:index+1];
```

GetItems is repeated after AddDownload for each URI. Success requires two consecutive readiness observations for every requested track. During this process, hooks observe key-mechanism events again.

The exact command sequence is shown below.

```text
RemoveDownload(track_1)
RemoveDownload(track_2)
GetItems(track_1, track_2) → wait for offline state removal
AddDownload(track_1)
AddDownload(track_2)
GetItems(track_1, track_2) → two readiness confirmations
writeFiles()
```

Refresh initiation depends on the operation mode and the available user confirmation. A separate automatic path is bounded by a specific predicate, a previously confirmed downloaded track, and one recovery attempt.

`NativeDownloads/src/Export/TrackExport.m`, lines 498–503.

```objective-c
- (BOOL)recoverMissingCachedKey:(NSDictionary *)track evidence:(NSDictionary *)evidence {
    if(self.finished||self.commandRequested||self.observingExisting||!SAPShouldRefreshCachedTrack(self.shareOnly,self.refreshAttempted,[self.confirmedDownloadedURIs containsObject:track[@"uri"]],evidence))return NO;
    self.refreshAttempted=YES;self.automaticKeyRefresh=YES;
    SAP_TRACE("export","confirmed_missing_key_refresh",0,@{@"uri":track[@"uri"],@"reason":evidence,@"downloaded_confirmed_twice":@YES,@"maximum_attempts":@1,@"source":@"user-authorized recovery for unreadable previously downloaded audio"});
    [self status:@"The downloaded track has no usable export key. Downloading this track again…"];
    [self refreshKeysForTracks:@[track]];return YES;
```

## 18. How OGG and M4A are written

`writeExportFile` creates `<safeName(title)>.ogg` inside the operation's temporary directory, copies the validated Ogg stream range, and checks the final size. On failure it removes that file. The higher-level `writeFiles` publishes results into the export library through `SAPExportLibraryPublish`.

`NativeDownloads/src/Export/TrackCacheExport.m`, lines 149–168.

```objective-c
static BOOL writeExportFile(FILE *temporary,NSURL *folder,NSUInteger number,NSString *title,
                            uint64_t start,uint64_t length,NSURL **result,BOOL (^cancelled)(void)) {
    NSFileManager *fm=NSFileManager.defaultManager;
    NSString *name=[NSString stringWithFormat:@"%@.ogg",safeName(title)];
    NSURL *destination=[folder URLByAppendingPathComponent:name];
    FILE *out=fopen(destination.path.fileSystemRepresentation,"wb");
    if(!out)return NO;
    BOOL ok=!fseeko(temporary,(off_t)start,SEEK_SET);uint64_t remaining=length;uint8_t buffer[65536];
    while(ok&&remaining) {
        if(cancelled&&cancelled()){ok=NO;break;}
        size_t count=remaining>sizeof(buffer)?sizeof(buffer):(size_t)remaining;
        ok=fread(buffer,1,count,temporary)==count&&fwrite(buffer,1,count,out)==count;
        if(ok)remaining-=count;
    }
    memset_s(buffer,sizeof(buffer),0,sizeof(buffer));
    if(fclose(out))ok=NO;
    NSDictionary *attributes=[fm attributesOfItemAtPath:destination.path error:nil];
    ok=ok&&[attributes[NSFileSize]unsignedLongLongValue]==length;
    if(!ok){[fm removeItemAtURL:destination error:nil];return NO;}
    [fm setAttributes:@{NSFileProtectionKey:NSFileProtectionCompleteUntilFirstUserAuthentication} ofItemAtPath:destination.path error:nil];
```

For M4A, `writeFiles` queues a separate conversion job.

`NativeDownloads/src/Export/TrackExport.m`, lines 525–539.

```objective-c
            if(m4a) {
                NSURL *output=[[url URLByDeletingPathExtension]URLByAppendingPathExtension:@"m4a"];
                // Producer continues reading the next Ogg while this file encodes.
                // Bound queued/running conversions and temporary inputs as well.
                dispatch_semaphore_wait(window,DISPATCH_TIME_FOREVER);
                if(atomic_load(&self->ended)||conversionCancel.cancelled){dispatch_semaphore_signal(window);failure=@"Audio conversion cancelled.";break;}
                dispatch_group_enter(conversions);
                NSUInteger itemNumber=number;
                dispatch_async(dispatch_get_main_queue(),^{[self status:[NSString stringWithFormat:@"Converting to M4A: %lu / %lu",(unsigned long)itemNumber,(unsigned long)self.resolved.count]];});
                SAPQueueM4AConversion(url,output,track,track[@"export_artwork"],^BOOL{return atomic_load(&self->ended)||conversionCancel.cancelled;},^(SAPM4AExportStatus code){
                    SAP_TRACE("export","m4a_conversion_finished",0,(@{@"track_uri":track[@"uri"]?:@"",@"status":@(code),@"target_bitrate_kbps":@320,@"encoder_limits_respected":@YES,@"audio_reencoded":@YES,@"parallel_limit":@(SAPM4AConversionParallelLimit)}));
                    if(code!=SAPM4AExportOK){@synchronized(conversionCancel){if(!conversionError)conversionError=code==SAPM4AExportCancelled?@"Audio export cancelled.":[NSString stringWithFormat:@"M4A conversion failed (code %u). No files were shared.",(unsigned)code];}[conversionCancel cancel];}
                    dispatch_semaphore_signal(window);dispatch_group_leave(conversions);
                });
                url=output;
```

The converter opens Ogg with `stb_vorbis_open_file_section`, obtains PCM samples through `stb_vorbis_get_samples_float`, and passes them to `AVAssetWriterInput`. `AVAssetWriter` creates the container with type `AVFileTypeAppleM4A`.

AAC settings are selected according to the particular system encoder's capabilities.

`NativeDownloads/src/Export/M4AExport.m`, lines 101–121.

```objective-c
    AudioConverterRef converter = NULL;
    if (AudioConverterNew(&pcm, &aac, &converter) != noErr) return nil;
    // The format-wide bitrate list includes unsupported combinations (for
    // example 320k mono at 22050 Hz). Query this concrete encoder instead.
    if (AudioConverterGetPropertyInfo(converter, kAudioConverterApplicableEncodeBitRates,
        &size, NULL) == noErr && size && size <= 4096) {
        AudioValueRange ranges[4096 / sizeof(AudioValueRange)];
        if (AudioConverterGetProperty(converter, kAudioConverterApplicableEncodeBitRates,
            &size, ranges) == noErr) {
            for (UInt32 i = 0; i < size / sizeof(AudioValueRange); ++i) {
                double candidate = MIN(320000., ranges[i].mMaximum);
                if (candidate >= ranges[i].mMinimum && candidate > bitrate) bitrate = (UInt32)candidate;
            }
        }
    }
    AudioConverterDispose(converter);
    // Unsupported settings must fail explicitly rather than silently changing codec.
    if (!bitrate) return nil;
    return @{AVFormatIDKey:@(kAudioFormatMPEG4AAC), AVSampleRateKey:@(outputRate),
        AVNumberOfChannelsKey:@(channels), AVEncoderBitRateKey:@(bitrate),
        AVEncoderBitRateStrategyKey:AVAudioBitRateStrategy_Constant,
```

The M4A contains AAC-LC at the selected supported bitrate up to 320 kbit/s. OGG retains the validated Vorbis stream. Metadata and artwork are added by the appropriate format handlers.

## 19. Separate diagnostic and management commands

An explicit offline check sends additional reads with an empty payload.

`NativeDownloads/src/Devices/OfflineCompatibilityChecks.m`, lines 104–109.

```objective-c
    NSDictionary *methods=@{@"licenses":@"LicenseStatus",@"playback":@"GetOfflinePlaybackStatus",@"preflight":@"BulkRedownloadPreflight",
        @"devices":@"GetDevices",@"local_device":@"GetLocalDevice",@"license_info":@"GetOfflineLicenseInfo"};
    for(NSString *name in methods) {
        NSString *method=methods[name];
        SAPTraceWithOperation(traceOperation,^{SAPCallReadOnlyService(offlineService,method,NSData.data,^(NSData *data,NSString *error){
            NSArray *fields=[data isKindOfClass:NSData.class]?SAPProtoFields(data):nil;
```

Every listed method uses `spotify.offline_esperanto.proto.Offline`.

| Method | Payload | Data read |
| --- | --- | --- |
| `LicenseStatus` | Empty | License limit, free license count, and error code |
| `GetOfflinePlaybackStatus` | Empty | Playback permission in field 1 |
| `BulkRedownloadPreflight` | Empty | Storage availability and downloads in progress |
| `GetDevices` | Empty | Registered devices |
| `GetLocalDevice` | Empty | Current device ID and cache ID |
| `GetOfflineLicenseInfo` | Empty | Offline license information |

Enabling offline playback on the current device uses `SetOfflinePlaybackAllowed` with `SAPProtoInteger(1, 1)`, producing payload `08 01`. This belongs to a separate device-management action.

The device manager also constructs direct HTTPS requests to `https://spclient.wg.spotify.com`.

```http
GET /offline/v1/licenseStatus
GET /offline/v1/devices
POST /offline/v1/devices/{device_id}/cache/{cache_id}/disable
```

These requests use the app's existing authenticated headers. The disable POST follows verification of the selected registration and a fresh state read. Its result is checked by reading the registry and quota again.

The corresponding code is in `NativeDownloads/src/Devices/OfflineDeviceManager.m`, functions `readRegistry`, `disableNext`, and `SAPEnableOfflineOnCurrentDevice`.

## 20. Call sequences by scenario

| Scenario | Sequence |
| --- | --- |
| Current track | `SAPPrepareNativeOffline → GetItems → AddDownload when needed → GetItems until two ready states` |
| Selected album in the release queue | `prepare → GetContexts → Contains → Collection.Add and Contains when needed → Offline.AddDownload(album URI) → SubscribeContexts/Progress` |
| Playlist download | `prepare → GetContexts → PlaylistService.SetOfflineState(uri, 1) → observe` |
| Album preparation for export | `GetEntity → GetContexts → makeEntityAvailableOfflineWithURL:trackURLs: when needed → GetContexts → writeFiles` |
| Export from usable cache | `GetEntity or existing metadata → map file ID to cache ID → extract → validate → write` |
| Track key refresh | `RemoveDownload → GetItems → AddDownload → GetItems → process cache again` |

## 21. What this analysis establishes

Service names, methods, field numbers, submission conditions, and response handling come from implementation calls. They can be checked against the listed files and lines.

Spotify's own implementation after entry into the native core requires separate observation. This includes the precise server-side semantics of key mode, actual network URLs serving particular audio, and the effectiveness of different album paths. The difference between AddDownload(album URI) and the native album handler is documented above as a code-level finding with historical evidence of a problem.

This is a static analysis of calls and conditions in the source. Actual execution of each branch and the results of internal commands are established by observations of a particular installation.
