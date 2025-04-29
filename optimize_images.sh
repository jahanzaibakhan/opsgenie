#!/bin/bash

# Install optipng and jpegoptim
echo "Updating system and installing optipng and jpegoptim..."
sudo apt-get update -qq
sudo apt-get install -y optipng jpegoptim

# Ask for app name
read -p "Enter your application name (e.g., abcdxyz123): " app_name
echo "You entered: $app_name"

# Confirm
read -p "Are you sure this is correct? (y/n): " confirm
if [[ "$confirm" != "y" ]]; then
  echo "Aborted by user."
  exit 1
fi

# Construct path
app_path="/home/master/applications/$app_name/public_html"

# Validate path
if [ ! -d "$app_path" ]; then
  echo "Directory $app_path does not exist. Please check the app name."
  exit 1
fi

# Optimize JPEGs
echo "Optimizing JPEG images..."
jpeg_count=$(find "$app_path" -type f \( -iname "*.jpg" -o -iname "*.jpeg" \) | tee /tmp/jpeg_list.txt | wc -l)
cat /tmp/jpeg_list.txt | xargs -d '\n' -r jpegoptim --strip-all --max=85 > /dev/null

# Optimize PNGs
echo "Optimizing PNG images..."
png_count=$(find "$app_path" -type f -iname "*.png" | tee /tmp/png_list.txt | wc -l)
cat /tmp/png_list.txt | xargs -d '\n' -r optipng -o7 > /dev/null

# Clean up temp files
rm -f /tmp/jpeg_list.txt /tmp/png_list.txt

# Summary
echo "-------------------------------------"
echo "✅ Optimization complete!"
echo "Total JPEG images optimized: $jpeg_count"
echo "Total PNG images optimized : $png_count"
echo "-------------------------------------"
