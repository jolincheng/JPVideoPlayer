/*
 * This file is part of the JPVideoPlayer package.
 * (c) NewPan <13246884282@163.com>
 *
 * For the full copyright and license information, please view the LICENSE
 * file that was distributed with this source code.
 *
 * Click https://github.com/Chris-Pan
 * or http://www.jianshu.com/users/e2f2d779c022/latest_articles to contact me.
 */

#import "JPVideoPlayerResourceLoader.h"
#import <MobileCoreServices/MobileCoreServices.h>
#import "JPVideoPlayerCompat.h"
#import "JPVideoPlayerCacheFile.h"
#import "JPVideoPlayerCachePath.h"
#import "JPVideoPlayerManager.h"

@interface JPVideoPlayerResourceLoader()

/**
 * The request queues.
 * It save the requests waiting for being given video data.
 */
@property (nonatomic, strong, nullable)NSMutableArray<AVAssetResourceLoadingRequest *> *pendingRequests;

/**
 * The video data total length.
 */
@property(nonatomic, assign)NSUInteger expectedSize;

/**
 * The video data cached in disk.
 */
@property(nonatomic, assign)NSUInteger receivedSize;

/**
 * The cache video data temporary cache path in disk.
 */
@property(nonatomic, strong, nullable)NSString *tempCacheVideoPath;

@property (nonatomic, strong) JPVideoPlayerCacheFile *cacheFile;

@end

static NSString *JPVideoPlayerMimeType = @"video/mp4";
@implementation JPVideoPlayerResourceLoader

- (instancetype)init {
    self = [super init];
    if (self) {
    }
    return self;
}

- (instancetype)initWithCustomURL:(NSURL *)customURL {
    NSParameterAssert(customURL);
    if(!customURL){
        return nil;
    }

    self = [super init];
    if(self){
        _customURL = customURL;
        _pendingRequests = [@[] mutableCopy];
        NSString *key = [JPVideoPlayerManager.sharedManager cacheKeyForURL:customURL];
        _cacheFile = [JPVideoPlayerCacheFile cacheFileWithFilePath:[JPVideoPlayerCachePath videoCacheTemporaryPathForKey:key]
                                                     indexFilePath:[JPVideoPlayerCachePath videoCacheIndexSavePathForKey:key]];
    }
    return self;
}


#pragma mark - AVAssetResourceLoaderDelegate

- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader
shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)loadingRequest{
    if (resourceLoader && loadingRequest){
        [self.pendingRequests addObject:loadingRequest];
        [self internalPendingRequests];
    }
    
    if (self.delegate && [self.delegate respondsToSelector:@selector(resourceLoader:requestRangeDidChange:)]) {
        AVAssetResourceLoadingDataRequest *request = [loadingRequest valueForKey:@"dataRequest"];
        NSString *rangeString = [self fetchRequestRangeStringWithDataRequest:request];
        [self.delegate resourceLoader:self requestRangeDidChange:rangeString];
    }
    
    return YES;
}

- (void)resourceLoader:(AVAssetResourceLoader *)resourceLoader
didCancelLoadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest{
    [self.pendingRequests removeObject:loadingRequest];
}

- (NSString *)fetchRequestRangeStringWithDataRequest:(AVAssetResourceLoadingDataRequest *)request {
    long long currentOffset = request.currentOffset;
    long long requestedOffset = request.requestedOffset;
    long long requestedLength = request.requestedLength;
    BOOL requestsAllDataToEndOfResource = request.requestsAllDataToEndOfResource;

    NSString *rangeString = nil;
    if (requestsAllDataToEndOfResource) {
        rangeString = [NSString stringWithFormat:@"bytes=%lld-", requestedOffset];
    }
    else {
        rangeString = [NSString stringWithFormat:@"bytes=%lld-%lld", requestedOffset, requestedOffset + requestedLength];
    }
    JPLogDebug(@"currentOffset: %lld, requestedOffset: %lld, requestedLength: %lld, requestsAllDataToEndOfResource: %d", currentOffset, requestedOffset, requestedLength, requestsAllDataToEndOfResource);
    NSParameterAssert(rangeString);
    return rangeString;
}


#pragma mark - Private

- (void)internalPendingRequests{
    // Enumerate all loadingRequest
    // For every singal loadingRequest, combine response-data length and file mimeType
    // Then judge the download file data is contain the loadingRequest's data or not, if Yes, take out the request's data and return to loadingRequest, next to colse this loadingRequest. if No, continue wait for download finished.
    if (!self.tempCacheVideoPath) {
        return;
    }
    
    NSError *error;
    NSData *tempVideoData = [NSData dataWithContentsOfFile:self.tempCacheVideoPath options:NSDataReadingMappedIfSafe error:&error];
    if (!error) {
        NSMutableArray *requestsCompleted = [NSMutableArray array];
        @autoreleasepool {
            for (AVAssetResourceLoadingRequest *loadingRequest in self.pendingRequests) {
                [self fillInContentInformation:loadingRequest.contentInformationRequest];
                
                BOOL didRespondFinished = [self respondWithDataForRequest:loadingRequest andTempVideoData:tempVideoData];
                if (didRespondFinished) {
                    [requestsCompleted addObject:loadingRequest];
                    [loadingRequest finishLoading];
                }
            }
        }
        if (requestsCompleted.count) {
            [self.pendingRequests removeObjectsInArray:[requestsCompleted copy]];
        }
    }
}

- (BOOL)respondWithDataForRequest:(AVAssetResourceLoadingRequest *)loadingRequest andTempVideoData:(NSData * _Nullable)tempVideoData{
    
    // Thanks for @DrunkenMouse(http://www.jianshu.com/users/5d853d21f7da/latest_articles) submmit a bug that my mistake of calculate "endOffset".
    // Thanks for Nick Xu Mark.
    
    AVAssetResourceLoadingDataRequest *dataRequest = loadingRequest.dataRequest;
    
    NSUInteger startOffset = (NSUInteger)dataRequest.requestedOffset;
    if (dataRequest.currentOffset!=0) {
        startOffset = (NSUInteger)dataRequest.currentOffset;
    }
    startOffset = MAX(0, startOffset);
    
    // Don't have any data at all for this request.
    if (self.receivedSize<startOffset) {
        return NO;
    }
    
    NSUInteger unreadBytes = self.receivedSize - startOffset;
    unreadBytes = MAX(0, unreadBytes);
    NSUInteger numberOfBytesToRespondWith = MIN((NSUInteger)dataRequest.requestedLength, unreadBytes);
    NSRange respondRange = NSMakeRange(startOffset, numberOfBytesToRespondWith);
    if (tempVideoData.length>=numberOfBytesToRespondWith) {
        [dataRequest respondWithData:[tempVideoData subdataWithRange:respondRange]];
    }
    
    long long endOffset = startOffset + dataRequest.requestedLength;
    
    // if the received data greater than the requestLength.
    if (self.receivedSize >= endOffset) {
        return YES;
    }
    // if the received data less than the requestLength.
    return NO;
}

- (void)fillInContentInformation:(AVAssetResourceLoadingContentInformationRequest * _Nonnull)contentInformationRequest{
    if (contentInformationRequest) {
        NSString *mimetype = JPVideoPlayerMimeType;
        CFStringRef contentType = UTTypeCreatePreferredIdentifierForTag(kUTTagClassMIMEType, (__bridge CFStringRef _Nonnull)(mimetype), NULL);
        contentInformationRequest.byteRangeAccessSupported = YES;
        contentInformationRequest.contentType = CFBridgingRelease(contentType);
        contentInformationRequest.contentLength = self.expectedSize;
    }
}

@end