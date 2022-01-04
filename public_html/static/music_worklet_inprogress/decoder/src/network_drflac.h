#pragma once

#include "block_vf.h"

typedef float float32_t;


typedef struct {
    bool initialized;
    unsigned char album[256];
    unsigned char trackno[8];
} NetworkDrFlacMeta;

typedef struct {
    drflac *pFlac;
    blockvf vf;
    NetworkDrFlacMeta meta;
    uint32_t currentFrame;    
} NetworkDrFlac;

typedef enum {
    NDRFLAC_SUCCESS = 0,
    NDRFLAC_GENERIC_ERROR = 1,
    NDRFLAC_NEED_MORE_DATA = 2,
} NetworkDrFlac_Err_Vals;

typedef union {
    uint32_t frames_read;
    uint32_t needed_offset;
} NetworkDrFlac_ReturnData;

#ifdef __EMSCRIPTEN__
#include <emscripten.h>
#define LIBEXPORT EMSCRIPTEN_KEEPALIVE
#else
#define LIBEXPORT
#endif

LIBEXPORT void network_drflac_init(NetworkDrFlac *ndrflac, const unsigned blocksize);
LIBEXPORT void network_drflac_deinit(NetworkDrFlac *ndrflac);
LIBEXPORT void *network_drflac_add_block(NetworkDrFlac *ndrflac, const uint32_t block_start, const unsigned filesize);
LIBEXPORT int network_drflac_seek_to_pcm_frame(NetworkDrFlac *ndrflac, const uint32_t pcmFrameIndex);
LIBEXPORT NetworkDrFlac_Err_Vals network_drflac_read_pcm_frames_f32(NetworkDrFlac *ndrflac, const uint32_t desired_pcm_frames, float32_t *outFloat, NetworkDrFlac_ReturnData *pReturnData);

// For JS convenience

LIBEXPORT uint32_t NetworkDrFlac_ReturnData_sizeof(void);
LIBEXPORT uint32_t NDRFLAC_SUCCESS_func(void);
LIBEXPORT uint32_t NDRFLAC_GENERIC_ERROR_func(void);
LIBEXPORT uint32_t NDRFLAC_NEED_MORE_DATA_func(void);

LIBEXPORT NetworkDrFlac *network_drflac_open(const unsigned blocksize);
LIBEXPORT void network_drflac_close(NetworkDrFlac *ndrflac);

LIBEXPORT uint64_t network_drflac_totalPCMFrameCount(const NetworkDrFlac *ndrflac);
LIBEXPORT uint32_t network_drflac_sampleRate(const NetworkDrFlac *ndrflac);
LIBEXPORT uint8_t network_drflac_bitsPerSample(const NetworkDrFlac *ndrflac);
LIBEXPORT uint8_t network_drflac_channels(const NetworkDrFlac *ndrflac);
LIBEXPORT uint64_t network_drflac_currentFrame(const NetworkDrFlac *ndrflac);
