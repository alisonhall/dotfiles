#!/bin/bash
# Download images from a list of image URLs in a Google spreadsheet
# The spreadsheet URL comes from IMAGE_LIST_CSV_URL (set it in ~/.shell_local)
# chmod +x getimagesfromlist.sh

hasDownloadImagesError="false"
downloadImagesAttempt=0
downloadToFolder="~/Downloads"


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

  while read p; do
    filename=$(echo ${p##*/})
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
  NUMIMAGES=$(ls | grep -Ei '\.jpg$|\.jpeg$|\.png$|\.gif$|\.bmp$' 2> /dev/null | wc -l)

  if [ "$NUMURLS" -eq "$NUMIMAGES" -a "$NUMIMAGES" -gt 0 ]
  then
    echo "Success!"
    echo "Number of URLs: $NUMURLS. Number of images downloaded: $NUMIMAGES"
    hasDownloadImagesError="false"
    downloadImagesAttempt=0
    cleanUpAfterSuccess
  else
    echo "Something FAILED."
    hasDownloadImagesError="true"
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

startRequest()
{
  echo "  url=$url"

  cd "$downloadToFolder"
  echo "  In folder:"
  pwd
  echo ""

  checkForExistingImage
}

startScript()
{
  echo "startScript..."

  # NOTE: Make sure that the Google spreadsheet Sheet is "Published" as a CSV.
  if [ -z "${IMAGE_LIST_CSV_URL:-}" ]; then
    echo "Set IMAGE_LIST_CSV_URL in ~/.shell_local to the spreadsheet's published CSV URL"
    exit 1
  fi
  wget -q -O - "$IMAGE_LIST_CSV_URL" > urls.txt

  getImagesFromUrls

	# while IFS="," read -r volume chapter baseUrl seriesName pageStart pageEnd createFolder remainder
	# while IFS="," read -r url remainder
	# do
	# 	if [ "$hasDownloadImagesError" = "false" ]
	# 	then
  #     startRequest
	# 	else
	# 		echo "Errors:"
	# 		echo "hasDownloadImagesError = $hasDownloadImagesError"
	# 		exit
	# 	fi
	# done < "url.txt"
}

echo "Start of script..."
startScript
echo "End of script..."

