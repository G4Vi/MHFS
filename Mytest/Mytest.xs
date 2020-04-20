#define PERL_NO_GET_CONTEXT
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "ppport.h"
#include <stdint.h>
#define DR_FLAC_IMPLEMENTATION
#include "dr_flac.h"
#include "FLAC/stream_encoder.h"

typedef void *(* malloc_ptr) (size_t);
typedef void  (* free_ptr)   (void*);
typedef void *(* realloc_ptr)(void *, size_t); 

typedef struct {
	malloc_ptr  malloc;
	free_ptr    free;
	realloc_ptr realloc;
    drflac *pFlac;

    FLAC__StreamEncoder *encoder;
	uint8_t *flacbuffer;
    uint64_t flacbuffersize;	
    uint64_t file_offset;
    uint64_t largest_offset;

} _mytest;

#define MIN(a,b) (((a)<(b))?(a):(b))

_mytest *_mytest_new(_mytest *mytest, const char *filename, malloc_ptr mymalloc, free_ptr myfree, realloc_ptr myrealloc)
{
	memset(mytest, 0, sizeof(*mytest));    
    mytest->malloc  = mymalloc ? mymalloc : &malloc;
	mytest->free    = myfree  ? myfree: &free;
	mytest->realloc = myrealloc ? myrealloc : &realloc;
    mytest->pFlac = drflac_open_file(filename, NULL);
    if (mytest->pFlac == NULL) {
        return NULL;
    }

	return mytest;
}

FLAC__StreamEncoderWriteStatus writecb(const FLAC__StreamEncoder *encoder, const FLAC__byte buffer[], size_t bytes, unsigned samples, unsigned current_frame, void *client_data)
{
    static maxbytes;
    if(bytes > maxbytes)
    {
        maxbytes = bytes;
        fprintf(stderr, "writecb maxbytes %u %u\n", maxbytes, samples);
    }
    //fprintf(stderr, "writecb %u %u\n", bytes, samples);
    _mytest *mytest = (_mytest*)client_data;
    // + 1 for terminating 0
    if((mytest->file_offset + bytes + 1) > mytest->flacbuffersize)
    {
        fprintf(stderr, "reallocating to %zu\n", mytest->flacbuffersize + (bytes * 2));
        mytest->flacbuffer = mytest->realloc(mytest->flacbuffer, mytest->flacbuffersize + (bytes * 2));
        if(mytest->flacbuffer == NULL)
        {
            return  FLAC__STREAM_ENCODER_WRITE_STATUS_FATAL_ERROR;
        }
        mytest->flacbuffersize = mytest->flacbuffersize + (bytes * 2);        
    }
    
    
    memcpy(&mytest->flacbuffer[mytest->file_offset], buffer, bytes);
    mytest->file_offset += bytes;
    if(mytest->file_offset > mytest->largest_offset) mytest->largest_offset = mytest->file_offset;
    return FLAC__STREAM_ENCODER_WRITE_STATUS_OK;
}





FLAC__StreamEncoderSeekStatus seekcb(const FLAC__StreamEncoder *encoder, FLAC__uint64 absolute_byte_offset, void *client_data)
{
    _mytest *mytest = (_mytest*)client_data;
    mytest->file_offset = absolute_byte_offset;
    return FLAC__STREAM_ENCODER_SEEK_STATUS_OK;
}

FLAC__StreamEncoderTellStatus tellcb(const FLAC__StreamEncoder *encoder, FLAC__uint64 *absolute_byte_offset, void *client_data)
{
     _mytest *mytest = (_mytest*)client_data;
     *absolute_byte_offset = mytest->file_offset;
     return FLAC__STREAM_ENCODER_TELL_STATUS_OK;
}


bool _mytest_get_flac(_mytest *mytest, uint64_t start, size_t count)
{
    mytest->file_offset     = 0;
    mytest->largest_offset  = 0;
	mytest->flacbuffersize = count * sizeof(FLAC__int32);		
	mytest->flacbuffer = mytest->malloc(mytest->flacbuffersize);
    if(mytest->flacbuffer == NULL)
    {
        return false;
    }
   

	/* allocate the encoder */
	if((mytest->encoder = FLAC__stream_encoder_new()) == NULL) {
		fprintf(stderr, "ERROR: allocating encoder\n");
		return true;
	}

    FLAC__bool ok = true;
	FLAC__StreamEncoderInitStatus init_status;
    drflac *pFlac = mytest->pFlac;
	//ok &= FLAC__stream_encoder_set_verify(mytest->encoder, true);
	ok &= FLAC__stream_encoder_set_verify(mytest->encoder, false);
	ok &= FLAC__stream_encoder_set_compression_level(mytest->encoder, 5);
	ok &= FLAC__stream_encoder_set_channels(mytest->encoder, pFlac->channels);
	ok &= FLAC__stream_encoder_set_bits_per_sample(mytest->encoder, pFlac->bitsPerSample);
	ok &= FLAC__stream_encoder_set_sample_rate(mytest->encoder, pFlac->sampleRate);
	ok &= FLAC__stream_encoder_set_total_samples_estimate(mytest->encoder, count);

	if(!ok) {
		goto _mytest_get_flac_cleanup;
	}
    
	//init_status = FLAC__stream_encoder_init_stream(mytest->encoder, &writecb, &seekcb, &tellcb, NULL, mytest);
	init_status = FLAC__stream_encoder_init_stream(mytest->encoder, &writecb, NULL, NULL, NULL, mytest);
	if(init_status != FLAC__STREAM_ENCODER_INIT_STATUS_OK) {
		fprintf(stderr, "ERROR: initializing encoder: %s\n", FLAC__StreamEncoderInitStatusString[init_status]);
		goto _mytest_get_flac_cleanup;
	}

    // read in the desired amount of samples   
    // todo handle 24 bits
    
    /*
    if(!drflac_seek_to_pcm_frame(pFlac, start))
    {
        goto _mytest_get_flac_cleanup;    
    }   
    fprintf(stderr, "seeked to absolute, allocating %u\n", count * pFlac->channels * sizeof(int32_t));
    int32_t *rawSamples = mytest->malloc((size_t)count * pFlac->channels * sizeof(int32_t));
    if(rawSamples == NULL)
    {
        goto _mytest_get_flac_cleanup;
    }    
    if(drflac_read_pcm_frames_s32(mytest->pFlac, count, rawSamples) != count)
    {
        goto _mytest_get_flac_cleanup;       
    }
    */
    
    if(!drflac_seek_to_pcm_frame(pFlac, start))
    {
        goto _mytest_get_flac_cleanup;    
    } 
    
    fprintf(stderr, "seeked to absolute, allocating %u\n", count * pFlac->channels * sizeof(int16_t));
    int16_t *raw16Samples = malloc((size_t)count * pFlac->channels * sizeof(int16_t));
    if(raw16Samples == NULL)
    {
        goto _mytest_get_flac_cleanup;
    }    
    if(drflac_read_pcm_frames_s16(mytest->pFlac, count, raw16Samples) != count)
    {
        free(raw16Samples);
        goto _mytest_get_flac_cleanup;       
    }
    FLAC__int32 *fbuffer = malloc(sizeof(FLAC__int32)*count * pFlac->channels);    
    for(unsigned i = 0; i < (count * pFlac->channels) ; i++)
    {
        fbuffer[i] = raw16Samples[i];       
    }
    if(!FLAC__stream_encoder_process_interleaved(mytest->encoder, fbuffer, count))
    {
        fprintf(stderr, "   state: %s\n", FLAC__StreamEncoderStateString[FLAC__stream_encoder_get_state(mytest->encoder)]);
        free(fbuffer);
        free(raw16Samples);
        goto _mytest_get_flac_cleanup;        
    }
    free(raw16Samples);
    free(fbuffer);   
    
    if(FLAC__stream_encoder_finish(mytest->encoder))
    {
        fprintf(stderr, "should be encoded by now\n");
		FLAC__stream_encoder_delete(mytest->encoder);
        mytest->encoder = NULL;
		return true;
    }    
   
_mytest_get_flac_cleanup:
	FLAC__stream_encoder_delete(mytest->encoder);
    mytest->encoder = NULL;
	return false;
}

bool _mytest_get_wav(_mytest *mytest, uint64_t start, uint64_t end)
{
    mytest->flacbuffersize = (end - start) + 1 + 1;	
    mytest->largest_offset  = mytest->flacbuffersize - 1;
	mytest->flacbuffer = mytest->malloc(mytest->flacbuffersize);
    if(mytest->flacbuffer == NULL)
    {
        return false;
    }    
    
    drflac *pFlac = mytest->pFlac;
    uint64_t bytesleft = mytest->largest_offset;
    if(start < 44) {
        uint8_t data[44];
        memcpy(data, "RIFF", 4);
        uint32_t chunksize = (pFlac->totalPCMFrameCount * pFlac->channels * sizeof(int16_t)) + 36;
        memcpy(&data[4], &chunksize, 4);
        memcpy(&data[8], "WAVEfmt ", 8);
        uint32_t pcm = 16;
        memcpy(&data[16], &pcm, 4);
        uint16_t audioformat = 1;
        memcpy(&data[20], &audioformat, 2);
        uint16_t numchannels = pFlac->channels;
        memcpy(&data[22], &numchannels, 2);
        uint32_t samplerate = pFlac->sampleRate;
        memcpy(&data[24], &samplerate, 4);
        uint32_t byterate = samplerate * numchannels * (pFlac->bitsPerSample / 8);
        memcpy(&data[28], &byterate, 4);
        uint16_t blockalign = numchannels * (pFlac->bitsPerSample / 8);
        memcpy(&data[32], &blockalign, 2);
        uint16_t bitspersample = pFlac->bitsPerSample;
        memcpy(&data[34], &bitspersample, 2);
        memcpy(&data[36], "data", 4);
        uint32_t totalsize = pFlac->totalPCMFrameCount * pFlac->channels * sizeof(int16_t);
        memcpy(&data[40], &totalsize, 4);
        unsigned tcopy = MIN(44, end+1) - start;
        memcpy(&mytest->flacbuffer[start], data, tcopy);
        bytesleft -= tcopy;         
    }
    unsigned pcmframesize = (pFlac->channels * (pFlac->bitsPerSample/8));
    uint32_t count = bytesleft / pcmframesize;
    if((bytesleft % pcmframesize) > 0)  {
        count++;
    }
    fprintf(stderr, "decoding %u samples\n", count);
    if(count) {
        unsigned startsample;
        unsigned skipbytes;
        if(start < 44) {
            startsample = 0;
            skipbytes = 0;            
        }
        else {
            uint64_t startbyte = start - 44;
            startsample = startbyte / (pFlac->channels * (pFlac->bitsPerSample/8));
            skipbytes = 0;
            /*skipbytes = (startbyte+1) % (pFlac->channels * (pFlac->bitsPerSample/8));
            if(skipbytes > 0) {
                startsample++;
                fprintf(stderr, "skipbytes %u\n", skipbytes);
            }
            */
        }
        if(!drflac_seek_to_pcm_frame(pFlac, startsample))
        {
            return false;   
        }
        int16_t *raw16Samples = malloc((size_t)count * pFlac->channels * sizeof(int16_t));
        if(raw16Samples == NULL)
        {
            return false;
        }    
        if(drflac_read_pcm_frames_s16(mytest->pFlac, count, raw16Samples) != count)
        {
            free(raw16Samples);
            return false;     
        }
        uint8_t *tbuf = (uint8_t*)raw16Samples;
        memcpy(&mytest->flacbuffer[mytest->largest_offset-bytesleft],  tbuf + skipbytes, (size_t)bytesleft);       
        free(raw16Samples);
    }
    
    return true;
}

void * _mytest_get_wav_seg(_mytest *mytest, uint64_t start, size_t count)
{
    drflac *pFlac = mytest->pFlac;
    // read in the desired amount of samples   
    if(!drflac_seek_to_pcm_frame(pFlac, start))
    {
        return NULL;
    }     
    fprintf(stderr, "seeked to absolute\n");
    mytest->largest_offset = 44+ (count * pFlac->channels * sizeof(int16_t));
    uint8_t *data =  mytest->malloc(((size_t)count * pFlac->channels * sizeof(int16_t)) + 44 + 1);
    memcpy(data, "RIFF", 4);
    uint32_t chunksize = (count * pFlac->channels * sizeof(int16_t)) + 36;
    memcpy(&data[4], &chunksize, 4);
    memcpy(&data[8], "WAVEfmt ", 8);
    uint32_t pcm = 16;
    memcpy(&data[16], &pcm, 4);
    uint16_t audioformat = 1;
    memcpy(&data[20], &audioformat, 2);
    uint16_t numchannels = pFlac->channels;
    memcpy(&data[22], &numchannels, 2);
    uint32_t samplerate = pFlac->sampleRate;
    memcpy(&data[24], &samplerate, 4);
    uint32_t byterate = samplerate * numchannels * (pFlac->bitsPerSample / 8);
    memcpy(&data[28], &byterate, 4);
    uint16_t blockalign = numchannels * (pFlac->bitsPerSample / 8);
    memcpy(&data[32], &blockalign, 2);
    uint16_t bitspersample = pFlac->bitsPerSample;
    memcpy(&data[34], &bitspersample, 2);
    memcpy(&data[36], "data", 4);
    uint32_t totalsize = count * pFlac->channels * sizeof(int16_t);
    memcpy(&data[40], &totalsize, 4);
    
    int16_t *rawSamples = (int16_t*)(data + 44);
    if(rawSamples == NULL)
    {
        return NULL;
    }    
    if(drflac_read_pcm_frames_s16(mytest->pFlac, count, rawSamples) != count)
    {
        free(data);
        return NULL;    
    }
    
    return (void*)data;
}

void _mytest_delete(_mytest *mytest)
{
	drflac_close(mytest->pFlac);
}

void *mytest_perl_malloc(size_t size)
{
	void *ret;
	Newx(ret, size, uint8_t);
	return ret;
}

void mytest_perl_free(void *ptr)
{
    Safefree(ptr);
}

void *mytest_perl_realloc(void *ptr, size_t size)
{
	Renew(ptr, size, uint8_t);
	return ptr;
}

typedef _mytest* Mytest;

MODULE = Mytest		PACKAGE = Mytest

Mytest
new(filename)
        const char *filename
	CODE:		
		_mytest *mytest;
		Newx(mytest, 1, _mytest);
		fprintf(stderr, "pointer %p\n", mytest);
		if(_mytest_new(mytest, filename, &mytest_perl_malloc, &mytest_perl_free, &mytest_perl_realloc))
		{
	        RETVAL = mytest;
		}
		else
		{
			/* to do exception instead?*/
			RETVAL = (Mytest)&PL_sv_undef;
		}
		
	OUTPUT:
        RETVAL


void 
DESTROY(mytest)
        Mytest mytest
	CODE:
		_mytest_delete(mytest);
		fprintf(stderr, "deleted decoder\n");

SV *
get_flac(mytest, start, count)
        Mytest mytest
		UV start
		size_t count
	CODE:
	    fprintf(stderr, "_pointer %p\n", mytest);
		SV *data = NULL;		
		if(_mytest_get_flac(mytest, start, count))
		{
			fprintf(stderr, "flacbuffer at %p largest_offset %p\n", mytest->flacbuffer,mytest->largest_offset);
			mytest->flacbuffer[mytest->largest_offset] = '\0';
			data = newSV(0);
			sv_usepvn_flags(data, (char*)mytest->flacbuffer, mytest->largest_offset, SV_SMAGIC | SV_HAS_TRAILING_NUL);
			fprintf(stderr, "pvx %p\n", SvPVX(data));
		}
        else
        {
            data = &PL_sv_undef;
        }
	RETVAL = data;
    OUTPUT:
        RETVAL

SV *
get_wav(mytest, start, end)
        Mytest mytest
		UV start
		UV end
	CODE:
        SV *data = NULL;
        if(_mytest_get_wav(mytest, start, end))
        {
            mytest->flacbuffer[mytest->largest_offset] = '\0';
			data = newSV(0);
			sv_usepvn_flags(data, (char*)mytest->flacbuffer, mytest->largest_offset, SV_SMAGIC | SV_HAS_TRAILING_NUL);
			fprintf(stderr, "pvx %p\n", SvPVX(data));
        }
        else
        {
            data = &PL_sv_undef;
        }
    RETVAL = data;
    OUTPUT:
        RETVAL
        
SV *
get_wav_seg(mytest, start, count)
        Mytest mytest
		UV start
		size_t count
	CODE:
        SV *data = NULL;
        void *wav = _mytest_get_wav_seg(mytest, start, count);
        if(wav)
        {
            mytest->flacbuffer[mytest->largest_offset] = '\0';
			data = newSV(0);
			sv_usepvn_flags(data, (char*)wav, mytest->largest_offset, SV_SMAGIC | SV_HAS_TRAILING_NUL);
			fprintf(stderr, "pvx %p\n", SvPVX(data));
        }
        else
        {
            data = &PL_sv_undef;
        }
    RETVAL = data;
    OUTPUT:
        RETVAL
