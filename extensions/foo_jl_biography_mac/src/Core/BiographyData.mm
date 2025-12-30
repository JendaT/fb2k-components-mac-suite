//
//  BiographyData.mm
//  foo_jl_biography_mac
//
//  Immutable data models for artist biography information
//

#import "BiographyData.h"

#pragma mark - SimilarArtistRef

@implementation SimilarArtistRef

- (instancetype)initWithName:(NSString *)name
                thumbnailURL:(nullable NSURL *)thumbnailURL
               musicBrainzId:(nullable NSString *)mbid {
    self = [super init];
    if (self) {
        _name = [name copy];
        _thumbnailURL = [thumbnailURL copy];
        _musicBrainzId = [mbid copy];
    }
    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<SimilarArtistRef: %@>", self.name];
}

- (BOOL)isEqual:(id)object {
    if (self == object) return YES;
    if (![object isKindOfClass:[SimilarArtistRef class]]) return NO;

    SimilarArtistRef *other = (SimilarArtistRef *)object;
    return [self.name isEqualToString:other.name];
}

- (NSUInteger)hash {
    return self.name.hash;
}

@end

#pragma mark - BiographyData

@implementation BiographyData

- (instancetype)initWithBuilder:(BiographyDataBuilder *)builder {
    self = [super init];
    if (self) {
        _artistName = [builder.artistName copy];
        _musicBrainzId = [builder.musicBrainzId copy];
        _biography = [builder.biography copy];
        _biographySummary = [builder.biographySummary copy];
        _biographySource = builder.biographySource;
        _language = [builder.language copy];
        _artistImage = builder.artistImage;
        _artistImageURL = [builder.artistImageURL copy];
        _imageSource = builder.imageSource;
        _imageType = builder.imageType;
        _tags = [builder.tags copy];
        _similarArtists = [builder.similarArtists copy];
        _genre = [builder.genre copy];
        _country = [builder.country copy];
        _listeners = builder.listeners;
        _playcount = builder.playcount;
        _fetchedAt = builder.fetchedAt ?: [NSDate date];
        _isFromCache = builder.isFromCache;
        _isStale = builder.isStale;
    }
    return self;
}

- (BOOL)hasBiography {
    return self.biography.length > 0 || self.biographySummary.length > 0;
}

- (BOOL)hasImage {
    return self.artistImage != nil || self.artistImageURL != nil;
}

- (NSString *)biographySourceDisplayName {
    return [self displayNameForSource:self.biographySource];
}

- (NSString *)imageSourceDisplayName {
    return [self displayNameForSource:self.imageSource];
}

- (NSString *)displayNameForSource:(BiographySource)source {
    switch (source) {
        case BiographySourceLastFm:
            return @"Last.fm";
        case BiographySourceWikipedia:
            return @"Wikipedia";
        case BiographySourceAudioDb:
            return @"TheAudioDB";
        case BiographySourceFanartTv:
            return @"Fanart.tv";
        case BiographySourceCache:
            return @"Cache";
        case BiographySourceUnknown:
        default:
            return @"Unknown";
    }
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<BiographyData: %@ (bio: %@, image: %@)>",
            self.artistName,
            self.hasBiography ? @"yes" : @"no",
            self.hasImage ? @"yes" : @"no"];
}

@end

#pragma mark - BiographyDataBuilder

@implementation BiographyDataBuilder

- (instancetype)init {
    self = [super init];
    if (self) {
        _biographySource = BiographySourceUnknown;
        _imageSource = BiographySourceUnknown;
        _imageType = BiographyImageTypeThumb;
        _isFromCache = NO;
        _isStale = NO;
    }
    return self;
}

- (instancetype)initWithArtistName:(NSString *)artistName {
    self = [self init];
    if (self) {
        _artistName = [artistName copy];
    }
    return self;
}

- (BiographyData *)build {
    NSAssert(self.artistName.length > 0, @"Artist name is required");
    return [[BiographyData alloc] initWithBuilder:self];
}

@end
