#pragma once

#include "../fb2k_sdk.h"
#include <mutex>

#ifdef __OBJC__
@class PlayVancedController;
#endif

class PlayVancedCallbackManager {
public:
    static PlayVancedCallbackManager& instance();

#ifdef __OBJC__
    void registerController(PlayVancedController* controller);
    void unregisterController(PlayVancedController* controller);
#endif

    void onPlaybackNewTrack(metadb_handle_ptr track);
    void onPlaybackStop(play_control::t_stop_reason reason);
    void onPlaybackPause(bool paused);
    void onPlaybackTime(double time);
    void onPlaybackSeek(double time);
    void onVolumeChange(float newVolDb);
    void onSelectionChanged();
    void onPlaybackOrderChanged(t_size order);

    metadb_handle_ptr getCurrentPlayingTrack() const;

private:
    PlayVancedCallbackManager() = default;
    metadb_handle_ptr m_playingTrack;
    mutable std::mutex m_trackMutex;
};

#ifdef __OBJC__
#import <Cocoa/Cocoa.h>

typedef void (^ArtworkCompletion)(NSImage * _Nullable image);

@interface ArtworkFetcher : NSObject

+ (instancetype)sharedFetcher;

- (nullable NSImage *)cachedImageForPath:(NSString *)path;
- (void)fetchArtworkForPath:(NSString *)path completion:(ArtworkCompletion)completion;
- (void)clearCache;

+ (NSImage *)placeholderImageOfSize:(CGFloat)size;

@end

#endif
