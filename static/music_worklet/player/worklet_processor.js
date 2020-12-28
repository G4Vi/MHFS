//import RingBuffer from "./AudioWriterReader.js" import doesnt work in FF

const READER_MSG = {
  'RESET'     : 0,  // data param token
  'FRAMES_ADD' : 1, // data param number of frames
  'STOP_AT'    : 2  // data param token, uint64 starting_frame to stop
};

const WRITER_MSG = {
  'FRAMES_ADD' : 0,  // data param tok and number of frames
  'START_TIME' : 1,  // data param tok, time
  'START_FRAME': 2,  // data param tok, uint64 frame
  'WRITE_INFO' : 3   // data param tok, uint32 writeindex, uint32 count
}

// number of message slots in use
const MSG_COUNT = {
  'READER' : 0,
  'WRITER' : 1
};




class RingBuffer {

  constructor(sab, type){
    this._readindex = 0;
    this._writeindex = 0;
    this._buffer = new type(sab);    
  }

  static reader(sab, type) {     
      
      return new RingBuffer(sab, type);
  }

  static writer(sab, type) {
     
      return new RingBuffer(sab, type);
  }

  write(arr) {
      const count = arr.length;
      if((this._writeindex+count) < this._buffer.length) {
          this._buffer.set(arr, this._writeindex);
          this._writeindex += count;
      }
      else {
          const splitIndex = this._buffer.length - this._writeindex;
          const firstHalf = arr.subarray(0, splitIndex);
          const secondHalf = arr.subarray(splitIndex);
          this._buffer.set(firstHalf, this._writeindex);
          this._buffer.set(secondHalf);
          this._writeindex = secondHalf.length;
      }
  }

  read(dest, max) {
      const tocopy = Math.min(max, dest.length);
      const nextReadIndex = this._readindex + tocopy;
      if(nextReadIndex < this._buffer.length) {
          dest.set(this._buffer.subarray(this._readindex, nextReadIndex));
          this._readindex += tocopy;       
      }
      else {
          const overflow = nextReadIndex - this._buffer.length;          
          const firstHalf = this._buffer.subarray(this._readindex);
          const secondHalf = this._buffer.subarray(0, overflow);  
          dest.set(firstHalf);
          dest.set(secondHalf, firstHalf.length);
          this._readindex = secondHalf.length;          
      }
      return tocopy;
  }

  reset() {
    this._readindex = 0;
    this._writeindex = 0;
  } 

}

class AudioReader {
  // takes an array of SharedArrayBuffers, one for each channel
  constructor(sabs) {
    this.count = 0; // stores number of sample-frames
    this.arbs = [];
    for(let i = 0; i < sabs.length; i++) {
      this.arbs[i] = RingBuffer.reader(sabs[i], Float32Array);
    }
  }

  reset() {
    this.count = 0;
    for(let i = 0; i < this.arbs.length; i++) {
      this.arbs[i].reset();
    }
  }

  add(num) {
    this.count += num;
    if(this.count > this.arbs[0]._buffer.length) {
      console.error('bufferoverrun dropping frames');
      this.count = this.arbs[0]._buffer.length;      
    }    
  }

  read(outputArray) {
    let copied = 0;
    for(let chanIndex = 0; chanIndex < outputArray.length; chanIndex++) {
        copied = this.arbs[chanIndex].read(outputArray[chanIndex], this.count);
    }
    this.count -= copied;
    return copied;
  }

  writeindex() {
    let wi = this.arbs[0]._readindex + this.count;
    if(wi >= this.arbs[0]._buffer.length) {
      wi -= this.arbs[0]._buffer.length;
    }
    return wi;
  }
}


class MusicProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this._initialized = false;
    this.port.onmessage = (e) => {
          console.log(e.data);
          if(e.data.message == 'init') {
                const sharedbuffers = e.data.sharedbuffers;              
                this._MessageCount = new Uint32Array(sharedbuffers.message_count);
                this._AudioReader    = new AudioReader(sharedbuffers.arb);
                this._MessageReader = RingBuffer.reader(sharedbuffers.reader_messages, Uint32Array);
                this._MessageWriter = RingBuffer.writer(sharedbuffers.writer_messages, Uint32Array);              
                this._tok = 0;
                this._tempmessagebuf = new Uint32Array(3);
                this._tempfloatbuf = new Float32Array(this._tempmessagebuf.buffer);
                this._tempbigbuf = new Uint32Array(4);
                this._tempbigbuf64 = new BigUint64Array(this._tempbigbuf.buffer);
                this._initialized = true;
          }
    };
  }

  _pullFrames(outputArray) {
    let copied = this._AudioReader.read(outputArray);
    // if copied < 128 there was an underrun
    if(copied === 0) return;
    this._tempmessagebuf[0] = WRITER_MSG.FRAMES_ADD;
    this._tempmessagebuf[1] = this._tok;
    this._tempmessagebuf[2] = copied;
    this._MessageWriter.write(this._tempmessagebuf);
    Atomics.add(this._MessageCount, MSG_COUNT.WRITER, 3);     
  }

  _SendTime(time) {
    this._tempmessagebuf[0] = WRITER_MSG.START_TIME;
    this._tempmessagebuf[1] = this._tok;
    this._tempfloatbuf[2]   = time;
    this._MessageWriter.write(this._tempmessagebuf);
    Atomics.add(this._MessageCount, MSG_COUNT.WRITER, 3);
  }

  _SendFrame(frameNum) {
    this._tempbigbuf[0] = WRITER_MSG.START_FRAME;
    this._tempbigbuf[1] = this._tok;
    this._tempbigbuf64[1] = BigInt(frameNum);
    this._MessageWriter.write(this._tempbigbuf);
    Atomics.add(this._MessageCount, MSG_COUNT.WRITER, 4);
  }

  _SendWriteInfo(wi, count) {
    this._tempbigbuf[0] = WRITER_MSG.WRITE_INFO;
    this._tempbigbuf[1] = this._tok;
    this._tempbigbuf[2] = wi;
    this._tempbigbuf[3] = count;
    this._MessageWriter.write(this._tempbigbuf);
    Atomics.add(this._MessageCount, MSG_COUNT.WRITER, 4);
  }

    process (inputs, outputs, parameters) {
      if(!this._initialized) {
        return true;
      }
      
      // process messages
      const messagetotal = Atomics.load(this._MessageCount, MSG_COUNT.READER);
      let messages = messagetotal;
      while(messages > 0) {
          this._MessageReader.read(this._tempmessagebuf,2);
          // RESET, clear the count, no audio data is available
          if(this._tempmessagebuf[0] === READER_MSG.RESET) {
            this._tok = this._tempmessagebuf[1];
            this._AudioReader.reset();           
            messages -= 2;            
          }
          // FRAMES_ADD increment the count, new audio data available
          else if(this._tempmessagebuf[0] === READER_MSG.FRAMES_ADD) {
            const fadd = this._tempmessagebuf[1];
            // return the time the frames are queued for
            this._SendTime(currentTime + (this._AudioReader.count/sampleRate));
            this._SendFrame(currentFrame + this._AudioReader.count);
            this._AudioReader.add(fadd);
            messages -= 2;
          }
          // STOP_AT stop audio starting at time(decrease the count)
          else if(this._tempmessagebuf[0] === READER_MSG.STOP_AT) {
            this._tok = this._tempmessagebuf[1];
            this._MessageReader.read(this._tempbigbuf,2);
            const cancelat = Number(this._tempbigbuf64[0]);          
            this._AudioReader.count =  cancelat > currentFrame ? (cancelat - currentFrame) : 0;
            const writeindex = this._AudioReader.writeindex();
            this._SendWriteInfo(writeindex, this._AudioReader.count);
            messages -= 4;
          }
          else {
            console.error('audioworklet: unknown message ' + this._tempmessagebuf[0]);
            messages -= 2;
          }          
      }
      Atomics.sub(this._MessageCount, MSG_COUNT.READER, messagetotal);
      
      // fill the buffer with our audio if we have it
      this._pullFrames(outputs[0]);
      return true
    }
  }
  
  registerProcessor('MusicProcessor', MusicProcessor);

  