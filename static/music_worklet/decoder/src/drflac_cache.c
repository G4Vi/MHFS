#include <stdio.h>
#include <stdbool.h>
#define DR_FLAC_BUFFER_SIZE (4096 * 16)
#define DR_FLAC_NO_STDIO
#define DR_FLAC_IMPLEMENTATION
#include "dr_flac.h"

#ifdef NETWORK_DR_FLAC_FORCE_REDBOOK
    #define MA_NO_WAV
    #define MINIAUDIO_IMPLEMENTATION
    #include "miniaudio.h"
#endif

#include "network_drflac.h"

typedef struct memrange {
    uint32_t start;
    struct memrange *next;
} memrange;

struct _NetworkDrFlacMem {
    void *buf;
    unsigned blocksize;
    memrange *block;
};

/*
struct _NetworkDrFlacResampleData {
    ma_resampler_config config;
    ma_resampler resampler;
    unsigned char album[256];
    unsigned char trackno[8];       
};
*/

#define NDRFLAC_OK(xndrflac) ((xndrflac)->error->code == NDRFLAC_SUCCESS)


static int network_drflac_mem_realloc_buf(NetworkDrFlacMem *pMem, const unsigned bufsize)
{
	void *newbuf = realloc(pMem->buf, bufsize);
	if(newbuf == NULL) return 0;
	pMem->buf = newbuf;
    return 1;	
}

static void network_drflac_mem_free(NetworkDrFlacMem *pMem)
{
    for(memrange *block = pMem->block; block != NULL;)
    {
        memrange *nextblock = block->next;
        free(block);
        block = nextblock;
    }
    if(pMem->buf != NULL) free(pMem->buf);
    free(pMem);
}

static void network_drflac_mem_add_block(NetworkDrFlacMem *pMem, const uint32_t block_start)
{
    memrange *block = malloc(sizeof(memrange));
    block->start = block_start;
    memrange **blocklist = &pMem->block;
    for(;  *blocklist != NULL;  blocklist = &((*blocklist)->next))
    {
        if(block->start < ((*blocklist)->start))
        {
            break;
        }      
    }

    memrange *nextblock = *blocklist;
    *blocklist = block;
    block->next = nextblock;
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

static const unsigned char *vorbis_comment_get_kv_match(const unsigned char *commentstr,  const char *keyname)
{
    const unsigned keylen = strlen(keyname);
    if(memcmp(commentstr, keyname, keylen) != 0) return NULL;
    if(commentstr[keylen] != '=') return NULL;
    return &commentstr[keylen+1];   
}

static void on_meta(void *pUserData, drflac_metadata *pMetadata)
{
    if(pMetadata->type != DRFLAC_METADATA_BLOCK_TYPE_VORBIS_COMMENT) return;
    NetworkDrFlac *ndrflac = (NetworkDrFlac *)pUserData;  

    const unsigned char *comments = (unsigned char *)pMetadata->data.vorbis_comment.pComments;
    unsigned char *commentstr = malloc(128);
    for(unsigned i = 0; i < pMetadata->data.vorbis_comment.commentCount; i++)
    {
        const unsigned commentsize = *(uint32_t*)comments;
        comments += 4;
        if(commentsize >= sizeof(commentstr))
        {
            commentstr = realloc(commentstr, commentsize+1);
        }
        memcpy(commentstr, comments, commentsize);
        comments += commentsize;
        commentstr[commentsize] = '\0';
        printf("commentstr %s\n", commentstr);
        do
        {
            const unsigned char *value = vorbis_comment_get_kv_match(commentstr, "ALBUM");
            if(value != NULL)
            {
                snprintf((char*)(ndrflac->meta.album), sizeof(ndrflac->meta.album), "%s", value);
                printf("album %s\n", ndrflac->meta.album);                
                break;
            }
            value = vorbis_comment_get_kv_match(commentstr, "TRACKNUMBER");
            if(value != NULL)
            {
                snprintf((char*)(ndrflac->meta.trackno), sizeof(ndrflac->meta.trackno), "%s", value);
                printf("track no %s\n", ndrflac->meta.trackno);
                break;
            }
        }
        while(0);
    }
    free(commentstr);
}

static bool has_necessary_blocks(NetworkDrFlac *ndrflac, const size_t bytesToRead)
{    
    const unsigned blocksize = ndrflac->pMem->blocksize;
    const unsigned last_needed_byte = ndrflac->fileoffset + bytesToRead -1; 

    // initialize needed block to the block with fileoffset
    unsigned needed_block = (ndrflac->fileoffset / ndrflac->pMem->blocksize) * ndrflac->pMem->blocksize;
    for(memrange *block = ndrflac->pMem->block; block != NULL; block = block->next)
    {
        if(block->start > needed_block)
        {
            // block starts after a needed block
            break;
        }
        else if(block->start == needed_block)
        {
            unsigned nextblock = block->start + blocksize;
            if(last_needed_byte < nextblock)
            {
                return true;
            }
            needed_block = nextblock;                
        }
    }

    printf("NEED MORE MEM file_offset: %u lastneedbyte %u needed_block %u\n", ndrflac->fileoffset, last_needed_byte, needed_block);
    ndrflac->error->code = NDRFLAC_MEM_NEED_MORE;
    ndrflac->error->extradata = needed_block;
    /*for(memrange *block = ndrflac->pMem->block; block != NULL;)
    {
        printf("block: %u\n", block->start);
        memrange *nextblock = block->next;        
        block = nextblock;
    }*/
    return false;
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

    
    if(!has_necessary_blocks(nwdrflac, bytesToRead))
    {
        return 0;
    }
    uint8_t  *src = (uint8_t*)(pMem->buf);
    src += src_offset;
    //printf("memcpy %u %u %u srcoffset %u filesize %u buffered %u\n", bufferOut, src, bytesToRead, src_offset, nwdrflac->filesize); 
    memcpy(bufferOut, src, bytesToRead);
    nwdrflac->fileoffset += bytesToRead;
    return bytesToRead;
}

NetworkDrFlac_Error *network_drflac_create_error(void)
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
    
NetworkDrFlac *network_drflac_open(const unsigned blocksize)
{
    NetworkDrFlacMem *mem = malloc(sizeof(NetworkDrFlacMem ));
    if(mem == NULL) return NULL;    
    mem->buf = NULL;
    mem->blocksize = blocksize;
    mem->block = NULL;
    NetworkDrFlac *ndrflac = malloc(sizeof(NetworkDrFlac));
    if(ndrflac == NULL)
    {
        free(mem);
        return NULL;
    }
    ndrflac->pFlac = NULL;    
    ndrflac->pMem = mem;
    ndrflac->filesize = 0;
    ndrflac->meta.initialized = false;
    ndrflac->meta.album[0] = '\0';
    ndrflac->meta.trackno[0] = '\0';
    return ndrflac;
}

void network_drflac_close(NetworkDrFlac *ndrflac)
{
    if(ndrflac->pFlac != NULL) drflac_close(ndrflac->pFlac);
    network_drflac_mem_free(ndrflac->pMem);
    free(ndrflac);
}

int network_drflac_add_block(NetworkDrFlac *ndrflac, const uint32_t block_start, const unsigned filesize)
{
    // resize and or create the buffer if necessary
    int bufok = (ndrflac->pMem->buf != NULL);
    if(filesize != ndrflac->filesize)
    {   
        printf("changing filesize from %u to %u\n", ndrflac->filesize, filesize);     
        if(filesize > ndrflac->filesize)
        {   
            bufok = network_drflac_mem_realloc_buf(ndrflac->pMem, filesize);            
        }
        // don't resize the buffer when file shrunk as a block could be pointing to it
        else
        {
            printf("warning, file shrunk\n");
        }
        ndrflac->filesize = filesize;

    }
    if(!bufok) return bufok;

    // finally add the block to the list
    network_drflac_mem_add_block(ndrflac->pMem, block_start);
    return 1;
}

void *network_drflac_bufptr(const NetworkDrFlac *ndrflac)
{
    return ndrflac->pMem->buf;
}

/* returns of samples */
uint64_t network_drflac_read_pcm_frames_f32_mem(NetworkDrFlac *ndrflac, uint32_t start_pcm_frame, uint32_t desired_pcm_frames, float32_t *outFloat, NetworkDrFlac_Error *error)
{   
    ndrflac->error = error;
    // initialize drflac if necessary
    if(ndrflac->pFlac == NULL)
    {
        ndrflac->fileoffset = 0;

        // finally open the file 
        if(!ndrflac->meta.initialized)
        {
            ndrflac->pFlac = drflac_open_with_metadata(&on_read_mem, &on_seek_mem, &on_meta, ndrflac, NULL);
        }
        else
        {
            ndrflac->pFlac = drflac_open(&on_read_mem, &on_seek_mem, ndrflac, NULL);
        }
        
        if((ndrflac->pFlac == NULL) || (!NDRFLAC_OK(ndrflac)))
        {
            if(!NDRFLAC_OK(ndrflac))
            {
                printf("network_drflac: another error?\n");                                   
            }
            else
            {
                printf("network_drflac: failed to open drflac\n"); 
                error->code = NDRFLAC_GENERIC_ERROR;   
            }
            goto network_drflac_read_pcm_frames_f32_mem_FAIL;                         
        }
        else
        {
            printf("network_drflac: opened successfully\n");
            ndrflac->meta.initialized = true;                      
        }
    }    

    drflac *pFlac = ndrflac->pFlac; 
    /*if(start_pcm_frame >= 5)
    {
        start_pcm_frame -= 5;
        desired_pcm_frames += 5;
    }      
    */

    // seek to sample 
    printf("seek to %u\n", start_pcm_frame);
    const uint32_t currentPCMFrame32 = pFlac->currentPCMFrame;
    const drflac_bool32 seekres = drflac_seek_to_pcm_frame(pFlac, start_pcm_frame);
    
    if(!NDRFLAC_OK(ndrflac))
    {        
        printf("network_drflac_read_pcm_frames_f32_mem: failed seek_to_pcm_frame NOT OK current: %u desired: %u\n", currentPCMFrame32, start_pcm_frame);
        goto network_drflac_read_pcm_frames_f32_mem_FAIL;        
    }
    else if(!seekres)
    {
        printf("network_drflac_read_pcm_frames_f32_mem: seek failed current: %u desired: %u\n", currentPCMFrame32, start_pcm_frame);     
        error->code = NDRFLAC_GENERIC_ERROR;
        goto network_drflac_read_pcm_frames_f32_mem_FAIL;
    }
    if(desired_pcm_frames == 0)
    {
        // we just wanted a seek
        return 0;
    }   

    // decode to pcm
    float32_t *data = malloc(pFlac->channels*sizeof(float32_t)*desired_pcm_frames);
    uint32_t frames_decoded = drflac_read_pcm_frames_f32(pFlac, desired_pcm_frames, data);
    if(frames_decoded != desired_pcm_frames)
    {
        printf("network_drflac_read_pcm_frames_f32_mem: expected %u decoded %u\n", desired_pcm_frames, frames_decoded);
    }
    if(!NDRFLAC_OK(ndrflac))
    {
        printf("network_drflac_read_pcm_frames_f32_mem: failed read_pcm_frames_f32\n");
        free(data);
        goto network_drflac_read_pcm_frames_f32_mem_FAIL;
    }
    // if we didn't read any data fail
    if(frames_decoded == 0)
    {
        printf("network_drflac_read_pcm_frames_f32_mem: failed read_pcm_frames_f32 (0)\n");
        free(data);
        error->code = NDRFLAC_GENERIC_ERROR;
        goto network_drflac_read_pcm_frames_f32_mem_FAIL;
    }

    #ifdef NETWORK_DR_FLAC_FORCE_REDBOOK
    // resample
    if(pFlac->sampleRate != 44100)
    {
        printf("Converting samplerate from %u to %u\n", pFlac->sampleRate, 44100);

        // create the resampler
        static int initialized = 0;
        static  ma_resampler_config config;
        static  ma_resampler resampler;
        if(!initialized)
        {
            initialized = 1;
            config = ma_resampler_config_init(ma_format_f32, pFlac->channels, pFlac->sampleRate,  44100, ma_resample_algorithm_linear);
            ma_resampler_init(&config, &resampler);
            uint32_t inlat = ma_resampler_get_input_latency(&resampler);
            printf("Input latency %u\n", inlat);
            uint32_t outlat = ma_resampler_get_output_latency(&resampler);
            printf("output latency %u\n", outlat);
        }
        // resample
        ma_uint64 frameCountIn  = frames_decoded;
        ma_uint64 frameCountOut = ma_resampler_get_expected_output_frame_count(&resampler, frameCountIn);
        uint32_t fin = frameCountIn;
        uint32_t fcount = frameCountOut;
        printf("framecountin %u framecountout %u\n", fin, fcount);
        float32_t *pFramesOut = malloc(frameCountOut*pFlac->channels*sizeof(float32_t));
        ma_result result_process = ma_resampler_process_pcm_frames(&resampler, data, &frameCountIn, pFramesOut, &frameCountOut);
        free(data);
        if (result_process != MA_SUCCESS)
        {
            printf("network_drflac_read_pcm_frames_f32_mem: failed read_pcm_frames_f32 resample\n");
            goto network_drflac_read_pcm_frames_f32_mem_FAIL;
        }
        data = pFramesOut;        
        frames_decoded = frameCountOut;                
    }
    #endif

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
    free(data);

    printf("returning from start_pcm_frame: %u frames_decoded %u\n", start_pcm_frame, frames_decoded);   
    // return number of samples   
    return frames_decoded;

network_drflac_read_pcm_frames_f32_mem_FAIL:
    if(ndrflac->pFlac != NULL)
    {
        drflac_close(ndrflac->pFlac);
        ndrflac->pFlac = NULL;
    }    
    return 0;
}

#undef NDRFLAC_OK
