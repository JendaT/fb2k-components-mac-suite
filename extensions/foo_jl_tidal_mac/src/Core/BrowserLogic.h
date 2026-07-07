//
//  BrowserLogic.h
//  foo_jl_tidal_mac
//
//  Pure decision logic for the browser panel: which result list is active
//  for a given (browseMode, searchType, librarySection), pagination gating
//  and offset/hasMore math, back-button routing, and mode-change no-op
//  rules. Foundation-only — no AppKit, no SDK — unit-tested standalone
//  (Tests/BrowserLogicTests.mm).
//
//  JLTidalBrowserController owns the state and forwards decisions here.
//

#pragma once

#import <Foundation/Foundation.h>
#import "BrowserState.h"

NS_ASSUME_NONNULL_BEGIN

@interface JLTidalBrowserLogic : NSObject

#pragma mark - Active-list selection

+ (BOOL)isShowingTracksInBrowseMode:(JLTidalBrowseMode)browseMode
                         searchType:(JLTidalSearchType)searchType
                     librarySection:(JLTidalLibrarySection)librarySection;

+ (BOOL)isShowingAlbumsInBrowseMode:(JLTidalBrowseMode)browseMode
                         searchType:(JLTidalSearchType)searchType
                     librarySection:(JLTidalLibrarySection)librarySection;

+ (BOOL)isShowingArtistsInBrowseMode:(JLTidalBrowseMode)browseMode
                          searchType:(JLTidalSearchType)searchType;

+ (BOOL)isShowingPlaylistsInBrowseMode:(JLTidalBrowseMode)browseMode
                        librarySection:(JLTidalLibrarySection)librarySection;

+ (BOOL)isDrillDownMode:(JLTidalBrowseMode)browseMode;

/// The mode a drill-down collapses back to.
+ (JLTidalBrowseMode)rootModeForPanelMode:(JLTidalPanelMode)panelMode;

#pragma mark - Pagination

/// Scroll-driven load-more gate: only when more pages exist, nothing is in
/// flight, and the view is within 100pt of the bottom.
+ (BOOL)shouldTriggerLoadMoreWithHasMore:(BOOL)hasMoreResults
                           isLoadingMore:(BOOL)isLoadingMore
                             isSearching:(BOOL)isSearching
                            scrollOffset:(CGFloat)scrollOffset
                           visibleHeight:(CGFloat)visibleHeight
                           contentHeight:(CGFloat)contentHeight;

/// Search pagination is absolute: next offset = request offset + returned count.
+ (NSInteger)offsetAfterSearchPageAtOffset:(NSInteger)requestOffset
                             returnedCount:(NSInteger)returnedCount;

/// A full page implies more may exist; a short page ends pagination.
+ (BOOL)hasMorePagesAfterReturnedCount:(NSInteger)returnedCount
                              pageSize:(NSInteger)pageSize;

#pragma mark - Navigation

/// Back button: ArtistTopTracks with a live artist returns to that artist's
/// albums; every other drill-down collapses straight to the root mode.
+ (BOOL)backReturnsToArtistAlbumsFromMode:(JLTidalBrowseMode)browseMode
                                hasArtist:(BOOL)hasArtist;

#pragma mark - Mode-change no-op rules

/// Same type while already showing search results changes nothing.
+ (BOOL)searchTypeChangeIsNoOpFromType:(JLTidalSearchType)currentType
                                toType:(JLTidalSearchType)newType
                            browseMode:(JLTidalBrowseMode)browseMode;

/// Same section while already showing the library list changes nothing.
+ (BOOL)librarySectionChangeIsNoOpFromSection:(JLTidalLibrarySection)currentSection
                                    toSection:(JLTidalLibrarySection)newSection
                                   browseMode:(JLTidalBrowseMode)browseMode;

@end

NS_ASSUME_NONNULL_END
