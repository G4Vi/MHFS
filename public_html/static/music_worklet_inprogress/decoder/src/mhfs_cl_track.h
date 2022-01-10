#pragma once

#include "blockvf.h"

typedef float float32_t;


typedef struct {
    bool initialized;
    unsigned char album[256];
    unsigned char trackno[8];
} mhfs_cl_track_metadata;

typedef struct {
    ma_decoder decoder;
    bool initialized;
    blockvf vf;
    mhfs_cl_track_metadata meta;
    uint32_t currentFrame;    
} mhfs_cl_track;

typedef enum {
    MHFS_CL_TRACK_SUCCESS = 0,
    MHFS_CL_TRACK_GENERIC_ERROR = 1,
    MHFS_CL_TRACK_NEED_MORE_DATA = 2,
} mhfs_cl_track_error;

typedef union {
    uint32_t frames_read;
    uint32_t needed_offset;
} mhfs_cl_track_return_data;

#ifdef __EMSCRIPTEN__
#include <emscripten.h>
#define LIBEXPORT EMSCRIPTEN_KEEPALIVE
#else
#define LIBEXPORT
#endif

LIBEXPORT void mhfs_cl_track_init(mhfs_cl_track *pTrack, const unsigned blocksize);
LIBEXPORT void mhfs_cl_track_deinit(mhfs_cl_track *pTrack);
LIBEXPORT void *mhfs_cl_track_add_block(mhfs_cl_track *pTrack, const uint32_t block_start, const unsigned filesize);
LIBEXPORT int mhfs_cl_track_seek_to_pcm_frame(mhfs_cl_track *pTrack, const uint32_t pcmFrameIndex);
LIBEXPORT mhfs_cl_track_error mhfs_cl_track_read_pcm_frames_f32(mhfs_cl_track *pTrack, const uint32_t desired_pcm_frames, float32_t *outFloat, mhfs_cl_track_return_data *pReturnData);

// For JS convenience

LIBEXPORT uint32_t mhfs_cl_track_return_data_sizeof(void);
LIBEXPORT uint32_t MHFS_CL_TRACK_SUCCESS_func(void);
LIBEXPORT uint32_t MHFS_CL_TRACK_GENERIC_ERROR_func(void);
LIBEXPORT uint32_t MHFS_CL_TRACK_NEED_MORE_DATA_func(void);

LIBEXPORT mhfs_cl_track *mhfs_cl_track_open(const unsigned blocksize);
LIBEXPORT void mhfs_cl_track_close(mhfs_cl_track *pTrack);

LIBEXPORT uint64_t mhfs_cl_track_totalPCMFrameCount(mhfs_cl_track *pTrack);
LIBEXPORT uint32_t mhfs_cl_track_sampleRate(const mhfs_cl_track *pTrack);
LIBEXPORT uint8_t mhfs_cl_track_bitsPerSample(const mhfs_cl_track *pTrack);
LIBEXPORT uint8_t mhfs_cl_track_channels(const mhfs_cl_track *pTrack);
LIBEXPORT uint64_t mhfs_cl_track_currentFrame(const mhfs_cl_track *pTrack);
