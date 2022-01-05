#pragma once
#include <stdbool.h>
#include <stdint.h>
#include <inttypes.h>

#include "dr_flac.h"

typedef struct blockvf_memrange {
    uint32_t start;
    struct blockvf_memrange *next;
} blockvf_memrange;

typedef enum {
    BLOCKVF_SUCCESS = 0,
    BLOCKVF_GENERIC_ERROR = 1,
    BLOCKVF_MEM_NEED_MORE = 2
} BlockVF_Err_Vals;

typedef struct {
    BlockVF_Err_Vals code;
    uint32_t extradata;
} BlockVF_LastData;

typedef struct  {
    void *buf;
    unsigned blocksize;
    blockvf_memrange *block;
    unsigned filesize;
    unsigned fileoffset;
    BlockVF_LastData lastdata;
} blockvf;

#define BLOCKVF_OK(blockvf) ((blockvf)->lastdata.code == BLOCKVF_SUCCESS)

unsigned blockvf_sizeof(void);
void blockvf_init(blockvf *pBlockvf, const unsigned blocksize);
void *blockvf_add_block(blockvf *pBlockvf, const uint32_t block_start, const unsigned filesize);
ma_result blockvf_seek(blockvf *pBlockvf, int64_t offset, ma_seek_origin origin);
ma_result blockvf_read(blockvf *pBlockvf, void* bufferOut, size_t bytesToRead, size_t *bytesRead);
void blockvf_deinit(blockvf *pBlockvf);

#if defined(BLOCKVF_IMPLEMENTATION)
#ifndef block_vf_c
#define block_vf_c

static int blockvf_realloc_buf(blockvf *pBlockvf, const unsigned bufsize)
{
	void *newbuf = realloc(pBlockvf->buf, bufsize);
	if(newbuf == NULL) return 0;
	pBlockvf->buf = newbuf;
    return 1;	
}

static void _blockvf_add_block(blockvf *pBlockvf, const uint32_t block_start)
{
    blockvf_memrange *block = malloc(sizeof(blockvf_memrange));
    block->start = block_start;
    blockvf_memrange **blocklist = &pBlockvf->block;
    for(;  *blocklist != NULL;  blocklist = &((*blocklist)->next))
    {
        if(block->start < ((*blocklist)->start))
        {
            break;
        }      
    }

    blockvf_memrange *nextblock = *blocklist;
    *blocklist = block;
    block->next = nextblock;
}

static bool blockvf_has_bytes(const blockvf *pBlockvf, const size_t bytesToRead, unsigned *neededblock)
{
    const unsigned blocksize = pBlockvf->blocksize;
    const unsigned last_needed_byte = pBlockvf->fileoffset + bytesToRead -1; 

    // initialize needed block to the block with fileoffset
    unsigned needed_block = (pBlockvf->fileoffset / pBlockvf->blocksize) * pBlockvf->blocksize;
    for(blockvf_memrange *block = pBlockvf->block; block != NULL; block = block->next)
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

    printf("NEED MORE MEM file_offset: %u lastneedbyte %u needed_block %u\n", pBlockvf->fileoffset, last_needed_byte, needed_block);
    *neededblock = needed_block;
    /*for(blockvf_memrange *block = pBlockvf->block; block != NULL;)
    {
        printf("block: %u\n", block->start);
        blockvf_memrange *nextblock = block->next;        
        block = nextblock;
    }*/
    return false;
}

unsigned blockvf_sizeof(void)
{
    return sizeof(blockvf);
}

void blockvf_init(blockvf *pBlockvf, const unsigned blocksize)
{
    pBlockvf->buf = NULL;
    pBlockvf->blocksize = blocksize;
    pBlockvf->block = NULL;
    pBlockvf->filesize = 0;
    pBlockvf->fileoffset = 0;
}
void *blockvf_add_block(blockvf *pBlockvf, const uint32_t block_start, const unsigned filesize)
{
    // resize and or create the buffer if necessary
    int bufok = (pBlockvf->buf != NULL);
    if(filesize != pBlockvf->filesize)
    {   
        printf("changing filesize from %u to %u\n", pBlockvf->filesize, filesize);     
        if(filesize > pBlockvf->filesize)
        {   
            bufok = blockvf_realloc_buf(pBlockvf, filesize);            
        }
        // don't resize the buffer when file shrunk as a block could be pointing to it
        else
        {
            printf("warning, file shrunk\n");
        }
        pBlockvf->filesize = filesize;

    }
    if(!bufok) return NULL;

    // finally add the block to the list
    _blockvf_add_block(pBlockvf, block_start);
    return ((uint8_t*)(pBlockvf->buf))+block_start;
}

ma_result blockvf_seek(blockvf *pBlockvf, int64_t offset, ma_seek_origin origin)
{
    if(!BLOCKVF_OK(pBlockvf))
    {
        printf("on_seek_mem: already failed, breaking %"PRId64" %u\n", offset, origin);
        return MA_ERROR;
    }

    if(origin == ma_seek_origin_end)
    {
        printf("on_seek_mem: ma_seek_origin_end not supported, breaking %"PRId64" %u\n", offset, origin);
        return MA_ERROR;
    }

    unsigned tempoffset = pBlockvf->fileoffset;
    if(origin == ma_seek_origin_current)
    {
        tempoffset += offset;
    }
    else
    {
        tempoffset = offset;
    }
    if((pBlockvf->filesize != 0) &&  (tempoffset >= pBlockvf->filesize))
    {
        printf("blockvf_seek: seek past end of stream\n");        
        return MA_ERROR;
    }

    printf("blockvf_seek seek update fileoffset %u\n", tempoffset);
    pBlockvf->fileoffset = tempoffset;
    return MA_SUCCESS;
}

// returns false when more data is needed
ma_result blockvf_read(blockvf *pBlockvf, void* bufferOut, size_t bytesToRead, size_t *bytesRead)
{
    if(!BLOCKVF_OK(pBlockvf))
    {
        printf("on_read_mem: already failed\n");
        *bytesRead = 0;
        return MA_ERROR;
    }

    unsigned endoffset = pBlockvf->fileoffset+bytesToRead-1;

    // adjust params based on file size 
    if(pBlockvf->filesize > 0)
    {
        if(pBlockvf->fileoffset >= pBlockvf->filesize)
        {
            printf("blockvf_read: fileoffset >= filesize %u %u\n", pBlockvf->fileoffset, pBlockvf->filesize);
            *bytesRead = 0;        
            return MA_SUCCESS;
        }       
        if(endoffset >= pBlockvf->filesize)
        {
            unsigned newendoffset = pBlockvf->filesize - 1;
            printf("blockvf_read: truncating endoffset from %u to %u\n", endoffset, newendoffset);
            endoffset = newendoffset;
            bytesToRead = endoffset - pBlockvf->fileoffset + 1;            
        }     
    }

    // nothing to read, do nothing
    if(bytesToRead == 0)
    {
        printf("blockvf_read: reached end of stream\n");
        *bytesRead = 0;        
        return MA_SUCCESS;
    }
    
    //  HARD fail, we don't have the needed data
    unsigned needed;
    if(!blockvf_has_bytes(pBlockvf, bytesToRead, &needed))
    {
        *bytesRead = 0;
        pBlockvf->lastdata.code = BLOCKVF_MEM_NEED_MORE;
        pBlockvf->lastdata.extradata = needed;
        return MA_ERROR;
    }
    
    // finally copy the data
    const unsigned src_offset = pBlockvf->fileoffset;
    uint8_t  *src = (uint8_t*)(pBlockvf->buf);
    src += src_offset;
    //printf("memcpy 0x%p 0x%p %zu srcoffset %u filesize %u\n", bufferOut, src, bytesToRead, src_offset, pBlockvf->filesize);
    memcpy(bufferOut, src, bytesToRead);
    pBlockvf->fileoffset += bytesToRead;
    *bytesRead = bytesToRead;
    return MA_SUCCESS;
}

void blockvf_deinit(blockvf *pBlockvf)
{
    for(blockvf_memrange *block = pBlockvf->block; block != NULL;)
    {
        blockvf_memrange *nextblock = block->next;
        free(block);
        block = nextblock;
    }
    if(pBlockvf->buf != NULL) free(pBlockvf->buf);
}



#endif  /* block_vf_c */
#endif  /* BLOCKVF_IMPLEMENTATION */