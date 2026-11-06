#pragma once
#import <Foundation/Foundation.h>
// Capture before creating any native temporary download. Unknown or incomplete
// baseline replies fail closed. Token is opaque, in-memory, and reusable only
// for idempotent cleanup of this same preparation job.
void SAPCaptureTemporaryOfflineExport(NSString *targetURI,NSArray<NSDictionary *> *resolvedTracks,
    void (^completion)(NSDictionary *token,NSString *error));
// Track: accepted means exact AddDownload success. Album: native invocation
// of the verified entity adapter. A queued invocation also requires cleanup
// when cancellation precedes its first visible context state.
// False never authorizes any removal.
void SAPCleanupTemporaryOfflineExport(NSDictionary *token,BOOL ourDownloadAccepted,
    void (^completion)(NSString *error));
