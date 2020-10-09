let aDFull;
let aD2Full;
let aIndex = 0;

class MusicProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this.port.onmessage = (e) => {
          console.log(e.data);
          if(e.data.message == 'addData') {
            aDFull = new Float32Array(e.data.chanzero);
            console.log(aDFull);
            aD2Full = new Float32Array(e.data.chanone);
          }
    };
  }

    process (inputs, outputs, parameters) {
      const output = outputs[0];
      if(!aDFull) return true;
      let aDOne = new Float32Array(aDFull.buffer, aIndex, 128);
      let aDTwo = new Float32Array(aD2Full.buffer, aIndex, 128);
      let audioData = [aDOne, aDTwo];

      let i = 0;
      output.forEach(channel => { 
        channel.set(audioData[i]);
        i++;    
        /*for (let i = 0; i < channel.length; i++) {
          channel[i] = Math.random() * 2 - 1
        }*/
      });
      aIndex += (128*4);
      return true
    }
  }
  
  registerProcessor('MusicProcessor', MusicProcessor);

  