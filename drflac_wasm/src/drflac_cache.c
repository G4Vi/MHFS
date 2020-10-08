#include <stdio.h>
#include <emscripten.h>
#define DR_FLAC_BUFFER_SIZE (4096 * 16)
#define DR_FLAC_NO_STDIO
#define DR_FLAC_NO_OGG
#define DR_FLAC_IMPLEMENTATION
#include "dr_flac.h"
#include <stdbool.h>

typedef float float32_t;

#define min(a,b) \
   ({ __typeof__ (a) _a = (a); \
       __typeof__ (b) _b = (b); \
     _a < _b ? _a : _b; })

typedef struct {
    const uint32_t *bufs;
    const size_t *bufsizes;
    const unsigned count;
    const unsigned start_offset;

    // blocks
    const unsigned blocksize;
} NetworkDrFlacMem;

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

void *network_drflac_create_error(void)
{
    NetworkDrFlac_Error *ndrerr = malloc(sizeof(NetworkDrFlac_Error));
    ndrerr->code = NDRFLAC_SUCCESS;
    return ndrerr;
}

void network_drflac_free_error(NetworkDrFlac_Error *ndrerr)
{
    free(ndrerr);
}

uint32_t network_drflac_error_code(const NetworkDrFlac_Error *ndrerr)
{
    return ndrerr->code;
}

uint32_t network_drflac_extra_data(const NetworkDrFlac_Error *ndrerr)
{
    return ndrerr->extradata;
}

typedef struct {
    unsigned fileoffset;
    unsigned filesize;
    drflac *pFlac;   
    NetworkDrFlac_Error *error;
    const NetworkDrFlacMem *pMem;   
} NetworkDrFlac;

#define NDRFLAC_OK(xndrflac) ((xndrflac)->error->code == NDRFLAC_SUCCESS)

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

void network_drflac_close(NetworkDrFlac *ndrflac)
{
    drflac_close(ndrflac->pFlac);
    free(ndrflac);
}

static drflac_bool32 on_seek_mem(void* pUserData, int offset, drflac_seek_origin origin)
{
    NetworkDrFlac *ndrflac = (NetworkDrFlac *)pUserData;
    if(!NDRFLAC_OK(ndrflac))
    {
        printf("on_seek_mem: already failed, breaking %d %u\n", offset, origin);
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
        printf("network_drflac: seek past end of stream\n");        
        return DRFLAC_FALSE;
    }

    printf("seek update fileoffset %u\n",tempoffset );
    ndrflac->fileoffset = tempoffset;
    return DRFLAC_TRUE;
}

typedef struct memrange {
    uint32_t start;
    struct memrange *next;
} memrange;

static bool has_necessary_blocks(NetworkDrFlac *ndrflac, const size_t bytesToRead)
{    
    const unsigned blocksize = ndrflac->pMem->blocksize;
    memrange *block;

    memrange *startblock = NULL;
    for(; block != NULL; block = block->next)
    {
        if(block->start <= ndrflac->fileoffset)
        {
            unsigned nextblock = block->start + blocksize;
            if(ndrflac->fileoffset < nextblock)
            {
                startblock = block;
                break;
            }
        }
        else
        {
            // block starts past what we need, there must be a gap need more mem
            break;
        }        
    }
    if(startblock == NULL)
    {
        printf("NEED MORE MEM\n");
        ndrflac->error->code = NDRFLAC_MEM_NEED_MORE;
        ndrflac->error->extradata = ndrflac->fileoffset;
        return false;   
    }

    
    unsigned last_needed_byte = ndrflac->fileoffset + bytesToRead -1; 
    unsigned last_next = startblock->start;
    bool foundEnd = false;
    for(block = startblock; block != NULL; block->next)
    {
        // there's a gap
        if(block->start > last_next)
        {
            break;
        }
        unsigned nextblock = block->start + blocksize;
        if(last_needed_byte < nextblock)
        {
            foundEnd = true;
            break;
        }
        last_next = nextblock;        
    }
    if(!foundEnd)
    {
        printf("NEED MORE MEM\n");
        ndrflac->error->code = NDRFLAC_MEM_NEED_MORE;
        ndrflac->error->extradata = last_next;
        return false;   
    }
    return true;
} 

static size_t on_read_mem(void* pUserData, void* bufferOut, size_t bytesToRead)
{
    const size_t ogbtr = bytesToRead;
    NetworkDrFlac *nwdrflac = (NetworkDrFlac *)pUserData;
    if(!NDRFLAC_OK(nwdrflac))
    {
        printf("on_read_mem: already failed\n");
        return 0;
    }
    unsigned endoffset = nwdrflac->fileoffset+bytesToRead-1;

    // adjust params based on file size 
    if(nwdrflac->filesize > 0)
    {
        if(nwdrflac->fileoffset >= nwdrflac->filesize)
        {
            printf("network_drflac: fileoffset >= filesize %u %u\n", nwdrflac->fileoffset, nwdrflac->filesize);
           // nwdrflac->error->code =  NDRFLAC_GENERIC_ERROR;
            return 0;
        }       
        if(endoffset >= nwdrflac->filesize)
        {
            unsigned newendoffset = nwdrflac->filesize - 1;
            printf("network_drflac: truncating endoffset from %u to %u\n", endoffset, newendoffset);
            endoffset = newendoffset;
            bytesToRead = endoffset - nwdrflac->fileoffset + 1;            
        }     
    }

    // nothing to read, do nothing
    if(bytesToRead == 0)
    {
        printf("network_drflac: reached end of stream\n");
        return 0;
    }
 
    const NetworkDrFlacMem *pMem = nwdrflac->pMem;    
    const unsigned src_offset = nwdrflac->fileoffset;

    /*
    if(!has_necessary_blocks(nwdrflac, bytesToRead)
    {
        return 0;
    }
    */
    
    unsigned copyable = pMem->bufsizes[0] - src_offset;        
    if((copyable < bytesToRead) || (src_offset >= pMem->bufsizes[0]))
    {
        printf("NEED MORE MEM\n");
        nwdrflac->error->code = NDRFLAC_MEM_NEED_MORE;
        return 0;   
    }
    

    uint8_t  *src = (uint8_t*)(pMem->bufs[0]);
    src += src_offset;
    printf("memcpy %u %u %u srcoffset %u filesize %u buffered %u\n", bufferOut, src, bytesToRead, src_offset, nwdrflac->filesize, pMem->bufsizes[0]);
    memcpy(bufferOut, src, bytesToRead);

    nwdrflac->fileoffset += bytesToRead;
    return bytesToRead;
}
    
void *network_drflac_open_mem(const size_t filesize, const void *mem, const size_t memsize, NetworkDrFlac_Error *error)
{   
    printf("network_drflac: allocating %lu\n", sizeof(NetworkDrFlac));
    NetworkDrFlac *ndrflac = malloc(sizeof(NetworkDrFlac));
    ndrflac->fileoffset = 0;
    ndrflac->filesize = filesize;
    ndrflac->error = error;
    ndrflac->pFlac = NULL;
    const NetworkDrFlacMem nwdrflacmem = {.bufs = &mem, .bufsizes = &memsize, .count = 1, .start_offset = 0};
    ndrflac->pMem = &nwdrflacmem;

    // finally open the file
    drflac *pFlac = drflac_open(&on_read_mem, &on_seek_mem, ndrflac, NULL);
    if((pFlac == NULL) || (!NDRFLAC_OK(ndrflac)))
    {
        if(!NDRFLAC_OK(ndrflac))
        {
            printf("network_drflac: another error?\n"); 
            if(pFlac != NULL) drflac_close(pFlac);                   
        }
        else
        {
            printf("network_drflac: failed to open drflac\n"); 
            error->code = NDRFLAC_GENERIC_ERROR;   
        }             
    }
    else
    {
        printf("network_drflac: opened successfully\n");    
        ndrflac->pFlac = pFlac;        
        return ndrflac;  
    }
    free(ndrflac);
    return NULL;
}

/* returns of samples */
uint64_t network_drflac_read_pcm_frames_f32_mem(NetworkDrFlac *ndrflac, uint32_t start_pcm_frame, uint32_t desired_pcm_frames, float32_t *outFloat, const void *mem, const size_t *memsize, const size_t memcount, NetworkDrFlac_Error *error)
{   
    drflac *pFlac = ndrflac->pFlac;
    const NetworkDrFlacMem nwdrflacmem = {.bufs = mem, .bufsizes = memsize, .count = memcount, .start_offset = 0};
    ndrflac->pMem = &nwdrflacmem;
    ndrflac->error = error;    

    // seek to sample 
    printf("seek to %u\n", start_pcm_frame);
    const uint32_t currentPCMFrame32 = pFlac->currentPCMFrame;
    const drflac_bool32 seekres = drflac_seek_to_pcm_frame(pFlac, start_pcm_frame);
    
    if(!NDRFLAC_OK(ndrflac))
    {        
        printf("network_drflac_read_pcm_frames_f32_mem: failed seek_to_pcm_frame NOT OK current: %u desired: %u\n", currentPCMFrame32, start_pcm_frame);
        return 0;        
    }
    else if(!seekres)
    {
        printf("network_drflac_read_pcm_frames_f32_mem: seek failed current: %u desired: %u\n", currentPCMFrame32, start_pcm_frame);     
        error->code = NDRFLAC_GENERIC_ERROR;
        return 0;
    }   

    // decode to pcm
    float32_t *data = malloc(pFlac->channels*sizeof(float32_t)*desired_pcm_frames);
    const uint32_t frames_decoded = drflac_read_pcm_frames_f32(pFlac, desired_pcm_frames, data);

    if(frames_decoded != desired_pcm_frames)
    {
        printf("network_drflac_read_pcm_frames_f32_mem: expected %u decoded %u\n", desired_pcm_frames, frames_decoded);
    }
    if(!NDRFLAC_OK(ndrflac))
    {
        printf("network_drflac_read_pcm_frames_f32_mem: failed read_pcm_frames_f32\n");
        free(data);
        return 0;
    }

    // deinterleave
    for(unsigned i = 0; i < frames_decoded; i++)
    {
        for(unsigned j = 0; j < pFlac->channels; j++)
        {            
            unsigned chanIndex = j*frames_decoded;
            float32_t sample = data[(i*pFlac->channels) + j];
            outFloat[chanIndex+i] = sample;
        }
    }
    printf("returning from start_pcm_frame: %u frames_decoded %u data %p\n", start_pcm_frame, frames_decoded, data);
    free(data);

    // return number of samples   
    return frames_decoded;
}
