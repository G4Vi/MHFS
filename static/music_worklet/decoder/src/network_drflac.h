#pragma once

typedef struct _NetworkDrFlacMem NetworkDrFlacMem;
typedef float float32_t;

typedef enum {
    NDRFLAC_SUCCESS = 0,
    NDRFLAC_GENERIC_ERROR = 1,
    NDRFLAC_MEM_NEED_MORE = 2,
    //NDRFLAC_END_OF_STREAM = 3    
} NetworkDrFlac_Err_Vals;

typedef struct {
    NetworkDrFlac_Err_Vals code;
    uint32_t extradata;
} NetworkDrFlac_Error;

typedef struct {
    unsigned fileoffset;
    unsigned filesize;
    drflac *pFlac;   
    NetworkDrFlac_Error *error;
    NetworkDrFlacMem *pMem;   
} NetworkDrFlac;

#ifdef __EMSCRIPTEN__
#include <emscripten.h>
#define LIBEXPORT EMSCRIPTEN_KEEPALIVE
#else
#define LIBEXPORT
#endif

LIBEXPORT NetworkDrFlac_Error *network_drflac_create_error(void);
LIBEXPORT void network_drflac_free_error(NetworkDrFlac_Error *ndrerr);
LIBEXPORT uint32_t network_drflac_error_code(const NetworkDrFlac_Error *ndrerr);
LIBEXPORT uint32_t network_drflac_extra_data(const NetworkDrFlac_Error *ndrerr);
LIBEXPORT uint64_t network_drflac_totalPCMFrameCount(const NetworkDrFlac *ndrflac);
LIBEXPORT uint32_t network_drflac_sampleRate(const NetworkDrFlac *ndrflac);
LIBEXPORT uint8_t network_drflac_bitsPerSample(const NetworkDrFlac *ndrflac);
LIBEXPORT uint8_t network_drflac_channels(const NetworkDrFlac *ndrflac);
LIBEXPORT NetworkDrFlac *network_drflac_open(const unsigned blocksize);
LIBEXPORT void network_drflac_close(NetworkDrFlac *ndrflac);
LIBEXPORT int network_drflac_add_block(NetworkDrFlac *ndrflac, const uint32_t block_start, const unsigned filesize);
LIBEXPORT void *network_drflac_bufptr(const NetworkDrFlac *ndrflac);
LIBEXPORT uint64_t network_drflac_read_pcm_frames_f32_mem(NetworkDrFlac *ndrflac, uint32_t start_pcm_frame, uint32_t desired_pcm_frames, float32_t *outFloat, NetworkDrFlac_Error *error);