#include <stdio.h>
#include <emscripten.h>
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
    bool failed;
    unsigned signal_id;
    bool isrunning;
} NetworkDrFlac;



EM_JS(unsigned, do_fetch, (const char *url, unsigned start, unsigned end, void *bufferOut, uint32_t *filesize, unsigned sigid), {   
    
    return Asyncify.handleAsync(async () => {
        let jsurl = UTF8ToString(url);

        const setFileSize = function(contentrange) {
            let re = new RegExp('/([0-9]+)');
            let res = re.exec(contentrange);
            if(!res) return;
            let size = Number(res[1]);
            let intSec = new Uint32Array(Module.HEAPU8.buffer, filesize, 1);
            intSec[0] = size;
            return true;
        };

        function makeRequest (method, url, signal) {
        return new Promise(function (resolve, reject) {
            var xhr = new XMLHttpRequest();
            
            const handler = function(){
                console.log('ABORT XHR');
                xhr.abort();
            };
            
            signal.addEventListener('abort', handler);            

            xhr.open(method, url);
            xhr.responseType = 'arraybuffer';
            xhr.setRequestHeader('Range', 'bytes='+start+'-'+end);

            xhr.onreadystatechange = function() {
                if(xhr.readyState == xhr.HEADERS_RECEIVED) {
                    if(!setFileSize(xhr.getResponseHeader('Content-Range'))) xhr.abort();
                }
            };

            xhr.onload = function () {
                signal.removeEventListener('abort', handler);
                if (this.status >= 200 && this.status < 300) {
                    console.log('xhr success');
                    resolve(xhr.response);
                } else {
                    console.log('xhr fail');                   
                    reject({
                        status: this.status,
                        statusText: xhr.statusText
                    });
                }
            };
            xhr.onerror = function () {
                console.log('xhr on error');
                signal.removeEventListener('abort', handler);
                reject({
                    status: this.status,
                    statusText: xhr.statusText
                });
            };
            
            xhr.onabort = function() {
                console.log('xhr abort');
                signal.removeEventListener('abort', handler);
                reject({
                    status: this.status,
                    statusText: xhr.statusText
                });
            };

            xhr.send();
            console.log('sending xhr');
        });
        }
        
        
        try {
            let signal = Module.GetJSObject(sigid)();
            const thedata = await makeRequest('GET', jsurl, signal);
            console.log('got thedata');
            /*
            fetch way
            let request = new Request(jsurl, {
            method :  'GET',
            headers : { 'Range': 'bytes='+start+'-'+end}      
            });
            let signal = Module.GetJSObject(sigid)();
            out('network_drflac: awaiting fetch: ' + jsurl);
            const response = await fetch(request, {signal});
            out('network_drflac: awaited fetch ' + jsurl);
            if(!response || !response.headers) {
                out("network_drflac: no response for fetch " + jsurl);
                let abc = await fetch(request, {signal});                 
                return 0;
            }
        
            // store the file size
            let contentrange = response.headers.get('Content-Range');
            let re = new RegExp('/([0-9]+)');
            let res = re.exec(contentrange);
            if(!res)
            {
                out("network_drflac: no Content-Range" + jsurl);                
                return 0;
            }          
            let size = Number(res[1]);           

            let intSec = new Uint32Array(Module.HEAPU8.buffer, filesize, 1);
            intSec[0] = size;
            // store the data
            const thedata = await response.arrayBuffer();
            */
        
            
            let dataHeap = new Uint8Array(Module.HEAPU8.buffer, bufferOut, thedata.byteLength);
            dataHeap.set(new Uint8Array(thedata));
    
            // return the number of bytes downloaded
            console.log('network_drflac: fetch completed, returning');
            return dataHeap.byteLength;
        } catch(error) {
            console.error(error + ' with ' + jsurl);            
            return 0;
        }
        
    });  
});

static size_t on_read_network(void* pUserData, void* bufferOut, size_t bytesToRead)
{
    NetworkDrFlac *nwdrflac = (NetworkDrFlac *)pUserData;
    if(nwdrflac->failed)
    {
        printf("network_drflac: on_read_network called when failed\n");           
        return 0;
    }    

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
        bytesread = do_fetch(nwdrflac->url, nwdrflac->fileoffset, endoffset, bufferOut, &nwdrflac->filesize, nwdrflac->signal_id);       
        if(bytesread == 0) nwdrflac->failed = true;
    }
    else
    {
        bytesread = endoffset-nwdrflac->fileoffset+1;
        memcpy(bufferOut, &nwdrflac->startData[nwdrflac->fileoffset], bytesread);
    }     
    
    if(nwdrflac->failed)
    {
        printf("network_drflac: failed on_read_network\n");           
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
    if(ndrflac->failed)
    {
        return DRFLAC_FALSE;
    }

    unsigned tempoffset = ndrflac->fileoffset;
    if(origin == drflac_seek_origin_current)
    {
        tempoffset += offset;
    }
    else
    {
        tempoffset = offset;
    }
    if((ndrflac->filesize != 0) &&  (tempoffset >= ndrflac->filesize))
    {
        return DRFLAC_FALSE;
    }

    ndrflac->fileoffset = tempoffset;
    return DRFLAC_TRUE;
}

void network_drflac_set_cancel(NetworkDrFlac *ndrflac)
{
    if(ndrflac->isrunning) ndrflac->failed = true;
}

void *network_drflac_open(const char *url, const unsigned sigid)
{   
    printf("network_drflac: allocating %lu\n", sizeof(NetworkDrFlac));
    NetworkDrFlac *ndrflac = malloc(sizeof(NetworkDrFlac));
    unsigned urlbuflen = strlen(url)+1;
    ndrflac->url = malloc(urlbuflen);
    memcpy(ndrflac->url, url, urlbuflen);
    ndrflac->fileoffset = 0;
    ndrflac->filesize = 0;
    ndrflac->failed = false;
    ndrflac->startOk = false;
    ndrflac->pFlac = NULL;
    ndrflac->signal_id = sigid;

   

    EM_ASM({
        Module.GetJSObject($0)().addEventListener('abort', function(){
            console.log('network_drflac: setting cancel');
            Module.ccall('network_drflac_set_cancel', null, ["number"], [$1]);
        });        
    }, sigid, ndrflac);

    do {
        ndrflac->isrunning = true;

        // optimization, cache the first NETWORK_DR_FLAC_START_CACHE bytes        
        printf("network_drflac: loading cache of : %s\n", ndrflac->url);
        size_t bytesread = do_fetch(ndrflac->url, 0, (NETWORK_DR_FLAC_START_CACHE-1), &ndrflac->startData, &ndrflac->filesize, ndrflac->signal_id);
        ndrflac->startOk = (bytesread <= ndrflac->filesize) && (bytesread == NETWORK_DR_FLAC_START_CACHE);
        if(ndrflac->failed) break;

        // finally open the file
        drflac *pFlac = drflac_open(&on_read_network, &on_seek_network, ndrflac, NULL);
        if((pFlac == NULL) || ndrflac->failed) break;          
        
        ndrflac->pFlac = pFlac;
        printf("network_drflac: opened successfully: %s\n", ndrflac->url);
        
        ndrflac->isrunning = false;
        return ndrflac;
    } while(0);

    printf("network_drflac: failed to open drflac or failed for %s\n", ndrflac->url);
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
    if(!drflac_seek_to_pcm_frame(ndrflac->pFlac, start_pcm_frame) || ndrflac->failed)
    {
        printf("network_drflac: failed seek_to_pcm_frame\n");
        ndrflac->failed = false;        
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
    ndrflac->isrunning = true;
    const uint32_t frames_decoded = drflac_read_pcm_frames_s16(pFlac, desired_pcm_frames, (int16_t*)(data));
    ndrflac->isrunning = false;
    printf("network_drflac: %s expected %u decoded %u\n", ndrflac->url, desired_pcm_frames, frames_decoded);
    if(ndrflac->failed)
    {
        printf("network_drflac: failed read_pcm_frames\n");
        ndrflac->failed = false;
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
