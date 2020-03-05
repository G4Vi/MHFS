#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <stdint.h>
#include <byteswap.h>
#include <inttypes.h>

//uint32_t newnum = ((topbytes >> 20) & 0xF)| ((topbytes >> 4) & 0xF0) | ((topbytes << 12) & 0xF000) | ((topbytes >> 4) & 0x0F00) | ((topbytes << 12) & 0xF0000);
#define SAMPLERATE(X) (((X >> 20) & 0xF)| ((X >> 4) & 0xFF0) | ((X << 12) & 0xFF000))

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
    printf("%c%c%c%c\n", buf[0], buf[1], buf[2], buf[3]);
  
    
    uint64_t importantProps = __bswap_64(*(uint64_t*)&buf[8+10]);
    unsigned sample_rate             = (uint32_t)((importantProps &  (((uint64_t)0x000FFFFF << 16) << 28)) >> 44);
    unsigned channels                = (uint8_t )((importantProps &  (((uint64_t)0x0000000E << 16) << 24)) >> 41) + 1;
    unsigned bitsPerSample           = (uint8_t )((importantProps &  (((uint64_t)0x0000001F << 16) << 20)) >> 36) + 1;
    uint64_t totalPCMFrameCount      =           ((importantProps & ((((uint64_t)0x0000000F << 16) << 16) | 0xFFFFFFFF)));
    printf("sample rate %u\nchannels %u\nbps %u\ntotalPCMFrameCount %" PRId64 "\n", sample_rate, channels, bitsPerSample, totalPCMFrameCount);
    printf("duration %f\n", ((double)totalPCMFrameCount/sample_rate));
    
    /*struct streaminfo *mysi = &buf[8];//(struct streaminfo*)(meta + 1);
    const unsigned char *sbytes = &buf[8+10];
    uint32_t topbytes = *(uint32_t*)sbytes;
    //uint32_t topbytes = mysi->sample_rate;
    //topbytes &= 0xF0FFFF;
    uint8_t *bbytes = (uint8_t*)&topbytes;
    printf("topbytes %x %x %x %x\n", bbytes[0], bbytes[1], bbytes[2], bbytes[3]);
   
    
    uint32_t newnum = SAMPLERATE(topbytes);
    //uint32_t newnum = SR(topbytes);
    bbytes = (uint8_t*)&newnum;
    printf("newnum %x %x %x %x\n", bbytes[0], bbytes[1], bbytes[2], bbytes[3]);

    unsigned sample_rate = newnum;
    unsigned numchannels = topbytes >> 16
    printf("sample rate %u\n", sample_rate);
    printf("num channels %u\n", __bswap_16 (mysi->num_channels));
    printf("bits per sample %u\n", mysi->bits_per_sample);
    printf("total samples %u\n", mysi->total_samples); */
    return 0;
}
