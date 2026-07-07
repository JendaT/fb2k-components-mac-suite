//
//  BrowserLogicTests.mm
//  foo_jl_tidal_mac
//
//  Unit tests for browser panel decisions: the active-list matrix,
//  pagination gate and math, back-button routing, and mode-change
//  no-op rules.
//

#import <Foundation/Foundation.h>
#import "../src/Core/BrowserLogic.h"
#include "TestHarness.h"

typedef JLTidalBrowserLogic Logic;

static void testActiveListMatrix(void) {
    // Exactly one list is active for every (mode, searchType, section) combo
    JLTidalBrowseMode modes[] = {
        JLTidalBrowseModeSearchResults, JLTidalBrowseModeAlbumTracks,
        JLTidalBrowseModeArtistTopTracks, JLTidalBrowseModeArtistAlbums,
        JLTidalBrowseModeLibraryList, JLTidalBrowseModePlaylistTracks,
    };
    for (size_t m = 0; m < 6; m++) {
        for (NSInteger st = 0; st <= 2; st++) {
            for (NSInteger ls = 0; ls <= 2; ls++) {
                int active = 0;
                active += [Logic isShowingTracksInBrowseMode:modes[m]
                                                  searchType:(JLTidalSearchType)st
                                              librarySection:(JLTidalLibrarySection)ls] ? 1 : 0;
                active += [Logic isShowingAlbumsInBrowseMode:modes[m]
                                                  searchType:(JLTidalSearchType)st
                                              librarySection:(JLTidalLibrarySection)ls] ? 1 : 0;
                active += [Logic isShowingArtistsInBrowseMode:modes[m]
                                                   searchType:(JLTidalSearchType)st] ? 1 : 0;
                active += [Logic isShowingPlaylistsInBrowseMode:modes[m]
                                                 librarySection:(JLTidalLibrarySection)ls] ? 1 : 0;
                CHECK_EQ(active, 1, "exactly one active list for mode=%zu st=%ld ls=%ld (got %d)",
                         m, (long)st, (long)ls, active);
            }
        }
    }

    // Spot-check the specific routing
    CHECK([Logic isShowingTracksInBrowseMode:JLTidalBrowseModeAlbumTracks
                                  searchType:JLTidalSearchTypeAlbums
                              librarySection:JLTidalLibrarySectionPlaylists],
          "album drill-down always shows tracks");
    CHECK([Logic isShowingAlbumsInBrowseMode:JLTidalBrowseModeArtistAlbums
                                  searchType:JLTidalSearchTypeTracks
                              librarySection:JLTidalLibrarySectionFavTracks],
          "artist albums drill-down always shows albums");
    CHECK([Logic isShowingTracksInBrowseMode:JLTidalBrowseModeLibraryList
                                  searchType:JLTidalSearchTypeAlbums
                              librarySection:JLTidalLibrarySectionFavTracks],
          "library fav-tracks shows tracks regardless of search type");
    CHECK([Logic isShowingArtistsInBrowseMode:JLTidalBrowseModeSearchResults
                                   searchType:JLTidalSearchTypeArtists],
          "artist search shows artists");
    CHECK([Logic isShowingPlaylistsInBrowseMode:JLTidalBrowseModeLibraryList
                                 librarySection:JLTidalLibrarySectionPlaylists],
          "library playlists section shows playlists");
}

static void testDrillDownAndRoot(void) {
    CHECK(![Logic isDrillDownMode:JLTidalBrowseModeSearchResults], "search results is root");
    CHECK(![Logic isDrillDownMode:JLTidalBrowseModeLibraryList], "library list is root");
    CHECK([Logic isDrillDownMode:JLTidalBrowseModeAlbumTracks], "album tracks is drill-down");
    CHECK([Logic isDrillDownMode:JLTidalBrowseModeArtistTopTracks], "artist top tracks is drill-down");
    CHECK([Logic isDrillDownMode:JLTidalBrowseModeArtistAlbums], "artist albums is drill-down");
    CHECK([Logic isDrillDownMode:JLTidalBrowseModePlaylistTracks], "playlist tracks is drill-down");

    CHECK_EQ([Logic rootModeForPanelMode:JLTidalPanelModeSearch],
             JLTidalBrowseModeSearchResults, "search panel roots at search results");
    CHECK_EQ([Logic rootModeForPanelMode:JLTidalPanelModeLibrary],
             JLTidalBrowseModeLibraryList, "library panel roots at library list");
}

static void testLoadMoreGate(void) {
    // Within 100pt of bottom, idle -> trigger
    CHECK([Logic shouldTriggerLoadMoreWithHasMore:YES isLoadingMore:NO isSearching:NO
                                     scrollOffset:850 visibleHeight:100 contentHeight:1000],
          "near bottom triggers");
    // Exactly at threshold (offset+visible == content-100) -> trigger
    CHECK([Logic shouldTriggerLoadMoreWithHasMore:YES isLoadingMore:NO isSearching:NO
                                     scrollOffset:800 visibleHeight:100 contentHeight:1000],
          "threshold boundary triggers");
    // Far from bottom -> no
    CHECK(![Logic shouldTriggerLoadMoreWithHasMore:YES isLoadingMore:NO isSearching:NO
                                      scrollOffset:0 visibleHeight:100 contentHeight:1000],
          "far from bottom does not trigger");
    // Gate flags each block independently
    CHECK(![Logic shouldTriggerLoadMoreWithHasMore:NO isLoadingMore:NO isSearching:NO
                                      scrollOffset:900 visibleHeight:100 contentHeight:1000],
          "no more results blocks");
    CHECK(![Logic shouldTriggerLoadMoreWithHasMore:YES isLoadingMore:YES isSearching:NO
                                      scrollOffset:900 visibleHeight:100 contentHeight:1000],
          "in-flight page blocks");
    CHECK(![Logic shouldTriggerLoadMoreWithHasMore:YES isLoadingMore:NO isSearching:YES
                                      scrollOffset:900 visibleHeight:100 contentHeight:1000],
          "active search blocks");
}

static void testPaginationMath(void) {
    CHECK_EQ([Logic offsetAfterSearchPageAtOffset:0 returnedCount:50], (NSInteger)50, "first page offset");
    CHECK_EQ([Logic offsetAfterSearchPageAtOffset:50 returnedCount:37], (NSInteger)87, "short page offset");
    CHECK_EQ([Logic offsetAfterSearchPageAtOffset:100 returnedCount:0], (NSInteger)100, "empty page keeps offset");

    CHECK([Logic hasMorePagesAfterReturnedCount:50 pageSize:50], "full page -> more");
    CHECK([Logic hasMorePagesAfterReturnedCount:51 pageSize:50], "overfull page -> more");
    CHECK(![Logic hasMorePagesAfterReturnedCount:49 pageSize:50], "short page -> done");
    CHECK(![Logic hasMorePagesAfterReturnedCount:0 pageSize:50], "empty page -> done");
}

static void testBackRouting(void) {
    CHECK([Logic backReturnsToArtistAlbumsFromMode:JLTidalBrowseModeArtistTopTracks hasArtist:YES],
          "top tracks with artist goes back to artist albums");
    CHECK(![Logic backReturnsToArtistAlbumsFromMode:JLTidalBrowseModeArtistTopTracks hasArtist:NO],
          "top tracks without artist collapses to root");
    CHECK(![Logic backReturnsToArtistAlbumsFromMode:JLTidalBrowseModeAlbumTracks hasArtist:YES],
          "album tracks collapses to root even with artist context");
    CHECK(![Logic backReturnsToArtistAlbumsFromMode:JLTidalBrowseModePlaylistTracks hasArtist:NO],
          "playlist tracks collapses to root");
}

static void testModeChangeNoOps(void) {
    CHECK([Logic searchTypeChangeIsNoOpFromType:JLTidalSearchTypeTracks
                                         toType:JLTidalSearchTypeTracks
                                     browseMode:JLTidalBrowseModeSearchResults],
          "same type at search results is no-op");
    CHECK(![Logic searchTypeChangeIsNoOpFromType:JLTidalSearchTypeTracks
                                          toType:JLTidalSearchTypeAlbums
                                      browseMode:JLTidalBrowseModeSearchResults],
          "different type is not no-op");
    CHECK(![Logic searchTypeChangeIsNoOpFromType:JLTidalSearchTypeTracks
                                          toType:JLTidalSearchTypeTracks
                                      browseMode:JLTidalBrowseModeAlbumTracks],
          "same type inside drill-down still exits drill-down");

    CHECK([Logic librarySectionChangeIsNoOpFromSection:JLTidalLibrarySectionPlaylists
                                             toSection:JLTidalLibrarySectionPlaylists
                                            browseMode:JLTidalBrowseModeLibraryList],
          "same section at library list is no-op");
    CHECK(![Logic librarySectionChangeIsNoOpFromSection:JLTidalLibrarySectionPlaylists
                                              toSection:JLTidalLibrarySectionFavTracks
                                             browseMode:JLTidalBrowseModeLibraryList],
          "different section is not no-op");
    CHECK(![Logic librarySectionChangeIsNoOpFromSection:JLTidalLibrarySectionPlaylists
                                              toSection:JLTidalLibrarySectionPlaylists
                                             browseMode:JLTidalBrowseModePlaylistTracks],
          "same section inside drill-down still reloads");
}

int main(void) {
    @autoreleasepool {
        testActiveListMatrix();
        testDrillDownAndRoot();
        testLoadMoreGate();
        testPaginationMath();
        testBackRouting();
        testModeChangeNoOps();
    }
    return testHarnessFinish("BrowserLogic");
}
