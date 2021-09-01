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
LIBEXPORT uint64_t mhfs_decoder_read_pcm_frames_f32_deinterleaved(mhfs_decoder *mhfs_d, NetworkDrFlac *ndrflac, const uint32_t desired_pcm_frames, float32_t *outFloat);
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
    if(mhfs_d->has_madc)  ma_data_converter_uninit(&mhfs_d->madc);
    free(mhfs_d);
}

void mhfs_decoder_flush(mhfs_decoder *mhfs_d)
{
    if(mhfs_d->has_madc)
    {
        ma_data_converter_uninit(&mhfs_d->madc);
        mhfs_d->has_madc = false;
    }
}

uint64_t mhfs_decoder_read_pcm_frames_f32(mhfs_decoder *mhfs_d, NetworkDrFlac *ndrflac, const uint32_t desired_pcm_frames, float32_t *outFloat)
{
    // open the decoder if needed
    if(network_drflac_open_drflac(ndrflac) != NDRFLAC_SUCCESS)
    {
        return 0;
    }
    
    // fast path, no resampling / channel conversion needed
    if((ndrflac->pFlac->sampleRate == mhfs_d->outputSampleRate) && (ndrflac->pFlac->channels != mhfs_d->outputChannels))
    {
        uint64_t decoded_frames = network_drflac_read_pcm_frames_f32(ndrflac, desired_pcm_frames, outFloat);
        if(decoded_frames == 0) return 0;
        return decoded_frames;
    }
    else
    {
        // initialize the data converter
        if(mhfs_d->has_madc && (mhfs_d->madc.config.channelsIn != ndrflac->pFlac->channels))
        {
            ma_data_converter_uninit(&mhfs_d->madc);
            mhfs_d->has_madc = false;            
        }
        if(!mhfs_d->has_madc)
        {
            ma_data_converter_config config = ma_data_converter_config_init(ma_format_f32, ma_format_f32, ndrflac->pFlac->channels, mhfs_d->outputChannels, ndrflac->pFlac->sampleRate, mhfs_d->outputSampleRate);           
            if(ma_data_converter_init(&config, &mhfs_d->madc) != MA_SUCCESS)
            {
                printf("failed to init data converter\n");
                return 0;
            }
            mhfs_d->has_madc = true;
            printf("success init data converter\n"); 
        }
        else if(mhfs_d->madc.config.sampleRateIn != ndrflac->pFlac->sampleRate)
        {
            if(ma_data_converter_set_rate(&mhfs_d->madc, ndrflac->pFlac->sampleRate, mhfs_d->outputSampleRate) != MA_SUCCESS)
            {
                printf("failed to change data converter samplerate\n");
                return 0;
            }
        }

        // decode
        const uint64_t dec_frames_req = ma_data_converter_get_required_input_frame_count(&mhfs_d->madc, desired_pcm_frames);
        float32_t *tempOut = malloc(dec_frames_req * sizeof(float32_t)*ndrflac->pFlac->channels);
        uint64_t decoded_frames = network_drflac_read_pcm_frames_f32(ndrflac, dec_frames_req, tempOut);
        if(decoded_frames == 0)
        {
           free(tempOut);
           return 0;
        }        

        // resample
        uint64_t frameCountOut = desired_pcm_frames;       
        ma_result result = ma_data_converter_process_pcm_frames(&mhfs_d->madc, tempOut, &decoded_frames, outFloat, &frameCountOut);
        free(tempOut);
        if(result != MA_SUCCESS)
        {
            printf("resample failed\n");
            return 0;
        }
        return frameCountOut;
    }
}

uint64_t mhfs_decoder_read_pcm_frames_f32_deinterleaved(mhfs_decoder *mhfs_d, NetworkDrFlac *ndrflac, const uint32_t desired_pcm_frames, float32_t *outFloat)
{
    float32_t *data = malloc(desired_pcm_frames * sizeof(float32_t)*mhfs_d->outputChannels);
    const uint64_t frames = mhfs_decoder_read_pcm_frames_f32(mhfs_d, ndrflac, desired_pcm_frames, data);    
    for(unsigned i = 0; i < frames; i++)
    {
        for(unsigned j = 0; j < mhfs_d->outputChannels; j++)
        {            
            unsigned chanIndex = j*frames;
            float32_t sample = data[(i*mhfs_d->outputChannels) + j];
            outFloat[chanIndex+i] = sample;
        }
    }
    free(data);
    return frames;
}

#endif  /* mhfs_decoder_c */
#endif  /* MHFSDECODER_IMPLEMENTATION */