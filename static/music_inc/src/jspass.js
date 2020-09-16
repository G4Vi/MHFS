/* For passing js objects to the emscripten, even if it is in an ES6 module */

let jsobjects = [];

const _InsertJSObject = function(val) {
    let objid = 0;
    while(jsobjects[objid]) objid++;
    jsobjects[objid] = val;
    return objid;
}

const _GetJSObject = function(objid) {
    return jsobjects[objid]
}

const _RemoveJSObject = function(objid) {
    jsobjects[objid] = undefined;
}

Module.InsertJSObject = _InsertJSObject; 
Module.GetJSObject = _GetJSObject;
Module.RemoveJSObject = _RemoveJSObject;

