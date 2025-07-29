#!/bin/bash

# -----------------------------
# WebP Conversion Bash Script
# -----------------------------
# Converts all .jpg/.jpeg/.png to .webp
# Shows before/after size, installs cwebp if needed
# -----------------------------

# Exit if any command fails
set -e

# Install webp if not installed
if ! command -v cwebp &> /dev/null; then
    echo "🛠️ Installing WebP tools..."
    sudo apt update
    sudo apt install -y webp
fi

# Start stats
echo "📁 Scanning images..."
BEFORE_SIZE=$(du -sh . | cut -f1)
IMAGE_COUNT=$(find . -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" \) | wc -l)
echo "🔎 Found $IMAGE_COUNT images to convert."

# Conversion loop
echo "🔄 Converting images to WebP..."
find . -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" \) | while read -r IMG; do
    WEBP="${IMG%.*}.webp"
    if [[ ! -f "$WEBP" ]]; then
        echo "▶️  Converting: $IMG"
        cwebp -quiet -q 80 "$IMG" -o "$WEBP"
    else
        echo "⏭️  Skipping (already exists): $WEBP"
    fi
done

# End stats
AFTER_SIZE=$(du -sh . | cut -f1)
WEBP_COUNT=$(find . -type f -iname "*.webp" | wc -l)

echo ""
echo "✅ Conversion complete!"
echo "📦 Before: $BEFORE_SIZE"
echo "📉 After:  $AFTER_SIZE"
echo "🖼️  Total .webp files created: $WEBP_COUNT"
