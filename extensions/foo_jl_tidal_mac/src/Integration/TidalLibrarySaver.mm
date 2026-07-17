//
//  TidalLibrarySaver.mm
//  foo_jl_tidal_mac
//

#import "TidalLibrarySaver.h"
#import <AppKit/AppKit.h>
#include <atomic>
#import "../Core/LibraryLayout.h"
#import "../Core/TidalConfig.h"
#import "../Core/TidalModels.h"
#import "../Services/TidalStreamResolver.h"
#import "TidalDashCache.h"

using tidal::logInfo;
using tidal::logError;
using tidal::logDebug;

static NSString *const kSaverLogPrefix = @"Library save";

static void saverLog(NSString *msg) {
    logInfo([[NSString stringWithFormat:@"%@: %@", kSaverLogPrefix, msg] UTF8String]);
}

static void saverError(NSString *msg) {
    logError([[NSString stringWithFormat:@"%@: %@", kSaverLogPrefix, msg] UTF8String]);
}

@implementation JLTidalLibrarySaver {
    dispatch_queue_t _queue;
    std::atomic<bool> _cancelled;
    NSMutableDictionary<NSString *, NSString *> *_genreMap;  // key -> "[Collection]", queue-confined
    NSString *_ffmpegPath;                                    // resolved once, may be nil
    BOOL _ffmpegProbed;
}

+ (instancetype)shared {
    static JLTidalLibrarySaver *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[JLTidalLibrarySaver alloc] init]; });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _queue = dispatch_queue_create("com.foobar2000.tidal.librarysaver", DISPATCH_QUEUE_SERIAL);
        _cancelled.store(false);
    }
    return self;
}

- (void)shutdown {
    _cancelled.store(true);
}

#pragma mark - Entry point

- (void)saveTrackIDs:(NSArray<NSString *> *)trackIDs {
    if (trackIDs.count == 0) return;
    _cancelled.store(false);
    dispatch_async(_queue, ^{
        [self runBatch:trackIDs];
    });
}

- (void)runBatch:(NSArray<NSString *> *)trackIDs {
    NSString *root = [NSString stringWithUTF8String:tidal::TidalConfig::getLibraryRoot().c_str()];
    if (root.length == 0) {
        saverError(@"no library root configured (Preferences > Tidal > Library)");
        return;
    }
    BOOL isDir = NO;
    if (![[NSFileManager defaultManager] fileExistsAtPath:root isDirectory:&isDir] || !isDir) {
        saverError([NSString stringWithFormat:@"library root not reachable: %@", root]);
        return;
    }

    [self loadGenreMap];
    saverLog([NSString stringWithFormat:@"starting batch of %lu track(s) -> %@",
              (unsigned long)trackIDs.count, root]);

    NSInteger saved = 0, skipped = 0, failed = 0;
    for (NSString *trackID in trackIDs) {
        if (_cancelled.load()) {
            saverLog(@"cancelled; abandoning remaining tracks");
            break;
        }
        switch ([self saveOneTrackID:trackID root:root]) {
            case 0: saved++; break;
            case 1: skipped++; break;
            default: failed++; break;
        }
    }
    saverLog([NSString stringWithFormat:@"done — %ld saved, %ld skipped, %ld failed",
              (long)saved, (long)skipped, (long)failed]);
}

// Returns 0 = saved, 1 = skipped, 2 = failed.
- (int)saveOneTrackID:(NSString *)trackID root:(NSString *)root {
    JLTidalTrack *track = [self fetchMetadataForTrackID:trackID];
    if (!track) {
        saverError([NSString stringWithFormat:@"metadata fetch failed for track %@", trackID]);
        return 2;
    }

    NSString *albumArtist = track.albumArtist.length > 0 ? track.albumArtist : track.artist;
    BOOL isVA = [JLTidalLibraryLayout isVariousArtists:albumArtist];
    NSString *displayName = isVA
        ? [NSString stringWithFormat:@"VA album \"%@\"", track.album ?: track.title]
        : (albumArtist ?: @"Unknown");

    NSString *collection = [self resolveCollectionForKey:[self genreKeyForTrack:track isVA:isVA]
                                             displayName:displayName
                                                    root:root];
    if (collection.length == 0) {
        saverLog([NSString stringWithFormat:@"skipped (no collection chosen): %@ - %@",
                  track.artist ?: @"?", track.title]);
        return 1;
    }

    NSString *collectionDir = [root stringByAppendingPathComponent:collection];
    NSString *artistFolder = nil;
    if (!isVA) {
        NSArray<NSString *> *listing = [[NSFileManager defaultManager]
                                        contentsOfDirectoryAtPath:collectionDir error:nil] ?: @[];
        artistFolder = [JLTidalLibraryLayout artistFolderInListing:listing artist:albumArtist];
    }

    NSString *year = [JLTidalLibraryLayout yearStringFromDate:track.releaseDate];
    NSString *albumRel = [JLTidalLibraryLayout albumPathForArtist:albumArtist
                                                             year:year
                                                       albumTitle:track.album ?: track.title
                                                    isCompilation:isVA
                                                     artistFolder:artistFolder];
    NSString *albumDir = [collectionDir stringByAppendingPathComponent:albumRel];

    // Resolve the stream before deciding the extension (DASH FLAC vs direct)
    JLTidalPlaybackInfo *info = [self resolveStreamForTrackID:trackID];
    if (!info) {
        saverError([NSString stringWithFormat:@"stream resolution failed: %@ - %@",
                    track.artist ?: @"?", track.title]);
        return 2;
    }

    BOOL isDASH = info.dashSegmentCount > 0 && info.dashMediaTemplate.length > 0;
    NSString *ffmpeg = [self ffmpegPath];
    BOOL codecIsFLAC = [[info.codec uppercaseString] isEqualToString:@"FLAC"];

    // Target extension: DASH FLAC remuxes to .flac (needs ffmpeg; the raw
    // blob is fMP4, saved as .m4a without it). Direct URLs keep their
    // native container.
    NSString *ext;
    if (isDASH) {
        ext = ffmpeg ? @"flac" : @"m4a";
    } else {
        ext = codecIsFLAC ? @"flac" : @"m4a";
    }

    NSString *fileName = [JLTidalLibraryLayout trackFileNameForNumber:track.trackNumber
                                                           discNumber:track.discNumber
                                                                title:track.title
                                                            extension:ext];
    NSString *target = [albumDir stringByAppendingPathComponent:fileName];
    NSFileManager *fm = [NSFileManager defaultManager];
    if ([fm fileExistsAtPath:target]) {
        saverLog([NSString stringWithFormat:@"exists, skipping: %@", [self relPath:target root:root]]);
        return 1;
    }

    NSData *audio;
    if (isDASH) {
        std::atomic<bool> *cancelled = &_cancelled;
        audio = [[JLTidalDashCache shared] blobForTrackID:trackID
                                            mediaTemplate:info.dashMediaTemplate
                                             segmentCount:info.dashSegmentCount
                                              isCancelled:^BOOL{ return cancelled->load(); }];
    } else if (info.streamURL) {
        audio = [self downloadURL:info.streamURL];
    } else {
        audio = nil;
    }
    if (audio.length == 0) {
        saverError([NSString stringWithFormat:@"download failed: %@ - %@",
                    track.artist ?: @"?", track.title]);
        return 2;
    }

    NSError *err = nil;
    if (![fm createDirectoryAtPath:albumDir withIntermediateDirectories:YES attributes:nil error:&err]) {
        saverError([NSString stringWithFormat:@"cannot create %@: %@", albumDir, err.localizedDescription]);
        return 2;
    }

    BOOL wroteTagged = NO;
    if (ffmpeg) {
        wroteTagged = [self remuxData:audio
                       inputExtension:(isDASH || !codecIsFLAC) ? @"mp4" : @"flac"
                               target:target
                             metadata:[self tagsForTrack:track]
                               ffmpeg:ffmpeg];
    }
    if (!wroteTagged) {
        // Raw fallback: correct container extension, no tags
        NSString *rawExt = (isDASH || !codecIsFLAC) ? @"m4a" : @"flac";
        NSString *rawName = [JLTidalLibraryLayout trackFileNameForNumber:track.trackNumber
                                                              discNumber:track.discNumber
                                                                   title:track.title
                                                               extension:rawExt];
        target = [albumDir stringByAppendingPathComponent:rawName];
        if ([fm fileExistsAtPath:target]) {
            saverLog([NSString stringWithFormat:@"exists, skipping: %@", [self relPath:target root:root]]);
            return 1;
        }
        if (![audio writeToFile:target options:NSDataWritingAtomic error:&err]) {
            saverError([NSString stringWithFormat:@"write failed: %@ (%@)", target, err.localizedDescription]);
            return 2;
        }
        if (ffmpeg) {
            saverError([NSString stringWithFormat:@"ffmpeg remux failed, saved raw container instead: %@",
                        [self relPath:target root:root]]);
        } else {
            saverLog(@"ffmpeg not found — saved raw container without tags");
        }
    }

    [self ensureCoverInAlbumDir:albumDir track:track];
    saverLog([NSString stringWithFormat:@"saved (%@): %@",
              info.qualityDescription, [self relPath:target root:root]]);
    return 0;
}

- (NSString *)relPath:(NSString *)path root:(NSString *)root {
    NSString *prefix = [root stringByAppendingString:@"/"];
    return [path hasPrefix:prefix] ? [path substringFromIndex:prefix.length] : path;
}

#pragma mark - Genre collection resolution

- (NSString *)genreKeyForTrack:(JLTidalTrack *)track isVA:(BOOL)isVA {
    if (isVA) {
        return [@"va-album:" stringByAppendingString:
                [(track.album ?: track.title) lowercaseString]];
    }
    NSString *artist = track.albumArtist.length > 0 ? track.albumArtist : track.artist;
    return [(artist ?: @"unknown") lowercaseString];
}

// Resolution order: existing artist folder on disk > remembered choice >
// prompt (remembered afterwards). Returns "[Collection]" or nil (skip).
- (NSString *)resolveCollectionForKey:(NSString *)key
                          displayName:(NSString *)displayName
                                 root:(NSString *)root {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *rootListing = [fm contentsOfDirectoryAtPath:root error:nil] ?: @[];
    NSArray<NSString *> *collections = [JLTidalLibraryLayout collectionNamesFromListing:rootListing];

    // 1. The existing curation on disk wins: an artist folder in some
    //    collection pins the artist there. (VA keys never match folders.)
    if (![key hasPrefix:@"va-album:"]) {
        for (NSString *collection in collections) {
            NSString *dir = [root stringByAppendingPathComponent:collection];
            NSArray<NSString *> *listing = [fm contentsOfDirectoryAtPath:dir error:nil] ?: @[];
            if ([JLTidalLibraryLayout artistFolderInListing:listing artist:key]) {
                logDebug([[NSString stringWithFormat:@"Library save: %@ pinned to %@ by existing artist folder",
                           displayName, collection] UTF8String]);
                return collection;
            }
        }
    }

    // 2. Remembered choice
    NSString *remembered = _genreMap[key];
    if (remembered.length > 0) return remembered;

    // 3. Ask once, remember forever
    NSString *chosen = [self promptForCollectionNamed:displayName collections:collections];
    if (chosen.length > 0) {
        _genreMap[key] = chosen;
        [self persistGenreMap];
    }
    return chosen;
}

// Blocks the worker queue while the user answers on the main thread.
// Returns "[Collection]" or nil (skip / cancel batch).
- (NSString *)promptForCollectionNamed:(NSString *)displayName
                           collections:(NSArray<NSString *> *)collections {
    if (_cancelled.load()) return nil;
    __block NSString *result = nil;
    __block BOOL cancelAll = NO;
    dispatch_sync(dispatch_get_main_queue(), ^{
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = [NSString stringWithFormat:@"Genre collection for %@", displayName];
        alert.informativeText = @"Pick the music.hq genre collection this belongs to. "
                                @"The choice is remembered for future saves.";
        [alert addButtonWithTitle:@"Save"];
        [alert addButtonWithTitle:@"Skip"];
        [alert addButtonWithTitle:@"Cancel Remaining"];

        NSComboBox *combo = [[NSComboBox alloc] initWithFrame:NSMakeRect(0, 0, 280, 26)];
        [combo addItemsWithObjectValues:collections];
        combo.completes = YES;
        if (collections.count > 0) combo.stringValue = collections[0];
        alert.accessoryView = combo;
        [alert.window setInitialFirstResponder:combo];

        NSModalResponse response = [alert runModal];
        if (response == NSAlertFirstButtonReturn) {
            NSString *value = [combo.stringValue stringByTrimmingCharactersInSet:
                               [NSCharacterSet whitespaceCharacterSet]];
            if (value.length > 0) {
                // User input flows into directory creation under the library
                // root; sanitize so path separators cannot escape it.
                NSString *inner = [value stringByTrimmingCharactersInSet:
                                   [NSCharacterSet characterSetWithCharactersInString:@"[]"]];
                inner = [JLTidalLibraryLayout sanitizeComponent:inner];
                result = [NSString stringWithFormat:@"[%@]", inner];
            }
        } else if (response == NSAlertThirdButtonReturn) {
            cancelAll = YES;
        }
    });
    if (cancelAll) _cancelled.store(true);
    return result;
}

- (void)loadGenreMap {
    if (_genreMap) return;
    _genreMap = [NSMutableDictionary dictionary];
    std::string json = tidal::TidalConfig::getGenreMapJSON();
    NSData *data = [[NSString stringWithUTF8String:json.c_str()]
                    dataUsingEncoding:NSUTF8StringEncoding];
    if (data) {
        id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        if ([parsed isKindOfClass:[NSDictionary class]]) {
            for (id k in parsed) {
                id v = parsed[k];
                if ([k isKindOfClass:[NSString class]] && [v isKindOfClass:[NSString class]]) {
                    // Values flow into directory creation under the library
                    // root; re-sanitize on load (same as the prompt path) so
                    // a tampered stored entry cannot escape it.
                    NSString *inner = [v stringByTrimmingCharactersInSet:
                                       [NSCharacterSet characterSetWithCharactersInString:@"[]"]];
                    inner = [JLTidalLibraryLayout sanitizeComponent:inner];
                    if (inner.length > 0) {
                        _genreMap[k] = [NSString stringWithFormat:@"[%@]", inner];
                    }
                }
            }
        }
    }
}

- (void)persistGenreMap {
    NSData *data = [NSJSONSerialization dataWithJSONObject:_genreMap options:0 error:nil];
    if (!data) return;
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (json) tidal::TidalConfig::setGenreMapJSON(std::string(json.UTF8String));
}

#pragma mark - Tags

- (NSDictionary<NSString *, NSString *> *)tagsForTrack:(JLTidalTrack *)track {
    NSMutableDictionary<NSString *, NSString *> *tags = [NSMutableDictionary dictionary];
    if (track.title.length) tags[@"title"] = track.title;
    if (track.artist.length) tags[@"artist"] = track.artist;
    if (track.album.length) tags[@"album"] = track.album;
    if (track.albumArtist.length) tags[@"album_artist"] = track.albumArtist;
    if (track.trackNumber > 0) {
        tags[@"track"] = track.totalTracks > 0
            ? [NSString stringWithFormat:@"%ld/%ld", (long)track.trackNumber, (long)track.totalTracks]
            : [NSString stringWithFormat:@"%ld", (long)track.trackNumber];
    }
    if (track.discNumber > 0) {
        tags[@"disc"] = [NSString stringWithFormat:@"%ld", (long)track.discNumber];
    }
    if (track.releaseDate) {
        static NSDateFormatter *fmt;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            fmt = [[NSDateFormatter alloc] init];
            fmt.dateFormat = @"yyyy-MM-dd";
            fmt.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
            fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        });
        tags[@"date"] = [fmt stringFromDate:track.releaseDate];
    }
    if (track.isrc.length) tags[@"isrc"] = track.isrc;
    if (track.copyright.length) tags[@"copyright"] = track.copyright;
    return tags;
}

#pragma mark - ffmpeg

- (NSString *)ffmpegPath {
    if (_ffmpegProbed) return _ffmpegPath;
    _ffmpegProbed = YES;
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *candidate in @[@"/opt/homebrew/bin/ffmpeg",
                                  @"/usr/local/bin/ffmpeg",
                                  @"/usr/bin/ffmpeg"]) {
        if ([fm isExecutableFileAtPath:candidate]) {
            _ffmpegPath = candidate;
            break;
        }
    }
    return _ffmpegPath;
}

// Writes audio data to a temp file and stream-copies it (with tags) to
// target via ffmpeg. Returns NO on any failure; target is left absent.
- (BOOL)remuxData:(NSData *)audio
   inputExtension:(NSString *)inputExt
           target:(NSString *)target
         metadata:(NSDictionary<NSString *, NSString *> *)metadata
           ffmpeg:(NSString *)ffmpeg {
    NSString *tmp = [NSTemporaryDirectory() stringByAppendingPathComponent:
                     [NSString stringWithFormat:@"jl-tidal-save-%@.%@",
                      [NSUUID UUID].UUIDString, inputExt]];
    if (![audio writeToFile:tmp options:NSDataWritingAtomic error:nil]) return NO;

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:ffmpeg];
    task.arguments = [JLTidalLibraryLayout ffmpegArgumentsForInput:tmp
                                                            output:target
                                                          metadata:metadata];
    task.standardInput = [NSFileHandle fileHandleWithNullDevice];
    task.standardOutput = [NSFileHandle fileHandleWithNullDevice];
    NSPipe *stderrPipe = [NSPipe pipe];
    task.standardError = stderrPipe;

    NSError *err = nil;
    BOOL ok = NO;
    if ([task launchAndReturnError:&err]) {
        NSData *stderrData = [stderrPipe.fileHandleForReading readDataToEndOfFile];
        [task waitUntilExit];
        ok = (task.terminationStatus == 0);
        if (!ok) {
            NSString *log = [[NSString alloc] initWithData:stderrData encoding:NSUTF8StringEncoding] ?: @"";
            NSString *tail = log.length > 500 ? [log substringFromIndex:log.length - 500] : log;
            saverError([NSString stringWithFormat:@"ffmpeg exit %d: %@", task.terminationStatus, tail]);
        }
    } else {
        saverError([NSString stringWithFormat:@"ffmpeg launch failed: %@", err.localizedDescription]);
    }

    [[NSFileManager defaultManager] removeItemAtPath:tmp error:nil];
    if (!ok) [[NSFileManager defaultManager] removeItemAtPath:target error:nil];
    return ok;
}

#pragma mark - Cover art

- (void)ensureCoverInAlbumDir:(NSString *)albumDir track:(JLTidalTrack *)track {
    NSString *coverPath = [albumDir stringByAppendingPathComponent:@"cover.jpg"];
    if ([[NSFileManager defaultManager] fileExistsAtPath:coverPath]) return;
    if (!track.albumArtURL) return;

    // Try the 1280px rendition first, fall back to the model's 640px URL
    NSURL *bigURL = [NSURL URLWithString:
                     [track.albumArtURL.absoluteString
                      stringByReplacingOccurrencesOfString:@"640x640" withString:@"1280x1280"]];
    NSData *img = bigURL ? [self downloadURL:bigURL] : nil;
    if (img.length == 0) img = [self downloadURL:track.albumArtURL];
    if (img.length > 0) {
        [img writeToFile:coverPath options:NSDataWritingAtomic error:nil];
    }
}

#pragma mark - Synchronous helpers (worker queue only)

- (JLTidalTrack *)fetchMetadataForTrackID:(NSString *)trackID {
    __block JLTidalTrack *result = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[JLTidalStreamResolver shared] getMetadataForTrackID:trackID
                                               completion:^(JLTidalTrack *track, NSError *error) {
        result = track;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));
    return result;
}

- (JLTidalPlaybackInfo *)resolveStreamForTrackID:(NSString *)trackID {
    __block JLTidalPlaybackInfo *result = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[JLTidalStreamResolver shared] resolveStreamForTrackID:trackID
                                                 completion:^(JLTidalPlaybackInfo *info, NSError *error) {
        result = info;
        dispatch_semaphore_signal(sem);
    }];
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC));
    return result;
}

- (NSData *)downloadURL:(NSURL *)url {
    // Dedicated session with explicit timeouts. sharedSession's 7-day
    // resource timeout would let a stalled CDN transfer hold the serial
    // saver queue until the 300 s outer semaphore expires per file.
    static NSURLSession *session = nil;
    static dispatch_once_t sessionOnce;
    dispatch_once(&sessionOnce, ^{
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
        cfg.timeoutIntervalForRequest = 60;
        cfg.timeoutIntervalForResource = 240;
        session = [NSURLSession sessionWithConfiguration:cfg];
    });

    __block NSData *result = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURLSessionDataTask *task = [session dataTaskWithURL:url
                                        completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [(NSHTTPURLResponse *)response statusCode];
        if (!error && status >= 200 && status < 300) result = data;
        dispatch_semaphore_signal(sem);
    }];
    [task resume];
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_SEC)) != 0) {
        [task cancel];
    }
    return result;
}

@end
