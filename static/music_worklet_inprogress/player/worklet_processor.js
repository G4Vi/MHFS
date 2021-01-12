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
        return true;
      }
      
      const starttime = currentTime;

       // possibly adjust the readindex
      this._audioreader.processmessages();

      
      // fill the buffer with audio
      let cnt = this._audioreader.read(outputs[0]); 
      if(cnt < 128) {
        console.error('XRUN');
      }
      const endtime =   currentTime;
      if((endtime - starttime) > 0.002) {
        console.error('XRUN 2');
      }
      return true
    }
  }
  
  registerProcessor('MusicProcessor', MusicProcessor);

  