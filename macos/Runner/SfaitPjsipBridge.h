#import <Foundation/Foundation.h>
#import <FlutterMacOS/FlutterMacOS.h>

@interface SfaitPjsipBridge : NSObject
+ (instancetype)shared;
- (void)configureWithMessenger:(NSObject<FlutterBinaryMessenger> *)messenger;
@end
