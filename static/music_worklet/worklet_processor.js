//import RingBuffer from "./AudioWriterReader.js" import doesnt work in FF

const READER_MSG = {
  'RESET'     : 0, // data param token
  'FRAMES_ADD' : 1 // data param number of frames
};

const WRITER_MSG = {
  'FRAMES_ADD' : 0, // data param tok and number of frames
  'START_TIME' : 1  // data param aqindex, time
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


class MusicProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this._initialized = false;
    this.port.onmessage = (e) => {
          console.log(e.data);
          if(e.data.message == 'init') {
                const sharedbuffers = e.data.sharedbuffers;              
                this._MessageCount = new Uint32Array(sharedbuffers.message_count);
                this._AudioReader    = [RingBuffer.reader(sharedbuffers.arb[0], Float32Array), RingBuffer.reader(sharedbuffers.arb[1], Float32Array)];
                this._MessageReader = RingBuffer.reader(sharedbuffers.reader_messages, Uint32Array);
                this._MessageWriter = RingBuffer.writer(sharedbuffers.writer_messages, Uint32Array);              
                this._tok = 0;
                this._tempmessagebuf = new Uint32Array(3);
                this._tempfloatbuf = new Float32Array(this._tempmessagebuf.buffer);
                this._dataframes = 0;
                this._initialized = true;
          }
    };
  }

  _pullFrames(outputArray) {
    let copied = 0;
    for(let chanIndex = 0; chanIndex < outputArray.length; chanIndex++) {
        copied = this._AudioReader[chanIndex].read(outputArray[chanIndex], this._dataframes);
    }
    if(copied === 0) return;
    this._tempmessagebuf[0] = WRITER_MSG.FRAMES_ADD;
    this._tempmessagebuf[1] = this._tok;
    this._tempmessagebuf[2] = copied;
    this._MessageWriter.write(this._tempmessagebuf);
    Atomics.add(this._MessageCount, MSG_COUNT.WRITER, 3);
    this._dataframes -= copied;
    if((copied < 128) && (this._AudioReader[0]._readindex > 0)) {
        console.log('buffer underrun, copied ' + copied);
    }  
  }

  _SendTime(time, aqindex) {
    this._tempmessagebuf[0] = WRITER_MSG.START_TIME;
    this._tempmessagebuf[1] = aqindex;
    this._tempfloatbuf[2] = time;
    this._MessageWriter.write(this._tempmessagebuf);
    Atomics.add(this._MessageCount, MSG_COUNT.WRITER, 3);
  }

    process (inputs, outputs, parameters) {
      if(!this._initialized) {
        return true;
      }
      
      // process messages
      const messagetotal = Atomics.load(this._MessageCount, MSG_COUNT.READER);
      let messages = messagetotal;
      while(messages > 0) {
          this._MessageReader.read(this._tempmessagebuf,messages);
          if(this._tempmessagebuf[0] === READER_MSG.RESET) {
            this._tok = this._tempmessagebuf[1];
            this._dataframes = 0;
            for(let i = 0; i < this._AudioReader.length; i++) {
              this._AudioReader[i].reset();
            }
            messages -= 2;            
          }
          else if(this._tempmessagebuf[0] === READER_MSG.FRAMES_ADD) {
            const fadd = this._tempmessagebuf[1];
            this._SendTime(currentTime + (this._dataframes/sampleRate), this._tempmessagebuf[2]);
            this._dataframes += fadd;
            messages -= 3;
          }
          else {
            messages -= 2;
          }          
      }
      Atomics.sub(this._MessageCount, MSG_COUNT.READER, messagetotal);
      
      
      this._pullFrames(outputs[0]);
      return true
    }
  }
  
  registerProcessor('MusicProcessor', MusicProcessor);

  