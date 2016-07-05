//
//  GSFileLoadManager.h
//  Geo4ME
//
//  Created by Сергей Веселовский on 04.02.16.
//  Copyright © 2016 GradoService LLC. All rights reserved.
//

#import <Foundation/Foundation.h>
@class GSFileLoadManager;
@protocol GSFileLoadManagerDelegate <NSObject>
@optional
/*!
@discussion  Custom implementation for thumbnail creating. Needed if expected file isn't image
 */
- (UIImage*) makeThumbnailForItemWithURL:(NSURL*) itemURL;
/*!
 @discussion Informs delegate that loading was successfuly completed
 */
- (void) fileLoader:(GSFileLoadManager*) fileLoader didLoadFileWithURL:(NSURL*) itemURL;
@required
/*!
 @discussion This method must return prefered filePath for file or loading will end with error.
 */
- (NSString*) fileLoader:(GSFileLoadManager*) fileLoader filePathForItemWithURL:(NSURL*) itemURL;
@end
/**
Basic caching rules: 
 1) If the file is in the RAM, then it is on the disk;
 2) If the file is on a disk, the loading is not necessary;
 3) If not present, then start the download.
 */
@interface GSFileLoadManager : NSObject
/*!
 @param itemURL URL of file on server
 @param parameters Parameters for query (width, height, crop, stretch)
 @param success Block that will be executed in case of success result. Will return nil for not image files
 @param failure Block that will be executed in case of failed result
 @discussion This methos will load file from server and return thumbnail image (migth be nil if it's not image) and stored it in cache
 @warning Will return nil in success block for not image files
 @return Cached thumbnail or nil.
 */
- (UIImage*) loadFileWithURL:(NSURL*) itemURL parameters:(NSDictionary*)parameters ignoreCache:(BOOL) ignoreCache success:(void(^) (id response)) success failure:(void(^)(NSError* error)) failure;

/*!
 @param itemURL URL of file on server
 @param Parameters parameters for query (width, height, crop, stretch)
 @param success Block that will be executed in case of success result. Will return nil for not image files
 @param failure Block that will be executed in case of failed result
 @discussion This methos will load thumbnail from server and stored it in cache
 */
- (UIImage*) loadSmallPhotoWithURL:(NSURL*)itemURL withParameters:(NSDictionary*) params signature:(NSString*)signature ignoreCache:(BOOL) ignoreCache success:(void(^) (id response)) success failure:(void(^)(NSError* error)) failure;

/*!
 @param itemURL URL of file on server
 @param parameters Parameters for query (width, height, crop, stretch)
 @param success Block that will be executed in case of success result
 @param failure Block that will be executed in case of failed result
 @discussion    This method will load file from server to disk and notify reciever with block.
 */
- (NSOperation*) loadOriginalFileWithURL:(NSURL*)itemURL withParameters:(NSDictionary*) params success:(void(^) (NSString *filePath)) success failure:(GSFailureRequestCompletionV2) failure progress:(GSProgressRequest)progress;
- (void) clearFilesDirectory;

/*!
 @discussion Delegate helps loader to create thumbnails for not image items and get filePath to store big files, so u can get them later
 */
@property (nonatomic,weak) id<GSFileLoadManagerDelegate> delegate;
@end
