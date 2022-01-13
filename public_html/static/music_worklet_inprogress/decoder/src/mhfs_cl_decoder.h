#pragma once
typedef struct {
    unsigned outputSampleRate;
    unsigned outputChannels;
    bool has_madc;
    ma_data_converter madc;
} mhfs_cl_decoder;

#ifdef __EMSCRIPTEN__
#include <emscripten.h>
#define LIBEXPORT EMSCRIPTEN_KEEPALIVE
#else
#define LIBEXPORT
#endif


LIBEXPORT mhfs_cl_decoder *mhfs_cl_decoder_create(const unsigned outputSampleRate, const unsigned outputChannels);
LIBEXPORT mhfs_cl_track_error mhfs_cl_decoder_read_pcm_frames_f32_deinterleaved(mhfs_cl_decoder *mhfs_d, mhfs_cl_track *pTrack, const uint32_t desired_pcm_frames, float32_t *tempData, float32_t *outFloat, mhfs_cl_track_return_data *pReturnData);
LIBEXPORT void mhfs_cl_decoder_close(mhfs_cl_decoder *mhfs_d);
LIBEXPORT void mhfs_cl_decoder_flush(mhfs_cl_decoder *mhfs_d);

#if defined(MHFSCLDECODER_IMPLEMENTATION)
#ifndef mhfs_cl_decoder_c
#define mhfs_cl_decoder_c

mhfs_cl_decoder *mhfs_cl_decoder_create(const unsigned outputSampleRate, const unsigned outputChannels)
{
    mhfs_cl_decoder *mhfs_d = malloc(sizeof(mhfs_cl_decoder));
    if(mhfs_d == NULL) return NULL;
    mhfs_d->outputSampleRate = outputSampleRate;
    mhfs_d->outputChannels = outputChannels;
    mhfs_d->has_madc = false;
    return mhfs_d;    
}

void mhfs_cl_decoder_close(mhfs_cl_decoder *mhfs_d)
{
    if(mhfs_d->has_madc)  ma_data_converter_uninit(&mhfs_d->madc, NULL);
    free(mhfs_d);
}

void mhfs_cl_decoder_flush(mhfs_cl_decoder *mhfs_d)
{
    if(mhfs_d->has_madc)
    {
        ma_data_converter_uninit(&mhfs_d->madc, NULL);
        mhfs_d->has_madc = false;
    }
}

mhfs_cl_track_error mhfs_cl_decoder_read_pcm_frames_f32(mhfs_cl_decoder *mhfs_d, mhfs_cl_track *pTrack, const uint32_t desired_pcm_frames, float32_t *outFloat, mhfs_cl_track_return_data *pReturnData)
{
    // open the decoder if needed
    if(!pTrack->dec_initialized)
    {
        printf("force open ma_decoder (not initialized)\n");
        const mhfs_cl_track_error openCode = mhfs_cl_track_read_pcm_frames_f32(pTrack, 0, NULL, pReturnData);
        if(openCode != MHFS_CL_TRACK_SUCCESS)
        {
            return openCode;
        }
    }
    
    // fast path, no resampling / channel conversion needed
    if((mhfs_cl_track_sampleRate(pTrack) == mhfs_d->outputSampleRate) && (mhfs_cl_track_channels(pTrack) != mhfs_d->outputChannels))
    {
        return mhfs_cl_track_read_pcm_frames_f32(pTrack, desired_pcm_frames, outFloat, pReturnData);
    }
    else
    {
        // initialize the data converter
        if(mhfs_d->has_madc && (mhfs_d->madc.channelsIn != mhfs_cl_track_channels(pTrack)))
        {
            ma_data_converter_uninit(&mhfs_d->madc, NULL);
            mhfs_d->has_madc = false;            
        }
        if(!mhfs_d->has_madc)
        {
            ma_data_converter_config config = ma_data_converter_config_init(ma_format_f32, ma_format_f32, mhfs_cl_track_channels(pTrack), mhfs_d->outputChannels, mhfs_cl_track_sampleRate(pTrack), mhfs_d->outputSampleRate);
            if(ma_data_converter_init(&config, NULL, &mhfs_d->madc) != MA_SUCCESS)
            {
                printf("failed to init data converter\n");
                return MHFS_CL_TRACK_GENERIC_ERROR;
            }
            mhfs_d->has_madc = true;
            printf("success init data converter\n"); 
        }
        else if(mhfs_d->madc.sampleRateIn != mhfs_cl_track_sampleRate(pTrack))
        {
            if(ma_data_converter_set_rate(&mhfs_d->madc, mhfs_cl_track_sampleRate(pTrack), mhfs_d->outputSampleRate) != MA_SUCCESS)
            {
                printf("failed to change data converter samplerate\n");
                return MHFS_CL_TRACK_GENERIC_ERROR;
            }
        }

        // decode
        uint64_t dec_frames_req;
        if(ma_data_converter_get_required_input_frame_count(&mhfs_d->madc, desired_pcm_frames, &dec_frames_req) != MA_SUCCESS)
        {
            printf("failed to get data converter input frame count\n");
            return MHFS_CL_TRACK_GENERIC_ERROR;
        }
        float32_t *tempOut = malloc(dec_frames_req * sizeof(float32_t)*mhfs_cl_track_channels(pTrack));
        const mhfs_cl_track_error readCode = mhfs_cl_track_read_pcm_frames_f32(pTrack, dec_frames_req, tempOut, pReturnData);
        if((readCode != MHFS_CL_TRACK_SUCCESS) || (pReturnData->frames_read == 0))
        {
            free(tempOut);
            return readCode;
        }
        uint64_t decoded_frames = pReturnData->frames_read;

        // resample
        uint64_t frameCountOut = desired_pcm_frames;       
        ma_result result = ma_data_converter_process_pcm_frames(&mhfs_d->madc, tempOut, &decoded_frames, outFloat, &frameCountOut);
        free(tempOut);
        if(result != MA_SUCCESS)
        {
            printf("resample failed\n");
            return MHFS_CL_TRACK_GENERIC_ERROR;
        }
        pReturnData->frames_read = frameCountOut;
        return MHFS_CL_TRACK_SUCCESS;
    }
}

mhfs_cl_track_error mhfs_cl_decoder_read_pcm_frames_f32_deinterleaved(mhfs_cl_decoder *mhfs_d, mhfs_cl_track *pTrack, const uint32_t desired_pcm_frames, float32_t *tempData, float32_t *outFloat, mhfs_cl_track_return_data *pReturnData)
{
    const mhfs_cl_track_error code = mhfs_cl_decoder_read_pcm_frames_f32(mhfs_d, pTrack, desired_pcm_frames, tempData, pReturnData);
    if(code == MHFS_CL_TRACK_SUCCESS)
    {
        for(unsigned i = 0; i < pReturnData->frames_read; i++)
        {
            for(unsigned j = 0; j < mhfs_d->outputChannels; j++)
            {
                unsigned chanIndex = j*pReturnData->frames_read;
                float32_t sample = tempData[(i*mhfs_d->outputChannels) + j];
                outFloat[chanIndex+i] = sample;
            }
        }
    }
    return code;
}

#endif  /* mhfs_cl_decoder_c */
#endif  /* MHFSCLDECODER_IMPLEMENTATION */
