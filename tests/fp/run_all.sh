#!/bin/sh

mkdir -p vectors
./create_vectors.sh
./remove_spaces.sh
./append_ctrlSig.sh
