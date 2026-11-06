//
//  GalleryImageParsing.mm
//  foo_jl_biography_mac
//
//  Pure JSON->ArtistImage mapping for the gallery image sources
//

#import "GalleryImageParsing.h"
#import "ArtistImage.h"
#import "../API/BiographyAPIConstants.h"

@implementation GalleryImageParsing

#pragma mark - TheAudioDB

+ (NSArray<ArtistImage *> *)imagesFromAudioDbArtist:(NSDictionary *)artist {
    NSMutableArray<ArtistImage *> *images = [NSMutableArray array];

    // Parse fanart images (strArtistFanart, strArtistFanart2, strArtistFanart3, strArtistFanart4)
    NSArray *fanartKeys = @[@"strArtistFanart", @"strArtistFanart2", @"strArtistFanart3", @"strArtistFanart4"];
    for (NSString *key in fanartKeys) {
        ArtistImage *image = [self audioDbImageFromArtist:artist key:key type:ArtistImageTypeBackground];
        if (image) [images addObject:image];
    }

    // Parse thumbnail
    ArtistImage *thumb = [self audioDbImageFromArtist:artist key:@"strArtistThumb" type:ArtistImageTypeThumbnail];
    if (thumb) [images addObject:thumb];

    // Parse logo
    ArtistImage *logo = [self audioDbImageFromArtist:artist key:@"strArtistLogo" type:ArtistImageTypeLogo];
    if (logo) [images addObject:logo];

    // Parse wide thumb (use as thumbnail)
    ArtistImage *wideThumb = [self audioDbImageFromArtist:artist key:@"strArtistWideThumb" type:ArtistImageTypeThumbnail];
    if (wideThumb) [images addObject:wideThumb];

    // Parse banner
    ArtistImage *banner = [self audioDbImageFromArtist:artist key:@"strArtistBanner" type:ArtistImageTypeBanner];
    if (banner) [images addObject:banner];

    // Parse cutout (use as thumbnail)
    ArtistImage *cutout = [self audioDbImageFromArtist:artist key:@"strArtistCutout" type:ArtistImageTypeThumbnail];
    if (cutout) [images addObject:cutout];

    // Parse clearart (use as logo)
    ArtistImage *clearart = [self audioDbImageFromArtist:artist key:@"strArtistClearart" type:ArtistImageTypeLogo];
    if (clearart) [images addObject:clearart];

    return [images copy];
}

+ (nullable ArtistImage *)audioDbImageFromArtist:(NSDictionary *)artist
                                             key:(NSString *)key
                                            type:(ArtistImageType)type {
    id value = artist[key];
    if (!value || value == [NSNull null]) return nil;
    if (![value isKindOfClass:[NSString class]]) return nil;

    NSString *urlString = (NSString *)value;
    if (urlString.length == 0) return nil;

    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return nil;

    // AudioDB provides /preview suffix for thumbnails
    NSURL *thumbnailURL = nil;
    if (type == ArtistImageTypeBackground) {
        NSString *thumbUrlString = [urlString stringByAppendingString:@"/preview"];
        thumbnailURL = [NSURL URLWithString:thumbUrlString];
    }

    return [[ArtistImage alloc] initWithURL:url
                               thumbnailURL:thumbnailURL
                                  imageType:type
                                     source:BiographySourceAudioDb
                                      likes:0];  // AudioDB doesn't provide likes
}

#pragma mark - Fanart.tv

+ (NSArray<ArtistImage *> *)imagesFromFanartTvResponse:(NSDictionary *)response {
    NSMutableArray<ArtistImage *> *images = [NSMutableArray array];

    // Parse artist backgrounds (high priority)
    NSArray *backgrounds = response[@"artistbackground"];
    if ([backgrounds isKindOfClass:[NSArray class]]) {
        for (NSDictionary *item in backgrounds) {
            ArtistImage *image = [self fanartTvImageFromItem:item type:ArtistImageTypeBackground];
            if (image) [images addObject:image];
        }
    }

    // Parse artist thumbs
    NSArray *thumbs = response[@"artistthumb"];
    if ([thumbs isKindOfClass:[NSArray class]]) {
        for (NSDictionary *item in thumbs) {
            ArtistImage *image = [self fanartTvImageFromItem:item type:ArtistImageTypeThumbnail];
            if (image) [images addObject:image];
        }
    }

    // Parse HD music logos
    NSArray *hdLogos = response[@"hdmusiclogo"];
    if ([hdLogos isKindOfClass:[NSArray class]]) {
        for (NSDictionary *item in hdLogos) {
            ArtistImage *image = [self fanartTvImageFromItem:item type:ArtistImageTypeLogo];
            if (image) [images addObject:image];
        }
    }

    // Parse regular music logos (fallback)
    NSArray *logos = response[@"musiclogo"];
    if ([logos isKindOfClass:[NSArray class]]) {
        for (NSDictionary *item in logos) {
            ArtistImage *image = [self fanartTvImageFromItem:item type:ArtistImageTypeLogo];
            if (image) [images addObject:image];
        }
    }

    // Parse music banners
    NSArray *banners = response[@"musicbanner"];
    if ([banners isKindOfClass:[NSArray class]]) {
        for (NSDictionary *item in banners) {
            ArtistImage *image = [self fanartTvImageFromItem:item type:ArtistImageTypeBanner];
            if (image) [images addObject:image];
        }
    }

    return [images copy];
}

+ (nullable ArtistImage *)fanartTvImageFromItem:(NSDictionary *)item type:(ArtistImageType)type {
    if (![item isKindOfClass:[NSDictionary class]]) return nil;

    NSString *urlString = item[@"url"];
    if (!urlString || ![urlString isKindOfClass:[NSString class]] || urlString.length == 0) {
        return nil;
    }

    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return nil;

    // FanartTV provides likes count
    NSInteger likes = 0;
    id likesValue = item[@"likes"];
    if ([likesValue respondsToSelector:@selector(integerValue)]) {
        likes = [likesValue integerValue];
    }

    return [[ArtistImage alloc] initWithURL:url
                               thumbnailURL:nil  // FanartTV doesn't provide thumbs
                                  imageType:type
                                     source:BiographySourceFanartTv
                                      likes:likes];
}

#pragma mark - Deezer

+ (nullable ArtistImage *)imageFromDeezerArtist:(NSDictionary *)artist {
    if (![artist isKindOfClass:[NSDictionary class]]) return nil;

    // Get the XL image (1000x1000) as main, big (500x500) as thumbnail
    NSString *pictureXL = [artist[@"picture_xl"] isKindOfClass:[NSString class]] ? artist[@"picture_xl"] : nil;
    NSString *pictureBig = [artist[@"picture_big"] isKindOfClass:[NSString class]] ? artist[@"picture_big"] : nil;
    NSString *pictureMedium = [artist[@"picture_medium"] isKindOfClass:[NSString class]] ? artist[@"picture_medium"] : nil;

    // Use the best available
    NSString *mainUrl = pictureXL ?: pictureBig ?: pictureMedium;
    NSString *thumbUrl = pictureBig ?: pictureMedium;

    if (mainUrl.length == 0) return nil;

    // Deezer's default silhouette placeholder is served under the MD5 of the
    // empty string (missing picture id hashes to it) - skip it
    if ([mainUrl containsString:kDeezerPlaceholderHash]) return nil;

    NSURL *url = [NSURL URLWithString:mainUrl];
    if (!url) return nil;
    NSURL *thumbnailURL = thumbUrl ? [NSURL URLWithString:thumbUrl] : nil;

    return [[ArtistImage alloc] initWithURL:url
                               thumbnailURL:thumbnailURL
                                  imageType:ArtistImageTypeThumbnail
                                     source:BiographySourceDeezer
                                      likes:0
                               originalSize:CGSizeMake(1000, 1000)];
}

#pragma mark - MBID validation

+ (BOOL)isValidMBID:(NSString *)mbid {
    if (![mbid isKindOfClass:[NSString class]] || mbid.length == 0) return NO;

    // Validate MBID is a proper UUID to prevent path injection
    static NSRegularExpression *uuidRegex = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        uuidRegex = [NSRegularExpression regularExpressionWithPattern:
                     @"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$"
                                                             options:NSRegularExpressionCaseInsensitive
                                                               error:nil];
    });

    return [uuidRegex numberOfMatchesInString:mbid options:0 range:NSMakeRange(0, mbid.length)] > 0;
}

@end
