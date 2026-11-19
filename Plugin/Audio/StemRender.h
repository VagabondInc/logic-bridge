#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct {
    double tempo;
    double numerator;
    NSInteger denominator;
    double cycleStart;
    double cycleEnd;
    BOOL hasCycle;
} StemHostSnapshot;

typedef NS_ENUM(NSInteger, StemCaptureStatus) {
    StemCaptureStatusIdle,
    StemCaptureStatusWaiting,
    StemCaptureStatusRecording,
    StemCaptureStatusComplete,
    StemCaptureStatusRangeChanged,
    StemCaptureStatusTooLong,
    StemCaptureStatusUnavailable,
};

@interface StemRender : NSObject
- (AUInternalRenderBlock)makeBlock;
- (void)setMusicalContext:(nullable AUHostMusicalContextBlock)musical
                transport:(nullable AUHostTransportStateBlock)transport;
- (StemHostSnapshot)snapshot;
- (void)setCaptureSampleRate:(double)rate channels:(UInt32)channels nonInterleaved:(BOOL)nonInterleaved;
- (BOOL)armCycleCapture;
- (void)cancelCycleCapture;
- (StemCaptureStatus)captureStatus;
- (nullable NSData *)takeCycleWAVWithContext:(StemHostSnapshot *)context;
@end

NS_ASSUME_NONNULL_END
