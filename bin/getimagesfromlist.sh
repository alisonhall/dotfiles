#!/bin/bash
# Download images from a list of image URLs in a Google spreadsheet
# The spreadsheet URL comes from IMAGE_LIST_CSV_URL (set it in local/shell_local.sh)
# chmod +x getimagesfromlist.sh

downloadImagesAttempt=0


checkForExistingImage()
{
  echo "checkForExistingImage..."
  downloadImagesAttempt=$(($downloadImagesAttempt+1))

  if [ -a urls.txt ]
  then
    while [ -a urls.txt ]; do
      echo ""
      echo "Trying again to get images...."
      echo ""
      getUndownloadedImagesFromUrls
    done
  else
    echo "urls.txt not found"
  fi
}

getImagesFromUrls()
{
  echo "getImagesFromUrls..."
  sort -u urls.txt | uniq -u | wget -i-

  checkIfAllImagesDownloaded
}

getUndownloadedImagesFromUrls()
{
  echo "getUndownloadedImagesFromUrls..."

  while IFS= read -r p; do
    p=${p%$'\r'}  # drop a Windows line ending, if the CSV has them
    filename=${p##*/}
    if [ -a "$filename" ]
    then
      echo "Already have $filename"
    else
      echo "$p" | wget -i-
    fi
  done <urls.txt

  checkIfAllImagesDownloaded
}

checkIfAllImagesDownloaded()
{
  echo "checkIfAllImagesDownloaded..."
  NUMURLS=$(sort -u urls.txt | uniq -u | grep -io '.jpg\|.jpeg\|.png\|.gif\|.bmp' | wc -l)
  # shellcheck disable=SC2010  # image names here have no newlines
  NUMIMAGES=$(ls | grep -Ei '\.jpg$|\.jpeg$|\.png$|\.gif$|\.bmp$' 2> /dev/null | wc -l)

  if [ "$NUMURLS" -eq "$NUMIMAGES" ] && [ "$NUMIMAGES" -gt 0 ]
  then
    echo "Success!"
    echo "Number of URLs: $NUMURLS. Number of images downloaded: $NUMIMAGES"
    downloadImagesAttempt=0
    cleanUpAfterSuccess
  else
    echo "Something FAILED."
    echo "Number of URLs: $NUMURLS. Number of images downloaded: $NUMIMAGES"
    echo ""
    echo ""

    if (($downloadImagesAttempt < 5))
    then
      checkForExistingImage
    else
      echo "After download attempt $downloadImagesAttempt, exiting script"
      echo "Please try again later"
      exit
    fi
  fi
}

cleanUpAfterSuccess()
{
  echo "cleanUpAfterSuccess..."
  rm urls.txt
  echo "Done!"
}

startScript()
{
  echo "startScript..."

  # NOTE: Make sure that the Google spreadsheet Sheet is "Published" as a CSV.
  if [ -z "${IMAGE_LIST_CSV_URL:-}" ]; then
    echo "Set IMAGE_LIST_CSV_URL in local/shell_local.sh to the spreadsheet's published CSV URL"
    exit 1
  fi
  wget -q -O - "$IMAGE_LIST_CSV_URL" > urls.txt

  getImagesFromUrls
}

echo "Start of script..."
startScript
echo "End of script..."

