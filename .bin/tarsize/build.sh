#!/bin/bash

gcc -Wall -fPIC -shared -o tarsize.so tarsize.c -ldl

gcc -Wall -fPIC -shared -o tarpart.so tarpart.c -ldl

