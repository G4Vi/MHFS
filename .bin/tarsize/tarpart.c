#define _GNU_SOURCE
#include <unistd.h>
#include <stdio.h>
#include <stdint.h>
#include <inttypes.h>
#include <stdlib.h>
#include <errno.h>
#include <dlfcn.h>
#include <string.h>
#include <stdbool.h>

#define OUT_FD 1

ssize_t (*original_write)(int, const void *, size_t) = NULL;
ssize_t (*original_read)(int fd, void *buf, size_t count) = NULL;
int (*original_close)(int) = NULL;
uint64_t start = 0;
uint64_t end = 0;

uint64_t wpos = 0;
uint64_t toWrite = 0;
static int LASTFD = -1;
static unsigned SEEKAMT = 0;
static bool WriteRelevant = false;


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




int close(int fd)
{
    if(fd == LASTFD)
    {
        SEEKAMT = 0;        
    }
    return original_close(fd);
}
ssize_t read(int fd, void *buf, size_t count)
{
    LASTFD = fd;   
    if(((wpos+10240) > start) && (toWrite > 0)) //if we are set to write bytes from the start index or past it and there are still bytes to write then we probably need this data
    {            
        WriteRelevant = true;  
        if(SEEKAMT > 0)
        {
            lseek(fd, SEEKAMT, SEEK_CUR);
            SEEKAMT = 0;
        }             
        return original_read(fd, buf, count);        
    }
    else
    {
        SEEKAMT += count;
    }
    return count;
}

ssize_t write(int fd, const void *buf, size_t count)
{
    if(fd != OUT_FD)
    {
        return original_write(fd, buf, count);
    }
    if(WriteRelevant)
    {
        WriteRelevant = false;
        uint64_t skipbytes = start <= wpos ? 0 : start - wpos; 
        uint64_t actcount = count - skipbytes;
        uint64_t nowwrite = (actcount < toWrite) ? actcount : toWrite;
        const char *actualbuf = ((const char *)buf) + skipbytes;            
        original_write(fd, actualbuf, nowwrite);
        toWrite -= nowwrite;
    }
    wpos += count;        
    return count;   
}



