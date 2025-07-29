#!/bin/bash

set -e

echo "========= Installing Required Packages ========="
# Update package list
sudo apt update

# Install pngquant (for PNG) and jpegoptim (for JPG)
sudo apt install -y pngquant jpegoptim

echo -e "\n========= Calculating Size Before Compression ========="
before=$(find . -type f \( -iname "*.png" -o -iname "*.jpg" -o -iname "*.jpeg" \) -exec du -cb {} + | grep total$ | awk '{print $1}')

echo -e "\n========= Compressing PNG Images ========="
find . -type f -iname "*.png" | xargs -P 4 -I{} bash -c '
  echo "Compressing PNG: {}"
  pngquant --quality=65-90 --speed 10 --force --ext .png "{}"
'

echo -e "\n========= Compressing JPG Images ========="
find . -type f \( -iname "*.jpg" -o -iname "*.jpeg" \) | xargs -P 4 -I{} bash -c '
  echo "Compressing JPG: {}"
  jpegoptim --max=85 --strip-all --all-progressive "{}" > /dev/null
'

echo -e "\n========= Calculating Size After Compression ========="
after=$(find . -type f \( -iname "*.png" -o -iname "*.jpg" -o -iname "*.jpeg" \) -exec du -cb {} + | grep total$ | awk '{print $1}')

echo -e "\n========= Compression Summary ========="
echo "Before compression: $((before / 1024)) KB"
echo "After compression : $((after / 1024)) KB"
echo "Space saved       : $(((before - after) / 1024)) KB"
echo "======================================="
