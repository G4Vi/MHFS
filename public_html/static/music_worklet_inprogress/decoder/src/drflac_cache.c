#include <stdio.h>
#include <stdbool.h>
#define DR_FLAC_BUFFER_SIZE (4096 * 16)
#define DR_FLAC_NO_STDIO
#define DR_FLAC_IMPLEMENTATION
#include "dr_flac.h"

#define BLOCKVF_IMPLEMENTATION
#include "block_vf.h"

#include "network_drflac.h"




static drflac_bool32 on_seek_mem(void* pUserData, int offset, drflac_seek_origin origin)
{
    NetworkDrFlac *ndrflac = (NetworkDrFlac *)pUserData;
    return blockvf_seek(&ndrflac->vf, offset, origin) ? DRFLAC_TRUE : DRFLAC_FALSE;
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

static size_t on_read_mem(void* pUserData, void* bufferOut, size_t bytesToRead)
{    
    NetworkDrFlac *nwdrflac = (NetworkDrFlac *)pUserData;
    size_t bytesRead;
    blockvf_read(&nwdrflac->vf, bufferOut, bytesToRead, &bytesRead);
    return bytesRead;
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

void network_drflac_init(NetworkDrFlac *ndrflac, const unsigned blocksize)
{
    ndrflac->pFlac = NULL;
    blockvf_init(&ndrflac->vf, blocksize);    
    ndrflac->meta.initialized = false;
    ndrflac->meta.album[0] = '\0';
    ndrflac->meta.trackno[0] = '\0';
    ndrflac->currentFrame = 0;
}

void network_drflac_deinit(NetworkDrFlac *ndrflac)
{
    if(ndrflac->pFlac != NULL) drflac_close(ndrflac->pFlac);
    blockvf_deinit(&ndrflac->vf);
}

void *network_drflac_add_block(NetworkDrFlac *ndrflac, const uint32_t block_start, const unsigned filesize)
{
    return blockvf_add_block(&ndrflac->vf, block_start, filesize);
}

// network_drflac_read_pcm_frames_f32 will catch the error if we dont here
int network_drflac_seek_to_pcm_frame(NetworkDrFlac *ndrflac, const uint32_t pcmFrameIndex)
{
    if(ndrflac->pFlac != NULL)
    {
        if(pcmFrameIndex >= ndrflac->pFlac->totalPCMFrameCount) return 0;
    }
    ndrflac->currentFrame = pcmFrameIndex;
    return 1;    
}

uint32_t NetworkDrFlac_ReturnData_sizeof(void)
{
    return sizeof(NetworkDrFlac_ReturnData);
}

uint32_t NDRFLAC_SUCCESS_func(void)
{
    return NDRFLAC_SUCCESS;
}

uint32_t NDRFLAC_GENERIC_ERROR_func(void)
{
    return NDRFLAC_GENERIC_ERROR;
}

uint32_t NDRFLAC_NEED_MORE_DATA_func(void)
{
    return NDRFLAC_NEED_MORE_DATA;
}

NetworkDrFlac *network_drflac_open(const unsigned blocksize)
{    
    NetworkDrFlac *ndrflac = malloc(sizeof(NetworkDrFlac));
    if(ndrflac == NULL)
    {
        return NULL;
    }
    network_drflac_init(ndrflac, blocksize);
    return ndrflac;
}

void network_drflac_close(NetworkDrFlac *ndrflac)
{
    network_drflac_deinit(ndrflac);
    free(ndrflac);
}

uint64_t network_drflac_currentFrame(const NetworkDrFlac *ndrflac)
{
    return ndrflac->currentFrame;
}

NetworkDrFlac_Err_Vals network_drflac_read_pcm_frames_f32(NetworkDrFlac *ndrflac, const uint32_t desired_pcm_frames, float32_t *outFloat, NetworkDrFlac_ReturnData *pReturnData)
{
    NetworkDrFlac_ReturnData rd;
    if(pReturnData == NULL) pReturnData = &rd;
    NetworkDrFlac_Err_Vals retval = NDRFLAC_SUCCESS;
    ndrflac->vf.lastdata.code = BLOCKVF_SUCCESS;

    // initialize drflac if necessary
    if(ndrflac->pFlac == NULL)
    {
        ndrflac->vf.fileoffset = 0;

        // finally open the file 
        if(!ndrflac->meta.initialized)
        {
            ndrflac->pFlac = drflac_open_with_metadata(&on_read_mem, &on_seek_mem, &on_meta, ndrflac, NULL);
        }
        else
        {
            ndrflac->pFlac = drflac_open(&on_read_mem, &on_seek_mem, ndrflac, NULL);
        }
        
        if((ndrflac->pFlac == NULL) || (!BLOCKVF_OK(&ndrflac->vf)))
        {
            if(!BLOCKVF_OK(&ndrflac->vf))
            {
                retval = (NetworkDrFlac_Err_Vals)ndrflac->vf.lastdata.code;
                pReturnData->needed_offset = ndrflac->vf.lastdata.extradata;
                printf("network_drflac: another error?\n");
            }
            else
            {
                retval = NDRFLAC_GENERIC_ERROR;
                printf("network_drflac: failed to open drflac\n"); 
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

    // seek to sample 
    printf("seek to %u\n", ndrflac->currentFrame);
    const uint32_t currentPCMFrame32 = pFlac->currentPCMFrame;
    const drflac_bool32 seekres = drflac_seek_to_pcm_frame(pFlac, ndrflac->currentFrame);    
    if(!BLOCKVF_OK(&ndrflac->vf))
    {
        retval = (NetworkDrFlac_Err_Vals)ndrflac->vf.lastdata.code;
        pReturnData->needed_offset = ndrflac->vf.lastdata.extradata;
        printf("network_drflac_read_pcm_frames_f32_mem: failed seek_to_pcm_frame NOT OK current: %u desired: %u\n", currentPCMFrame32, ndrflac->currentFrame);
        goto network_drflac_read_pcm_frames_f32_mem_FAIL;        
    }
    else if(!seekres)
    {
        printf("network_drflac_read_pcm_frames_f32_mem: seek failed current: %u desired: %u\n", currentPCMFrame32, ndrflac->currentFrame);     
        retval = NDRFLAC_GENERIC_ERROR;
        goto network_drflac_read_pcm_frames_f32_mem_FAIL;
    }

    // finally read
    uint32_t frames_decoded = 0;
    if(desired_pcm_frames != 0)
    {
        // decode to pcm
        frames_decoded = drflac_read_pcm_frames_f32(pFlac, desired_pcm_frames, outFloat);
        if(frames_decoded != desired_pcm_frames)
        {
            printf("network_drflac_read_pcm_frames_f32_mem: expected %u decoded %u\n", desired_pcm_frames, frames_decoded);
        }
        if(!BLOCKVF_OK(&ndrflac->vf))
        {
            retval = (NetworkDrFlac_Err_Vals)ndrflac->vf.lastdata.code;
            pReturnData->needed_offset = ndrflac->vf.lastdata.extradata;
            printf("network_drflac_read_pcm_frames_f32_mem: failed read_pcm_frames_f32\n");
            goto network_drflac_read_pcm_frames_f32_mem_FAIL;
        }
        ndrflac->currentFrame += frames_decoded;
    }

    printf("returning from ndrflac->currentFrame: %u frames_decoded %u\n", ndrflac->currentFrame, frames_decoded);
    pReturnData->frames_read = frames_decoded;
    return NDRFLAC_SUCCESS;

network_drflac_read_pcm_frames_f32_mem_FAIL:
    if(ndrflac->pFlac != NULL)
    {
        drflac_close(ndrflac->pFlac);
        ndrflac->pFlac = NULL;
    }    
    return retval;
}

#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"
#define MHFSDECODER_IMPLEMENTATION
#include "mhfs_decoder.h"
