//
//  BrowserLogic.mm
//  foo_jl_tidal_mac
//

#import "BrowserLogic.h"

@implementation JLTidalBrowserLogic

#pragma mark - Active-list selection

+ (BOOL)isShowingTracksInBrowseMode:(JLTidalBrowseMode)browseMode
                         searchType:(JLTidalSearchType)searchType
                     librarySection:(JLTidalLibrarySection)librarySection {
    if (browseMode == JLTidalBrowseModeAlbumTracks ||
        browseMode == JLTidalBrowseModeArtistTopTracks ||
        browseMode == JLTidalBrowseModePlaylistTracks) {
        return YES;
    }
    if (browseMode == JLTidalBrowseModeLibraryList &&
        librarySection == JLTidalLibrarySectionFavTracks) {
        return YES;
    }
    return browseMode == JLTidalBrowseModeSearchResults &&
           searchType == JLTidalSearchTypeTracks;
}

+ (BOOL)isShowingAlbumsInBrowseMode:(JLTidalBrowseMode)browseMode
                         searchType:(JLTidalSearchType)searchType
                     librarySection:(JLTidalLibrarySection)librarySection {
    if (browseMode == JLTidalBrowseModeArtistAlbums) return YES;
    if (browseMode == JLTidalBrowseModeLibraryList &&
        librarySection == JLTidalLibrarySectionFavAlbums) {
        return YES;
    }
    return browseMode == JLTidalBrowseModeSearchResults &&
           searchType == JLTidalSearchTypeAlbums;
}

+ (BOOL)isShowingArtistsInBrowseMode:(JLTidalBrowseMode)browseMode
                          searchType:(JLTidalSearchType)searchType {
    return browseMode == JLTidalBrowseModeSearchResults &&
           searchType == JLTidalSearchTypeArtists;
}

+ (BOOL)isShowingPlaylistsInBrowseMode:(JLTidalBrowseMode)browseMode
                        librarySection:(JLTidalLibrarySection)librarySection {
    return browseMode == JLTidalBrowseModeLibraryList &&
           librarySection == JLTidalLibrarySectionPlaylists;
}

+ (BOOL)isDrillDownMode:(JLTidalBrowseMode)browseMode {
    return browseMode != JLTidalBrowseModeSearchResults &&
           browseMode != JLTidalBrowseModeLibraryList;
}

+ (JLTidalBrowseMode)rootModeForPanelMode:(JLTidalPanelMode)panelMode {
    return panelMode == JLTidalPanelModeLibrary
        ? JLTidalBrowseModeLibraryList
        : JLTidalBrowseModeSearchResults;
}

#pragma mark - Pagination

+ (BOOL)shouldTriggerLoadMoreWithHasMore:(BOOL)hasMoreResults
                           isLoadingMore:(BOOL)isLoadingMore
                             isSearching:(BOOL)isSearching
                            scrollOffset:(CGFloat)scrollOffset
                           visibleHeight:(CGFloat)visibleHeight
                           contentHeight:(CGFloat)contentHeight {
    if (!hasMoreResults || isLoadingMore || isSearching) return NO;
    // Load more when within 100pt of the bottom
    return scrollOffset + visibleHeight >= contentHeight - 100;
}

+ (NSInteger)offsetAfterSearchPageAtOffset:(NSInteger)requestOffset
                             returnedCount:(NSInteger)returnedCount {
    return requestOffset + returnedCount;
}

+ (BOOL)hasMorePagesAfterReturnedCount:(NSInteger)returnedCount
                              pageSize:(NSInteger)pageSize {
    return returnedCount >= pageSize;
}

#pragma mark - Navigation

+ (BOOL)backReturnsToArtistAlbumsFromMode:(JLTidalBrowseMode)browseMode
                                hasArtist:(BOOL)hasArtist {
    if (!hasArtist) return NO;
    // Both of these are reached *from* an artist's album list, so back belongs
    // there. Playlist tracks and library drill-downs have no artist level.
    return browseMode == JLTidalBrowseModeArtistTopTracks ||
           browseMode == JLTidalBrowseModeAlbumTracks;
}

#pragma mark - Mode-change no-op rules

+ (BOOL)searchTypeChangeIsNoOpFromType:(JLTidalSearchType)currentType
                                toType:(JLTidalSearchType)newType
                            browseMode:(JLTidalBrowseMode)browseMode {
    return newType == currentType && browseMode == JLTidalBrowseModeSearchResults;
}


+ (nullable NSString *)displayQualityForAudioQuality:(nullable NSString *)audioQuality
                                           mediaTags:(nullable NSArray<NSString *> *)mediaTags {
    // No mediaMetadata in the response: nothing better to go on.
    if (mediaTags == nil) return audioQuality;

    // mediaTags lists the formats Tidal actually holds, so it decides in both
    // directions. Previously it could only cap a lossless claim downward, and a
    // release whose audioQuality lagged behind a HIRES_LOSSLESS tag was shown
    // as merely lossless.
    BOOL hasHiRes = NO, hasLossless = NO;
    for (NSString *tag in mediaTags) {
        if ([tag isEqualToString:@"HIRES_LOSSLESS"]) hasHiRes = YES;
        else if ([tag isEqualToString:@"LOSSLESS"] || [tag isEqualToString:@"MQA"]) hasLossless = YES;
    }

    if (hasHiRes) return @"HI_RES_LOSSLESS";

    BOOL claimsLossless = [audioQuality isEqualToString:@"LOSSLESS"] ||
                          [audioQuality isEqualToString:@"HI_RES"] ||
                          [audioQuality isEqualToString:@"HI_RES_LOSSLESS"];
    if (!claimsLossless) {
        // Tags promise lossless while audioQuality says otherwise: believe the tags.
        return hasLossless ? @"LOSSLESS" : audioQuality;
    }

    // A lossless claim is only kept when a lossless format is really on offer.
    return hasLossless ? audioQuality : @"HIGH";
}

+ (BOOL)librarySectionChangeIsNoOpFromSection:(JLTidalLibrarySection)currentSection
                                    toSection:(JLTidalLibrarySection)newSection
                                   browseMode:(JLTidalBrowseMode)browseMode {
    return newSection == currentSection && browseMode == JLTidalBrowseModeLibraryList;
}

@end
