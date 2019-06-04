#define _GNU_SOURCE
#include <unistd.h>
#include <stdio.h>
#include <stdint.h>
#include <inttypes.h>
#include <stdlib.h>
#include <errno.h>
#include <dlfcn.h>
#include <string.h>

#define OUT_FD 1

ssize_t (*original_write)(int, const void *, size_t) = NULL;
ssize_t (*original_read)(int fd, void *buf, size_t count) = NULL;
int (*original_close)(int) = NULL;
uint64_t start = 0;
uint64_t end = 0;

uint64_t wpos = 0;
uint64_t toWrite = 0;
static void __attribute__ ((constructor)) lib_init(void)
{
    const char *sstart = getenv("TS_TAR_START");
    if(sstart != NULL)
    {
        start = atoi(sstart);
    }
    const char *ends = getenv("TS_TAR_END");
    if(ends != NULL)
    {
        end = atoi(ends);
    }
    toWrite = end - start + 1;
    original_read = dlsym(RTLD_NEXT, "read");
    original_write = dlsym(RTLD_NEXT, "write"); 
    original_close = dlsym(RTLD_NEXT, "close");   
}

static int LASTFD = -1;
static size_t LASTCOUNT;
static unsigned SEEKAMT = 0;

int close(int fd)
{
    if(fd == LASTFD) return 0;
    return original_close(fd);
}
ssize_t read(int fd, void *buf, size_t count)
{
    //fprintf(stderr, "actual read %d %p %u %u\n", fd, buf, count, lseek(fd, 0, SEEK_CUR));
    return original_read(fd, buf, count); 
}

ssize_t write(int fd, const void *buf, size_t count)
{
    if(fd != OUT_FD)
    {
        return original_write(fd, buf, count);
    }
    if(((wpos+count) > start) && (toWrite > 0))
    {            
        uint64_t skipbytes = start <= wpos ? 0 : start - wpos; 
        uint64_t actcount = count - skipbytes;
        uint64_t nowwrite = (actcount < toWrite) ? actcount : toWrite;
        const char *actualbuf = ((const char *)buf) + skipbytes;            
        original_write(fd, actualbuf, nowwrite);
        toWrite -= nowwrite;
    }
    else
    {            
        //we don't care about that data            
        SEEKAMT += LASTCOUNT;
    }
    
    wpos += count;        
    return count;   
}



