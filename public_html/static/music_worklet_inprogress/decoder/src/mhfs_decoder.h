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
LIBEXPORT NetworkDrFlac_Err_Vals mhfs_decoder_read_pcm_frames_f32_deinterleaved(mhfs_decoder *mhfs_d, NetworkDrFlac *ndrflac, const uint32_t desired_pcm_frames, float32_t *outFloat, NetworkDrFlac_ReturnData *pReturnData);
LIBEXPORT void mhfs_decoder_close(mhfs_decoder *mhfs_d);
LIBEXPORT void mhfs_decoder_flush(mhfs_decoder *mhfs_d);

#if defined(MHFSDECODER_IMPLEMENTATION) || defined(MHFSDECODER_IMPLEMENTATION)
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

void mhfs_decoder_close(mhfs_decoder *mhfs_d)
{
    if(mhfs_d->has_madc)  ma_data_converter_uninit(&mhfs_d->madc, NULL);
    free(mhfs_d);
}

void mhfs_decoder_flush(mhfs_decoder *mhfs_d)
{
    if(mhfs_d->has_madc)
    {
        ma_data_converter_uninit(&mhfs_d->madc, NULL);
        mhfs_d->has_madc = false;
    }
}

NetworkDrFlac_Err_Vals mhfs_decoder_read_pcm_frames_f32(mhfs_decoder *mhfs_d, NetworkDrFlac *ndrflac, const uint32_t desired_pcm_frames, float32_t *outFloat, NetworkDrFlac_ReturnData *pReturnData)
{
    // open the decoder if needed
    const NetworkDrFlac_Err_Vals openCode = network_drflac_read_pcm_frames_f32(ndrflac, 0, NULL, pReturnData);
    if(openCode != NDRFLAC_SUCCESS)
    {
        return openCode;
    }
    
    // fast path, no resampling / channel conversion needed
    if((network_drflac_sampleRate(ndrflac) == mhfs_d->outputSampleRate) && (network_drflac_channels(ndrflac) != mhfs_d->outputChannels))
    {
        return network_drflac_read_pcm_frames_f32(ndrflac, desired_pcm_frames, outFloat, pReturnData);
    }
    else
    {
        // initialize the data converter
        if(mhfs_d->has_madc && (mhfs_d->madc.channelsIn != network_drflac_channels(ndrflac)))
        {
            ma_data_converter_uninit(&mhfs_d->madc, NULL);
            mhfs_d->has_madc = false;            
        }
        if(!mhfs_d->has_madc)
        {
            ma_data_converter_config config = ma_data_converter_config_init(ma_format_f32, ma_format_f32, network_drflac_channels(ndrflac), mhfs_d->outputChannels, network_drflac_sampleRate(ndrflac), mhfs_d->outputSampleRate);           
            if(ma_data_converter_init(&config, NULL, &mhfs_d->madc) != MA_SUCCESS)
            {
                printf("failed to init data converter\n");
                return NDRFLAC_GENERIC_ERROR;
            }
            mhfs_d->has_madc = true;
            printf("success init data converter\n"); 
        }
        else if(mhfs_d->madc.sampleRateIn != network_drflac_sampleRate(ndrflac))
        {
            if(ma_data_converter_set_rate(&mhfs_d->madc, network_drflac_sampleRate(ndrflac), mhfs_d->outputSampleRate) != MA_SUCCESS)
            {
                printf("failed to change data converter samplerate\n");
                return NDRFLAC_GENERIC_ERROR;
            }
        }

        // decode
        uint64_t dec_frames_req;
        if(ma_data_converter_get_required_input_frame_count(&mhfs_d->madc, desired_pcm_frames, &dec_frames_req) != MA_SUCCESS)
        {
            printf("failed to get data converter input frame count\n");
            return NDRFLAC_GENERIC_ERROR;
        }
        float32_t *tempOut = malloc(dec_frames_req * sizeof(float32_t)*network_drflac_channels(ndrflac));
        const NetworkDrFlac_Err_Vals readCode = network_drflac_read_pcm_frames_f32(ndrflac, dec_frames_req, tempOut, pReturnData);
        if((readCode != NDRFLAC_SUCCESS) || (pReturnData->frames_read == 0))
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
            return NDRFLAC_GENERIC_ERROR;
        }
        pReturnData->frames_read = frameCountOut;
        return NDRFLAC_SUCCESS;
    }
}

NetworkDrFlac_Err_Vals mhfs_decoder_read_pcm_frames_f32_deinterleaved(mhfs_decoder *mhfs_d, NetworkDrFlac *ndrflac, const uint32_t desired_pcm_frames, float32_t *outFloat, NetworkDrFlac_ReturnData *pReturnData)
{
    float32_t *data = malloc(desired_pcm_frames * sizeof(float32_t)*mhfs_d->outputChannels);
    const NetworkDrFlac_Err_Vals code = mhfs_decoder_read_pcm_frames_f32(mhfs_d, ndrflac, desired_pcm_frames, data, pReturnData);
    if(code == NDRFLAC_SUCCESS)
    {
        for(unsigned i = 0; i < pReturnData->frames_read; i++)
        {
            for(unsigned j = 0; j < mhfs_d->outputChannels; j++)
            {
                unsigned chanIndex = j*pReturnData->frames_read;
                float32_t sample = data[(i*mhfs_d->outputChannels) + j];
                outFloat[chanIndex+i] = sample;
            }
        }
    }

    free(data);
    return code;
}

#endif  /* mhfs_decoder_c */
#endif  /* MHFSDECODER_IMPLEMENTATION */