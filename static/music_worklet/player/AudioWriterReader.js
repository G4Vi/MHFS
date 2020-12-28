class RingBuffer {

    constructor(sab, type){
        this._buffer = new type(sab);
        this._readindex = 0;
        this._writeindex = 0;
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

export {RingBuffer};

