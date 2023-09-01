import { Float32AudioRingBufferReader } from './AudioWriterReader.js'


class MusicProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this._initialized = false;
    this.port.onmessage = (e) => {
          console.log(e.data);
          if(e.data.message == 'init') {
                this._audioreader = Float32AudioRingBufferReader.from(e.data.audiobuffer);
                this._initialized = true;
          }
    };
  }

    process (inputs, outputs, parameters) {
      if(!this._initialized) {
        //this._lasttime = currentTime;   
        return true;
      }
      
      /*
      const newtime = currentTime;
      const delta = newtime - this._lasttime;
      if(delta > 0.00291) {
          console.error("ACTUAL XRUN " + delta);
      }
      this._lasttime = newtime;
      */

       // possibly adjust the readindex
      this._audioreader.processmessages();
      
      // fill the buffer with audio
      let amt = this._audioreader.read(outputs[0]);
      if(amt !== 128) {
        this._xrun += 1;
        if(this._xrun === 1) {
            console.log('worklet xrun');
        } else if(this._xrun % 100) {
            console.log('worklet xrun % 100');
        }
      } else {
        this._xrun = 0;
      }
      return true
    }
  }
  
  registerProcessor('MusicProcessor', MusicProcessor);

  