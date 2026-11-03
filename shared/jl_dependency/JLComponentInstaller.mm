//
// JLComponentInstaller.mm
//
// Lookup and install run on a private serial queue, waiting for each
// transfer in turn; NSURLSession calls back on its own serial queue. Work
// files live in <profile>/.jl-install/ (beside user-components, same
// volume): a staged or set-aside .component inside user-components could be
// loaded by foobar2000 as a second copy.
//

#import "JLComponentInstaller.h"

#import <CommonCrypto/CommonDigest.h>

#include <atomic>
#include <cerrno>
#include <fcntl.h>
#include <string>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

using namespace jl_dep;

namespace {

NSString *const kWorkFolder = @".jl-install";
NSString *const kLockName = @"lock";
NSString *const kSetAsideName = @"set-aside";
NSString *const kUserAgent = @"foobar2000-jl-components";
constexpr NSUInteger kMaxSmallBytes = 1024 * 1024;   // API answers and SHA256SUMS
constexpr int64_t kTransferTimeout = 300;            // seconds for one transfer
constexpr size_t kTagsToTry = 5;
constexpr NSTimeInterval kStaleWorkFiles = 60 * 60;  // left by an install that died

std::string utf8(NSString *s) {
    return s ? std::string(s.UTF8String ?: "") : std::string();
}

NSString *ns(const std::string &s) {
    return [NSString stringWithUTF8String:s.c_str()] ?: @"";
}

NSString *megabytes(uint64_t bytes) {
    return [NSString stringWithFormat:@"%.1f MB", static_cast<double>(bytes) / (1024.0 * 1024.0)];
}

bool allowedURL(NSURL *url) {
    return url && allowedDownloadHost(utf8(url.scheme.lowercaseString), utf8(url.host));
}

NSString *sha256OfFile(NSString *path) {
    FILE *f = fopen(path.fileSystemRepresentation, "rb");
    if (!f) return nil;
    CC_SHA256_CTX ctx;
    CC_SHA256_Init(&ctx);
    std::vector<unsigned char> buffer(1 << 16);
    size_t n;
    while ((n = fread(buffer.data(), 1, buffer.size(), f)) > 0) CC_SHA256_Update(&ctx, buffer.data(), static_cast<CC_LONG>(n));
    const bool failed = ferror(f) != 0;
    fclose(f);
    if (failed) return nil;
    unsigned char digest[CC_SHA256_DIGEST_LENGTH];
    CC_SHA256_Final(digest, &ctx);
    NSMutableString *hex = [NSMutableString stringWithCapacity:2 * CC_SHA256_DIGEST_LENGTH];
    for (unsigned char b : digest) [hex appendFormat:@"%02x", b];
    return hex;
}

// Runs a system tool, its stdout and stderr into `output`; the exit status,
// or -1 when it could not start. Stopped after two minutes.
int runTool(NSString *path, NSArray<NSString *> *arguments, NSString **output) {
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:path];
    task.arguments = arguments;
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = pipe;
    task.standardInput = [NSFileHandle fileHandleWithNullDevice];
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) return -1;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (task.running) [task terminate];
    });
    NSData *data = [pipe.fileHandleForReading readDataToEndOfFile];
    [task waitUntilExit];
    if (output) *output = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return task.terminationStatus;
}

} // namespace

// ---------------------------------------------------------------------------

@implementation JLDependencyDescriptor
- (NSString *)releasesPageURL {
    NSString *query = self.tagPrefix;
    if ([query hasSuffix:@"-v"]) query = [query substringToIndex:query.length - 2];
    return [NSString stringWithFormat:@"https://github.com/%@/releases?q=%@", self.repository,
                                      [query stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLQueryAllowedCharacterSet]];
}
@end

@implementation JLReleaseInfo
@end

// ---------------------------------------------------------------------------

@interface JLComponentInstaller () <NSURLSessionDownloadDelegate>
@end

@implementation JLComponentInstaller {
    dispatch_queue_t _queue;
    NSOperationQueue *_delegateQueue;
    std::atomic<bool> _cancelled;
    std::atomic<bool> _committing;          // moving the bundle into place: no stopping now
    int _lockFd;                            // held (flock) for a whole install; -1 when not
    // Shared with the delegate queue and main: under @synchronized(self)
    NSURLSessionTask *_task;                // the transfer in flight
    JLInstallProgress _progress;
    NSURLSessionDownloadTask *_download;    // the package download in flight
    dispatch_semaphore_t _downloadDone;
    NSString *_downloadTo;
    NSString *_downloadError;
    BOOL _downloaded;
    uint64_t _expectedSize;
    BOOL _redirectRefused;
}

- (instancetype)initWithDescriptor:(JLDependencyDescriptor *)descriptor userComponents:(NSString *)folder {
    if ((self = [super init])) {
        _descriptor = descriptor;
        // Resolved, so the work folder beside it is on the same volume even
        // when user-components is a link to another one
        _userComponents = [folder stringByResolvingSymlinksInPath];
        _queue = dispatch_queue_create("jl.dependency.install", DISPATCH_QUEUE_SERIAL);
        _delegateQueue = [[NSOperationQueue alloc] init];
        _delegateQueue.maxConcurrentOperationCount = 1;
        _cancelled = false;
        _committing = false;
        _lockFd = -1;
    }
    return self;
}

- (void)dealloc {
    if (_lockFd >= 0) close(_lockFd);
}

- (NSString *)workFolder {
    return [[_userComponents stringByDeletingLastPathComponent] stringByAppendingPathComponent:kWorkFolder];
}

- (NSString *)installedBundlePath {
    NSString *name = _descriptor.component;
    return [[_userComponents stringByAppendingPathComponent:name]
        stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"component"]];
}

+ (NSString *)versionOfBundleAt:(NSString *)path {
    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[path stringByAppendingPathComponent:@"Contents/Info.plist"]];
    id version = info[@"CFBundleShortVersionString"];
    return [version isKindOfClass:[NSString class]] ? version : nil;
}

- (NSString *)installedVersion {
    return [JLComponentInstaller versionOfBundleAt:[self installedBundlePath]];
}

- (NSURLSession *)newSession {
    NSURLSessionConfiguration *config = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    config.timeoutIntervalForRequest = 30;
    config.timeoutIntervalForResource = kTransferTimeout;
    config.HTTPAdditionalHeaders = @{ @"User-Agent": kUserAgent };
    return [NSURLSession sessionWithConfiguration:config delegate:self delegateQueue:_delegateQueue];
}

- (void)setTask:(NSURLSessionTask *)task {
    @synchronized(self) { _task = task; }
}

+ (std::vector<Release>)releasesFromJSON:(NSData *)data {
    std::vector<Release> out;
    if (!data) return out;
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if ([root isKindOfClass:[NSDictionary class]] && root[@"tag_name"]) root = @[ root ];   // one release
    if (![root isKindOfClass:[NSArray class]]) return out;
    for (id item in (NSArray *)root) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        NSDictionary *r = item;
        id tag = r[@"tag_name"], draft = r[@"draft"], pre = r[@"prerelease"], assets = r[@"assets"];
        if (![tag isKindOfClass:[NSString class]] || ![assets isKindOfClass:[NSArray class]]) continue;
        Release release;
        release.tag = utf8(tag);
        // Anything not plainly false counts as a draft / prerelease
        release.draft = ![draft isKindOfClass:[NSNumber class]] || [draft boolValue];
        release.prerelease = ![pre isKindOfClass:[NSNumber class]] || [pre boolValue];
        for (id a in (NSArray *)assets) {
            if (![a isKindOfClass:[NSDictionary class]]) continue;
            id name = a[@"name"], size = a[@"size"], url = a[@"browser_download_url"];
            if (![name isKindOfClass:[NSString class]] || ![url isKindOfClass:[NSString class]]) continue;
            Asset asset;
            asset.name = utf8(name);
            asset.url = utf8(url);
            asset.size = [size isKindOfClass:[NSNumber class]] ? [size unsignedLongLongValue] : 0;
            release.assets.push_back(asset);
        }
        out.push_back(std::move(release));
    }
    return out;
}

+ (std::vector<std::string>)refNamesFromJSON:(NSData *)data {
    std::vector<std::string> out;
    if (!data) return out;
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (![root isKindOfClass:[NSArray class]]) return out;
    for (id item in (NSArray *)root) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        id ref = ((NSDictionary *)item)[@"ref"];
        if ([ref isKindOfClass:[NSString class]]) out.push_back(utf8(ref));
    }
    return out;
}

#pragma mark - Transfers

// A small GET (an API answer, the checksums), waited for on the pipeline
// queue. nil with `problem` set on any failure; `status` the HTTP status
// when there was an answer.
- (NSData *)get:(NSString *)urlString accept:(NSString *)accept status:(NSInteger *)status problem:(NSString **)problem {
    *problem = nil;
    if (status) *status = 0;
    NSURL *url = [NSURL URLWithString:urlString];
    if (!allowedURL(url)) {
        *problem = @"The release points somewhere other than GitHub.";
        return nil;
    }
    if (_cancelled) {
        *problem = @"Cancelled.";
        return nil;
    }
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
    if (accept) [request setValue:accept forHTTPHeaderField:@"Accept"];
    __block NSData *result = nil;
    __block NSString *failure = nil;
    __block NSInteger code = 0;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    NSURLSession *session = [self newSession];
    @synchronized(self) { _redirectRefused = NO; }
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request
                                            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        code = [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        if (error) failure = [NSString stringWithFormat:@"Download failed (%@).", error.localizedDescription];
        else if (code != 200) failure = [NSString stringWithFormat:@"GitHub answered with status %ld.", (long)code];
        else if (data.length > kMaxSmallBytes) failure = @"GitHub's answer is unexpectedly large.";
        else result = data;
        dispatch_semaphore_signal(done);
    }];
    [self setTask:task];
    [task resume];
    [session finishTasksAndInvalidate];
    const long timedOut = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, kTransferTimeout * NSEC_PER_SEC));
    [self setTask:nil];
    if (timedOut) {
        [task cancel];
        *problem = @"GitHub did not answer in time.";
        return nil;
    }
    if (status) *status = code;
    BOOL refused;
    @synchronized(self) { refused = _redirectRefused; }
    if (_cancelled) failure = @"Cancelled.";
    else if (refused) failure = @"The download was redirected away from GitHub.";
    else if (code == 403 || code == 429) failure = @"GitHub refused the request (too many requests); try again in a few minutes.";
    if (failure || !result) {
        *problem = failure ?: @"The download failed.";
        return nil;
    }
    return result;
}

// The package, with progress, into `path`; nil on success
- (NSString *)downloadPackage:(JLReleaseInfo *)release to:(NSString *)path {
    NSURL *url = [NSURL URLWithString:release.packageURL];
    if (!allowedURL(url)) return @"The release points somewhere other than GitHub.";
    NSURLSession *session = [self newSession];
    NSURLSessionDownloadTask *task = [session downloadTaskWithURL:url];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    @synchronized(self) {
        _download = task;
        _downloadDone = done;
        _downloadTo = path;
        _downloadError = nil;
        _downloaded = NO;
        _expectedSize = release.packageSize;
        _redirectRefused = NO;
    }
    [self setTask:task];
    [task resume];
    [session finishTasksAndInvalidate];
    const long timedOut = dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (kTransferTimeout + 30) * NSEC_PER_SEC));
    [self setTask:nil];
    NSString *problem = nil;
    @synchronized(self) {
        // Late callbacks from this task are ignored from here on
        _download = nil;
        _downloadDone = nil;
        if (timedOut) problem = @"The download timed out.";
        else if (_redirectRefused) problem = @"The download was redirected away from GitHub.";
        else if (_downloadError) problem = _downloadError;
        else if (!_downloaded) problem = @"The download did not complete.";
    }
    if (timedOut) [task cancel];
    return problem;
}

- (void)URLSession:(NSURLSession *)session
                    task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response
                newRequest:(NSURLRequest *)request
         completionHandler:(void (^)(NSURLRequest *))completionHandler {
    if (allowedURL(request.URL)) {
        completionHandler(request);
        return;
    }
    @synchronized(self) { _redirectRefused = YES; }
    [task cancel];
    completionHandler(nil);
}

- (void)URLSession:(NSURLSession *)session
                 downloadTask:(NSURLSessionDownloadTask *)downloadTask
                 didWriteData:(int64_t)bytesWritten
            totalBytesWritten:(int64_t)totalBytesWritten
    totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    uint64_t expected;
    @synchronized(self) {
        if (downloadTask != _download) return;
        expected = _expectedSize;
    }
    const uint64_t total = static_cast<uint64_t>(totalBytesWritten);
    if (total > kMaxDownloadBytes || (expected > 0 && total > expected)) {
        @synchronized(self) { _downloadError = @"The download is larger than the release says."; }
        [downloadTask cancel];
        return;
    }
    const uint64_t of = expected > 0 ? expected : static_cast<uint64_t>(std::max<int64_t>(0, totalBytesExpectedToWrite));
    if (of > 0) {
        [self report:[NSString stringWithFormat:@"Downloading %@ of %@", megabytes(total), megabytes(of)]
            fraction:static_cast<double>(total) / static_cast<double>(of)];
    }
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didFinishDownloadingToURL:(NSURL *)location {
    NSString *to;
    @synchronized(self) {
        if (downloadTask != _download) return;
        to = _downloadTo;
    }
    const NSInteger status = [downloadTask.response isKindOfClass:[NSHTTPURLResponse class]]
        ? ((NSHTTPURLResponse *)downloadTask.response).statusCode : 0;
    if (status != 200) {
        @synchronized(self) { _downloadError = [NSString stringWithFormat:@"Download failed (status %ld).", (long)status]; }
        return;
    }
    // The file is deleted when this returns: move it now
    NSError *error = nil;
    [[NSFileManager defaultManager] removeItemAtPath:to error:nil];
    const BOOL moved = [[NSFileManager defaultManager] moveItemAtURL:location toURL:[NSURL fileURLWithPath:to] error:&error];
    @synchronized(self) {
        if (moved) _downloaded = YES;
        else _downloadError = [NSString stringWithFormat:@"Could not keep the download (%@).", error.localizedDescription];
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    dispatch_semaphore_t done = nil;
    @synchronized(self) {
        if (task != _download) return;
        if (error && !_downloadError && !_cancelled) {
            _downloadError = [NSString stringWithFormat:@"Download failed (%@).", error.localizedDescription];
        }
        done = _downloadDone;
    }
    if (done) dispatch_semaphore_signal(done);
}

- (void)report:(NSString *)step fraction:(double)fraction {
    JLInstallProgress progress;
    @synchronized(self) { progress = _progress; }
    if (progress) dispatch_async(dispatch_get_main_queue(), ^{ progress(step, fraction); });
}

- (void)cancel {
    if (_committing) return;   // the bundle is moving into place: let it finish
    _cancelled = true;
    NSURLSessionTask *task;
    @synchronized(self) { task = _task; }
    [task cancel];
}

#pragma mark - Release lookup

- (void)lookUp:(void (^)(JLReleaseInfo *, NSString *))done {
    _cancelled = false;
    dispatch_async(_queue, ^{
        NSString *problem = nil;
        JLReleaseInfo *info = [self findRelease:&problem];
        const BOOL cancelled = self->_cancelled;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (cancelled) done(nil, nil);
            else done(info, info ? nil : problem);
        });
    });
}

- (JLReleaseInfo *)findRelease:(NSString **)problem {
    JLDependencyDescriptor *d = _descriptor;
    NSString *accept = @"application/vnd.github+json";
    NSString *api = [NSString stringWithFormat:@"https://api.github.com/repos/%@", d.repository];
    // The component's tags, newest first: however many other components
    // were released since, its own releases are found
    NSData *refs = [self get:[NSString stringWithFormat:@"%@/git/matching-refs/tags/%@", api, d.tagPrefix]
                      accept:accept status:nullptr problem:problem];
    if (!refs) return nil;
    const std::vector<std::string> tags = newestTags([JLComponentInstaller refNamesFromJSON:refs], utf8(d.tagPrefix), kTagsToTry);
    for (const std::string &tag : tags) {
        NSInteger status = 0;
        NSString *failure = nil;
        NSString *tagPath = [ns(tag) stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
        NSData *json = [self get:[NSString stringWithFormat:@"%@/releases/tags/%@", api, tagPath]
                          accept:accept status:&status problem:&failure];
        if (_cancelled) {
            *problem = @"Cancelled.";
            return nil;
        }
        if (!json) {
            if (status == 404) continue;   // a tag without a published release
            *problem = failure;
            return nil;
        }
        const Pick pick = pickRelease([JLComponentInstaller releasesFromJSON:json], utf8(d.repository), utf8(d.tagPrefix),
                                      utf8(d.assetName));
        if (!pick.found) continue;   // a draft, a prerelease, or without its checksums
        if (compare(pick.version, parseVersion(utf8(d.minVersion))) < 0) {
            *problem = [NSString stringWithFormat:@"The newest %@ release (%@) is older than %@ needs (%@).",
                                                  d.displayName, ns(toString(pick.version)), d.dependentName, d.minVersion];
            return nil;
        }
        JLReleaseInfo *info = [[JLReleaseInfo alloc] init];
        info.version = ns(toString(pick.version));
        info.tag = ns(pick.tag);
        info.packageURL = ns(pick.package.url);
        info.sumsURL = ns(pick.sums.url);
        info.packageSize = pick.package.size;
        return info;
    }
    *problem = [NSString stringWithFormat:@"No %@ release with a checksum was found on GitHub.", d.displayName];
    return nil;
}

#pragma mark - Install lock

// flock on <work>/lock, held for the whole install: the kernel lets go when
// the process dies, so a crashed install never blocks the next one. The
// file holds the holder's name for the other gates to show.

- (NSString *)lockPath {
    return [[self workFolder] stringByAppendingPathComponent:kLockName];
}

- (NSString *)lockHolder {
    if (_lockFd >= 0) return nil;   // this installer holds it
    const int fd = open([self lockPath].fileSystemRepresentation, O_RDONLY);
    if (fd < 0) return nil;
    NSString *holder = nil;
    if (flock(fd, LOCK_SH | LOCK_NB) != 0 && errno == EWOULDBLOCK) {
        char buffer[256] = {};
        const ssize_t n = read(fd, buffer, sizeof buffer - 1);
        holder = n > 0 ? [[NSString stringWithUTF8String:buffer] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] : nil;
        if (!holder.length) holder = @"another component";
    }
    close(fd);   // also drops the shared lock when it was taken
    return holder;
}

- (NSString *)acquireLock {
    [[NSFileManager defaultManager] createDirectoryAtPath:[self workFolder] withIntermediateDirectories:YES attributes:nil error:nil];
    const int fd = open([self lockPath].fileSystemRepresentation, O_CREAT | O_RDWR, 0644);
    if (fd < 0) return @"Could not create the install lock.";
    if (flock(fd, LOCK_EX | LOCK_NB) != 0) {
        close(fd);
        NSString *holder = [self lockHolder];
        return [NSString stringWithFormat:@"%@ is being installed from %@.", _descriptor.displayName, holder ?: @"another component"];
    }
    const std::string name = utf8(_descriptor.dependentName) + "\n";
    if (ftruncate(fd, 0) != 0 || pwrite(fd, name.data(), name.size(), 0) != static_cast<ssize_t>(name.size())) {
        close(fd);
        return @"Could not write the install lock.";
    }
    _lockFd = fd;
    return nil;
}

- (void)releaseLock {
    if (_lockFd < 0) return;
    if (ftruncate(_lockFd, 0) != 0) {}   // the name goes; the file stays, never unlinked under another holder
    close(_lockFd);                      // releases the flock
    _lockFd = -1;
}

#pragma mark - Install

- (void)install:(JLReleaseInfo *)release progress:(JLInstallProgress)progress done:(void (^)(NSString *, BOOL))done {
    _cancelled = false;
    _committing = false;
    @synchronized(self) { _progress = [progress copy]; }
    dispatch_async(_queue, ^{
        NSString *problem = [self runInstall:release];
        // Cancelled only if it stopped the install: a success stays one
        const BOOL cancelled = problem != nil && self->_cancelled;
        @synchronized(self) { self->_progress = nil; }
        dispatch_async(dispatch_get_main_queue(), ^{ done(cancelled ? nil : problem, cancelled); });
    });
}

// The whole pipeline; nil on success
- (NSString *)runInstall:(JLReleaseInfo *)release {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *work = [self workFolder];
    NSString *token = [[NSUUID UUID] UUIDString];
    NSString *zip = [work stringByAppendingPathComponent:[NSString stringWithFormat:@"download-%@.zip", token]];
    NSString *staging = [work stringByAppendingPathComponent:[NSString stringWithFormat:@"staging-%@", token]];
    NSString *problem = [self acquireLock];
    if (!problem) {
        problem = [self installFrom:release zip:zip staging:staging];
        [fm removeItemAtPath:zip error:nil];
        [fm removeItemAtPath:staging error:nil];
        [self releaseLock];
    }
    if (problem && !_cancelled) NSLog(@"[jl_dependency] %@ install failed: %@", _descriptor.displayName, problem);
    return problem;
}

- (NSString *)installFrom:(JLReleaseInfo *)release zip:(NSString *)zip staging:(NSString *)staging {
    NSString *problem = nil;
    // 1. The checksum, then the package
    [self report:@"Downloading the checksum" fraction:-1];
    NSData *sums = [self get:release.sumsURL accept:nil status:nullptr problem:&problem];
    if (!sums) return problem ?: @"The checksum file could not be downloaded.";
    const std::string expected = findSha256(std::string(static_cast<const char *>(sums.bytes), sums.length), utf8(_descriptor.assetName));
    if (expected.empty()) return @"The release's checksum file does not list the package.";
    if (_cancelled) return @"Cancelled.";
    [self report:@"Downloading" fraction:0];
    if ((problem = [self downloadPackage:release to:zip])) return _cancelled ? @"Cancelled." : problem;
    if (_cancelled) return @"Cancelled.";
    return [self installPackage:zip size:release.packageSize sha256:ns(expected) staging:staging];
}

// The unpacked tree: only folders and plain files, all inside the bundle,
// every folder readable
- (NSString *)checkUnpacked:(NSString *)staging bundle:(NSString *)bundle {
    NSString *root = [staging stringByStandardizingPath];
    NSString *allowed = [[bundle stringByStandardizingPath] stringByAppendingString:@"/"];
    NSString *mac = [root stringByAppendingPathComponent:@"mac"];
    __block BOOL unreadable = NO;
    NSDirectoryEnumerator<NSURL *> *walk = [[NSFileManager defaultManager]
                   enumeratorAtURL:[NSURL fileURLWithPath:root]
        includingPropertiesForKeys:@[ NSURLIsSymbolicLinkKey, NSURLIsRegularFileKey, NSURLIsDirectoryKey ]
                           options:0
                      errorHandler:^BOOL(NSURL *url, NSError *error) {
                          unreadable = YES;
                          return NO;
                      }];
    for (NSURL *url in walk) {
        NSNumber *link = nil, *file = nil, *folder = nil;
        [url getResourceValue:&link forKey:NSURLIsSymbolicLinkKey error:nil];
        [url getResourceValue:&file forKey:NSURLIsRegularFileKey error:nil];
        [url getResourceValue:&folder forKey:NSURLIsDirectoryKey error:nil];
        if (link.boolValue) return @"The package holds a symbolic link.";
        if (!file.boolValue && !folder.boolValue) return @"The package holds something other than files and folders.";
        NSString *path = [url.path stringByStandardizingPath];
        if (![path isEqualToString:mac] && ![[path stringByAppendingString:@"/"] isEqualToString:allowed] &&
            ![path hasPrefix:allowed]) {
            return @"The package holds files outside the component.";
        }
    }
    if (unreadable) return @"The unpacked package could not be read completely.";
    return nil;
}

// Steps 2-4 on a downloaded package: exactly what the release lists, a
// well-formed archive of this one component, into place
- (NSString *)installPackage:(NSString *)zip size:(uint64_t)packageSize sha256:(NSString *)expected staging:(NSString *)staging {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *component = _descriptor.component;
    NSString *bundleName = [component stringByAppendingPathExtension:@"component"];
    NSString *problem = nil;

    // 2. Exactly what the release lists
    [self report:@"Verifying" fraction:-1];
    const uint64_t size = [[fm attributesOfItemAtPath:zip error:nil] fileSize];
    if (packageSize > 0 && size != packageSize) return @"The download's size does not match the release.";
    NSString *actual = sha256OfFile(zip);
    if (!actual || ![actual isEqualToString:expected.lowercaseString]) return @"The download does not match the release's checksum.";

    // 3. Unpack only what looks like one component, then check what came out
    NSString *listing = nil;
    if (runTool(@"/usr/bin/zipinfo", @[ zip ], &listing) != 0 || !listing) return @"The package could not be read.";
    const ArchiveCheck check = checkArchiveListing(utf8(listing), utf8(bundleName), utf8(component));
    if (!check.ok) return [NSString stringWithFormat:@"The package is not as expected (%@).", ns(check.reason)];
    if (![fm createDirectoryAtPath:staging withIntermediateDirectories:YES attributes:nil error:nil]) {
        return @"Could not create a folder to unpack into.";
    }
    NSString *output = nil;
    // ditto exits 0 on some damaged archives but says so: anything it says fails
    if (runTool(@"/usr/bin/ditto", @[ @"-x", @"-k", @"--noqtn", zip, staging ], &output) != 0 || output.length > 0) {
        return @"The package could not be unpacked.";
    }
    NSString *staged = [[staging stringByAppendingPathComponent:@"mac"] stringByAppendingPathComponent:bundleName];
    if ((problem = [self checkUnpacked:staging bundle:staged])) return problem;
    NSString *executable = [[staged stringByAppendingPathComponent:@"Contents/MacOS"] stringByAppendingPathComponent:component];
    if (![fm isExecutableFileAtPath:executable]) return @"The package has no executable.";
    NSString *version = [JLComponentInstaller versionOfBundleAt:staged];
    if (compare(parseVersion(utf8(version)), parseVersion(utf8(_descriptor.minVersion))) < 0) {
        return [NSString stringWithFormat:@"The package's version (%@) is older than needed.", version ?: @"none"];
    }
    if (runTool(@"/usr/bin/codesign", @[ @"--verify", @"--strict", staged ], &output) != 0) {
        return @"The package's code signature does not verify.";
    }

    // 4. Into place. From here a cancel no longer stops it. A bundle already
    //    there is set aside (never rewritten in place: the running process
    //    may have it mapped), removed next launch.
    _committing = true;
    if (_cancelled) return @"Cancelled.";
    [self report:@"Installing" fraction:-1];
    NSString *target = [self installedBundlePath];
    NSString *folder = [target stringByDeletingLastPathComponent];
    if (![fm createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil]) {
        return @"Could not create the component's folder.";
    }
    NSString *aside = nil;
    if ([fm fileExistsAtPath:target]) {
        NSString *asideFolder = [[self workFolder] stringByAppendingPathComponent:kSetAsideName];
        [fm createDirectoryAtPath:asideFolder withIntermediateDirectories:YES attributes:nil error:nil];
        aside = [asideFolder stringByAppendingPathComponent:
                                 [NSString stringWithFormat:@"%@-%@.component", component, [[NSUUID UUID] UUIDString]]];
        if (rename(target.fileSystemRepresentation, aside.fileSystemRepresentation) != 0) {
            return @"Could not move the installed version aside.";
        }
    }
    // rename(2), not a copy: the work folder is beside user-components on
    // the same volume, so the bundle appears whole or not at all
    if (rename(staged.fileSystemRepresentation, target.fileSystemRepresentation) != 0) {
        const int err = errno;
        if (aside) rename(aside.fileSystemRepresentation, target.fileSystemRepresentation);
        return [NSString stringWithFormat:@"Could not install the component (%s).", strerror(err)];
    }
    NSLog(@"[jl_dependency] %@ %@ installed to %@", _descriptor.displayName, version, target);
    return nil;
}

- (void)cleanUpAtLaunch {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *work = [self workFolder];
    // Not while another process installs
    const int fd = open([self lockPath].fileSystemRepresentation, O_RDONLY);
    if (fd >= 0) {
        const bool busy = flock(fd, LOCK_EX | LOCK_NB) != 0;
        close(fd);
        if (busy) return;
    }
    NSString *asideFolder = [work stringByAppendingPathComponent:kSetAsideName];
    NSString *prefix = [_descriptor.component stringByAppendingString:@"-"];
    NSString *target = [self installedBundlePath];
    for (NSString *name in [fm contentsOfDirectoryAtPath:asideFolder error:nil]) {
        if (![name hasPrefix:prefix]) continue;
        NSString *path = [asideFolder stringByAppendingPathComponent:name];
        // An install died between the two moves: the old bundle goes back
        if (![fm fileExistsAtPath:target] && rename(path.fileSystemRepresentation, target.fileSystemRepresentation) == 0) continue;
        [fm removeItemAtPath:path error:nil];
    }
    for (NSString *name in [fm contentsOfDirectoryAtPath:work error:nil]) {
        if (![name hasPrefix:@"download-"] && ![name hasPrefix:@"staging-"]) continue;
        NSString *path = [work stringByAppendingPathComponent:name];
        NSDate *modified = [fm attributesOfItemAtPath:path error:nil].fileModificationDate;
        if (modified && -modified.timeIntervalSinceNow > kStaleWorkFiles) [fm removeItemAtPath:path error:nil];
    }
}

@end
