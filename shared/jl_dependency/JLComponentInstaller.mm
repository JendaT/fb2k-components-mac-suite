//
// JLComponentInstaller.mm
//
// The install runs as one pipeline on a private serial queue, waiting for
// each transfer in turn. Work files live in <profile>/.jl-install/ (beside
// user-components, same volume): a staged or set-aside .component inside
// user-components could be loaded by foobar2000 as a second copy.
//

#import "JLComponentInstaller.h"

#import <CommonCrypto/CommonDigest.h>

#include <atomic>
#include <cerrno>
#include <fcntl.h>
#include <signal.h>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

using namespace jl_dep;

namespace {

NSString *const kWorkFolder = @".jl-install";
NSString *const kLockName = @"lock";
NSString *const kSetAsideName = @"set-aside";
NSString *const kUserAgent = @"foobar2000-jl-components";
constexpr NSTimeInterval kLockStaleSeconds = 15 * 60;
constexpr NSUInteger kMaxSumsBytes = 64 * 1024;
constexpr int64_t kTransferTimeout = 300;   // seconds for one download

std::string utf8(NSString *s) {
    return s ? std::string(s.UTF8String ?: "") : std::string();
}

NSString *ns(const std::string &s) {
    return [NSString stringWithUTF8String:s.c_str()] ?: @"";
}

NSString *megabytes(uint64_t bytes) {
    return [NSString stringWithFormat:@"%.1f MB", static_cast<double>(bytes) / (1024.0 * 1024.0)];
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

bool processAlive(pid_t pid) {
    return pid > 0 && (kill(pid, 0) == 0 || errno == EPERM);
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
    NSURLSessionTask *_task;                // the transfer in flight (delegate queue / pipeline)
    BOOL _holdsLock;
    // The package download in flight
    dispatch_semaphore_t _downloadDone;
    NSString *_downloadTo;
    NSString *_downloadError;
    uint64_t _expectedSize;
    BOOL _downloaded;
    JLInstallProgress _progress;
    BOOL _redirectRefused;
}

- (instancetype)initWithDescriptor:(JLDependencyDescriptor *)descriptor userComponents:(NSString *)folder {
    if ((self = [super init])) {
        _descriptor = descriptor;
        _userComponents = [folder copy];
        _queue = dispatch_queue_create("jl.dependency.install", DISPATCH_QUEUE_SERIAL);
        _delegateQueue = [[NSOperationQueue alloc] init];
        _delegateQueue.maxConcurrentOperationCount = 1;
        _cancelled = false;
    }
    return self;
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

+ (std::vector<Release>)releasesFromJSON:(NSData *)data {
    std::vector<Release> out;
    if (!data) return out;
    id root = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
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

#pragma mark - Release lookup

- (void)lookUp:(void (^)(JLReleaseInfo *, NSString *))done {
    NSString *api = [NSString stringWithFormat:@"https://api.github.com/repos/%@/releases?per_page=100", _descriptor.repository];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:api]];
    [request setValue:@"application/vnd.github+json" forHTTPHeaderField:@"Accept"];
    NSURLSession *session = [self newSession];
    JLDependencyDescriptor *d = _descriptor;
    NSURLSessionDataTask *task = [session dataTaskWithRequest:request
                                            completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSString *problem = nil;
        JLReleaseInfo *info = nil;
        const NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        if (error) {
            problem = [NSString stringWithFormat:@"Could not reach GitHub (%@).", error.localizedDescription];
        } else if (status == 403 || status == 429) {
            problem = @"GitHub refused the request (too many requests); try again in a few minutes.";
        } else if (status != 200) {
            problem = [NSString stringWithFormat:@"GitHub answered with status %ld.", (long)status];
        } else {
            const Pick pick = pickRelease([JLComponentInstaller releasesFromJSON:data], utf8(d.tagPrefix), utf8(d.assetName));
            if (!pick.found) {
                problem = [NSString stringWithFormat:@"No %@ release with a checksum was found on GitHub.", d.displayName];
            } else if (compare(pick.version, parseVersion(utf8(d.minVersion))) < 0) {
                problem = [NSString stringWithFormat:@"The newest %@ release (%@) is older than %@ needs (%@).",
                                                     d.displayName, ns(toString(pick.version)), d.dependentName, d.minVersion];
            } else {
                info = [[JLReleaseInfo alloc] init];
                info.version = ns(toString(pick.version));
                info.tag = ns(pick.tag);
                info.packageURL = ns(pick.package.url);
                info.sumsURL = ns(pick.sums.url);
                info.packageSize = pick.package.size;
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ done(info, problem); });
    }];
    [task resume];
    [session finishTasksAndInvalidate];
}

#pragma mark - Install lock

- (NSString *)lockPath {
    return [[self workFolder] stringByAppendingPathComponent:kLockName];
}

// The holder's name and pid, or false when there is no live lock
- (BOOL)readLock:(NSString **)holder pid:(pid_t *)pid {
    NSString *path = [self lockPath];
    NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (!text) return NO;
    NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
    const pid_t owner = lines.count > 1 ? static_cast<pid_t>(lines[1].intValue) : 0;
    NSDate *written = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil].fileModificationDate;
    if (!processAlive(owner) || !written || -written.timeIntervalSinceNow > kLockStaleSeconds) return NO;
    if (holder) *holder = lines.firstObject ?: @"";
    if (pid) *pid = owner;
    return YES;
}

- (NSString *)lockHolder {
    NSString *holder = nil;
    pid_t pid = 0;
    if (![self readLock:&holder pid:&pid]) return nil;
    if (pid == getpid() && [holder isEqualToString:_descriptor.dependentName]) return nil;   // this dependent
    return holder.length ? holder : @"another component";
}

- (NSString *)acquireLock {
    [[NSFileManager defaultManager] createDirectoryAtPath:[self workFolder] withIntermediateDirectories:YES attributes:nil error:nil];
    for (int attempt = 0; attempt < 2; attempt++) {
        const int fd = open([self lockPath].fileSystemRepresentation, O_CREAT | O_EXCL | O_WRONLY, 0644);
        if (fd >= 0) {
            const std::string text = utf8(_descriptor.dependentName) + "\n" + std::to_string(getpid()) + "\n";
            const ssize_t written = write(fd, text.data(), text.size());
            close(fd);
            if (written != static_cast<ssize_t>(text.size())) {
                unlink([self lockPath].fileSystemRepresentation);
                return @"Could not write the install lock.";
            }
            _holdsLock = YES;
            return nil;
        }
        if (errno != EEXIST) return @"Could not create the install lock.";
        NSString *holder = nil;
        if ([self readLock:&holder pid:nullptr]) {
            return [NSString stringWithFormat:@"%@ is being installed from %@.", _descriptor.displayName, holder];
        }
        unlink([self lockPath].fileSystemRepresentation);   // stale: its owner is gone
    }
    return @"Could not take the install lock.";
}

- (void)releaseLock {
    if (_holdsLock) unlink([self lockPath].fileSystemRepresentation);
    _holdsLock = NO;
}

#pragma mark - Install

- (void)cancel {
    _cancelled = true;
    NSURLSessionTask *task = _task;
    [task cancel];
}

- (void)report:(NSString *)step fraction:(double)fraction {
    JLInstallProgress progress = _progress;
    if (progress) dispatch_async(dispatch_get_main_queue(), ^{ progress(step, fraction); });
}

// A small file (the checksums), waited for on the pipeline queue
- (NSData *)fetchSmall:(NSString *)urlString problem:(NSString **)problem {
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url || !allowedDownloadHost(utf8(url.scheme.lowercaseString), utf8(url.host))) {
        *problem = @"The release points somewhere other than GitHub.";
        return nil;
    }
    __block NSData *result = nil;
    __block NSString *failure = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    NSURLSession *session = [self newSession];
    _redirectRefused = NO;
    NSURLSessionDataTask *task = [session dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        const NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        if (error) failure = [NSString stringWithFormat:@"Download failed (%@).", error.localizedDescription];
        else if (status != 200) failure = [NSString stringWithFormat:@"Download failed (status %ld).", (long)status];
        else if (data.length > kMaxSumsBytes) failure = @"The checksum file is unexpectedly large.";
        else result = data;
        dispatch_semaphore_signal(done);
    }];
    _task = task;
    [task resume];
    [session finishTasksAndInvalidate];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, kTransferTimeout * NSEC_PER_SEC));
    _task = nil;
    if (_redirectRefused) failure = @"The download was redirected away from GitHub.";
    if (!result && problem) *problem = failure ?: @"Download timed out.";
    return failure ? nil : result;
}

// The package, with progress, into `path`
- (NSString *)downloadPackage:(JLReleaseInfo *)release to:(NSString *)path {
    NSURL *url = [NSURL URLWithString:release.packageURL];
    if (!url || !allowedDownloadHost(utf8(url.scheme.lowercaseString), utf8(url.host))) {
        return @"The release points somewhere other than GitHub.";
    }
    _downloadDone = dispatch_semaphore_create(0);
    _downloadTo = path;
    _downloadError = nil;
    _downloaded = NO;
    _expectedSize = release.packageSize;
    _redirectRefused = NO;
    NSURLSession *session = [self newSession];
    NSURLSessionDownloadTask *task = [session downloadTaskWithURL:url];
    _task = task;
    [task resume];
    [session finishTasksAndInvalidate];
    const long timedOut = dispatch_semaphore_wait(_downloadDone, dispatch_time(DISPATCH_TIME_NOW, (kTransferTimeout + 30) * NSEC_PER_SEC));
    _task = nil;
    if (timedOut) {
        [task cancel];
        return @"The download timed out.";
    }
    if (_redirectRefused) return @"The download was redirected away from GitHub.";
    if (_downloadError) return _downloadError;
    return _downloaded ? nil : @"The download did not complete.";
}

- (void)URLSession:(NSURLSession *)session
                    task:(NSURLSessionTask *)task
    willPerformHTTPRedirection:(NSHTTPURLResponse *)response
                newRequest:(NSURLRequest *)request
         completionHandler:(void (^)(NSURLRequest *))completionHandler {
    NSURL *to = request.URL;
    if (allowedDownloadHost(utf8(to.scheme.lowercaseString), utf8(to.host))) {
        completionHandler(request);
    } else {
        _redirectRefused = YES;
        [task cancel];
        completionHandler(nil);
    }
}

- (void)URLSession:(NSURLSession *)session
                 downloadTask:(NSURLSessionDownloadTask *)downloadTask
                 didWriteData:(int64_t)bytesWritten
            totalBytesWritten:(int64_t)totalBytesWritten
    totalBytesExpectedToWrite:(int64_t)totalBytesExpectedToWrite {
    const uint64_t total = static_cast<uint64_t>(totalBytesWritten);
    if (total > kMaxDownloadBytes || (_expectedSize > 0 && total > _expectedSize)) {
        _downloadError = @"The download is larger than the release says.";
        [downloadTask cancel];
        return;
    }
    const uint64_t of = _expectedSize > 0 ? _expectedSize : static_cast<uint64_t>(std::max<int64_t>(0, totalBytesExpectedToWrite));
    if (of > 0) {
        [self report:[NSString stringWithFormat:@"Downloading %@ of %@", megabytes(total), megabytes(of)]
            fraction:static_cast<double>(total) / static_cast<double>(of)];
    }
}

- (void)URLSession:(NSURLSession *)session downloadTask:(NSURLSessionDownloadTask *)downloadTask didFinishDownloadingToURL:(NSURL *)location {
    const NSInteger status = [downloadTask.response isKindOfClass:[NSHTTPURLResponse class]]
        ? ((NSHTTPURLResponse *)downloadTask.response).statusCode : 0;
    if (status != 200) {
        _downloadError = [NSString stringWithFormat:@"Download failed (status %ld).", (long)status];
        return;
    }
    // The file is deleted when this returns: move it now
    NSError *error = nil;
    [[NSFileManager defaultManager] removeItemAtPath:_downloadTo error:nil];
    if ([[NSFileManager defaultManager] moveItemAtURL:location toURL:[NSURL fileURLWithPath:_downloadTo] error:&error]) {
        _downloaded = YES;
    } else {
        _downloadError = [NSString stringWithFormat:@"Could not keep the download (%@).", error.localizedDescription];
    }
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task didCompleteWithError:(NSError *)error {
    if (![task isKindOfClass:[NSURLSessionDownloadTask class]]) return;
    if (error && !_downloadError && !_cancelled) {
        _downloadError = [NSString stringWithFormat:@"Download failed (%@).", error.localizedDescription];
    }
    if (_downloadDone) dispatch_semaphore_signal(_downloadDone);
}

// The unpacked tree: only folders and plain files, all inside the bundle
- (NSString *)checkUnpacked:(NSString *)staging bundle:(NSString *)bundle {
    NSString *root = [staging stringByStandardizingPath];
    NSString *allowed = [[bundle stringByStandardizingPath] stringByAppendingString:@"/"];
    NSString *mac = [root stringByAppendingPathComponent:@"mac"];
    NSDirectoryEnumerator<NSURL *> *walk = [[NSFileManager defaultManager]
                   enumeratorAtURL:[NSURL fileURLWithPath:root]
        includingPropertiesForKeys:@[ NSURLIsSymbolicLinkKey, NSURLIsRegularFileKey, NSURLIsDirectoryKey ]
                           options:0
                      errorHandler:nil];
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
    return nil;
}

- (void)install:(JLReleaseInfo *)release progress:(JLInstallProgress)progress done:(void (^)(NSString *, BOOL))done {
    _cancelled = false;
    _progress = [progress copy];
    dispatch_async(_queue, ^{
        NSString *problem = [self runInstall:release];
        const BOOL cancelled = self->_cancelled;
        self->_progress = nil;
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
    if (problem) NSLog(@"[jl_dependency] %@ install failed: %@", _descriptor.displayName, problem);
    return problem;
}

- (NSString *)installFrom:(JLReleaseInfo *)release zip:(NSString *)zip staging:(NSString *)staging {
    NSString *problem = nil;

    // 1. The checksum, then the package
    [self report:@"Downloading the checksum" fraction:-1];
    NSData *sums = [self fetchSmall:release.sumsURL problem:&problem];
    if (_cancelled) return @"Cancelled.";
    if (!sums) return problem;
    const std::string expected = findSha256(std::string(static_cast<const char *>(sums.bytes), sums.length), utf8(_descriptor.assetName));
    if (expected.empty()) return @"The release's checksum file does not list the package.";
    [self report:@"Downloading" fraction:0];
    if ((problem = [self downloadPackage:release to:zip])) return _cancelled ? @"Cancelled." : problem;
    if (_cancelled) return @"Cancelled.";
    return [self installPackage:zip size:release.packageSize sha256:ns(expected) staging:staging];
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

    // 3. Unpack only a well-formed archive of this one component
    NSString *listing = nil;
    if (runTool(@"/usr/bin/zipinfo", @[ zip ], &listing) != 0 || !listing) return @"The package could not be read.";
    const ArchiveCheck check = checkArchiveListing(utf8(listing), utf8(bundleName), utf8(component));
    if (!check.ok) return [NSString stringWithFormat:@"The package is not as expected (%@).", ns(check.reason)];
    if (![fm createDirectoryAtPath:staging withIntermediateDirectories:YES attributes:nil error:nil]) {
        return @"Could not create a folder to unpack into.";
    }
    NSString *output = nil;
    if (runTool(@"/usr/bin/ditto", @[ @"-x", @"-k", @"--noqtn", zip, staging ], &output) != 0) {
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
    if (_cancelled) return @"Cancelled.";

    // 4. Into place: a bundle already there is set aside (never rewritten in
    //    place: the running process may have it mapped), removed next launch
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
        if (![fm moveItemAtPath:target toPath:aside error:nil]) return @"Could not move the installed version aside.";
    }
    NSError *error = nil;
    if (![fm moveItemAtPath:staged toPath:target error:&error]) {
        if (aside) [fm moveItemAtPath:aside toPath:target error:nil];
        return [NSString stringWithFormat:@"Could not install the component (%@).", error.localizedDescription];
    }
    NSLog(@"[jl_dependency] %@ %@ installed to %@", _descriptor.displayName, version, target);
    return nil;
}

- (void)removeSetAside {
    NSString *folder = [[self workFolder] stringByAppendingPathComponent:kSetAsideName];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *prefix = [_descriptor.component stringByAppendingString:@"-"];
    for (NSString *name in [fm contentsOfDirectoryAtPath:folder error:nil]) {
        if ([name hasPrefix:prefix]) [fm removeItemAtPath:[folder stringByAppendingPathComponent:name] error:nil];
    }
}

@end
