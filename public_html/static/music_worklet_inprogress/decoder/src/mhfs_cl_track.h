#pragma once

#include "blockvf.h"

typedef float float32_t;


typedef struct {
    uint64_t totalPCMFrameCount;
    double durationInSecs;
    uint32_t sampleRate;
    uint8_t channels;
    uint8_t bitsPerSample;
    bool hasSeekTable;
    unsigned char album[256];
    unsigned char trackno[8];
} mhfs_cl_track_metadata;

#define MHFS_CL_TRACK_MAX_ALLOCS 3
typedef struct {
    void *allocptrs[MHFS_CL_TRACK_MAX_ALLOCS];
    size_t allocsizes[MHFS_CL_TRACK_MAX_ALLOCS];
} mhfs_cl_track_allocs;

typedef struct {
    // for backup and restore
    ma_decoder backupDecoder;
    unsigned backupFileOffset;
    mhfs_cl_track_allocs allocs;

    ma_decoder_config decoderConfig;
    ma_decoder decoder;
    bool dec_initialized;
    blockvf vf;
    mhfs_cl_track_metadata meta;
    bool meta_initialized;
    uint32_t currentFrame;
    char mime[16];
    char fullfilename[256];
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

LIBEXPORT void mhfs_cl_track_init(mhfs_cl_track *pTrack, const unsigned blocksize, const char *mime, const char *fullfilename, const uint64_t totalPCMFrameCount);
LIBEXPORT void mhfs_cl_track_deinit(mhfs_cl_track *pTrack);
LIBEXPORT void *mhfs_cl_track_add_block(mhfs_cl_track *pTrack, const uint32_t block_start, const unsigned filesize);
LIBEXPORT int mhfs_cl_track_seek_to_pcm_frame(mhfs_cl_track *pTrack, const uint32_t pcmFrameIndex);
LIBEXPORT mhfs_cl_track_error mhfs_cl_track_read_pcm_frames_f32(mhfs_cl_track *pTrack, const uint32_t desired_pcm_frames, float32_t *outFloat, mhfs_cl_track_return_data *pReturnData);

// For JS convenience

LIBEXPORT uint32_t mhfs_cl_track_return_data_sizeof(void);
LIBEXPORT uint32_t mhfs_cl_track_sizeof(void);
LIBEXPORT uint32_t MHFS_CL_TRACK_SUCCESS_func(void);
LIBEXPORT uint32_t MHFS_CL_TRACK_GENERIC_ERROR_func(void);
LIBEXPORT uint32_t MHFS_CL_TRACK_NEED_MORE_DATA_func(void);

LIBEXPORT uint64_t mhfs_cl_track_totalPCMFrameCount(mhfs_cl_track *pTrack);
LIBEXPORT uint32_t mhfs_cl_track_sampleRate(const mhfs_cl_track *pTrack);
LIBEXPORT uint8_t mhfs_cl_track_bitsPerSample(const mhfs_cl_track *pTrack);
LIBEXPORT uint8_t mhfs_cl_track_channels(const mhfs_cl_track *pTrack);
LIBEXPORT uint64_t mhfs_cl_track_currentFrame(const mhfs_cl_track *pTrack);
LIBEXPORT double mhfs_cl_track_durationInSecs(const mhfs_cl_track *pTrack);

#if defined(MHFSCLTRACK_IMPLEMENTATION)
#ifndef mhfs_cl_track_c
#define mhfs_cl_track_c

#ifndef MHFSCLTR_PRINT_ON
    #define MHFSCLTR_PRINT_ON 0
#endif

#define MHFSCLTR_PRINT(...) \
    do { if (MHFSCLTR_PRINT_ON) fprintf(stdout, __VA_ARGS__); } while (0)

#define mhfs_cl_member_size(type, member) sizeof(((type *)0)->member)

static void mhfs_cl_track_metadata_init(mhfs_cl_track_metadata *pMetadata, const uint64_t totalPCMFrameCount, const uint32_t sampleRate, const uint8_t channels, const uint8_t bitsPerSample)
{
    pMetadata->totalPCMFrameCount = totalPCMFrameCount;
    pMetadata->sampleRate = sampleRate;
    pMetadata->channels = channels;
    pMetadata->bitsPerSample = bitsPerSample;
    pMetadata->durationInSecs = (pMetadata->sampleRate > 0) ? ((double)totalPCMFrameCount / sampleRate) : 0;
}

static mhfs_cl_track_error mhfs_cl_track_error_from_blockvf_error(const blockvf_error bvferr)
{
    switch(bvferr)
    {
        case BLOCKVF_SUCCESS:
        return MHFS_CL_TRACK_SUCCESS;

        case BLOCKVF_MEM_NEED_MORE:
        return MHFS_CL_TRACK_NEED_MORE_DATA;

        case BLOCKVF_GENERIC_ERROR:
        default:
        return MHFS_CL_TRACK_GENERIC_ERROR;
    }
}

static ma_result mhfs_cl_track_on_seek_ma_decoder(ma_decoder *pDecoder, int64_t offset, ma_seek_origin origin)
{
    return blockvf_seek((blockvf*)pDecoder->pUserData, offset, origin);
}

static drflac_bool32 mhfs_cl_track_on_seek_drflac(void* pUserData, int offset, drflac_seek_origin origin)
{
    return blockvf_seek(&((mhfs_cl_track *)pUserData)->vf, offset, (ma_seek_origin)origin) == MA_SUCCESS;
}

static void mhfs_cl_track_on_meta_drflac(void *pUserData, drflac_metadata *pMetadata)
{
    mhfs_cl_track *pTrack = (mhfs_cl_track *)pUserData;
    if(pMetadata->type == DRFLAC_METADATA_BLOCK_TYPE_VORBIS_COMMENT)
    {
        drflac_vorbis_comment_iterator comment_iterator;
        drflac_init_vorbis_comment_iterator(&comment_iterator, pMetadata->data.vorbis_comment.commentCount, pMetadata->data.vorbis_comment.pComments);
        uint32_t commentLength;

        const char *strAlbum = "ALBUM=";
        size_t albumlen = strlen(strAlbum);
        const char *comment;
        while((comment = drflac_next_vorbis_comment(&comment_iterator, &commentLength)) != NULL)
        {
            MHFSCLTR_PRINT("%.*s\n", commentLength, comment);
        }
    }
    else if(pMetadata->type == DRFLAC_METADATA_BLOCK_TYPE_PICTURE)
    {
        MHFSCLTR_PRINT("Picture mime: %.*s\n", pMetadata->data.picture.mimeLength, pMetadata->data.picture.mime);
    }
    else if(pMetadata->type == DRFLAC_METADATA_BLOCK_TYPE_SEEKTABLE)
    {
        pTrack->meta.hasSeekTable = true;
    }
}


static ma_result mhfs_cl_track_on_read_ma_decoder(ma_decoder *pDecoder, void* bufferOut, size_t bytesToRead, size_t *bytesRead)
{
    return blockvf_read((blockvf*)pDecoder->pUserData, bufferOut, bytesToRead, bytesRead);
}

static size_t mhfs_cl_track_on_read_drflac(void* pUserData, void* bufferOut, size_t bytesToRead)
{
    size_t bytesRead;
    const ma_result res =  blockvf_read(&((mhfs_cl_track *)pUserData)->vf, bufferOut, bytesToRead, &bytesRead);
    if(res == MA_SUCCESS) return bytesRead;
    return 0;
}

uint64_t mhfs_cl_track_totalPCMFrameCount(mhfs_cl_track *pTrack)
{
    return pTrack->meta.totalPCMFrameCount;
}

uint32_t mhfs_cl_track_sampleRate(const mhfs_cl_track *pTrack)
{
    return pTrack->meta.sampleRate;
}

uint8_t mhfs_cl_track_bitsPerSample(const mhfs_cl_track *pTrack)
{
    return pTrack->meta.bitsPerSample;
}

uint8_t mhfs_cl_track_channels(const mhfs_cl_track *pTrack)
{
    return pTrack->meta.channels;
}

// round up to nearest multiple of 8
static inline size_t ceil8(const size_t toround)
{
    return ((toround +7) & (~7));
}

static void *mhfs_cl_track_malloc(size_t sz, void* pUserData)
{
    mhfs_cl_track *pTrack = (mhfs_cl_track *)pUserData;
    mhfs_cl_track_allocs *pAllocs = &pTrack->allocs;
    for(unsigned i = 0; i < MHFS_CL_TRACK_MAX_ALLOCS; i++)
    {
        if(pAllocs->allocptrs[i] == NULL)
        {
            const size_t rsz = ceil8(sz);
            uint8_t *res = malloc(rsz * 2);
            if(res == NULL)
            {
                MHFSCLTR_PRINT("%s: %zu malloc failed\n", __func__, sz);
            }
            MHFSCLTR_PRINT("%s: %zu %p\n", __func__, sz, res);
            pAllocs->allocsizes[i]= sz;
            pAllocs->allocptrs[i] = res;
            return res;
        }
    }
    MHFSCLTR_PRINT("%s: %zu failed to find slot for alloc\n", __func__, sz);
    return NULL;
}

static void mhfs_cl_track_free(void* p, void* pUserData)
{
    mhfs_cl_track *pTrack = (mhfs_cl_track *)pUserData;
    mhfs_cl_track_allocs *pAllocs = &pTrack->allocs;

    for(unsigned i = 0; i < MHFS_CL_TRACK_MAX_ALLOCS; i++)
    {
        if(pAllocs->allocptrs[i] == p)
        {
            MHFSCLTR_PRINT("%s: 0x%p\n", __func__, p);
            free(p);
            pAllocs->allocptrs[i] = NULL;
            return;
        }
    }
    MHFSCLTR_PRINT("%s: failed to record free %p\n", __func__, p);
}

static void *mhfs_cl_track_realloc(void *p, size_t sz, void* pUserData)
{
    if(p == NULL)
    {
        MHFSCLTR_PRINT("%s: %zu realloc passing to malloc\n", __func__, sz);
        return mhfs_cl_track_malloc(sz, pUserData);
    }
    else if(sz == 0)
    {
        MHFSCLTR_PRINT("%s: %zu realloc passing to free\n", __func__, sz);
        mhfs_cl_track_free(p, pUserData);
        return NULL;
    }

    mhfs_cl_track *pTrack = (mhfs_cl_track *)pUserData;
    mhfs_cl_track_allocs *pAllocs = &pTrack->allocs;
    for(unsigned i = 0; i < MHFS_CL_TRACK_MAX_ALLOCS; i++)
    {
        if(pAllocs->allocptrs[i] == p)
        {
            const size_t osz = pAllocs->allocsizes[i];
            const size_t orsz = ceil8(pAllocs->allocsizes[i]);
            const size_t rsz = ceil8(sz);
            // avoid losing the start of backup by moving it down
            if(rsz < orsz)
            {
                uint8_t *ogalloc = p;
                memmove(ogalloc+rsz, ogalloc+orsz, sz);
            }
            uint8_t *newalloc = realloc(p, rsz*2);
            if(newalloc == NULL)
            {
                if(rsz >= orsz)
                {
                    MHFSCLTR_PRINT("%s: %zu realloc failed\n", __func__, sz);
                    return NULL;
                }
                // we moved the data down so we can't fail
                newalloc = p;
            }
            // move the backup data forward
            else if(rsz > orsz)
            {
                memmove(newalloc+rsz, newalloc+orsz, osz);
            }

            pAllocs->allocsizes[i]= sz;
            pAllocs->allocptrs[i] = newalloc;
            return newalloc;
        }
    }
    MHFSCLTR_PRINT("%s: %zu failed to find\n", __func__, sz);
    return NULL;
}

static inline void mhfs_cl_track_allocs_backup_or_restore(mhfs_cl_track *pTrack, const bool backup)
{
    // copy ma_decoder and blockvf fileoffset
    if(backup)
    {
        pTrack->backupDecoder    = pTrack->decoder;
        pTrack->backupFileOffset = pTrack->vf.fileoffset;
    }
    else
    {
        pTrack->decoder       = pTrack->backupDecoder;
        pTrack->vf.fileoffset = pTrack->backupFileOffset;
    }

    // copy the allocations
    mhfs_cl_track_allocs *pAllocs = &pTrack->allocs;
    for(unsigned i = 0; i < MHFS_CL_TRACK_MAX_ALLOCS; i++)
    {
        if(pAllocs->allocptrs[i] != NULL)
        {
            const size_t offset = ceil8(pAllocs->allocsizes[i]);
            uint8_t *allocBuf = pAllocs->allocptrs[i];
            const uint8_t *srcBuf;
            uint8_t *destBuf;
            if(backup)
            {
                srcBuf = allocBuf;
                destBuf = allocBuf + offset;
            }
            else
            {
                srcBuf = allocBuf + offset;
                destBuf = allocBuf;
            }
            memcpy(destBuf, srcBuf, pAllocs->allocsizes[i]);
        }
    }
}

static inline void mhfs_cl_track_allocs_backup(mhfs_cl_track *pTrack)
{
    return mhfs_cl_track_allocs_backup_or_restore(pTrack, true);
}

static inline void mhfs_cl_track_allocs_restore(mhfs_cl_track *pTrack)
{
    return mhfs_cl_track_allocs_backup_or_restore(pTrack, false);
}

void mhfs_cl_track_init(mhfs_cl_track *pTrack, const unsigned blocksize, const char *mime, const char *fullfilename, const uint64_t totalPCMFrameCount)
{
    for(unsigned i = 0; i < MHFS_CL_TRACK_MAX_ALLOCS; i++)
    {
        pTrack->allocs.allocptrs[i] = NULL;
    }
    snprintf(pTrack->mime, mhfs_cl_member_size(mhfs_cl_track, mime), "%s", mime);
    snprintf(pTrack->fullfilename, mhfs_cl_member_size(mhfs_cl_track, fullfilename), "%s", fullfilename);
    pTrack->decoderConfig = ma_decoder_config_init(ma_format_f32, 0, 0);
    ma_allocation_callbacks cbs;
    cbs.pUserData = pTrack;
    cbs.onMalloc = &mhfs_cl_track_malloc;
    cbs.onRealloc = &mhfs_cl_track_realloc;
    cbs.onFree = &mhfs_cl_track_free;
    pTrack->decoderConfig.allocationCallbacks = cbs;

    pTrack->dec_initialized = false;
    blockvf_init(&pTrack->vf, blocksize);
    pTrack->meta_initialized = false;
    pTrack->meta.totalPCMFrameCount = totalPCMFrameCount;
    pTrack->currentFrame = 0;
}

void mhfs_cl_track_deinit(mhfs_cl_track *pTrack)
{
    if(pTrack->dec_initialized) ma_decoder_uninit(&pTrack->decoder);
    blockvf_deinit(&pTrack->vf);
}

void *mhfs_cl_track_add_block(mhfs_cl_track *pTrack, const uint32_t block_start, const unsigned filesize)
{
    return blockvf_add_block(&pTrack->vf, block_start, filesize);
}

// mhfs_cl_track_read_pcm_frames_f32 will catch the error if we dont here
int mhfs_cl_track_seek_to_pcm_frame(mhfs_cl_track *pTrack, const uint32_t pcmFrameIndex)
{
    if(pTrack->dec_initialized)
    {
        if(pcmFrameIndex >= mhfs_cl_track_totalPCMFrameCount(pTrack))
        {
            // allow seeking to 0 always
            if(pcmFrameIndex != 0)
            {
                return 0;
            }
        }
    }
    pTrack->currentFrame = pcmFrameIndex;
    return 1;
}

uint32_t mhfs_cl_track_return_data_sizeof(void)
{
    return sizeof(mhfs_cl_track_return_data);
}

uint32_t mhfs_cl_track_sizeof(void)
{
    return sizeof(mhfs_cl_track);
}

uint32_t MHFS_CL_TRACK_SUCCESS_func(void)
{
    return MHFS_CL_TRACK_SUCCESS;
}

uint32_t MHFS_CL_TRACK_GENERIC_ERROR_func(void)
{
    return MHFS_CL_TRACK_GENERIC_ERROR;
}

uint32_t MHFS_CL_TRACK_NEED_MORE_DATA_func(void)
{
    return MHFS_CL_TRACK_NEED_MORE_DATA;
}

uint64_t mhfs_cl_track_currentFrame(const mhfs_cl_track *pTrack)
{
    return pTrack->currentFrame;
}

double mhfs_cl_track_durationInSecs(const mhfs_cl_track *pTrack)
{
    return pTrack->meta.durationInSecs;
}

typedef enum {
	DAF_FLAC,
	DAF_MP3,
    DAF_WAV,
	DAF_PCM
} DecoderAudioFormats;

static inline void mhfs_cl_track_swap_tryorder(ma_encoding_format *first,  ma_encoding_format *second)
{
    ma_encoding_format temp = *first;
    *first = *second;
    *second = temp;
}

static mhfs_cl_track_error mhfs_cl_track_open_ma_decoder(mhfs_cl_track *pTrack, mhfs_cl_track_return_data *pReturnData)
{
    // determine the order to try codecs
    ma_encoding_format tryorder[] = { ma_encoding_format_flac, ma_encoding_format_mp3, ma_encoding_format_wav};
    unsigned max_try_count = sizeof(tryorder) / sizeof(tryorder[0]);

    const size_t namelen = strlen(pTrack->fullfilename);
    const char *lastFourChars = (namelen >= 4) ? (pTrack->fullfilename + namelen - 4) : "";

    if(pTrack->decoderConfig.encodingFormat != ma_format_unknown)
    {
        // fast path we already opened the decoder before
        tryorder[0] = pTrack->decoderConfig.encodingFormat;
        max_try_count = 1;
    }
    // attempt to speed up guesses checking magic numbers
    else if((pTrack->vf.buf != NULL) && (memcmp(pTrack->vf.buf, "fLaC", 4) == 0))
    {
        mhfs_cl_track_swap_tryorder(&tryorder[DAF_FLAC], &tryorder[0]);
    }
    else if((pTrack->vf.buf != NULL) && (memcmp(pTrack->vf.buf, "RIFF", 4) == 0))
    {
        mhfs_cl_track_swap_tryorder(&tryorder[DAF_WAV], &tryorder[0]);
    }
    // fallback, attempt to speed up guesses by mime
    else if(strcmp(pTrack->mime, "audio/flac") == 0)
    {
        mhfs_cl_track_swap_tryorder(&tryorder[DAF_FLAC], &tryorder[0]);
    }
    else if((strcmp(pTrack->mime, "audio/wave") == 0) || (strcmp(pTrack->mime, "audio/wav") == 0))
    {
        mhfs_cl_track_swap_tryorder(&tryorder[DAF_WAV], &tryorder[0]);
    }
    else if(strcmp(pTrack->mime, "audio/mpeg") == 0)
    {
        mhfs_cl_track_swap_tryorder(&tryorder[DAF_MP3], &tryorder[0]);
    }
    // fallback, fallback attempt to speed up guesses with file extension
    else if(strcmp(lastFourChars, "flac") == 0)
    {
        mhfs_cl_track_swap_tryorder(&tryorder[DAF_FLAC], &tryorder[0]);
    }
    else if(strcmp(lastFourChars, ".wav") == 0)
    {
        mhfs_cl_track_swap_tryorder(&tryorder[DAF_WAV], &tryorder[0]);
    }
    else if(strcmp(lastFourChars, ".mp3") == 0)
    {
        mhfs_cl_track_swap_tryorder(&tryorder[DAF_MP3], &tryorder[0]);
    }
    // check ID3 tags last as signal for mp3 as they could be anything
    else if((pTrack->vf.buf != NULL) && (memcmp(pTrack->vf.buf, "ID3", 3) == 0))
    {
        mhfs_cl_track_swap_tryorder(&tryorder[DAF_MP3], &tryorder[0]);
    }
    else
    {
        MHFSCLTR_PRINT("warning: unable to guess format\n");
    }

    // finally attempt to open encoders
    mhfs_cl_track_error res = MHFS_CL_TRACK_GENERIC_ERROR;
    bool blockVFfailed = false;
    uint32_t neededOffset;

    for(unsigned i = 0; i < max_try_count; i++)
    {
        pTrack->vf.fileoffset = 0;
        pTrack->decoderConfig.encodingFormat = tryorder[i];
        ma_result openRes = ma_decoder_init(&mhfs_cl_track_on_read_ma_decoder, &mhfs_cl_track_on_seek_ma_decoder, &pTrack->vf, &pTrack->decoderConfig, &pTrack->decoder);
        if(!BLOCKVF_OK(&pTrack->vf))
        {
            if(openRes == MA_SUCCESS) ma_decoder_uninit(&pTrack->decoder);
            if(!blockVFfailed)
            {
                blockVFfailed = true;
                neededOffset = pTrack->vf.lastdata.extradata;
                res = mhfs_cl_track_error_from_blockvf_error(pTrack->vf.lastdata.code);
            }
        }
        else if(openRes == MA_SUCCESS)
        {
            pTrack->dec_initialized = true;
            return MHFS_CL_TRACK_SUCCESS;
        }
        // otherwise try the next codec
        pTrack->vf.lastdata.code = BLOCKVF_SUCCESS;
    }

    // failure, reset the encoding format
    pTrack->decoderConfig.encodingFormat = ma_encoding_format_unknown;
    if(blockVFfailed)
    {
        pReturnData->needed_offset = neededOffset;
    }
    return res;
}

// pTrack must have an opened ma_decoder
static mhfs_cl_track_error mhfs_cl_track_load_metadata(mhfs_cl_track *pTrack, mhfs_cl_track_return_data *pReturnData)
{
    mhfs_cl_track_error retval = MHFS_CL_TRACK_SUCCESS;
    unsigned savefileoffset = pTrack->vf.fileoffset;
    pTrack->vf.fileoffset = 0;
    do {
        if(pTrack->decoderConfig.encodingFormat == ma_encoding_format_flac)
        {
            pTrack->meta.hasSeekTable = false;
            drflac *pFlac = drflac_open_with_metadata(&mhfs_cl_track_on_read_drflac, &mhfs_cl_track_on_seek_drflac, &mhfs_cl_track_on_meta_drflac, pTrack, NULL);
            if(!BLOCKVF_OK(&pTrack->vf))
            {
                retval = mhfs_cl_track_error_from_blockvf_error(pTrack->vf.lastdata.code);
                pReturnData->needed_offset = pTrack->vf.lastdata.extradata;
                MHFSCLTR_PRINT("%s failed: drflac_open_with_metadata blockvf error\n", __func__);                    
                break;
            }               
            else if(pFlac != NULL)
            {
                MHFSCLTR_PRINT("flac samplerate %u\n", pFlac->sampleRate);
                mhfs_cl_track_metadata_init(&pTrack->meta, pFlac->totalPCMFrameCount, pFlac->sampleRate, pFlac->channels, pFlac->bitsPerSample);
                drflac_close(pFlac);
                if(!pTrack->meta.hasSeekTable)
                {
                    MHFSCLTR_PRINT("warning: track does NOT have seektable!\n");
                }
                break;
            }
        }

        // fallback to initializing from ma_decoder or from passed in value
        uint64_t totalPCMFrameCount = pTrack->meta.totalPCMFrameCount;
        if(pTrack->decoderConfig.encodingFormat != ma_encoding_format_mp3)
        {
            ma_decoder_get_length_in_pcm_frames(&pTrack->decoder, &totalPCMFrameCount);
        }
        MHFSCLTR_PRINT("decoder output samplerate %u\n", pTrack->decoder.outputSampleRate);
        mhfs_cl_track_metadata_init(&pTrack->meta, totalPCMFrameCount, pTrack->decoder.outputSampleRate, pTrack->decoder.outputChannels, 0);
    } while(0);

    if(retval == MHFS_CL_TRACK_SUCCESS)
    {
        pTrack->meta_initialized = true;
    }
    pTrack->vf.fileoffset = savefileoffset;
    pTrack->vf.lastdata.code = BLOCKVF_SUCCESS;
    return retval;
}

mhfs_cl_track_error mhfs_cl_track_read_pcm_frames_f32(mhfs_cl_track *pTrack, const uint32_t desired_pcm_frames, float32_t *outFloat, mhfs_cl_track_return_data *pReturnData)
{
    mhfs_cl_track_return_data rd;
    if(pReturnData == NULL) pReturnData = &rd;
    mhfs_cl_track_error retval = MHFS_CL_TRACK_SUCCESS;
    pTrack->vf.lastdata.code = BLOCKVF_SUCCESS;

    // initialize the decoder if necessary
    if(!pTrack->dec_initialized)
    {
        retval = mhfs_cl_track_open_ma_decoder(pTrack, pReturnData);
        if(retval != MHFS_CL_TRACK_SUCCESS) return retval;
    }
    // initialize the metadata if necessary
    if(!pTrack->meta_initialized)
    {
        retval = mhfs_cl_track_load_metadata(pTrack, pReturnData);
        if(retval != MHFS_CL_TRACK_SUCCESS) return retval;
    }

    // seek to sample
    MHFSCLTR_PRINT("seek to %u d_pcmframes %u\n", pTrack->currentFrame, desired_pcm_frames);
    const uint32_t currentPCMFrame32 = 0xFFFFFFFF;
    mhfs_cl_track_allocs_backup(pTrack);
    const ma_result seekRes = ma_decoder_seek_to_pcm_frame(&pTrack->decoder, pTrack->currentFrame);
    if(!BLOCKVF_OK(&pTrack->vf))
    {
        retval = mhfs_cl_track_error_from_blockvf_error(pTrack->vf.lastdata.code);
        pReturnData->needed_offset = pTrack->vf.lastdata.extradata;
        MHFSCLTR_PRINT("%s: failed seek_to_pcm_frame NOT OK current: %u desired: %u\n", __func__, currentPCMFrame32, pTrack->currentFrame);
        //goto mhfs_cl_track_read_pcm_frames_f32_FAIL;

        mhfs_cl_track_allocs_restore(pTrack);
        return retval;
    }
    if(seekRes != MA_SUCCESS)
    {
        MHFSCLTR_PRINT("%s: seek failed current: %u desired: %u ma_result %d\n", __func__, currentPCMFrame32, pTrack->currentFrame, seekRes);
        retval = MHFS_CL_TRACK_GENERIC_ERROR;
        goto mhfs_cl_track_read_pcm_frames_f32_FAIL;
    }

    // finally read
    uint64_t frames_decoded = 0;
    if(desired_pcm_frames != 0)
    {
        uint64_t toread = desired_pcm_frames;

        // decode to pcm
        mhfs_cl_track_allocs_backup(pTrack);
        ma_result decRes = ma_decoder_read_pcm_frames(&pTrack->decoder, outFloat, toread, &frames_decoded);
        if(!BLOCKVF_OK(&pTrack->vf))
        {
            retval = mhfs_cl_track_error_from_blockvf_error(pTrack->vf.lastdata.code);
            pReturnData->needed_offset = pTrack->vf.lastdata.extradata;
            MHFSCLTR_PRINT("mhfs_cl_track_read_pcm_frames_f32_mem: failed read_pcm_frames_f32\n");
            //goto mhfs_cl_track_read_pcm_frames_f32_FAIL;

            mhfs_cl_track_allocs_restore(pTrack);
            return retval;
        }
        if(decRes != MA_SUCCESS)
        {
            MHFSCLTR_PRINT("mhfs_cl_track_read_pcm_frames_f32_mem: failed read_pcm_frames_f32(decode), ma_result %d\n", decRes);
            retval = MHFS_CL_TRACK_GENERIC_ERROR;
            if(decRes == MA_AT_END)
            {
                MHFSCLTR_PRINT("MA_AT_END\n"); // not a real error
            }
            goto mhfs_cl_track_read_pcm_frames_f32_FAIL;
        }
        if(frames_decoded != desired_pcm_frames)
        {
            MHFSCLTR_PRINT("mhfs_cl_track_read_pcm_frames_f32_mem: expected %u decoded %"PRIu64"\n", desired_pcm_frames, frames_decoded);
        }
        pTrack->currentFrame += frames_decoded;
    }

    MHFSCLTR_PRINT("returning from pTrack->currentFrame: %u, totalFrames %"PRIu64" frames_decoded %"PRIu64" desired %u\n", pTrack->currentFrame, mhfs_cl_track_totalPCMFrameCount(pTrack), frames_decoded, desired_pcm_frames);
    pReturnData->frames_read = frames_decoded;
    return MHFS_CL_TRACK_SUCCESS;

mhfs_cl_track_read_pcm_frames_f32_FAIL:
    if(pTrack->dec_initialized)
    {
        ma_decoder_uninit(&pTrack->decoder);
        pTrack->dec_initialized = false;
    }
    return retval;
}

#endif  /* mhfs_cl_track_c */
#endif  /* MHFSCLTRACK_IMPLEMENTATION */
