console.log('postjs');
Module['LoadTypes'] = function(BINDTO, wasmMod) {
    wasmMod = wasmMod || Module;
    BINDTO.ValueInfo = wasmMod._ValueInfo;
    const currentObject = [BINDTO];
    let mainindex = 0;
    BINDTO[wasmMod.UTF8ToString(BINDTO.ValueInfo(mainindex, 1))] = BINDTO.ValueInfo(mainindex, 2); // load MCT_VT_CONST_IV)
    while(1) {
        const ValueType = BINDTO.ValueInfo(mainindex, 0);
        if(ValueType === 0) break;
        if(ValueType === BINDTO.MCT_VT_CONST_IV) {
            BINDTO[wasmMod.UTF8ToString(BINDTO.ValueInfo(mainindex, 1))] = BINDTO.ValueInfo(mainindex, 2);
        }
        else if(ValueType === BINDTO.MCT_VT_CONST_CSTRING) {
            BINDTO[wasmMod.UTF8ToString(BINDTO.ValueInfo(mainindex, 1))] = wasmMod.UTF8ToString(BINDTO.ValueInfo(mainindex, 2));
        }
        else if(ValueType === BINDTO.MCT_VT_ST) {
            const struct = { name: wasmMod.UTF8ToString(BINDTO.ValueInfo(mainindex, 1)), size: BINDTO.ValueInfo(mainindex, 2), members : {}};
            currentObject.push(struct);
        }
        else if(ValueType === BINDTO.MCT_VT_ST_END) {
            const structmeta = currentObject.pop();
            const structPrototype = {
                members : structmeta.members,
                get : function(memberName) {
                    const ptr = (this.ptr + this.members[memberName].offset);
                    if(this.members[memberName].type === BINDTO.MCT_VT_UINT32) {
                        return wasmMod.HEAPU32[ptr  >> 2];
                    }
                    else if(this.members[memberName].type === BINDTO.MCT_VT_UINT64) {
                        return BigInt(wasmMod.HEAPU32[ptr  >> 2]) + (BigInt(wasmMod.HEAPU32[(ptr+4)  >> 2]) << BigInt(32));
                    }
                    else if(this.members[memberName].type === BINDTO.MCT_VT_UINT16) {
                        return wasmMod.HEAPU16[ptr  >> 1];
                    }
                    else if(this.members[memberName].type === BINDTO.MCT_VT_UINT8) {
                        return wasmMod.HEAPU8[ptr];
                    }
                    throw("ENOTIMPLEMENTED");
                }
            };
            const struct = function(ptr) {
                this.ptr = ptr;
            };
            struct.prototype = structPrototype;
            struct.prototype.constructor = struct;
            BINDTO[structmeta.name] = {
                from : (ptr) => new struct(ptr),
                sizeof : structmeta.size
            };
        }
        else if((ValueType === BINDTO.MCT_VT_UINT64) || (ValueType === BINDTO.MCT_VT_UINT32) || (ValueType === BINDTO.MCT_VT_UINT16) || (ValueType === BINDTO.MCT_VT_UINT8)) {
            currentObject[currentObject.length-1].members[wasmMod.UTF8ToString(BINDTO.ValueInfo(mainindex, 1))] = {
                type : ValueType,
                offset : BINDTO.ValueInfo(mainindex, 2)
            };
        }
        mainindex++;
    }
};
//LoadTypes(Module, Module);
