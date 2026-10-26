#pragma once
#import <Foundation/Foundation.h>

// Separates pending requests from native queue confirmation. Observation is
// bounded and cancellable; queue confirmation does not prove audio playback.
BOOL SAPStartArtistReleaseDownloads(NSArray<NSDictionary *> *releases,
                                   void (^progress)(NSDictionary *snapshot),NSString **error);
void SAPStopAddingArtistReleases(void);
