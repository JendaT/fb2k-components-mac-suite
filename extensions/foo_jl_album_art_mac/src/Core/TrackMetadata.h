//
//  TrackMetadata.h
//  foo_jl_album_art_mac
//
//  Immutable metadata snapshot for remote artwork search
//  Captured at search start, holds all data needed to query APIs
//
//  Foundation-only: SDK extraction lives in TrackMetadata+FB2K.h so this
//  class (and everything depending on it) compiles standalone for unit tests.
//

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Immutable snapshot of track metadata for artwork search
@interface TrackMetadata : NSObject

/// Primary artist name (ARTIST field)
@property (readonly, copy) NSString *artist;

/// Album artist (ALBUM ARTIST / ALBUMARTIST fields)
/// May differ from artist for compilations
@property (readonly, copy) NSString *albumArtist;

/// Album name
@property (readonly, copy) NSString *album;

/// Track title (for display in save dialog)
@property (readonly, copy) NSString *title;

/// MusicBrainz Release ID (specific release/pressing)
/// Standard tag: MUSICBRAINZ_RELEASEID / MUSICBRAINZ RELEASE ID
@property (readonly, copy, nullable) NSString *musicBrainzReleaseID;

/// MusicBrainz Release Group ID (abstract album across releases)
/// Standard tag: MUSICBRAINZ_RELEASEGROUPID / MUSICBRAINZ RELEASE GROUP ID
@property (readonly, copy, nullable) NSString *musicBrainzReleaseGroupID;

/// Discogs Release ID (for future Phase 2)
/// Standard tag: DISCOGS_RELEASE_ID / DISCOGS RELEASE ID
@property (readonly, copy, nullable) NSString *discogsReleaseID;

/// File URL of the track (file:// URL); nil for streams
@property (readonly, strong, nullable) NSURL *fileURL;

/// Parent folder URL of the track (for save location); nil for streams
@property (readonly, strong, nullable) NSURL *folderURL;

/// Designated initializer. fileURL/folderURL are derived from trackPath.
/// @param trackPath Raw foobar2000 path ("file://..." prefixed or plain); may be nil
- (instancetype)initWithArtist:(NSString *)artist
                   albumArtist:(NSString *)albumArtist
                         album:(NSString *)album
                         title:(NSString *)title
          musicBrainzReleaseID:(nullable NSString *)mbReleaseID
     musicBrainzReleaseGroupID:(nullable NSString *)mbReleaseGroupID
              discogsReleaseID:(nullable NSString *)discogsReleaseID
                     trackPath:(nullable NSString *)trackPath NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/// Convert a raw foobar2000 path to a file URL.
/// foobar2000 paths use a "file://" prefix with an UNENCODED native path
/// (spaces etc. are literal), so NSURL string parsing must not be used.
/// Returns nil for empty paths or non-file schemes (http://, mms://, ...).
+ (nullable NSURL *)fileURLFromFB2KPath:(nullable NSString *)path;

/// Check if we have enough data to search (at minimum: artist + album)
@property (readonly, getter=isSearchable) BOOL searchable;

/// Check if we have MusicBrainz IDs for direct lookup
@property (readonly) BOOL hasMusicBrainzIDs;

@end

NS_ASSUME_NONNULL_END
