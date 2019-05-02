#!/bin/bash

gcc -Wall -fPIC -shared -o tarsize.so tarsize.c -ldl

