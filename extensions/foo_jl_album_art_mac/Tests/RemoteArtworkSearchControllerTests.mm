//
//  RemoteArtworkSearchControllerTests.mm
//  foo_jl_album_art_mac
//
//  Unit tests for RemoteArtworkSearchController using mock providers.
//  Covers aggregation, deduplication, sort order, completion semantics,
//  unconfigured-provider skipping, and the stale-completion race that
//  previously corrupted a new search after cancel/restart.
//

#import "TestHarness.h"
#import "../src/Core/RemoteArtworkSearchController.h"

#pragma mark - Mock provider

typedef void (^MockSearchHandler)(TrackMetadata *metadata, ArtworkSearchCompletion completion);

@interface MockProvider : NSObject <ArtworkSourceProvider>
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *displayName;
@property (nonatomic, copy) MockSearchHandler searchHandler;
@property (nonatomic, assign) NSInteger cancelCount;
@property (nonatomic, assign, getter=isConfigured) BOOL configured;
@end

@implementation MockProvider

- (instancetype)initWithIdentifier:(NSString *)identifier {
    self = [super init];
    if (self) {
        _identifier = [identifier copy];
        _displayName = [identifier capitalizedString];
        _configured = YES;
    }
    return self;
}

// isConfigured is synthesized from the configured property (getter=isConfigured)
- (BOOL)requiresAPIKey { return NO; }
- (NSTimeInterval)rateLimitInterval { return 0; }

- (void)searchWithMetadata:(TrackMetadata *)metadata
                completion:(ArtworkSearchCompletion)completion {
    if (self.searchHandler) {
        self.searchHandler(metadata, completion);
    }
}

- (void)cancel {
    self.cancelCount++;
}

@end

#pragma mark - Recording delegate

@interface RecordingDelegate : NSObject <RemoteArtworkSearchDelegate>
@property (nonatomic, assign) NSInteger startCount;
@property (nonatomic, assign) NSInteger completeCount;
@property (nonatomic, strong) NSArray<ArtworkResult *> *lastResults;
@property (nonatomic, strong) NSError *lastError;
@property (nonatomic, copy) NSString *lastProgress;
@end

@implementation RecordingDelegate
- (void)searchDidStart { self.startCount++; }
- (void)searchDidUpdateProgress:(NSString *)message { self.lastProgress = message; }
- (void)searchDidFindResults:(NSArray<ArtworkResult *> *)results { self.lastResults = results; }
- (void)searchDidFailWithError:(NSError *)error { self.lastError = error; }
- (void)searchDidComplete { self.completeCount++; }
@end

#pragma mark - Helpers

static TrackMetadata *TestMetadata(void) {
    return [[TrackMetadata alloc] initWithArtist:@"Artist"
                                     albumArtist:@""
                                           album:@"Album"
                                           title:@"Title"
                            musicBrainzReleaseID:nil
                       musicBrainzReleaseGroupID:nil
                                discogsReleaseID:nil
                                       trackPath:nil];
}

static ArtworkResult *Result(NSString *source, NSString *url, RemoteArtworkType type, CGFloat size) {
    return [[ArtworkResult alloc] initWithSourceIdentifier:source
                                                sourceName:source
                                              thumbnailURL:[NSURL URLWithString:url]
                                         fullResolutionURL:[NSURL URLWithString:url]
                                                resolution:CGSizeMake(size, size)
                                               artworkType:type];
}

/// Pump the main runloop until the condition holds or the timeout expires
static BOOL WaitFor(BOOL (^condition)(void), NSTimeInterval timeout) {
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!condition()) {
        if ([deadline timeIntervalSinceNow] < 0) {
            return NO;
        }
        [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode
                               beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.02]];
    }
    return YES;
}

#pragma mark - Tests

static void testAggregationAndDedup(void) {
    TEST_CONTEXT("aggregation");

    MockProvider *a = [[MockProvider alloc] initWithIdentifier:@"alpha"];
    MockProvider *b = [[MockProvider alloc] initWithIdentifier:@"beta"];

    a.searchHandler = ^(TrackMetadata *metadata, ArtworkSearchCompletion completion) {
        completion(@[Result(@"alpha", @"https://x/1.jpg", RemoteArtworkTypeFront, 1000),
                     Result(@"alpha", @"https://x/shared.jpg", RemoteArtworkTypeFront, 500)], nil);
    };
    b.searchHandler = ^(TrackMetadata *metadata, ArtworkSearchCompletion completion) {
        completion(@[Result(@"beta", @"https://x/shared.jpg", RemoteArtworkTypeFront, 500),
                     Result(@"beta", @"https://x/2.jpg", RemoteArtworkTypeBack, 800)], nil);
    };

    RemoteArtworkSearchController *controller =
        [[RemoteArtworkSearchController alloc] initWithProviders:@[a, b]];
    RecordingDelegate *delegate = [[RecordingDelegate alloc] init];
    controller.delegate = delegate;

    [controller searchForArtworkWithMetadata:TestMetadata()];

    CHECK_TRUE(WaitFor(^{ return (BOOL)(delegate.completeCount > 0); }, 2.0), "search completes");
    CHECK_EQ(delegate.startCount, 1, "one start");
    CHECK_EQ(delegate.completeCount, 1, "one complete");
    CHECK_EQ(delegate.lastResults.count, 3, "duplicate URL merged");
    CHECK_NIL(delegate.lastError, "no error");
    CHECK_FALSE(controller.isSearching, "not searching after completion");

    // Sort: Front (1000) > Front (500), then Back
    CHECK_STR_EQ(delegate.lastResults[0].fullResolutionURL.absoluteString, @"https://x/1.jpg",
                 "highest resolution front first");
    CHECK_EQ(delegate.lastResults[2].artworkType, RemoteArtworkTypeBack, "back sorted last");
}

static void testSourcePriorityTieBreak(void) {
    TEST_CONTEXT("priority");

    MockProvider *first = [[MockProvider alloc] initWithIdentifier:@"first"];
    MockProvider *second = [[MockProvider alloc] initWithIdentifier:@"second"];

    // Same type and resolution: provider registration order breaks the tie.
    // The second provider completes first to prove arrival order is irrelevant.
    first.searchHandler = ^(TrackMetadata *m, ArtworkSearchCompletion completion) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            completion(@[Result(@"first", @"https://x/f.jpg", RemoteArtworkTypeFront, 1000)], nil);
        });
    };
    second.searchHandler = ^(TrackMetadata *m, ArtworkSearchCompletion completion) {
        completion(@[Result(@"second", @"https://x/s.jpg", RemoteArtworkTypeFront, 1000)], nil);
    };

    RemoteArtworkSearchController *controller =
        [[RemoteArtworkSearchController alloc] initWithProviders:@[first, second]];
    RecordingDelegate *delegate = [[RecordingDelegate alloc] init];
    controller.delegate = delegate;

    [controller searchForArtworkWithMetadata:TestMetadata()];

    CHECK_TRUE(WaitFor(^{ return (BOOL)(delegate.completeCount > 0); }, 2.0), "search completes");
    CHECK_EQ(delegate.lastResults.count, 2, "both results");
    CHECK_STR_EQ(delegate.lastResults[0].sourceIdentifier, @"first", "registration order wins tie");
}

static void testNoResultsError(void) {
    TEST_CONTEXT("no results");

    MockProvider *empty = [[MockProvider alloc] initWithIdentifier:@"empty"];
    empty.searchHandler = ^(TrackMetadata *m, ArtworkSearchCompletion completion) {
        completion(@[], nil);
    };

    RemoteArtworkSearchController *controller =
        [[RemoteArtworkSearchController alloc] initWithProviders:@[empty]];
    RecordingDelegate *delegate = [[RecordingDelegate alloc] init];
    controller.delegate = delegate;

    [controller searchForArtworkWithMetadata:TestMetadata()];

    CHECK_TRUE(WaitFor(^{ return (BOOL)(delegate.completeCount > 0); }, 2.0), "search completes");
    CHECK_NOT_NIL(delegate.lastError, "error reported");
    CHECK_EQ(delegate.lastError.code, ArtworkFetchErrorNoResults, "no-results code");
}

static void testInvalidMetadata(void) {
    TEST_CONTEXT("invalid metadata");

    MockProvider *provider = [[MockProvider alloc] initWithIdentifier:@"p"];
    RemoteArtworkSearchController *controller =
        [[RemoteArtworkSearchController alloc] initWithProviders:@[provider]];
    RecordingDelegate *delegate = [[RecordingDelegate alloc] init];
    controller.delegate = delegate;

    TrackMetadata *bad = [[TrackMetadata alloc] initWithArtist:@""
                                                   albumArtist:@""
                                                         album:@""
                                                         title:@""
                                          musicBrainzReleaseID:nil
                                     musicBrainzReleaseGroupID:nil
                                              discogsReleaseID:nil
                                                     trackPath:nil];
    [controller searchForArtworkWithMetadata:bad];

    CHECK_TRUE(WaitFor(^{ return (BOOL)(delegate.lastError != nil); }, 2.0), "fails");
    CHECK_EQ(delegate.lastError.code, ArtworkFetchErrorInvalidMetadata, "metadata error code");
    CHECK_EQ(delegate.startCount, 0, "search never started");
}

static void testUnconfiguredProviderSkipped(void) {
    TEST_CONTEXT("unconfigured skipped");

    MockProvider *active = [[MockProvider alloc] initWithIdentifier:@"active"];
    MockProvider *inactive = [[MockProvider alloc] initWithIdentifier:@"inactive"];
    inactive.configured = NO;

    __block BOOL inactiveQueried = NO;
    inactive.searchHandler = ^(TrackMetadata *m, ArtworkSearchCompletion completion) {
        inactiveQueried = YES;
        completion(@[], nil);
    };
    active.searchHandler = ^(TrackMetadata *m, ArtworkSearchCompletion completion) {
        completion(@[Result(@"active", @"https://x/a.jpg", RemoteArtworkTypeFront, 100)], nil);
    };

    RemoteArtworkSearchController *controller =
        [[RemoteArtworkSearchController alloc] initWithProviders:@[active, inactive]];
    RecordingDelegate *delegate = [[RecordingDelegate alloc] init];
    controller.delegate = delegate;

    [controller searchForArtworkWithMetadata:TestMetadata()];

    CHECK_TRUE(WaitFor(^{ return (BOOL)(delegate.completeCount > 0); }, 2.0), "completes without inactive");
    CHECK_FALSE(inactiveQueried, "unconfigured provider not queried");
    CHECK_EQ(delegate.lastResults.count, 1, "active result delivered");
}

static void testStaleCompletionIgnoredAfterRestart(void) {
    TEST_CONTEXT("stale completion");

    // First search: provider stashes its completion without calling it.
    // After cancel + new search, firing the STALE completion must not
    // count against the new search's pending sources or results.
    __block ArtworkSearchCompletion staleCompletion = nil;
    __block ArtworkSearchCompletion freshCompletion = nil;
    __block NSInteger calls = 0;

    MockProvider *provider = [[MockProvider alloc] initWithIdentifier:@"p"];
    provider.searchHandler = ^(TrackMetadata *m, ArtworkSearchCompletion completion) {
        calls++;
        if (calls == 1) {
            staleCompletion = completion;
        } else {
            freshCompletion = completion;
        }
    };

    RemoteArtworkSearchController *controller =
        [[RemoteArtworkSearchController alloc] initWithProviders:@[provider]];
    RecordingDelegate *delegate = [[RecordingDelegate alloc] init];
    controller.delegate = delegate;

    [controller searchForArtworkWithMetadata:TestMetadata()];
    CHECK_TRUE(WaitFor(^{ return (BOOL)(staleCompletion != nil); }, 2.0), "first search issued");

    [controller cancel];
    CHECK_EQ(provider.cancelCount, 1, "provider cancelled");

    [controller searchForArtworkWithMetadata:TestMetadata()];
    CHECK_TRUE(WaitFor(^{ return (BOOL)(freshCompletion != nil); }, 2.0), "second search issued");

    // Fire the stale completion with results that must be discarded
    staleCompletion(@[Result(@"p", @"https://x/stale.jpg", RemoteArtworkTypeFront, 100)], nil);

    [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode
                          beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
    CHECK_EQ(delegate.completeCount, 0, "stale completion does not finish new search");
    CHECK_TRUE(controller.isSearching, "still searching");
    CHECK_NIL(delegate.lastResults, "stale results discarded");

    // Fresh completion finishes the search with the real result
    freshCompletion(@[Result(@"p", @"https://x/fresh.jpg", RemoteArtworkTypeFront, 100)], nil);

    CHECK_TRUE(WaitFor(^{ return (BOOL)(delegate.completeCount > 0); }, 2.0), "fresh completion completes");
    CHECK_EQ(delegate.lastResults.count, 1, "one result");
    CHECK_STR_EQ(delegate.lastResults[0].fullResolutionURL.absoluteString,
                 @"https://x/fresh.jpg", "fresh result kept");
}

static void testCancelSilencesDelegate(void) {
    TEST_CONTEXT("cancel");

    __block ArtworkSearchCompletion pendingCompletion = nil;
    MockProvider *provider = [[MockProvider alloc] initWithIdentifier:@"p"];
    provider.searchHandler = ^(TrackMetadata *m, ArtworkSearchCompletion completion) {
        pendingCompletion = completion;
    };

    RemoteArtworkSearchController *controller =
        [[RemoteArtworkSearchController alloc] initWithProviders:@[provider]];
    RecordingDelegate *delegate = [[RecordingDelegate alloc] init];
    controller.delegate = delegate;

    [controller searchForArtworkWithMetadata:TestMetadata()];
    CHECK_TRUE(WaitFor(^{ return (BOOL)(pendingCompletion != nil); }, 2.0), "search issued");

    [controller cancel];
    CHECK_FALSE(controller.isSearching, "not searching after cancel");

    NSInteger completeBefore = delegate.completeCount;
    pendingCompletion(@[Result(@"p", @"https://x/late.jpg", RemoteArtworkTypeFront, 100)], nil);

    [[NSRunLoop mainRunLoop] runMode:NSDefaultRunLoopMode
                          beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.2]];
    CHECK_EQ(delegate.completeCount, completeBefore, "no callbacks after cancel");
    CHECK_NIL(delegate.lastResults, "no results after cancel");
}

int main(void) {
    @autoreleasepool {
        testAggregationAndDedup();
        testSourcePriorityTieBreak();
        testNoResultsError();
        testInvalidMetadata();
        testUnconfiguredProviderSkipped();
        testStaleCompletionIgnoredAfterRestart();
        testCancelSilencesDelegate();
    }
    return test_summary("RemoteArtworkSearchControllerTests");
}
