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

int main(int argc, char **argv)
{
    if(argc < 2)
    {
        fprintf(stderr, "No file provided\n");
        return -1;
    }    
    int fd = open(argv[1], O_RDONLY);
    if(fd == -1)
    {
        fprintf(stderr, "Can't open\n");
        return -1;
    }
    unsigned char buf[4+4+256];
    ssize_t bytes = read(fd, buf, sizeof(buf));
    if(bytes != sizeof(buf))
    {
        fprintf(stderr, "read failed\n");
        return -1;
    }
    
    printf("BE BYTES: "); print_bytes(&buf[8+10], 8);    
    uint64_t importantProps = __bswap_64(*(uint64_t*)&buf[8+10]);
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

    return 0;
}
