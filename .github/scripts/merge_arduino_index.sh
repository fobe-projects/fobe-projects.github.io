#!/bin/bash

# Merge package_esp32_index.json and package_nrf52_index.json into package_fobe_index.json

set -e  # Exit on error

# Get the directory where this script is located and navigate to project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
cd "${PROJECT_ROOT}"

# Function to clean up build directory
cleanup() {
    if [ -d "build" ]; then
        echo "Cleaning up build directory..."
        rm -rf build
    fi
}

# Set trap to clean up on exit or error
trap cleanup EXIT

# Check if jq is installed
if ! command -v jq &> /dev/null; then
    echo "Error: jq tool is required to process JSON files"
    echo "On macOS, you can install it with: brew install jq"
    exit 1
fi

# Function to find the latest version directory
find_latest_version() {
    local platform_dir="$1"
    if [ ! -d "$platform_dir" ]; then
        echo ""
        return
    fi
    
    # Find all version directories and sort them
    find "$platform_dir" -maxdepth 1 -type d -name "*.*.*" | \
        xargs -I {} basename {} | \
        sort -V | \
        tail -1
}

echo "Loading package index files from local directories..."

# Create build directory
mkdir -p build

# Find latest ESP32 version and copy index file
echo "Looking for ESP32 package index..."
ESP32_LATEST_VERSION=$(find_latest_version "arduino/esp32")
if [ -z "$ESP32_LATEST_VERSION" ]; then
    echo "Error: No ESP32 version directories found in arduino/esp32/"
    exit 1
fi

ESP32_INDEX_FILE="arduino/esp32/$ESP32_LATEST_VERSION/package_fobe_esp32_index.json"
if [ ! -f "$ESP32_INDEX_FILE" ]; then
    echo "Error: Could not find $ESP32_INDEX_FILE"
    exit 1
fi

cp "$ESP32_INDEX_FILE" build/package_esp32_index.json
echo "✓ Copied ESP32 package index from version $ESP32_LATEST_VERSION"

# Find latest nRF52 version and copy index file
echo "Looking for nRF52 package index..."
NRF52_LATEST_VERSION=$(find_latest_version "arduino/nrf52")
if [ -z "$NRF52_LATEST_VERSION" ]; then
    echo "Error: No nRF52 version directories found in arduino/nrf52/"
    exit 1
fi

NRF52_INDEX_FILE="arduino/nrf52/$NRF52_LATEST_VERSION/package_fobe_nrf52_index.json"
if [ ! -f "$NRF52_INDEX_FILE" ]; then
    echo "Error: Could not find $NRF52_INDEX_FILE"
    exit 1
fi

cp "$NRF52_INDEX_FILE" build/package_nrf52_index.json
echo "✓ Copied nRF52 package index from version $NRF52_LATEST_VERSION"

# Check if required files exist after download
if [ ! -f "build/package_esp32_index.json" ]; then
    echo "Error: Failed to download package_esp32_index.json"
    exit 1
fi

if [ ! -f "build/package_nrf52_index.json" ]; then
    echo "Error: Failed to download package_nrf52_index.json"
    exit 1
fi

if [ ! -f "arduino/package_fobe_index.json" ]; then
    echo "Error: arduino/package_fobe_index.json does not exist, please create a base version first"
    exit 1
fi

echo "Starting smart merge of JSON files..."

# Create temporary file
TEMP_FILE=$(mktemp)

# Complex merge logic
jq -s '
# Get original file, ESP32 file, and nRF52 file
.[2] as $original |
.[0] as $esp32 |
.[1] as $nrf52 |

# Merge platforms: keep original versions, add new versions, overwrite with new one for the same version number
($original.packages[0].platforms // []) as $original_platforms |
($esp32.packages[0].platforms // []) as $esp32_platforms |
($nrf52.packages[0].platforms // []) as $nrf52_platforms |

# Create an array of all new platforms (with deduplication)
($esp32_platforms + $nrf52_platforms | 
  group_by(.architecture + "_" + .version) | 
  map(.[0])
) as $new_platforms |

# Merge platforms logic
(
  # First add all new platforms (already deduplicated)
  $new_platforms +
  # Then add original platforms, but only those whose architecture and version do not exist in new platforms
  ($original_platforms | map(
    . as $orig |
    if ($new_platforms | any(.architecture == $orig.architecture and .version == $orig.version))
    then empty
    else $orig
    end
  ))
) as $merged_platforms |

# Merge tools: completely based on new files, keep tools with the same name but different versions
($esp32.packages[0].tools // []) as $esp32_tools |
($nrf52.packages[0].tools // []) as $nrf52_tools |

# Merge all tools, deduplication logic: keep only one with the same name and version
($esp32_tools + $nrf52_tools | 
  group_by(.name + "_" + .version) | 
  map(.[0])
) as $merged_tools |

{
  "packages": [
    {
      "name": ($original.packages[0].name),
      "maintainer": ($original.packages[0].maintainer),
      "websiteURL": ($original.packages[0].websiteURL),
      "help": ($original.packages[0].help),
      "platforms": $merged_platforms,
      "tools": $merged_tools
    }
  ]
}
' build/package_esp32_index.json build/package_nrf52_index.json arduino/package_fobe_index.json > "$TEMP_FILE"

# Check if the generated file is valid JSON
if jq empty "$TEMP_FILE" 2>/dev/null; then
    # Move temporary file to target location
    mv "$TEMP_FILE" arduino/package_fobe_index.json
    echo "✅ Smart merge completed!"
    
    # Display merge statistics
    echo ""
    echo "📊 Merge Statistics:"
    
    # Count platform numbers
    ESP32_PLATFORMS=$(jq '.packages[0].platforms | length' build/package_esp32_index.json)
    NRF52_PLATFORMS=$(jq '.packages[0].platforms | length' build/package_nrf52_index.json)
    FINAL_PLATFORMS=$(jq '.packages[0].platforms | length' arduino/package_fobe_index.json)
    
    echo "  ESP32 new platforms: $ESP32_PLATFORMS"
    echo "  nRF52 new platforms: $NRF52_PLATFORMS"
    echo "  Total platforms after merge: $FINAL_PLATFORMS"
    
    # Count tools
    ESP32_TOOLS=$(jq '.packages[0].tools | length' build/package_esp32_index.json 2>/dev/null || echo "0")
    NRF52_TOOLS=$(jq '.packages[0].tools | length' build/package_nrf52_index.json 2>/dev/null || echo "0")
    FINAL_TOOLS=$(jq '.packages[0].tools | length' arduino/package_fobe_index.json)
    
    echo "  ESP32 tools: $ESP32_TOOLS"
    echo "  nRF52 tools: $NRF52_TOOLS"
    echo "  Total tools after merge: $FINAL_TOOLS"
    
    # Verify platform architectures
    echo ""
    echo "📋 Included platform architectures and versions:"
    jq -r '.packages[0].platforms[] | "  - \(.architecture): \(.name) v\(.version)"' arduino/package_fobe_index.json | sort
    
    # Verify tools
    echo ""
    echo "🔧 Included tools:"
    jq -r '.packages[0].tools[] | "  - \(.name) v\(.version)"' arduino/package_fobe_index.json | sort
    
    # Show platform update information
    echo ""
    echo "🔄 Platform update check:"
    
    # Compare versions for each architecture
    for arch in $(jq -r '.packages[0].platforms[].architecture' arduino/package_fobe_index.json | sort | uniq); do
        NEW_VERSION=$(jq -r --arg arch "$arch" '.packages[0].platforms[] | select(.architecture == $arch) | .version' arduino/package_fobe_index.json | head -1)
        echo "  - $arch: v$NEW_VERSION (merged)"
    done
    
else
    echo "❌ Error: Generated JSON file is invalid"
    rm -f "$TEMP_FILE"
    exit 1
fi

echo ""
echo "🎉 Smart merge completed!"