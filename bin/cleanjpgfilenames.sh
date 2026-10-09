#!/bin/bash
# Remove characters after .jpg in file names in the current folder
# e.g. "photo.jpg?w=800" -> "photo.jpg"
# chmod +x cleanjpgfilenames.sh

# Loop through all items in current directory
for entry in *;
do
    case "$entry" in
        *.jpg)
            # Already clean
            ;;
        *.jpg*)
            # Rename file to everything before the first .jpg, plus the .jpg extension
            newName="${entry%%.jpg*}.jpg"
            mv -i -- "$entry" "$newName"
            echo "Renamed: $entry -> $newName"
            ;;
        *)
            echo "SKIPPING: File does not match pattern: $entry"
            ;;
    esac
done
