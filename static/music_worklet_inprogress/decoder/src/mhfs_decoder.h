#pragma once
typedef struct {
    unsigned outputSampleRate;
    unsigned outputChannels;
    bool has_madc;
    ma_data_converter madc;
} mhfs_decoder;

#ifdef __EMSCRIPTEN__
#include <emscripten.h>
#define LIBEXPORT EMSCRIPTEN_KEEPALIVE
#else
#define LIBEXPORT
#endif


LIBEXPORT mhfs_decoder *mhfs_decoder_create(const unsigned outputSampleRate, const unsigned outputChannels);
LIBEXPORT uint64_t mhfs_decoder_read_pcm_frames_f32(mhfs_decoder *mhfs_d, NetworkDrFlac *ndrflac, uint32_t desired_pcm_frames, float32_t *outFloat);

#if defined(MHFSDECODER_IMPLEMENATION) || defined(MHFSDECODER_IMPLEMENATION)
#ifndef mhfs_decoder_c
#define mhfs_decoder_c

mhfs_decoder *mhfs_decoder_create(const unsigned outputSampleRate, const unsigned outputChannels)
{
    mhfs_decoder *mhfs_d = malloc(sizeof(mhfs_decoder));
    if(mhfs_d == NULL) return NULL;
    mhfs_d->outputSampleRate = outputSampleRate;
    mhfs_d->outputChannels = outputChannels;
    mhfs_d->has_madc = false;
    return mhfs_d;    
}

uint64_t mhfs_decoder_read_pcm_frames_f32(mhfs_decoder *mhfs_d, NetworkDrFlac *ndrflac, uint32_t desired_pcm_frames, float32_t *outFloat)
{
    return 0;    
}

#endif  /* mhfs_decoder_c */
#endif  /* MHFSDECODER_IMPLEMENATION */