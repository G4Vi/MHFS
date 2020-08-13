#define DR_FLAC_BUFFER_SIZE 262144
#define DR_FLAC_IMPLEMENTATION
#include "dr_flac.h"
typedef float float32_t;
typedef struct {
    const char *url;
    unsigned fileoffset;
} NetworkDrFlac;

#include <emscripten.h>
EM_JS(unsigned, do_fetch, (const char *url, unsigned start, unsigned end, void *bufferOut), {
  return Asyncify.handleAsync(async () => {
    out("waiting for a fetch");
    let request = new Request(UTF8ToString(url), {
            method :  'GET',
            headers : { 'Range': 'bytes='+start+'-'+end}      
        });
    const response = await fetch(request);
    out("got the fetch response");

    const thedata = await response.arrayBuffer();

    let dataHeap = new Uint8Array(Module.HEAPU8.buffer, bufferOut, thedata.byteLength);
    dataHeap.set(new Uint8Array(thedata));
    return dataHeap.byteLength;
  });
});

static size_t on_read_network(void* pUserData, void* bufferOut, size_t bytesToRead)
{
    //return fread(bufferOut, 1, bytesToRead, (FILE*)pUserData);
    NetworkDrFlac *nwdrflac = (NetworkDrFlac *)pUserData;
    uint8_t *bufdata = (uint8_t*)bufferOut;
    size_t bytesread = do_fetch(nwdrflac->url, nwdrflac->fileoffset, nwdrflac->fileoffset+bytesToRead-1, bufferOut);
    nwdrflac->fileoffset += bytesread;     
    //printf("bytesread %u, %c %c %c %c\n", bytesread, bufdata[0], bufdata[1], bufdata[2], bufdata[3]);
    return bytesread;
}
    

static drflac_bool32 on_seek_network(void* pUserData, int offset, drflac_seek_origin origin)
{
    DRFLAC_ASSERT(offset >= 0);  /* <-- Never seek backwards. */
    NetworkDrFlac *ndrflac = (NetworkDrFlac *)pUserData;
    if(origin == drflac_seek_origin_current)
    {
        ndrflac->fileoffset += offset;
    }
    else
    {
        ndrflac->fileoffset = offset;
    }
    return DRFLAC_FALSE;
}

void* get_audio(const char *url, const unsigned startSec, const unsigned countSec)
{
    NetworkDrFlac ndrflac = { url, 0};
    drflac *pFlac = drflac_open(&on_read_network, &on_seek_network, &ndrflac, NULL);
    if(pFlac == NULL)
    {
        printf("drflac: failed to open: %s\n", url);
        return NULL;
    }
    printf("drflac: opened successfully: %s\n", url);

    const unsigned start_pcm_frame = startSec * pFlac->sampleRate;
    unsigned desired_pcm_frames = (countSec * pFlac->sampleRate);    
    const unsigned frames_left = pFlac->totalPCMFrameCount - start_pcm_frame;
    if(frames_left < desired_pcm_frames) desired_pcm_frames = frames_left;
    
    void *retVal = NULL;
    
    // seek to start
    if(startSec != 0)
    {
        if(!drflac_seek_to_pcm_frame(pFlac, start_pcm_frame))
        {
            printf("drflac: failed to seek to start: %s\n", url);
            goto get_audio_EXIT;
        }
    }

    if(pFlac->bitsPerSample == 16)
    {
        // decode to pcm
        const unsigned framesize = sizeof(int16_t) * pFlac->channels;
        uint8_t *data = malloc(framesize*desired_pcm_frames);
        const uint64_t frames_decoded = drflac_read_pcm_frames_s16(pFlac, desired_pcm_frames, (int16_t*)(data));
        printf("drflac: %s expected %u decoded %u\n", url, desired_pcm_frames, frames_decoded);

        // fill result header
        /*
        result layout:
        [0] frames_decoded (8 bytes)
        [8] total_frames   (8 bytes)
        [16]sample_rate    (4 bytes)
        [20]bits_per_sample(1 byte)
        [21]num_channels   (1 byte)
        [22]reserved       (10 bytes)
        */        
        const unsigned result_header_size = 32;
        uint8_t *result = malloc(result_header_size+(sizeof(float32_t *) * pFlac->channels * frames_decoded)); 
        memcpy(result, &frames_decoded, sizeof(frames_decoded));
        memcpy(result+8,  &pFlac->totalPCMFrameCount, sizeof(pFlac->totalPCMFrameCount));
        memcpy(result+16, &pFlac->sampleRate, sizeof(pFlac->sampleRate));
        memcpy(result+20, &pFlac->bitsPerSample, sizeof(pFlac->bitsPerSample));
        memcpy(result+21, &pFlac->channels, sizeof(pFlac->channels));

        // convert to float
        for(uint64_t i = 0; i < frames_decoded; i++)
        {
            for(unsigned j = 0; j < pFlac->channels; j++)
            {
                uint16_t sample = *(uint16_t*)(data + (i * framesize) + (j*sizeof(int16_t*)));
                uint8_t *chanBase = result + result_header_size + (frames_decoded*sizeof(float32_t)*j);
                uint8_t *sampleDest = chanBase + (i*sizeof(float32_t));
                *(float32_t*)sampleDest = sample / 0x7FFF;             
            }
        }
        
        free(data);
        retVal = result;
    }
    else
    {
        printf("drflac: unsupports bits per sample: %s %u\n", url, pFlac->bitsPerSample );
        goto get_audio_EXIT;
    }

    
    

get_audio_EXIT:
    drflac_close(pFlac);
    return retVal;     
}
