//
//  ScrobbleTrack.mm
//  foo_scrobble_mac
//
//  Track model for scrobbling
//

#import "ScrobbleTrack.h"
#import "ScrobbleRules.h"

@implementation ScrobbleTrack

- (instancetype)init {
    self = [super init];
    if (self) {
        _submissionId = [[NSUUID UUID] UUIDString];
        _status = ScrobbleTrackStatusQueued;
        _retryCount = 0;
        _timestamp = (int64_t)[[NSDate date] timeIntervalSince1970];
    }
    return self;
}

- (instancetype)initWithArtist:(NSString *)artist
                         title:(NSString *)title
                      duration:(NSInteger)duration {
    self = [self init];
    if (self) {
        _artist = [artist copy];
        _title = [title copy];
        _duration = duration;
    }
    return self;
}

#pragma mark - Validation

- (BOOL)isValid {
    // Required fields must be present and within length limits
    if (_artist.length == 0 || _artist.length > ScrobbleRules::kMaxArtistLength) {
        return NO;
    }
    if (_title.length == 0 || _title.length > ScrobbleRules::kMaxTitleLength) {
        return NO;
    }

    // Duration must be within bounds
    if (_duration < ScrobbleRules::kMinTrackLength ||
        _duration > ScrobbleRules::kMaxTrackLength) {
        return NO;
    }

    // Timestamp must be valid
    if (!ScrobbleRules::isValidTimestamp(_timestamp)) {
        return NO;
    }

    return YES;
}

#pragma mark - Helpers

- (NSString *)deduplicationKey {
    return [NSString stringWithFormat:@"%@|%@|%lld",
            _artist ?: @"",
            _title ?: @"",
            _timestamp];
}

- (NSString *)displayDescription {
    return [NSString stringWithFormat:@"%@ - %@", _artist ?: @"?", _title ?: @"?"];
}

#pragma mark - NSSecureCoding

+ (BOOL)supportsSecureCoding {
    return YES;
}

- (void)encodeWithCoder:(NSCoder *)coder {
    [coder encodeObject:_artist forKey:@"artist"];
    [coder encodeObject:_title forKey:@"title"];
    [coder encodeObject:_album forKey:@"album"];
    [coder encodeObject:_albumArtist forKey:@"albumArtist"];
    [coder encodeInteger:_trackNumber forKey:@"trackNumber"];
    [coder encodeObject:_mbTrackId forKey:@"mbTrackId"];
    [coder encodeInteger:_duration forKey:@"duration"];
    [coder encodeInt64:_timestamp forKey:@"timestamp"];
    [coder encodeObject:_submissionId forKey:@"submissionId"];
    [coder encodeInteger:_status forKey:@"status"];
    [coder encodeInteger:_retryCount forKey:@"retryCount"];
    [coder encodeObject:_lastError forKey:@"lastError"];
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super init];
    if (self) {
        _artist = [coder decodeObjectOfClass:[NSString class] forKey:@"artist"];
        _title = [coder decodeObjectOfClass:[NSString class] forKey:@"title"];
        _album = [coder decodeObjectOfClass:[NSString class] forKey:@"album"];
        _albumArtist = [coder decodeObjectOfClass:[NSString class] forKey:@"albumArtist"];
        _trackNumber = [coder decodeIntegerForKey:@"trackNumber"];
        _mbTrackId = [coder decodeObjectOfClass:[NSString class] forKey:@"mbTrackId"];
        _duration = [coder decodeIntegerForKey:@"duration"];
        _timestamp = [coder decodeInt64ForKey:@"timestamp"];
        _submissionId = [coder decodeObjectOfClass:[NSString class] forKey:@"submissionId"];
        _status = (ScrobbleTrackStatus)[coder decodeIntegerForKey:@"status"];
        _retryCount = [coder decodeIntegerForKey:@"retryCount"];
        _lastError = [coder decodeObjectOfClass:[NSString class] forKey:@"lastError"];

        if (!_submissionId) {
            _submissionId = [[NSUUID UUID] UUIDString];
        }
    }
    return self;
}

#pragma mark - NSCopying

- (id)copyWithZone:(NSZone *)zone {
    ScrobbleTrack *copy = [[ScrobbleTrack allocWithZone:zone] init];
    copy.artist = _artist;
    copy.title = _title;
    copy.album = _album;
    copy.albumArtist = _albumArtist;
    copy.trackNumber = _trackNumber;
    copy.mbTrackId = _mbTrackId;
    copy.duration = _duration;
    copy.timestamp = _timestamp;
    copy.submissionId = _submissionId;
    copy.status = _status;
    copy.retryCount = _retryCount;
    copy.lastError = _lastError;
    return copy;
}

#pragma mark - Description

- (NSString *)description {
    return [NSString stringWithFormat:@"<ScrobbleTrack: %@ (%@)>",
            [self displayDescription],
            _status == ScrobbleTrackStatusQueued ? @"queued" :
            _status == ScrobbleTrackStatusInFlight ? @"in-flight" :
            _status == ScrobbleTrackStatusSubmitted ? @"submitted" : @"failed"];
}

@end
