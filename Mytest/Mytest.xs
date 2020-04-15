#define PERL_NO_GET_CONTEXT
#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "ppport.h"
#include <stdint.h>
#include "FLAC/stream_decoder.h"
#include "FLAC/stream_encoder.h"

typedef void *(* malloc_ptr) (size_t);
typedef void  (* free_ptr)   (void*);
typedef void *(* realloc_ptr)(void *, size_t); 

typedef struct {
	malloc_ptr  malloc;
	free_ptr    free;
	realloc_ptr realloc;

    uint32_t frame_count;
	uint32_t current_frame;
	FLAC__StreamDecoder *decoder;
	uint64_t frame_location[4096];
	FILE *file;

	FLAC__uint64 total_samples;
	unsigned sample_rate;
	unsigned channels;
	unsigned bps;

	uint64_t decoded_samples;
	uint64_t samples_left;
	uint8_t *flacbuffer;
    uint64_t flacbuffersize;
	FLAC__StreamEncoder *encoder;
    uint64_t file_offset;
    uint64_t largest_offset;

} _mytest;

#define MIN(a,b) (((a)<(b))?(a):(b))

FLAC__StreamDecoderWriteStatus write_callback(const FLAC__StreamDecoder *decoder, const FLAC__Frame *frame, const FLAC__int32 * const buffer[], void *client_data)
{    
	_mytest *mytest = (_mytest*)client_data;
	if(buffer [0] == NULL) {
		fprintf(stderr, "ERROR: buffer [0] is NULL\n");
		return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT;
	}
	/*
	if(buffer [1] == NULL) {
		fprintf(stderr, "ERROR: buffer [1] is NULL\n");
		return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT;
	}
	*/
	mytest->decoded_samples += frame->header.blocksize; 
    if(FLAC__stream_encoder_process(mytest->encoder, buffer, MIN(mytest->samples_left, frame->header.blocksize)))
    {
        fprintf(stderr, "successfully decoded %u, encoded %" PRIu64 "samples\n",  frame->header.blocksize, MIN(mytest->samples_left, frame->header.blocksize));
        mytest->samples_left -= frame->header.blocksize;
        return FLAC__STREAM_DECODER_WRITE_STATUS_CONTINUE;
    }
    return FLAC__STREAM_DECODER_WRITE_STATUS_ABORT;    	
}



void metadata_callback(const FLAC__StreamDecoder *decoder, const FLAC__StreamMetadata *metadata, void *client_data)
{
	(void)decoder, (void)client_data;
	_mytest *mytest = (_mytest*)client_data;

	if(metadata->type == FLAC__METADATA_TYPE_STREAMINFO) {
		((_mytest*)client_data)->total_samples = metadata->data.stream_info.total_samples;
		((_mytest*)client_data)->sample_rate = metadata->data.stream_info.sample_rate;
		((_mytest*)client_data)->channels = metadata->data.stream_info.channels;
		((_mytest*)client_data)->bps = metadata->data.stream_info.bits_per_sample;

		fprintf(stderr, "sample rate    : %u Hz\n", mytest->sample_rate);
		fprintf(stderr, "channels       : %u\n", mytest->channels);
		fprintf(stderr, "bits per sample: %u\n", mytest->bps);
		fprintf(stderr, "total samples  : %" PRIu64 "\n", mytest->total_samples);
        fprintf(stderr, "min block size  : %u\n", metadata->data.stream_info.min_blocksize);
        fprintf(stderr, "max block size  : %u\n", metadata->data.stream_info.max_blocksize);
		fprintf(stderr, "min frame size  : %u\n", metadata->data.stream_info.min_framesize);
		fprintf(stderr, "max frame size  : %u\n", metadata->data.stream_info.max_framesize);
       
        uint32_t fc = (mytest->total_samples / metadata->data.stream_info.max_blocksize);
		fc += ((mytest->total_samples % metadata->data.stream_info.max_blocksize) != 0);
		((_mytest*)client_data)->frame_count = fc;
		fprintf(stderr, "total frames  : %u\n", fc);
	}    
}

void error_callback(const FLAC__StreamDecoder *decoder, FLAC__StreamDecoderErrorStatus status, void *client_data)
{
	(void)decoder, (void)client_data;

	fprintf(stderr, "Got error callback: %s\n", FLAC__StreamDecoderErrorStatusString[status]);
}

_mytest *_mytest_new(_mytest *mytest, const char *filename)
{
	memset(mytest, 0, sizeof(*mytest));
	FLAC__StreamDecoder *decoder = 0;
	FLAC__StreamDecoderInitStatus init_status;
    if((decoder = FLAC__stream_decoder_new()) == NULL) {
	    fprintf(stderr, "ERROR: allocating decoder\n");
	    return NULL;
	}
	//(void)FLAC__stream_decoder_set_md5_checking(decoder, true);
	FLAC__stream_decoder_set_md5_checking(decoder, false);
    
    //init_status = FLAC__stream_decoder_init_file(decoder, filename, write_callback, metadata_callback, error_callback, mytest);

    mytest->file = fopen(filename, "rb");
	if(mytest->file  == NULL)
	{
		fprintf(stderr, "ERROR: fopen\n");
	    return NULL;
	}
   
	init_status = FLAC__stream_decoder_init_FILE(decoder, mytest->file, write_callback, metadata_callback, error_callback, mytest);
	if(init_status != FLAC__STREAM_DECODER_INIT_STATUS_OK) {
		fprintf(stderr, "ERROR: initializing decoder: %s\n", FLAC__StreamDecoderInitStatusString[init_status]);
		goto _mytest_new_CLEANUP;
	}

    uint64_t pos;
    if(FLAC__stream_decoder_process_until_end_of_metadata(decoder) && FLAC__stream_decoder_get_decode_position(decoder, &pos))
	{
		mytest->current_frame = 0;
		mytest->decoder = decoder;
		mytest->frame_location[0] = pos;
		mytest->decoded_samples = 0;	
		mytest->samples_left = 0;
		mytest->malloc = &malloc;
		mytest->free   = &free;
		mytest->realloc = &realloc;
		return mytest;		
	}

	_mytest_new_CLEANUP:
    FLAC__stream_decoder_delete(decoder);
	return NULL;
}

bool _mytest_get_frame_location(_mytest *mytest, uint32_t frame_index)
{
	if(mytest->frame_location[frame_index] != 0) return true;
	for(unsigned i = mytest->current_frame; i <= frame_index; i++)
	{
		if(FLAC__stream_decoder_skip_single_frame(mytest->decoder) && (FLAC__stream_decoder_get_state(mytest->decoder) != FLAC__STREAM_DECODER_END_OF_STREAM))
		{
			uint64_t pos;
			if(FLAC__stream_decoder_get_decode_position(mytest->decoder, &pos))
		    {
		    	mytest->current_frame++;
                mytest->frame_location[mytest->current_frame] = pos;
				continue;
		    }
		}
		return false;
	}
	return true;	
}

/*
int _mytest_get_flac_frames(_mytest *mytest, const uint32_t count, void *buf, size_t buf_bytes_left)
{
	int frames_fetched = 0;
    uint32_t s_frame_index = mytest->current_frame;	
	if(!_mytest_get_frame_location(mytest, s_frame_index))
	{
		return -1;
	}
	uint64_t start_loc = mytest->frame_location[s_frame_index];
	while(_mytest_get_frame_location(mytest, ++s_frame_index))
	{
		uint64_t end_loc = mytest->frame_location[s_frame_index];
		size_t framesize = end_loc - start_loc;
		if(framesize > buf_bytes_left) break;
		int64_t fpos = ftell(mytest->file);
		fseek(mytest->file, start_loc, SEEK_SET);
		fread(buf, 1, framesize, mytest->file);
		fseek(mytest->file, fpos, SEEK_SET);
        if(++frames_fetched >= count) break;
		buf = (((uint8_t*)buf) + framesize);
		buf_bytes_left -= framesize;
        start_loc = end_loc;
	}
	return frames_fetched;	
}
*/


size_t _mytest_flac_frames_size(_mytest *mytest, const unsigned count)
{
	int frames_fetched = 0;
    uint32_t s_frame_index = mytest->current_frame;
	// verify we started on a frame	
	if(!_mytest_get_frame_location(mytest, s_frame_index) || count == 0)
	{
		return 0;
	}
	size_t sumsize = 0;
	uint64_t start_loc = mytest->frame_location[s_frame_index];
	while(_mytest_get_frame_location(mytest, ++s_frame_index))
	{
		uint64_t end_loc = mytest->frame_location[s_frame_index];
		sumsize += (end_loc - start_loc);	
        if(++frames_fetched == count)
		{
			return sumsize;
		}	
        start_loc = end_loc;
	}
	return 0;
}

int _mytest_get_flac_frames(_mytest *mytest, void *buf, const int64_t start_loc, const size_t bytes)
{
	fprintf(stderr, "dumping from %" PRId64 " to (not inc)%" PRId64"\n", start_loc, start_loc+bytes);
	int64_t fpos = ftell(mytest->file);
	fseek(mytest->file, start_loc, SEEK_SET);
	fread(buf, 1, bytes, mytest->file);
	fseek(mytest->file, fpos, SEEK_SET);
	return 1;
}


FLAC__StreamEncoderWriteStatus writecb(const FLAC__StreamEncoder *encoder, const FLAC__byte buffer[], size_t bytes, unsigned samples, unsigned current_frame, void *client_data)
{
    _mytest *mytest = (_mytest*)client_data;
    if((mytest->file_offset + bytes) > mytest->flacbuffersize)
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

	mytest->decoded_samples = 0;
    mytest->file_offset     = 0;
    mytest->largest_offset  = 0;
	mytest->samples_left = count;
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
	//ok &= FLAC__stream_encoder_set_verify(mytest->encoder, true);
	ok &= FLAC__stream_encoder_set_verify(mytest->encoder, false);
	ok &= FLAC__stream_encoder_set_compression_level(mytest->encoder, 5);
	ok &= FLAC__stream_encoder_set_channels(mytest->encoder, mytest->channels);
	ok &= FLAC__stream_encoder_set_bits_per_sample(mytest->encoder, mytest->bps);
	ok &= FLAC__stream_encoder_set_sample_rate(mytest->encoder, mytest->sample_rate);
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

	if(FLAC__stream_decoder_seek_absolute(mytest->decoder, start))
	{
		fprintf(stderr, "seeked to absolute\n");
		do {
		    if(mytest->decoded_samples >= count)
		    {
                if(FLAC__stream_encoder_finish(mytest->encoder))
                {
                    fprintf(stderr, "should be encoded by now\n");
					FLAC__stream_encoder_delete(mytest->encoder);
		    	    return true;
                }
                goto _mytest_get_flac_cleanup;	    	
		    }
		}while (FLAC__stream_decoder_process_single(mytest->decoder));		
	}
_mytest_get_flac_cleanup:
	FLAC__stream_encoder_delete(mytest->encoder);
	return false;
}

void _mytest_delete(_mytest *mytest)
{
	FLAC__stream_decoder_delete(mytest->decoder);
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
		if(_mytest_new(mytest, filename))
		{
			mytest->malloc  = &mytest_perl_malloc;
		    mytest->free    = &mytest_perl_free;
		    mytest->realloc = &mytest_perl_realloc;
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

UV
get_flac_frame_count(mytest)
        Mytest mytest
	CODE:
	    RETVAL = mytest->frame_count;
	OUTPUT:
        RETVAL

SV *
get_flac_frames(mytest, count)
        Mytest mytest
		size_t count
	CODE:
	    fprintf(stderr, "_pointer %p\n", mytest);
		int64_t start_loc = mytest->frame_location[mytest->current_frame];
		size_t fsz = _mytest_flac_frames_size(mytest, count);
		fprintf(stderr, "frames size %zu\n", fsz);
		SV *data = newSV(fsz);
		fprintf(stderr, "pvx %p\n", SvPVX(data));
		if(_mytest_get_flac_frames(mytest, SvPVX(data), start_loc, fsz))
		{
			SvCUR_set(data, fsz); 
			SvPOK_on(data);
		}
	RETVAL = data;
    OUTPUT:
        RETVAL

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
			fprintf(stderr, "flacbuffer at %p\n", mytest->flacbuffer);
			if((mytest->file_offset + 1) > mytest->flacbuffersize)
            {
                fprintf(stderr, "reallocating to %" PRIu64 "\n", mytest->flacbuffersize + 1);
                mytest->flacbuffer = mytest->realloc(mytest->flacbuffer, mytest->flacbuffersize + 1);
                if(mytest->flacbuffer == NULL)
                {
					 data = &PL_sv_undef;
		        }				
			}
			if(data != &PL_sv_undef)
			{
				mytest->flacbuffer[mytest->largest_offset] = '\0';
				data = newSV(0);
			    sv_usepvn_flags(data, (char*)mytest->flacbuffer, mytest->largest_offset, SV_SMAGIC | SV_HAS_TRAILING_NUL);
				fprintf(stderr, "pvx %p\n", SvPVX(data));
			}
		}
        else
        {
            data = &PL_sv_undef;
        }
	RETVAL = data;
    OUTPUT:
        RETVAL