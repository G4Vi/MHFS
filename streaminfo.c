#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <stdint.h>
#include <byteswap.h>
#include <inttypes.h>
#include <assert.h>
#include <string.h>
 #include <sys/types.h>

#include <unistd.h> 
#define DR_FLAC_IMPLEMENTATION
#include "dr_flac.h"
//uint32_t newnum = ((topbytes >> 20) & 0xF)| ((topbytes >> 4) & 0xF0) | ((topbytes << 12) & 0xF000) | ((topbytes >> 4) & 0x0F00) | ((topbytes << 12) & 0xF0000);
#define SAMPLERATE(X) (((X >> 20) & 0xF)| ((X >> 4) & 0xFF0) | ((X << 12) & 0xFF000))


void print_bytes(const void *data, unsigned count)
{
    char buf[256];
    assert(count < (sizeof(buf) - 1));
    uint8_t *_data = (uint8_t*)data;
    unsigned i;
    char *bufptr = (char*)&buf;
    for(i = 0; i < count; i++)
    {
        sprintf(bufptr, "%02X ", _data[i]);
        bufptr += 3;
    }
    *(bufptr++) = '\n';   
    *bufptr = '\0';
    puts(buf);
}

#define LAST(k,n) ((k) & (((uint64_t)1<<(n))-1))  
#define UINTEGER_AT(UIA_VAR,UIA_START,UIA_LEN) LAST((UIA_VAR)>>(UIA_START), (UIA_LEN))

typedef enum {
    STREAMINFO     = 0,
    PADDING        = 1,
    APPLICATION    = 2,
    SEEKTABLE      = 3,
    VORBIS_COMMENT = 4,
    CUESHEET       = 5,
    PICTURE        = 6,
    INVALID        = 127
} METADATA_BLOCK_TYPE;


void read_metadata(int fd)
{
    unsigned lastflag = 0;
    do {
        uint8_t rawmeta[4];
        read(fd, rawmeta, 4);
        uint32_t header    = __bswap_32(*(uint32_t*)&rawmeta[0]);
        unsigned metalen   = UINTEGER_AT(header, 0, 24);
        METADATA_BLOCK_TYPE blocktype = UINTEGER_AT(header, 24, 7);
        lastflag  = UINTEGER_AT(header, 31, 1);
        printf("lastflag %u blocktype %u metalen %u\n", lastflag, blocktype, metalen);
        uint8_t *buf = malloc(metalen);
        read(fd, buf, metalen);
        if(blocktype == STREAMINFO)
        {
            printf("BE BYTES: "); print_bytes(&buf[10], 8);    
            uint64_t importantProps = __bswap_64(*(uint64_t*)&buf[10]);
            printf("LE BYTES: "); print_bytes(&importantProps, 8);    
            
            /*
            unsigned sample_rate             = (uint32_t)((importantProps &  (((uint64_t)0x000FFFFF << 16) << 28)) >> 44);
            unsigned channels                = (uint8_t )((importantProps &  (((uint64_t)0x0000000E << 16) << 24)) >> 41) + 1;
            unsigned bitsPerSample           = (uint8_t )((importantProps &  (((uint64_t)0x0000001F << 16) << 20)) >> 36) + 1;
            uint64_t totalPCMFrameCount      =           ((importantProps & ((((uint64_t)0x0000000F << 16) << 16) | 0xFFFFFFFF)));
            */
            
            unsigned sample_rate             = UINTEGER_AT(importantProps, 44, 20);
            unsigned channels                = UINTEGER_AT(importantProps, 41, 3) + 1;
            unsigned bitsPerSample           = UINTEGER_AT(importantProps, 36, 5) + 1;
            uint64_t totalPCMFrameCount      = UINTEGER_AT(importantProps, 0, 36);
            
            printf("sample rate %u\nchannels %u\nbps %u\ntotalPCMFrameCount %" PRId64 "\n", sample_rate, channels, bitsPerSample, totalPCMFrameCount);
            printf("duration %f\n", ((double)totalPCMFrameCount/sample_rate));
        }
        else if(blocktype == SEEKTABLE)
        {
            
            if((metalen % 18) != 0)
            {
                fprintf(stderr, "bad seek table\n");
                exit(-1);
            }
            unsigned num_seek_points =  metalen / 18;
            uint8_t *tbuf = buf; 
            for(unsigned i = 0; i < num_seek_points; i++)
            {
                uint64_t first_sample_number = __bswap_64(*(uint64_t*)tbuf);
                if(first_sample_number == 0xFFFFFFFFFFFFFFFF)
                {
                    printf("SEEKPOINT placeholder\n");
                }
                else
                {
                    uint64_t frame_offset        = __bswap_64(*(uint64_t*)(tbuf+8));
                    uint16_t frame_samples       = __bswap_16(*(uint16_t*)(tbuf+16));
                    printf("SEEKPOINT sample_number %" PRIu64 " frame_offset %" PRIu64 " frame_samples %u\n", first_sample_number, frame_offset, frame_samples);                    
                }
                tbuf += 18;
            }           
        }
        else if(blocktype == INVALID) 
        {
            fprintf(stderr, "Invalid blocktype\n");
            exit(-1);
        }
        free(buf);
    }
    while(! lastflag);
}

int main(int argc, char **argv)
{
    if(argc < 2)
    {
        fprintf(stderr, "No file provided\n");
        return -1;
    }    


    drflac *pFlac = drflac_open_file(argv[1], NULL);
    printf("pFlac->firstFLACFramePosInBytes %"PRIu64 "\n", pFlac->firstFLACFramePosInBytes);
    printf("sr %u\n", pFlac->currentFLACFrame.header.sampleRate);
    printf("crc8 %u\n", pFlac->currentFLACFrame.header.crc8);
    //drflac__read_and_decode_next_flac_frame(pFlac);
    uint64_t stotal = pFlac->totalPCMFrameCount; 
    uint64_t totalPCM = 0;   
    while(1)
    {
        printf("pos = %u\n", ftell(pFlac->bs.pUserData) - (DRFLAC_CACHE_L2_LINES_REMAINING(&pFlac->bs)*8 + DRFLAC_CACHE_L1_BITS_REMAINING(&pFlac->bs)/8));
        if (!drflac__read_next_flac_frame_header(&pFlac->bs, pFlac->bitsPerSample, &pFlac->currentFLACFrame.header)) {
            break;
        }
        printf("block size in pcm frames %u\n", pFlac->currentFLACFrame.header.blockSizeInPCMFrames);
        totalPCM += pFlac->currentFLACFrame.header.blockSizeInPCMFrames;
        //printf("ftell %d\n", ftell(pFlac->bs.pUserData));
        //printf("consumed bits %u\n", pFlac->bs.consumedBits);
        //printf("l1 bits remaining %u\n", DRFLAC_CACHE_L1_BITS_REMAINING(&pFlac->bs));
        //printf("l2 lines reminaing %u\n", DRFLAC_CACHE_L2_LINES_REMAINING(&pFlac->bs));

        drflac_result result = drflac__seek_to_next_flac_frame(pFlac);
        if (result != DRFLAC_SUCCESS) {
            break;
        }
        //printf("ftell %d\n", ftell(pFlac->bs.pUserData));
        //printf("consumed bits %u\n", pFlac->bs.consumedBits);
        //printf("l1 bits remaining %u\n", DRFLAC_CACHE_L1_BITS_REMAINING(&pFlac->bs));
        //printf("l2 lines reminaing %u\n", DRFLAC_CACHE_L2_LINES_REMAINING(&pFlac->bs));
        //printf("data left = %u\n", DRFLAC_CACHE_L2_LINES_REMAINING(&pFlac->bs)*8 + DRFLAC_CACHE_L1_BITS_REMAINING(&pFlac->bs)/8);
        if((DRFLAC_CACHE_L1_BITS_REMAINING(&pFlac->bs) % 8) != 0)
        {
            printf("extra bits\n");
        }
        
        
    }
    printf("totalPCM %"PRIu64"\n", totalPCM);
    printf("streaminfopcm %"PRIu64"\n", stotal);
   
    int fd = open(argv[1], O_RDONLY);
    if(fd == -1)
    {
        fprintf(stderr, "Can't open\n");
        return -1;
    }



  
    
    char magic[4];
    read(fd, magic, 4);
    
    
    read_metadata(fd);

    uint8_t buf[4];
    while(read(fd, buf, 4) == 4)
    {
        uint32_t frameheader = __bswap_32(*(uint32_t*)&buf[0]);
        unsigned code       = UINTEGER_AT(frameheader, 18, 14);
        unsigned reserved   = UINTEGER_AT(frameheader, 17, 1);
        unsigned reserved2  = UINTEGER_AT(frameheader, 0, 1);
        unsigned samplerate = UINTEGER_AT(frameheader, 8, 4);
        unsigned channelass = UINTEGER_AT(frameheader, 4, 4);
        //if((buf[i] == 0xFF) && (((*(uint16_t*)&buf[i+1]) >> 1) == 0x7c))
        if((code == 16382))
        //if((samplerate == 9) && (channelass == 1))
        {
            printf("pos = %u\n", lseek(fd, 0, SEEK_CUR) - 4);
            unsigned bstrat     = UINTEGER_AT(frameheader, 16, 1);
            if(bstrat != 0)
            {
                printf("variable block size not implemented\n");
                return -1;
            }
            unsigned bsize      = UINTEGER_AT(frameheader, 12, 4);
            if((bsize == 6) || (bsize == 7))
            {
                printf("these blocksize bits not implemented\n");
                return -1;
            }         
            unsigned ssize      = UINTEGER_AT(frameheader, 1, 3);
            if((ssize == 12) || (ssize == 14) || (ssize == 15) || (ssize == 13))
            {
                printf("these samplesize bits not implemented\n");
                return -1;
            }
            
            //printf("frame at %u\n", i);
            printf("reserved %u\n", reserved);
            printf("bstrat %u\n", bstrat);
            printf("bsize %u\n", bsize);
            printf("samplerate %u\n", samplerate);
            printf("channelass %u\n", channelass);
            printf("ssize %u\n", ssize);
            printf("reserved2 %u\n", reserved2);
            lseek(fd, 1800, SEEK_SET);
            uint32_t toread = 3462993-1800;
            uint8_t *flacbuf = malloc(toread);
            if(read(fd, flacbuf, toread) != toread)
            {
                fprintf(stderr, "didnt read enough\n");
                exit(-1);
            }
            char aaa;
            if(read(fd, &aaa, 1) != 0)
            {
                fprintf(stderr, "math bad\n");
                exit(-1);
            }
            mode_t mode = S_IRUSR | S_IWUSR | S_IRGRP | S_IROTH;
            int wfd = open("/home/sample/MHFS/dddd", O_WRONLY|O_CREAT|O_TRUNC, mode);
            if(wfd == -1)
            {
                fprintf(stderr, "open failed\n");
            }
            write(wfd, flacbuf, toread);
            close(wfd);


            return 0;            
        }
    }

    

    return 0;
}
