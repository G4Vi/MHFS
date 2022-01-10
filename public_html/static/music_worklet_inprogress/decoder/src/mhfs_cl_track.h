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

#if defined(MHFSCLTRACK_IMPLEMENTATION)
#ifndef mhfs_cl_track_c
#define mhfs_cl_track_c

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
    return blockvf_seek((blockvf *)pUserData, offset, (ma_seek_origin)origin) == MA_SUCCESS;
}

static void mhfs_cl_track_on_meta_drflac(void *pUserData, drflac_metadata *pMetadata)
{
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
            printf("%.*s\n", commentLength, comment);
        }
    }
    else if(pMetadata->type == DRFLAC_METADATA_BLOCK_TYPE_PICTURE)
    {
        printf("Picture mime: %.*s\n", pMetadata->data.picture.mimeLength, pMetadata->data.picture.mime);
    }
}


static ma_result mhfs_cl_track_on_read_ma_decoder(ma_decoder *pDecoder, void* bufferOut, size_t bytesToRead, size_t *bytesRead)
{
    return blockvf_read((blockvf*)pDecoder->pUserData, bufferOut, bytesToRead, bytesRead);
}

static size_t mhfs_cl_track_on_read_drflac(void* pUserData, void* bufferOut, size_t bytesToRead)
{
    size_t bytesRead;
    const ma_result res =  blockvf_read((blockvf*)pUserData, bufferOut, bytesToRead, &bytesRead);
    if(res == MA_SUCCESS) return bytesRead;
    return 0;
}

uint64_t mhfs_cl_track_totalPCMFrameCount(mhfs_cl_track *pTrack)
{
    uint64_t length = 0;
    ma_decoder_get_length_in_pcm_frames(&pTrack->decoder, &length);
    return length;
}

uint32_t mhfs_cl_track_sampleRate(const mhfs_cl_track *pTrack)
{
    //TODO fix me?
    return pTrack->decoder.outputSampleRate;
}

uint8_t mhfs_cl_track_bitsPerSample(const mhfs_cl_track *pTrack)
{
    //return pTrack->pFlac->bitsPerSample;
    //TODO fix me
    return 16;
}

uint8_t mhfs_cl_track_channels(const mhfs_cl_track *pTrack)
{
    //TODO fix me?
    //return pTrack->pFlac->channels;
    return pTrack->decoder.outputChannels;
}

void mhfs_cl_track_init(mhfs_cl_track *pTrack, const unsigned blocksize)
{
    pTrack->initialized = false;
    blockvf_init(&pTrack->vf, blocksize);
    pTrack->meta.initialized = false;
    pTrack->meta.album[0] = '\0';
    pTrack->meta.trackno[0] = '\0';
    pTrack->currentFrame = 0;
}

void mhfs_cl_track_deinit(mhfs_cl_track *pTrack)
{
    pTrack->meta.initialized = false;
    if(pTrack->initialized) ma_decoder_uninit(&pTrack->decoder);
    pTrack->initialized = false;
    blockvf_deinit(&pTrack->vf);
}

void *mhfs_cl_track_add_block(mhfs_cl_track *pTrack, const uint32_t block_start, const unsigned filesize)
{
    return blockvf_add_block(&pTrack->vf, block_start, filesize);
}

// mhfs_cl_track_read_pcm_frames_f32 will catch the error if we dont here
int mhfs_cl_track_seek_to_pcm_frame(mhfs_cl_track *pTrack, const uint32_t pcmFrameIndex)
{
    if(pTrack->initialized)
    {
        if(pcmFrameIndex >= mhfs_cl_track_totalPCMFrameCount(pTrack)) return 0;
    }
    pTrack->currentFrame = pcmFrameIndex;
    return 1;
}

uint32_t mhfs_cl_track_return_data_sizeof(void)
{
    return sizeof(mhfs_cl_track_return_data);
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

mhfs_cl_track *mhfs_cl_track_open(const unsigned blocksize)
{
    mhfs_cl_track *pTrack = malloc(sizeof(mhfs_cl_track));
    if(pTrack == NULL)
    {
        return NULL;
    }
    mhfs_cl_track_init(pTrack, blocksize);
    return pTrack;
}

void mhfs_cl_track_close(mhfs_cl_track *pTrack)
{
    mhfs_cl_track_deinit(pTrack);
    free(pTrack);
}

uint64_t mhfs_cl_track_currentFrame(const mhfs_cl_track *pTrack)
{
    return pTrack->currentFrame;
}

mhfs_cl_track_error mhfs_cl_track_read_pcm_frames_f32(mhfs_cl_track *pTrack, const uint32_t desired_pcm_frames, float32_t *outFloat, mhfs_cl_track_return_data *pReturnData)
{
    mhfs_cl_track_return_data rd;
    if(pReturnData == NULL) pReturnData = &rd;
    mhfs_cl_track_error retval = MHFS_CL_TRACK_SUCCESS;
    pTrack->vf.lastdata.code = BLOCKVF_SUCCESS;

    // initialize drflac if necessary
    if(!pTrack->initialized)
    {
        pTrack->vf.fileoffset = 0;

        // finally open the file
        ma_decoder_config config = ma_decoder_config_init(ma_format_f32, 0, 0);
        ma_result openRes = ma_decoder_init(&mhfs_cl_track_on_read_ma_decoder, &mhfs_cl_track_on_seek_ma_decoder, &pTrack->vf, &config, &pTrack->decoder);
        if((openRes != MA_SUCCESS) || (!BLOCKVF_OK(&pTrack->vf)))
        {
            if(!BLOCKVF_OK(&pTrack->vf))
            {
                if(openRes == MA_SUCCESS) ma_decoder_uninit(&pTrack->decoder);
                retval = mhfs_cl_track_error_from_blockvf_error(pTrack->vf.lastdata.code);
                pReturnData->needed_offset = pTrack->vf.lastdata.extradata;
                printf("%s: another error?\n", __func__);
            }
            else
            {
                retval = MHFS_CL_TRACK_GENERIC_ERROR;
                printf("%s: failed to open ma_decoder\n", __func__);
            }
            goto mhfs_cl_track_read_pcm_frames_f32_FAIL;
        }
        pTrack->initialized = true;

        if(!pTrack->meta.initialized)
        {
            unsigned savefileoffset = pTrack->vf.fileoffset;
            pTrack->vf.fileoffset = 0;
            drflac *pFlac = drflac_open_with_metadata(&mhfs_cl_track_on_read_drflac, &mhfs_cl_track_on_seek_drflac, &mhfs_cl_track_on_meta_drflac, &pTrack->vf, NULL);
            if(pFlac != NULL) drflac_close(pFlac);
            pTrack->vf.fileoffset = savefileoffset;
            pTrack->vf.lastdata.code = BLOCKVF_SUCCESS;
            pTrack->meta.initialized = true;
        }

        /*ma_format format;
        ma_uint32 channels;
        ma_uint32 sampleRate;
        ma_decoder tempdec;
        unsigned savefileoffset = pTrack->vf.fileoffset;
        pTrack->vf.fileoffset = 0;
        config = ma_decoder_config_init(ma_format_unknown, 0, 0);
        ma_decoder_init(&mhfs_cl_track_on_read_ma_decoder, &mhfs_cl_track_on_seek_ma_decoder, &pTrack->vf, &config, &tempdec);
        ma_data_source_get_data_format(tempdec.pBackend, &format, &channels, &sampleRate, NULL, 0);
        ma_decoder_uninit(&tempdec);
        pTrack->vf.fileoffset = savefileoffset;
        unsigned bps = 0;
        switch(format)
        {
            case ma_format_u8:
            bps = 8;
            break;
            case ma_format_s16:
            bps = 16;
            break;
            case ma_format_s24:
            bps = 24;
            break;
            case ma_format_s32:
            case ma_format_f32:
            bps = 32;
            break;
            default:
            bps = 0;
            break;
        }

        printf("channels %u, sampleRate %u bitdepth %u\n", channels, sampleRate, bps );*/
    }

    // seek to sample
    printf("seek to %u d_pcmframes %u\n", pTrack->currentFrame, desired_pcm_frames);
    const uint32_t currentPCMFrame32 = 0xFFFFFFFF;
    const bool seekres = MA_SUCCESS == ma_decoder_seek_to_pcm_frame(&pTrack->decoder, pTrack->currentFrame);
    if(!BLOCKVF_OK(&pTrack->vf))
    {
        retval = mhfs_cl_track_error_from_blockvf_error(pTrack->vf.lastdata.code);
        pReturnData->needed_offset = pTrack->vf.lastdata.extradata;
        printf("%s: failed seek_to_pcm_frame NOT OK current: %u desired: %u\n", __func__, currentPCMFrame32, pTrack->currentFrame);
        goto mhfs_cl_track_read_pcm_frames_f32_FAIL;
    }
    else if(!seekres)
    {
        printf("%s: seek failed current: %u desired: %u\n", __func__, currentPCMFrame32, pTrack->currentFrame);
        retval = MHFS_CL_TRACK_GENERIC_ERROR;
        goto mhfs_cl_track_read_pcm_frames_f32_FAIL;
    }

    // finally read
    uint64_t frames_decoded = 0;
    if(desired_pcm_frames != 0)
    {
        uint64_t toread = desired_pcm_frames;
        //uint64_t aframes;
        //ma_decoder_get_available_frames(&pTrack->decoder, &aframes);
        //if(aframes < toread) toread = aframes;
        printf("expected frames %"PRIu64"\n", toread);

        // decode to pcm
        ma_result decRes = ma_decoder_read_pcm_frames(&pTrack->decoder, outFloat, toread, &frames_decoded);
        if(!BLOCKVF_OK(&pTrack->vf))
        {
            retval = mhfs_cl_track_error_from_blockvf_error(pTrack->vf.lastdata.code);
            pReturnData->needed_offset = pTrack->vf.lastdata.extradata;
            printf("mhfs_cl_track_read_pcm_frames_f32_mem: failed read_pcm_frames_f32\n");
            goto mhfs_cl_track_read_pcm_frames_f32_FAIL;
        }
        if(decRes != MA_SUCCESS)
        {
            printf("mhfs_cl_track_read_pcm_frames_f32_mem: failed read_pcm_frames_f32(decode), ma_result %u\n", decRes);
            goto mhfs_cl_track_read_pcm_frames_f32_FAIL;
        }
        if(frames_decoded != desired_pcm_frames)
        {
            printf("mhfs_cl_track_read_pcm_frames_f32_mem: expected %u decoded %"PRIu64"\n", desired_pcm_frames, frames_decoded);
        }
        pTrack->currentFrame += frames_decoded;
    }

    printf("returning from pTrack->currentFrame: %u, totalFrames %"PRIu64" frames_decoded %"PRIu64" desired %u\n", pTrack->currentFrame, mhfs_cl_track_totalPCMFrameCount(pTrack), frames_decoded, desired_pcm_frames);
    pReturnData->frames_read = frames_decoded;
    return MHFS_CL_TRACK_SUCCESS;

mhfs_cl_track_read_pcm_frames_f32_FAIL:
    if(pTrack->initialized)
    {
        ma_decoder_uninit(&pTrack->decoder);
        pTrack->initialized = false;
    }
    return retval;
}

#endif  /* mhfs_cl_track_c */
#endif  /* MHFSCLTRACK_IMPLEMENTATION */
