#include <stdio.h>
#define DR_FLAC_BUFFER_SIZE 262144
#define DR_FLAC_IMPLEMENTATION
#include "dr_flac.h"

typedef float float32_t;
typedef struct {
    char *url;
    unsigned fileoffset;
    drflac *pFlac;
    unsigned filesize;
} NetworkDrFlac;

#include <emscripten.h>

EM_JS(unsigned, do_fetch, (const char *url, unsigned start, unsigned end, void *bufferOut, uint32_t *filesize), {  
 function abortableFetch(request, opts) {
    const controller = new AbortController();
    const signal = controller.signal;

  return {
    abort: () => controller.abort(),
    ready: fetch(request, { ...opts, signal })
  };
 }
var global;
 if (typeof WorkerGlobalScope !== 'undefined' && self instanceof WorkerGlobalScope) {

    global = self;
 }
 else
 {
    global = window;
 }

 function DeclareGlobal(name, value) {
    Object.defineProperty(global, name, {
        value: value,
        configurable: false,
        writable: true
    });
};
  
  let jsurl = UTF8ToString(url);
  return Asyncify.handleAsync(async () => {
    out("waiting for a fetch");
    let request = new Request(jsurl, {
            method :  'GET',
            headers : { 'Range': 'bytes='+start+'-'+end}      
        });
    //const response = await fetch(request);

    DeclareGlobal('NetworkDrFlacFetch', abortableFetch(request));
    const response = await global.NetworkDrFlacFetch.ready;
    out("got the fetch response");

    // store the file size
    let contentrange = response.headers.get('Content-Range');
    let re = new RegExp('/([0-9]+)');
    let res = re.exec(contentrange);
    if(!res) return 0;          
    let size = Number(res[1]);
    let intSec = new Uint32Array(Module.HEAPU8.buffer, filesize, 1);
    intSec[0] = size;

    const thedata = await response.arrayBuffer();
    let dataHeap = new Uint8Array(Module.HEAPU8.buffer, bufferOut, thedata.byteLength);
    dataHeap.set(new Uint8Array(thedata));
    return dataHeap.byteLength;
  });
});

EM_JS(void, stop_fetch, (void), {
    var global;
 if (typeof WorkerGlobalScope !== 'undefined' && self instanceof WorkerGlobalScope) {

    global = self;
 }
 else
 {
    global = window;
 }
 global.NetworkDrFlacFetch.abort();
});

static size_t on_read_network(void* pUserData, void* bufferOut, size_t bytesToRead)
{
    // try to avoid seeking too far
    NetworkDrFlac *nwdrflac = (NetworkDrFlac *)pUserData;
    
     unsigned endoffset = nwdrflac->fileoffset+bytesToRead-1;
    // not sure if this is right
    if(nwdrflac->filesize > 0)
    {
        if(nwdrflac->fileoffset >= nwdrflac->filesize) return 0;       
        if(endoffset >= nwdrflac->filesize) endoffset = nwdrflac->filesize - 1;     
    }

    uint8_t *bufdata = (uint8_t*)bufferOut;
    size_t bytesread = do_fetch(nwdrflac->url, nwdrflac->fileoffset, endoffset, bufferOut, &nwdrflac->filesize);
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
    if((ndrflac->filesize != 0) &&  (ndrflac->fileoffset >= ndrflac->filesize))
    {
        return DRFLAC_FALSE;
    }
    return DRFLAC_TRUE;
}

void* network_drflac_open(const char *url)
{
    printf("network_drflac: allocating\n");
    NetworkDrFlac *ndrflac = malloc(sizeof(ndrflac));
    unsigned urlbuflen = strlen(url)+1;
    ndrflac->url = malloc(urlbuflen);
    memcpy(ndrflac->url, url, urlbuflen);
    ndrflac->fileoffset = 0;
    ndrflac->filesize = 0;
    drflac *pFlac = drflac_open(&on_read_network, &on_seek_network, ndrflac, NULL);
    if(pFlac == NULL)
    {
        printf("network_drflac: failed to open drflac for %s\n", ndrflac->url);
        free(ndrflac->url);
        free(ndrflac);
        return NULL;
    }   
    ndrflac->pFlac = pFlac;
    printf("network_drflac: opened successfully: %s\n", ndrflac->url);
    return ndrflac;
}

uint64_t network_drflac_totalPCMFrameCount(const NetworkDrFlac *ndrflac)
{
    return ndrflac->pFlac->totalPCMFrameCount;
}

uint32_t network_drflac_sampleRate(const NetworkDrFlac *ndrflac)
{
    return ndrflac->pFlac->sampleRate;
}

uint8_t network_drflac_bitsPerSample(const NetworkDrFlac *ndrflac)
{
    return ndrflac->pFlac->bitsPerSample;
}

uint8_t network_drflac_channels(const NetworkDrFlac *ndrflac)
{
    return ndrflac->pFlac->channels;
}

/* returns of the number of bytes of the wav file */
uint64_t network_drflac_read_pcm_frames_s16_to_wav(const NetworkDrFlac *ndrflac, uint32_t start_pcm_frame, uint32_t desired_pcm_frames, uint8_t *outWav)
{
    drflac *pFlac = ndrflac->pFlac;
    printf("network_drflac:  seeking to %u, currentframe %u\n", start_pcm_frame, pFlac->currentPCMFrame);
    if(!drflac_seek_to_pcm_frame(ndrflac->pFlac, start_pcm_frame))
    {
        printf("network_drflac: failed to seek: %s\n", ndrflac->url);
        return 0;
    }
    if(pFlac->bitsPerSample != 16)
    {
        printf("network_drflac: bitspersample not 16: %u\n", pFlac->bitsPerSample);
        return 0;
    }
    printf("network_drflac: seek success. reading %u\n", desired_pcm_frames);

    // decode to pcm
    const unsigned framesize = sizeof(int16_t) * pFlac->channels;
    uint8_t *data = malloc(framesize*desired_pcm_frames);
    const uint32_t frames_decoded = drflac_read_pcm_frames_s16(pFlac, desired_pcm_frames, (int16_t*)(data));
    printf("drflac: %s expected %u decoded %u\n", ndrflac->url, desired_pcm_frames, frames_decoded);

    // encode to wav
    uint32_t audio_data_size = frames_decoded * pFlac->channels * (pFlac->bitsPerSample/8);        
    memcpy(&outWav[0], "RIFF", 4);
    uint32_t chunksize = audio_data_size + 36;
    memcpy(&outWav[4], &chunksize, 4);
    memcpy(&outWav[8], "WAVEfmt ", 8);
    uint32_t pcm = 16;
    memcpy(&outWav[16], &pcm, 4);
    uint16_t audioformat = 1;
    memcpy(&outWav[20], &audioformat, 2);
    uint16_t numchannels = pFlac->channels;
    memcpy(&outWav[22], &numchannels, 2);
    uint32_t samplerate = pFlac->sampleRate;
    memcpy(&outWav[24], &samplerate, 4);
    uint32_t byterate = samplerate * numchannels * (pFlac->bitsPerSample / 8);
    memcpy(&outWav[28], &byterate, 4);
    uint16_t blockalign = numchannels * (pFlac->bitsPerSample / 8);
    memcpy(&outWav[32], &blockalign, 2);
    uint16_t bitspersample = pFlac->bitsPerSample;
    memcpy(&outWav[34], &bitspersample, 2);
    memcpy(&outWav[36], "data", 4);
    memcpy(&outWav[40], &audio_data_size, 4);
    memcpy(&outWav[44], data, audio_data_size);        
    
    free(data);    
    return 44+audio_data_size;
}


void network_drflac_close(NetworkDrFlac *ndrflac)
{
    drflac_close(ndrflac->pFlac);
    free(ndrflac->url);
    free(ndrflac);
}

void* get_audio(const char *url, const unsigned startSec, const unsigned countSec)
{
    return NULL;
    /*
    const unsigned start_pcm_frame = startSec * pFlac->sampleRate;
    unsigned desired_pcm_frames = (countSec * pFlac->sampleRate);    
    const unsigned frames_left = pFlac->totalPCMFrameCount - start_pcm_frame;
    if(frames_left < desired_pcm_frames) desired_pcm_frames = frames_left;
    */
    drflac *pFlac = NULL;
    void *retVal = NULL;
    if(pFlac->bitsPerSample == 16)
    {
       

        unsigned frames_decoded = 0;
        uint8_t *data = NULL;
        

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
       // uint8_t *result = malloc(result_header_size+(sizeof(float32_t) * pFlac->channels * frames_decoded)); 
        uint8_t *result = malloc(result_header_size+(sizeof(int16_t) * pFlac->channels * frames_decoded)+44); 
        memcpy(result, &frames_decoded, sizeof(frames_decoded));
        memcpy(result+8,  &pFlac->totalPCMFrameCount, sizeof(pFlac->totalPCMFrameCount));
        memcpy(result+16, &pFlac->sampleRate, sizeof(pFlac->sampleRate));
        memcpy(result+20, &pFlac->bitsPerSample, sizeof(pFlac->bitsPerSample));
        memcpy(result+21, &pFlac->channels, sizeof(pFlac->channels));

        /*
        // convert to float
        for(uint64_t i = 0; i < frames_decoded; i++)
        {
            for(unsigned j = 0; j < pFlac->channels; j++)
            {
                uint8_t *sampleaddr = (uint8_t*)(data + (i * framesize) + (j*sizeof(int16_t)));
                //printf("samples addr = %p\n", sampleaddr);
                uint16_t sample = *(uint16_t*)sampleaddr;
                uint8_t *chanBase = result + result_header_size + (frames_decoded*sizeof(float32_t)*j);
                uint8_t *sampleDest = chanBase + (i*sizeof(float32_t));
                *(float32_t*)sampleDest = (float32_t)sample / 0x7FFF;
                if(*(float32_t*)sampleDest > 1)
                {
                    *(float32_t*)sampleDest = 1;
                }
                else if(*(float32_t*)sampleDest < -1)
                {
                    *(float32_t*)sampleDest = -1;
                }             
            }
        }
        */

        // convert to wav
        uint32_t audio_data_size = frames_decoded * pFlac->channels * (pFlac->bitsPerSample/8);        
        memcpy(32+&result[0], "RIFF", 4);
        uint32_t chunksize = audio_data_size + 36;
        memcpy(32+&result[4], &chunksize, 4);
        memcpy(32+&result[8], "WAVEfmt ", 8);
        uint32_t pcm = 16;
        memcpy(32+&result[16], &pcm, 4);
        uint16_t audioformat = 1;
        memcpy(32+&result[20], &audioformat, 2);
        uint16_t numchannels = pFlac->channels;
        memcpy(32+&result[22], &numchannels, 2);
        uint32_t samplerate = pFlac->sampleRate;
        memcpy(32+&result[24], &samplerate, 4);
        uint32_t byterate = samplerate * numchannels * (pFlac->bitsPerSample / 8);
        memcpy(32+&result[28], &byterate, 4);
        uint16_t blockalign = numchannels * (pFlac->bitsPerSample / 8);
        memcpy(32+&result[32], &blockalign, 2);
        uint16_t bitspersample = pFlac->bitsPerSample;
        memcpy(32+&result[34], &bitspersample, 2);
        memcpy(32+&result[36], "data", 4);
        memcpy(32+&result[40], &audio_data_size, 4);
        memcpy(32+&result[44], data, audio_data_size);        
        
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
