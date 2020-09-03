#include <stdio.h>
#define DR_FLAC_BUFFER_SIZE 262144
#define DR_FLAC_NO_STDIO
#define DR_FLAC_NO_OGG
#define DR_FLAC_IMPLEMENTATION
#include "dr_flac.h"
#include <stdbool.h>

#define NETWORK_DR_FLAC_START_CACHE 1024
//#define NETWORK_DR_FLAC_START_CACHE (262144*2)

typedef float float32_t;
typedef struct {
    char *url;
    unsigned fileoffset;
    drflac *pFlac;
    unsigned filesize;
    uint8_t startData[NETWORK_DR_FLAC_START_CACHE];
    bool startOk;
    bool cancelled;
} NetworkDrFlac;

#include <emscripten.h>

EM_JS(unsigned, do_fetch, (const char *url, unsigned start, unsigned end, void *bufferOut, uint32_t *filesize), {  
    
    function abortableFetch(request) {
       const controller = new AbortController();
       const signal = controller.signal;    
     return {
       abort: () => controller.abort(),
       ready: fetch(request, {signal })
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
        
        let request = new Request(jsurl, {
            method :  'GET',
            headers : { 'Range': 'bytes='+start+'-'+end}      
        });
        
        
        try {
            DeclareGlobal('NetworkDrFlacFetch', abortableFetch(request));
            out('network_drflac: awaiting fetch: ' + jsurl);
            const response = await global.NetworkDrFlacFetch.ready;
            out('network_drflac: awaited fetch ' + jsurl);
            if(!response || !response.headers) {
                out("network_drflac: no response for fetch " + jsurl);
                global.NetworkDrFlacFetch = null;
                return 0;
            }
        
            // store the file size
            let contentrange = response.headers.get('Content-Range');
            let re = new RegExp('/([0-9]+)');
            let res = re.exec(contentrange);
            if(!res)
            {
                out("network_drflac: no Content-Range" + jsurl);
                global.NetworkDrFlacFetch = null;
                return 0;
            }          
            let size = Number(res[1]);
            let intSec = new Uint32Array(Module.HEAPU8.buffer, filesize, 1);
            intSec[0] = size;
        
            // store the data
            const thedata = await response.arrayBuffer();
            let dataHeap = new Uint8Array(Module.HEAPU8.buffer, bufferOut, thedata.byteLength);
            dataHeap.set(new Uint8Array(thedata));
    
            // return the number of bytes downloaded
            global.NetworkDrFlacFetch = null;
            return dataHeap.byteLength;
        } catch(error) {
            console.error(error + ' with ' + jsurl);
            global.NetworkDrFlacFetch = null;
            return 0;
        }
        
    });  
});

/*
EM_JS(unsigned, do_fetch, (const char *url, unsigned start, unsigned end, void *bufferOut, uint32_t *filesize), {  
    return do_fetch_js(url, start, end, bufferOut, filesize);
});
*/

static size_t on_read_network(void* pUserData, void* bufferOut, size_t bytesToRead)
{
    NetworkDrFlac *nwdrflac = (NetworkDrFlac *)pUserData;

    // try to avoid seeking too far    
    unsigned endoffset = nwdrflac->fileoffset+bytesToRead-1;
    // not sure if this is right
    if(nwdrflac->filesize > 0)
    {
        if(nwdrflac->fileoffset >= nwdrflac->filesize) return 0;       
        if(endoffset >= nwdrflac->filesize) endoffset = nwdrflac->filesize - 1;     
    }

    size_t bytesread;
    if((endoffset > (NETWORK_DR_FLAC_START_CACHE-1)) || !nwdrflac->startOk)
    {
        bytesread = do_fetch(nwdrflac->url, nwdrflac->fileoffset, endoffset, bufferOut, &nwdrflac->filesize);
    }
    else
    {
        bytesread = endoffset-nwdrflac->fileoffset+1;
        memcpy(bufferOut, &nwdrflac->startData[nwdrflac->fileoffset], bytesread);
    }     
    
    if(nwdrflac->cancelled)
    {
        printf("network_drflac: cancelled on_read_network\n");           
        return 0;
    }

    nwdrflac->fileoffset += bytesread;
    return bytesread;
}
    
/*
    Just keep track of the offset for reads
*/
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

void network_drflac_abort_current(NetworkDrFlac *ndrflac)
{
    int fetchexists = EM_ASM_INT({
        return global.NetworkDrFlacFetch ? 1 : 0;
    });
    if(!fetchexists) {
        printf("network_drflac: no cancel, no op active\n");
        return;
    }
    printf("network_drflac: cancelling\n");
    ndrflac->cancelled = true;
    EM_ASM({
        var global;
        if (typeof WorkerGlobalScope !== 'undefined' && self instanceof WorkerGlobalScope) {
           global = self;
        }
        else
        {
           global = window;
        }
        global.NetworkDrFlacFetch.abort();
        global.NetworkDrFlacFetch = null;
    });
}


void *network_drflac_open(const char *url)
{   
    printf("network_drflac: allocating %lu\n", sizeof(NetworkDrFlac));
    NetworkDrFlac *ndrflac = malloc(sizeof(NetworkDrFlac));
    unsigned urlbuflen = strlen(url)+1;
    ndrflac->url = malloc(urlbuflen);
    memcpy(ndrflac->url, url, urlbuflen);
    ndrflac->fileoffset = 0;
    ndrflac->filesize = 0;
    ndrflac->cancelled = false;
    ndrflac->startOk = false;
    ndrflac->pFlac = NULL;

    do {
        // optimization, cache the first NETWORK_DR_FLAC_START_CACHE bytes        
        printf("network_drflac: loading cache of : %s\n", ndrflac->url);
        size_t bytesread = do_fetch(ndrflac->url, 0, (NETWORK_DR_FLAC_START_CACHE-1), &ndrflac->startData, &ndrflac->filesize);
        ndrflac->startOk = (bytesread <= ndrflac->filesize) && (bytesread == NETWORK_DR_FLAC_START_CACHE);
        if(ndrflac->cancelled) break;

        // finally open the file
        drflac *pFlac = drflac_open(&on_read_network, &on_seek_network, ndrflac, NULL);
        if((pFlac == NULL) || ndrflac->cancelled) break;          
        
        ndrflac->pFlac = pFlac;
        printf("network_drflac: opened successfully: %s\n", ndrflac->url);
        return ndrflac;
    } while(0);

    printf("network_drflac: failed to open drflac or cancelled for %s\n", ndrflac->url);
    free(ndrflac->url);
    free(ndrflac);
    return NULL;
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
uint64_t network_drflac_read_pcm_frames_s16_to_wav(NetworkDrFlac *ndrflac, uint32_t start_pcm_frame, uint32_t desired_pcm_frames, uint8_t *outWav)
{
    drflac *pFlac = ndrflac->pFlac;
    const uint32_t currentPCMFrame32 = pFlac->currentPCMFrame;
    printf("network_drflac:  seeking to %u, currentframe %u\n", start_pcm_frame, currentPCMFrame32);
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
    printf("network_drflac: %s expected %u decoded %u\n", ndrflac->url, desired_pcm_frames, frames_decoded);
    if(ndrflac->cancelled)
    {
        printf("network_drflac: cancelled read_pcm_frames\n");
        ndrflac->cancelled = false;
        free(data);
        return 0;
    }

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
