// Audio-thread capture states. Only the control thread allocates and frees the PCM buffer.
typedef enum {
    CaptureIdle, CaptureWaiting, CaptureRecording, CaptureWorking, CaptureComplete,
    CaptureRangeChanged, CaptureTooLong, CaptureUnavailable
} CapturePhase;

typedef struct {
    _Atomic(CapturePhase) phase;
    atomic_bool cancel;
    double sampleRate;
    UInt32 channels;
    BOOL nonInterleaved;
    int16_t *pcm;
    size_t frameCount;
    size_t capacity;
    double nextBeat;
    StemHostSnapshot context;
} CycleCapture;

enum { wavHeaderSize = 44, maxWAVBytes = 20 * 1024 * 1024 };

static size_t frameOffset(double target, double beat, double beatsPerFrame, UInt32 frames) {
    double offset = ceil((target - beat) / beatsPerFrame - 1e-6);
    return (size_t)fmin(frames, fmax(0, offset));
}

static void copyPCM(CycleCapture *capture, const AudioBufferList *audio, size_t first,
                    size_t frames, BOOL *silence) {
    UInt32 channels = capture->channels;
    int16_t *destination = capture->pcm + capture->frameCount * channels;
    if (*silence) {
        memset(destination, 0, frames * channels * sizeof(int16_t));
    } else {
        for (UInt32 channel = 0; channel < channels; ++channel) {
            UInt32 buffer = capture->nonInterleaved ? channel : 0;
            size_t stride = capture->nonInterleaved ? 1 : channels;
            size_t index = first * stride + (capture->nonInterleaved ? 0 : channel);
            if (buffer >= audio->mNumberBuffers || !audio->mBuffers[buffer].mData ||
                (index + (frames - 1) * stride + 1) * sizeof(float) > audio->mBuffers[buffer].mDataByteSize) {
                *silence = YES;
                return;
            }
            const float *source = audio->mBuffers[buffer].mData;
            for (size_t frame = 0; frame < frames; ++frame) {
                float sample = source[index + frame * stride];
                if (!isfinite(sample)) sample = 0;
                int16_t pcm = (int16_t)lrintf(fminf(32767, fmaxf(-32768, sample * 32768)));
                destination[frame * channels + channel] = (int16_t)CFSwapInt16HostToLittle((uint16_t)pcm);
            }
        }
    }
    capture->frameCount += frames;
}

static CapturePhase recordFrames(CycleCapture *capture, CapturePhase phase, StemHostSnapshot host,
                                 BOOL moving, double beat, UInt32 frames, const AudioBufferList *audio,
                                 BOOL silent) {
    if (!moving || !host.hasCycle || !isfinite(beat) || !isfinite(host.tempo) || host.tempo <= 0) {
        if (phase == CaptureRecording) return CaptureRangeChanged;
        return CaptureWaiting;
    }

    double beatsPerFrame = host.tempo / (60 * capture->sampleRate);
    double tolerance = beatsPerFrame * 2;
    if (phase == CaptureRecording) {
        if (fabs(host.cycleStart - capture->context.cycleStart) > tolerance ||
            fabs(host.cycleEnd - capture->context.cycleEnd) > tolerance ||
            fabs(beat - capture->nextBeat) > tolerance || beat >= host.cycleEnd + tolerance) {
            return CaptureRangeChanged;
        }
    } else if (beat > host.cycleStart + tolerance ||
               beat + beatsPerFrame * frames < host.cycleStart) {
        return CaptureWaiting;
    } else {
        capture->context = host;
        capture->frameCount = 0;
    }

    size_t first = frameOffset(host.cycleStart, beat, beatsPerFrame, frames);
    size_t end = frameOffset(host.cycleEnd, beat, beatsPerFrame, frames);
    if (end > first) {
        if (end - first > capture->capacity - capture->frameCount) return CaptureTooLong;
        BOOL missing = silent;
        copyPCM(capture, audio, first, end - first, &missing);
        if (missing && !silent) return CaptureUnavailable;
    }
    if (capture->frameCount == 0) return CaptureWaiting;
    capture->nextBeat = beat + beatsPerFrame * frames;
    return capture->nextBeat >= host.cycleEnd - 1e-9
        ? CaptureComplete : CaptureRecording;
}

static void renderCapture(CycleCapture *capture, StemHostSnapshot host, BOOL moving, double beat,
                          UInt32 frames, const AudioBufferList *audio, BOOL silent) {
    CapturePhase phase = atomic_load(&capture->phase);
    if (phase != CaptureWaiting && phase != CaptureRecording) return;
    if (!atomic_compare_exchange_strong(&capture->phase, &phase, CaptureWorking)) return;

    CapturePhase next = CaptureIdle;
    if (!atomic_load(&capture->cancel)) {
        next = recordFrames(capture, phase, host, moving, beat, frames, audio, silent);
    }
    atomic_store(&capture->phase, atomic_load(&capture->cancel) ? CaptureIdle : next);
}

static void writeLE16(uint8_t *target, uint16_t value) {
    uint16_t encoded = CFSwapInt16HostToLittle(value);
    memcpy(target, &encoded, sizeof(encoded));
}

static void writeLE32(uint8_t *target, uint32_t value) {
    uint32_t encoded = CFSwapInt32HostToLittle(value);
    memcpy(target, &encoded, sizeof(encoded));
}

static NSData *encodeWAV(CycleCapture *capture) {
    uint32_t rate = (uint32_t)lrint(capture->sampleRate);
    uint16_t frameBytes = (uint16_t)(capture->channels * sizeof(int16_t));
    uint32_t length = (uint32_t)(capture->frameCount * frameBytes);
    NSMutableData *wav = [NSMutableData dataWithLength:wavHeaderSize + length];
    uint8_t *head = wav.mutableBytes;
    memcpy(head, "RIFF", 4);
    writeLE32(head + 4, 36 + length);
    memcpy(head + 8, "WAVEfmt ", 8);
    writeLE32(head + 16, 16);
    writeLE16(head + 20, 1);
    writeLE16(head + 22, (uint16_t)capture->channels);
    writeLE32(head + 24, rate);
    writeLE32(head + 28, rate * frameBytes);
    writeLE16(head + 32, frameBytes);
    writeLE16(head + 34, 16);
    memcpy(head + 36, "data", 4);
    writeLE32(head + 40, length);
    memcpy(head + wavHeaderSize, capture->pcm, length);
    return wav;
}
