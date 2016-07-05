//
//  GSFileLoadManager.m
//  Geo4ME
//
//  Created by Сергей Веселовский on 04.02.16.
//  Copyright © 2016 GradoService LLC. All rights reserved.
//

#import "GSFileLoadManager.h"
#import "NSFileManager+PhotoSaving.h"
#import "GSUIImageCategory.h" //тут лежат методы для создания миниатюрок (для изображения и для видео), добавить метод создания круглой миниатюрки на диске
#import "GSServerWorker.h" //тут возьмем методы для download и upload файла
#import <CommonCrypto/CommonDigest.h>
#import "GSNSURLCategory.h"

@interface GSFileLoadManager()
@property (nonatomic,nonnull) NSMutableDictionary<NSURL*,UIImage*> *imageCache;//тут должен быть кеш оперативы
@property (nonatomic,nonnull) NSMutableDictionary<NSURL*,NSString*> *cacheSignatures;//тут должен быть кеш оперативы
@property (nonatomic) NSMutableDictionary<NSURL*,NSArray<GSSuccessRequestCompletion>*> *successBlocksAndURLMatching;
@property (nonatomic) NSMutableDictionary<NSURL*,  NSArray<GSFailureRequestCompletion>*> *failBlocksAndURLMatching;
@end

@implementation GSFileLoadManager
@synthesize imageCache;

- (id) init{
    self = [super init];
    if (self) {
        imageCache = [NSMutableDictionary new];
        _cacheSignatures = [NSMutableDictionary new];
        self.successBlocksAndURLMatching = [NSMutableDictionary new];
        self.failBlocksAndURLMatching = [NSMutableDictionary new];
    }
    return self;
}

#pragma mark - New implementation
- (UIImage*) loadSmallPhotoWithURL:(NSURL*)itemURL withParameters:(NSDictionary*) params signature:(NSString*)signature ignoreCache:(BOOL) ignoreCache success:(void(^) (id response)) success failure:(void(^)(NSError* error)) failure{
    __weak typeof(self) weakSelf = self;
    NSURL *urlWithParametersButToken = [[itemURL cutToken] urlCauseAppedingParams:params];
    NSString *filePath = [self makeFilePathForSelfCreatedThumbnail:[urlWithParametersButToken absoluteString] signature:signature];
    if (!ignoreCache) {
        if([_cacheSignatures[urlWithParametersButToken] isEqualToString:signature]){ //если есть в ОП файл с такой сигнатурой
            UIImage *result = imageCache[urlWithParametersButToken];//проверим в ОП
            if (result) {
                return result;
            }
        }
         //проверим, есть ли фото с такими параметрами на диске
        if ([[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
            UIImage *result = [UIImage imageWithData:[[NSFileManager defaultManager] contentsAtPath:filePath]];
            if(result){
                imageCache[urlWithParametersButToken] = result;
                _cacheSignatures[urlWithParametersButToken] = signature;
                return result;
            }
        }
    }
    //добавим блоки в массив для выполнения
    @synchronized(self) {
        [self addSuccessBlock:[success copy] forURL:urlWithParametersButToken];
        if (failure) {
            [self addFailBlock:[failure copy] forURL:urlWithParametersButToken];
        }
    }
    if (self.successBlocksAndURLMatching[urlWithParametersButToken].count <= 1) {//если никто еще не обращался за этим файликом
        //загрузим фото с заданными параметрами
        [[GSServerWorker sharedWorker] downloadFileToPath:filePath withURL:itemURL withParameters:params success:^(id response) { //response из этого метода возвращается nil, так загрузка сразу на диск идет
            if ([weakSelf.delegate respondsToSelector:@selector(fileLoader:didLoadFileWithURL:)]) { //сообщаем делегату, что файл был загружен
                [weakSelf.delegate fileLoader:weakSelf didLoadFileWithURL:itemURL];
            }
            response = [UIImage imageWithData:[[NSFileManager defaultManager] contentsAtPath:filePath]]; //костыльненько =(
            imageCache[urlWithParametersButToken] = response; //сохранить в ОП
            _cacheSignatures[urlWithParametersButToken] = signature; //сохранить сигнатуру для последующих проверок
            [weakSelf executeAllSuccessBlocksForURL:urlWithParametersButToken withResponse:response];
//            success(response);
        }failure:^(AFHTTPRequestOperation *op,NSError *error) {
            [weakSelf executeAllFailBlocksForURL:urlWithParametersButToken withError:error];
        } progress:nil];
    }
    
    return nil;
}

- (NSOperation*) loadOriginalFileWithURL:(NSURL*)itemURL withParameters:(NSDictionary*) params success:(void(^) (NSString *filePath)) success failure:(GSFailureRequestCompletionV2) failure progress:(GSProgressRequest)progress{
    __weak typeof(self) weakSelf = self;
    NSString *filePath;
    filePath = [self.delegate fileLoader:weakSelf filePathForItemWithURL:(NSURL*) itemURL];
    if (!filePath) {
        ELog(@"You have to implement delegate methods");
        return nil;
    }
    if ([[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
        success(filePath); //если делегат вдруг сам не смог проверить, что файл есть, то давайте скажем ему об этом
        return nil;
    }
    NSOperation *op = [[GSServerWorker sharedWorker] downloadFileToPath:filePath withURL:itemURL withParameters:params success:^(id response) {
        success(filePath);
    }failure:failure progress:progress];
    return op;
}



#pragma mark - Old Implementation Parts
- (UIImage*) loadFileWithURL:(NSURL*) itemURL parameters:(NSDictionary*)parameters ignoreCache:(BOOL) ignoreCache success:(void(^) (id response)) success failure:(void(^)(NSError* error)) failure{
    //проверить в оперативе
    if (!ignoreCache) {
        UIImage *result = imageCache[itemURL];
        if (result) {
            return result;
        }
    }
    
    __weak typeof(self) weakSelf = self;
    NSURL *urlWithParametersButToken = [[itemURL cutToken] urlCauseAppedingParams:parameters];
    NSString *filePath = [self.delegate fileLoader:weakSelf filePathForItemWithURL:(NSURL*) itemURL];
    if (!filePath) {//если пришел nil, возвращаем ошибку
        NSMutableDictionary* details = [NSMutableDictionary dictionary];
        [details setValue:@"Unexpected error" forKey:NSLocalizedDescriptionKey];
        NSError *error = [NSError errorWithDomain:@"GSUnhandledErrors" code:400 userInfo:details];
        failure(error);
        return nil;
    }

        //проверить на диске
    if ([[NSFileManager defaultManager] fileExistsAtPath:filePath] && !ignoreCache) {
        //создать миниатюрку, сохранить в ОП и вернуть в success блок
        UIImage *thumbnail;
        if ([self.delegate respondsToSelector:@selector(makeThumbnailForItemWithURL:)]) {//если делегат определил метод для создания миниатюры, значит он знает, что делает
            thumbnail = [self.delegate makeThumbnailForItemWithURL:itemURL];
        }
        else{//если нет, то используем свою реализацию (неизвестно, что произойдет для видео)
            thumbnail = [self makeThumbnailForItemAtFilePath:filePath itemURL:[itemURL absoluteString]];//параметры не учитываем. Т.к. при вызове этой функции не указываются размеры миниатюры, то они будут дефолтными.
        }
        if (thumbnail) {//если миниатюра существует не смотря ни на что, то сохраним в ОП
            [imageCache setObject:thumbnail forKey:itemURL];
        }
        return thumbnail;
    }

    @synchronized(self) {
        [self addSuccessBlock:[success copy] forURL:urlWithParametersButToken];
        if (failure) {
            [self addFailBlock:[failure copy] forURL:urlWithParametersButToken];
        }
    }
    if (self.successBlocksAndURLMatching[urlWithParametersButToken].count <= 1) {//если никто еще не обращался за этим файликом
        //загрузить
        [[GSServerWorker sharedWorker] downloadFileToPath:filePath withURL:itemURL withParameters:parameters success:^(id response) {
            //файл загружен и сохранен на диск
            //надо
            //создать миниатюру
            UIImage *thumbnail;
            if ([weakSelf.delegate respondsToSelector:@selector(makeThumbnailForItemWithURL:)]) {//если делегат определил метод для создания миниатюры, значит он знает, что делает
                thumbnail = [weakSelf.delegate makeThumbnailForItemWithURL:itemURL];
            }
            else{ //если нет, то используем свою реализацию (неизвестно, что произойдет для видео)
//                if (![[NSFileManager defaultManager] fileExistsAtPath:[weakSelf makeFilePathForSelfCreatedThumbnail:[itemURL absoluteString] signature:nil]]) { //если не создавал ранее миниатюру
                    thumbnail = [weakSelf makeThumbnailForItemAtFilePath:filePath itemURL:[itemURL absoluteString]]; //параметры не учитываем. Т.к. при вызове этой функции не указываются размеры миниатюры, то они будут дефолтными.
//                }
            }
            [imageCache setObject:thumbnail forKey:itemURL];
            if ([weakSelf.delegate respondsToSelector:@selector(fileLoader:didLoadFileWithURL:)]) { //сообщаем делегату, что файл был загружен
                [weakSelf.delegate fileLoader:weakSelf didLoadFileWithURL:itemURL];
            }
            //отдать в success
            [weakSelf executeAllSuccessBlocksForURL:urlWithParametersButToken withResponse:thumbnail];
        } failure:^(AFHTTPRequestOperation* op,NSError *error) {
            if (failure) {
                [weakSelf executeAllFailBlocksForURL:urlWithParametersButToken withError:error];
            }
        } progress:nil];
    }
    return nil;
}

#pragma mark - Blocks operations
//Add success block to array of success blocks
- (void) addSuccessBlock:(id __nonnull)successBlock forURL:(NSURL*)url {
    if (self.successBlocksAndURLMatching[url]) {
        NSMutableArray *array = [self.successBlocksAndURLMatching[url] mutableCopy];
        [array addObject:successBlock];

        self.successBlocksAndURLMatching[url] = array.copy;
    }
    else{
        self.successBlocksAndURLMatching[url] = @[successBlock];
    }
}
//Add success block to array of success blocks
- (void) addFailBlock:(id __nonnull)failBlock forURL:(NSURL*)url{
    if (self.failBlocksAndURLMatching[url]) {
        NSMutableArray *array = [self.failBlocksAndURLMatching[url] mutableCopy];
        [array addObject:failBlock];
        self.failBlocksAndURLMatching[url] = array.copy;
    }
    else{
        self.failBlocksAndURLMatching[url] = @[failBlock];
    }
}
- (void) removeSuccessBlock:(id __nonnull)successBlock forURL:(NSURL*)url{
    if (self.successBlocksAndURLMatching[url]) {
        NSMutableArray *array = [self.successBlocksAndURLMatching[url] mutableCopy];
        [array removeObject:successBlock];
        self.successBlocksAndURLMatching[url] = array.copy;
    }
}
- (void) removeFailBlock:(id __nonnull)failBlock forURL:(NSURL*)url{
    if (self.failBlocksAndURLMatching[url]) {
        NSMutableArray *array = [self.failBlocksAndURLMatching[url] mutableCopy];
        [array removeObject:failBlock];
        self.failBlocksAndURLMatching[url] = array.copy;
    }
}
- (void) executeAllSuccessBlocksForURL:(NSURL*)url withResponse:(id)response{
    for (GSSuccessRequestCompletion success in self.successBlocksAndURLMatching[url]) {
        success(response);
    }
    [self removeAllBlocksForURL:url];
}
- (void) executeAllFailBlocksForURL:(NSURL*)url withError:(NSError*)error{
    for (void (^ myblock)(NSError* err) in self.failBlocksAndURLMatching[url]) {
        myblock(error);
    }
    [self removeAllBlocksForURL:url];
}
- (void) removeAllBlocksForURL:(NSURL*)url{
    [self.successBlocksAndURLMatching removeObjectForKey:url];
    [self.failBlocksAndURLMatching removeObjectForKey:url];
}

#pragma mark - Support methods

- (UIImage*) makeThumbnailForItemAtFilePath:(NSString*)filePath itemURL:(NSString*) itemURL{
    NSString *thumbnailPath = [self makeFilePathForSelfCreatedThumbnail:itemURL signature:nil];
    [UIImage makeThumbnailImageAtPath:filePath saveToPath:thumbnailPath maximumPixelSize:150];
    UIImage *thumb = [UIImage imageWithData:[[NSFileManager defaultManager] contentsAtPath:thumbnailPath]];
    return thumb;
}
- (NSString *)makeFilePathForSelfCreatedThumbnail:(NSString*) originalPhotoURL signature:(NSString*)signature{
    NSString *cacheDirectory = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) objectAtIndex:0];
    NSString *thumbsDirectory = [cacheDirectory stringByAppendingPathComponent:@"FileLoaderThumbnails"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:thumbsDirectory]) {
        [[NSFileManager defaultManager] createDirectoryAtPath:thumbsDirectory withIntermediateDirectories:YES attributes:nil error:nil];
    }
    NSString *thumbnailPath;
    if (signature) {//TODO: этот код неверен в общем случае, исправить
        thumbnailPath = [thumbsDirectory stringByAppendingPathComponent:[[self MD5:originalPhotoURL] stringByAppendingString:signature]];
    }
    else{
        thumbnailPath = [thumbsDirectory stringByAppendingPathComponent:[self MD5:originalPhotoURL]];
        thumbnailPath = [thumbnailPath stringByAppendingPathExtension:@"jpg"];
    }
    return thumbnailPath;
}

- (void) clearFilesDirectory{
    NSString *tempDirectory = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) objectAtIndex:0];
    NSString *thumbsDirectory = [tempDirectory stringByAppendingPathComponent:@"FileLoaderOriginal"];
    [[NSFileManager defaultManager] removeItemAtPath:thumbsDirectory error:nil];
}
- (void) clearThumbnailsDirectory{
    NSString *tempDirectory = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES) objectAtIndex:0];
    NSString *thumbsDirectory = [tempDirectory stringByAppendingPathComponent:@"FileLoaderThumbnails"];
    [[NSFileManager defaultManager] removeItemAtPath:thumbsDirectory error:nil];
}


- (NSString *)MD5:(NSString*) string {
    
    const char * pointer = [string UTF8String];
    unsigned char md5Buffer[CC_MD5_DIGEST_LENGTH];
    
    CC_MD5(pointer, (CC_LONG)strlen(pointer), md5Buffer);
    
    NSMutableString *tmp = [NSMutableString stringWithCapacity:CC_MD5_DIGEST_LENGTH * 2];
    for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++)
        [tmp appendFormat:@"%02x",md5Buffer[i]];
    
    return tmp;
}

@end
