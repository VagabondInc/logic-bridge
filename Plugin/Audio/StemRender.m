#import "StemRender.h"
#import <math.h>
#import <stdatomic.h>
#import "StemCapture.inc"

@implementation StemRender {
    AUHostMusicalContextBlock _musical;
    AUHostTransportStateBlock _transport;
    atomic_uint _sequence;
    _Atomic(double) _tempo, _numerator, _cycleStart, _cycleEnd;
    _Atomic(NSInteger) _denominator;
    atomic_bool _hasCycle;
    CycleCapture _capture;
}

// The host stops rendering before render resources are reconfigured.
- (void)setMusicalContext:(AUHostMusicalContextBlock)musical
                transport:(AUHostTransportStateBlock)transport {
    _musical = [musical copy];
    _transport = [transport copy];
    publish(self, (StemHostSnapshot){0});
}

// The render thread publishes a coherent snapshot without locking or allocating.
static void publish(StemRender *render, StemHostSnapshot value) {
    atomic_fetch_add(&render->_sequence, 1);
    atomic_store(&render->_tempo, value.tempo);
    atomic_store(&render->_numerator, value.numerator);
    atomic_store(&render->_denominator, value.denominator);
    atomic_store(&render->_cycleStart, value.cycleStart);
    atomic_store(&render->_cycleEnd, value.cycleEnd);
    atomic_store(&render->_hasCycle, value.hasCycle);
    atomic_fetch_add(&render->_sequence, 1);
}

- (AUInternalRenderBlock)makeBlock {
    return ^AUAudioUnitStatus(AudioUnitRenderActionFlags *flags,
        const AudioTimeStamp *timestamp, AUAudioFrameCount frames,
        NSInteger bus, AudioBufferList *output, const AURenderEvent *events,
        AURenderPullInputBlock pull) {
        StemHostSnapshot value = {0};
        double beat = NAN;
        if (self->_musical &&
            !self->_musical(&value.tempo, &value.numerator, &value.denominator, &beat, NULL, NULL)) {
            beat = NAN;
            value = (StemHostSnapshot){0};
        }
        AUHostTransportStateFlags state = 0;
        if (self->_transport &&
            self->_transport(&state, NULL, &value.cycleStart, &value.cycleEnd)) {
            value.hasCycle = (state & AUHostTransportStateCycling) &&
                isfinite(value.cycleStart) && isfinite(value.cycleEnd) &&
                value.cycleEnd > value.cycleStart;
        }
        publish(self, value);
        if (bus != 0) return kAudioUnitErr_InvalidElement;
        if (!pull) return kAudioUnitErr_NoConnection;
        AUAudioUnitStatus status = pull(flags, timestamp, frames, 0, output);
        if (status == noErr && frames > 0) {
            renderCapture(&self->_capture, value, (state & AUHostTransportStateMoving) != 0,
                          beat, frames, output, (*flags & kAudioUnitRenderAction_OutputIsSilence) != 0);
        }
        return status;
    };
}

- (StemHostSnapshot)snapshot {
    unsigned start = atomic_load(&_sequence);
    if (start & 1) return (StemHostSnapshot){0};
    StemHostSnapshot value = {
        .tempo = atomic_load(&_tempo),
        .numerator = atomic_load(&_numerator),
        .denominator = atomic_load(&_denominator),
        .cycleStart = atomic_load(&_cycleStart),
        .cycleEnd = atomic_load(&_cycleEnd),
        .hasCycle = atomic_load(&_hasCycle)
    };
    return start == atomic_load(&_sequence) ? value : (StemHostSnapshot){0};
}

- (void)setCaptureSampleRate:(double)rate channels:(UInt32)channels nonInterleaved:(BOOL)nonInterleaved {
    @synchronized (self) {
        [self cancelCycleCapture];
        _capture.sampleRate = rate;
        _capture.channels = channels;
        _capture.nonInterleaved = nonInterleaved;
    }
}

- (BOOL)armCycleCapture {
    @synchronized (self) {
        if (atomic_load(&_capture.phase) != CaptureIdle ||
            _capture.sampleRate <= 0 || _capture.channels < 1 || _capture.channels > 2) return NO;
        _capture.capacity = (maxWAVBytes - wavHeaderSize) / (_capture.channels * sizeof(int16_t));
        if (!_capture.pcm) _capture.pcm = malloc(maxWAVBytes - wavHeaderSize);
        if (!_capture.pcm) return NO;
        _capture.frameCount = 0;
        atomic_store(&_capture.cancel, false);
        atomic_store(&_capture.phase, CaptureWaiting);
        return YES;
    }
}

- (void)cancelCycleCapture {
    @synchronized (self) {
        atomic_store(&_capture.cancel, true);
        CapturePhase phase = atomic_load(&_capture.phase);
        while (phase != CaptureWorking && phase != CaptureIdle) {
            if (atomic_compare_exchange_strong(&_capture.phase, &phase, CaptureIdle)) {
                phase = CaptureIdle;
                break;
            }
        }
        if (phase == CaptureIdle) {
            free(_capture.pcm);
            _capture.pcm = NULL;
        }
    }
}

- (StemCaptureStatus)captureStatus {
    switch (atomic_load(&_capture.phase)) {
        case CaptureIdle: return StemCaptureStatusIdle;
        case CaptureWaiting: return StemCaptureStatusWaiting;
        case CaptureRecording:
        case CaptureWorking: return StemCaptureStatusRecording;
        case CaptureComplete: return StemCaptureStatusComplete;
        case CaptureRangeChanged: return StemCaptureStatusRangeChanged;
        case CaptureTooLong: return StemCaptureStatusTooLong;
        case CaptureUnavailable: return StemCaptureStatusUnavailable;
    }
}

- (NSData *)takeCycleWAVWithContext:(StemHostSnapshot *)context {
    @synchronized (self) {
        if (atomic_load(&_capture.phase) != CaptureComplete) return nil;
        *context = _capture.context;
        NSData *wav = encodeWAV(&_capture);
        free(_capture.pcm);
        _capture.pcm = NULL;
        atomic_store(&_capture.phase, CaptureIdle);
        return wav;
    }
}

- (void)dealloc {
    free(_capture.pcm);
}

@end
