#!/bin/bash

# Set fallback locale to prevent read issues
export LC_ALL=C.UTF-8
export LANG=C.UTF-8

# Install tools
echo "Updating system and installing optipng and jpegoptim..."
sudo apt-get update -qq
sudo apt-get install -y optipng jpegoptim

# Prompt for app name once (no confirmation)
read -rp "Enter your application name (e.g., abcdxyz123): " app_name

# Validate input
if [[ -z "$app_name" ]]; then
  echo "❌ Application name cannot be empty."
  exit 1
fi

# Set path
app_path="/home/master/applications/$app_name/public_html"

# Validate path
if [ ! -d "$app_path" ]; then
  echo "❌ Directory $app_path does not exist."
  exit 1
fi

# Start optimizing
echo "🔧 Optimizing images in $app_path..."

# Find all JPG/JPEG files and optimize them with jpegoptim (verbose output)
jpeg_count=$(find "$app_path" -type f \( -iname "*.jpg" -o -iname "*.jpeg" \) | tee /tmp/jpeg_list.txt | wc -l)

# Apply optimization with verbose output to check changes
cat /tmp/jpeg_list.txt | xargs -d '\n' -r jpegoptim --strip-all --max=85 --verbose

# Find all PNG files and optimize them with optipng
png_count=$(find "$app_path" -type f -iname "*.png" | tee /tmp/png_list.txt | wc -l)
cat /tmp/png_list.txt | xargs -d '\n' -r optipng -o7 --verbose

# Clean up
rm -f /tmp/jpeg_list.txt /tmp/png_list.txt

# Summary
echo "-------------------------------------"
echo "✅ Optimization complete!"
echo "Total JPEG images optimized: $jpeg_count"
echo "Total PNG images optimized : $png_count"
echo "Target path: $app_path"
echo "-------------------------------------"
