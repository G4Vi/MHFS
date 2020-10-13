const STATE = {
  'MORE_DATA' : 0,
  'FRAMES_AVAILABLE' : 1,
  'READ_INDEX' : 2,
  'WRITE_INDEX' : 3,
  'RING_BUFFER_LENGTH': 4,
};

class MusicProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this._initialized = false;
    this.port.onmessage = (e) => {
          console.log(e.data);
          if(e.data.message == 'init') {
             const sharedbuffers = e.data.sharedbuffers;
              this._States = new Int32Array(sharedbuffers.states);
              this._AudioRingBuffer = [new Float32Array(sharedbuffers.arb[0]), new Float32Array(sharedbuffers.arb[1])];
              this._RingBufferLength = this._States[STATE.RING_BUFFER_LENGTH];
              this._initialized = true;
          }
    };
  }

  _pullFrames(outputArray) {
    const readIndex = this._States[STATE.READ_INDEX];
    const fAvail = Atomics.load(this._States, STATE.FRAMES_AVAILABLE);
    const tocopy = Math.min(this._RingBufferLength -fAvail, outputArray[0].length);
    const nextReadIndex = readIndex + tocopy;
    let newReadIndex;
    for(let chanIndex = 0; chanIndex < outputArray.length; chanIndex++) {
        if(nextReadIndex < this._RingBufferLength) {
          //console.log('read COPY begin ' + readIndex, ' past end ' + nextReadIndex + ' tocopy ' + tocopy + ' currentFrame ' + currentFrame);
          outputArray[chanIndex].set(this._AudioRingBuffer[chanIndex].subarray(readIndex, nextReadIndex));
          newReadIndex =  this._States[STATE.READ_INDEX] + tocopy;         
        }
        else {
          let overflow = nextReadIndex - this._RingBufferLength;          
          let firstHalf = this._AudioRingBuffer[chanIndex].subarray(readIndex);
          //console.log('read COPY begin ' + readIndex, ' past end ' + (readIndex + firstHalf.length) + ' tocopy ' + firstHalf.length);
          let secondHalf = this._AudioRingBuffer[chanIndex].subarray(0, overflow);
          //console.log('read COPY begin ' + 0, ' past end ' + secondHalf.length + ' tocopy ' + secondHalf.length);          
          outputArray[chanIndex].set(firstHalf);
          outputArray[chanIndex].set(secondHalf, firstHalf.length);
          newReadIndex = secondHalf.length;          
        }
    }
    this._States[STATE.READ_INDEX] = newReadIndex;
    Atomics.add(this._States, STATE.FRAMES_AVAILABLE, tocopy); 
    // if this happens we just reset the buffer, undo if it happened
    /*if(Atomics.add(this._States, STATE.FRAMES_AVAILABLE, tocopy) === this._RingBufferLength) {
        Atomics.sub(this._States, STATE.FRAMES_AVAILABLE, tocopy);
    }*/
  }

    process (inputs, outputs, parameters) {
      if(!this._initialized) {
        return true;
      }
      this._pullFrames(outputs[0]);
      return true
    }
  }
  
  registerProcessor('MusicProcessor', MusicProcessor);

  