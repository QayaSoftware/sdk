#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"

typedef void (*qaya_audio_render)(void *user, float *out, ma_uint32 frames);

struct qaya_audio_device {
    ma_device device;
    qaya_audio_render render;
    void *user;
};

static void qaya_audio_callback(ma_device *device, void *output, const void *input, ma_uint32 frames) {
    struct qaya_audio_device *self = device->pUserData;
    (void)input;
    self->render(self->user, output, frames);
}

struct qaya_audio_device *qaya_audio_open(ma_uint32 sample_rate, ma_uint32 period_frames, qaya_audio_render render, void *user, ma_uint32 *actual_rate) {
    struct qaya_audio_device *self = ma_malloc(sizeof *self, NULL);
    if (self == NULL) return NULL;
    self->render = render;
    self->user = user;
    ma_device_config config = ma_device_config_init(ma_device_type_playback);
    config.playback.format = ma_format_f32;
    config.playback.channels = 2;
    config.sampleRate = sample_rate;
    config.periodSizeInFrames = period_frames;
    config.noPreSilencedOutputBuffer = MA_TRUE;
    config.noClip = MA_TRUE;
    config.dataCallback = qaya_audio_callback;
    config.pUserData = self;
    if (ma_device_init(NULL, &config, &self->device) != MA_SUCCESS) {
        ma_free(self, NULL);
        return NULL;
    }
    *actual_rate = self->device.sampleRate;
    return self;
}

int qaya_audio_start(struct qaya_audio_device *self) {
    return ma_device_start(&self->device) == MA_SUCCESS;
}

void qaya_audio_close(struct qaya_audio_device *self) {
    ma_device_uninit(&self->device);
    ma_free(self, NULL);
}

const char *qaya_audio_backend(struct qaya_audio_device *self) {
    return ma_get_backend_name(self->device.pContext->backend);
}
