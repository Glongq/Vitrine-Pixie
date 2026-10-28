#import "SpotifyTransport.h"
#import "TrackJournal.h"
#import "WireProto.h"
#import "PlayerTrace.h"
#import "Diagnostics.h"
#import "Deadline.h"
#import "DiagnosticTrace.h"
#include <stdatomic.h>

#include <os/lock.h>
NSString *const SAPOfflineService = @"spotify.offline_esperanto.proto.Offline";
static __weak id player, transport;
static __weak id providedTransport, provenTransport, provenBridge, candidates[8];
static unsigned nextCandidateSlot;
static os_unfair_lock candidatesLock = OS_UNFAIR_LOCK_INIT;
static dispatch_queue_t worker;
static void *downloadWorkerKey=&downloadWorkerKey;
void SAPInitializeTransportRuntime(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        worker = dispatch_queue_create("SpotifyAudioProbe.native-download",
            dispatch_queue_attr_make_with_autorelease_frequency(DISPATCH_QUEUE_SERIAL, DISPATCH_AUTORELEASE_FREQUENCY_WORK_ITEM));
        dispatch_queue_set_specific(worker,downloadWorkerKey,downloadWorkerKey,NULL);
    });
}
dispatch_queue_t SAPTransportWorker(void) {return worker;}
BOOL SAPOnTransportWorker(void) {return dispatch_get_specific(downloadWorkerKey)!=NULL;}
id SAPTransportPlayer(void) {return player;}
void SAPTransportSetPlayer(id value) {player=value;}
id SAPCurrentTransport(void) {return transport;}
id SAPProvenTransport(void) {os_unfair_lock_lock(&candidatesLock);id value=provenTransport;os_unfair_lock_unlock(&candidatesLock);return value;}
void SAPTransportVerifiedEndpoints(id __strong *proven,id __strong *bridge) {
    os_unfair_lock_lock(&candidatesLock);*proven=provenTransport;*bridge=provenBridge;os_unfair_lock_unlock(&candidatesLock);
}
#ifdef SAP_RUNTIME_TESTING
static NSMutableArray *seenNativeCalls;
void SAPRememberNativeCall(id endpoint, id serviceName, id methodName) {
    if (![serviceName isKindOfClass:NSString.class] || ![methodName isKindOfClass:NSString.class]) return;
    NSDictionary *entry = @{@"class": NSStringFromClass(object_getClass(endpoint)), @"service": serviceName, @"method": methodName};
    os_unfair_lock_lock(&candidatesLock);
    if (!seenNativeCalls) seenNativeCalls = [NSMutableArray array];
    if (![seenNativeCalls containsObject:entry]) { [seenNativeCalls addObject:entry]; if (seenNativeCalls.count > 64) [seenNativeCalls removeObjectAtIndex:0]; }
    os_unfair_lock_unlock(&candidatesLock);
}
#endif
void SAPRememberTransport(id value, BOOL provided, BOOL proven) {
    if (!value) return;
    os_unfair_lock_lock(&candidatesLock);
    if(!provided && !proven && transport==value) {os_unfair_lock_unlock(&candidatesLock);return;}
    if (provided) providedTransport = value;
    if (proven) {
        provenTransport = value;
        if([NSStringFromClass(object_getClass(value)) isEqual:@"SPTEsperantoTransportBridgeImpl"])provenBridge=value;
    }
    BOOL found = NO;
    for (unsigned i = 0; i < 8; i++) if (candidates[i] == value) { found = YES; break; }
    if (!found) candidates[(nextCandidateSlot++) % 8] = value;
    transport = value;
    os_unfair_lock_unlock(&candidatesLock);
}
NSArray *SAPTransportCandidates(void) {
    NSMutableArray *result = [NSMutableArray array];
    os_unfair_lock_lock(&candidatesLock);
    id proven = provenTransport, provided = providedTransport, bridge=provenBridge;
    if (proven) [result addObject:proven];
    if(bridge && ![result containsObject:bridge])[result addObject:bridge];
    if (provided && ![result containsObject:provided]) [result addObject:provided];
    // Prefer the C++ bridge to Cosmos, whose implementation silently drops
    // non-200 replies. Each fallback must answer a read-only GetItems probe.
    for (unsigned pass = 0; pass < 2; pass++) for (unsigned i = 0; i < 8; i++) {
        id value = candidates[i]; if (!value || [result containsObject:value]) continue;
        BOOL bridge = [NSStringFromClass(object_getClass(value)) isEqual:@"SPTEsperantoTransportBridgeImpl"];
        if (bridge == (pass == 0)) [result addObject:value];
    }
    os_unfair_lock_unlock(&candidatesLock);
    return result;
}


#ifdef SAP_RUNTIME_TESTING
NSDictionary *SAPTransportInventoryForTesting(void) {
    NSArray *pool=SAPTransportCandidates();NSMutableArray *classes=[NSMutableArray array];
    for(id value in pool)[classes addObject:NSStringFromClass(object_getClass(value))];
    os_unfair_lock_lock(&candidatesLock);NSArray *seen=[seenNativeCalls copy]?:@[];os_unfair_lock_unlock(&candidatesLock);
    return @{@"candidates":classes,@"native_calls":seen};
}
#endif
