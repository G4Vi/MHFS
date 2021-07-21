#!/bin/sh
set -e
cd "$(dirname "$0")"
# no support for modules in audio worklet on firefox so concat
head -n -2 AudioWriterReader.js > worklet_processor_ff.js
tail -n +2 worklet_processor.js >> worklet_processor_ff.js

