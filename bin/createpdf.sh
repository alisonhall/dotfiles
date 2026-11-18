#!/bin/bash
# Create a pdf from images in a folder
# chmod +x createpdf.sh

pdfName=${PWD##*/}
inFolderAbove=''
NUMIMAGES=0
NUMPAGES=0

checkContinue()
{
  echo "checkContinue..."
  while true; do
    read -p "Do you wish to start again?  " yn
    case "$yn" in
        [Yy]* ) startScript; break;;
        [Nn]* ) exit;;
        * ) echo "Please answer yes or no.";;
    esac
  done
}

checkNumPagesInPDF()
{
  echo "checkNumPagesInPDF..."
  # shellcheck disable=SC2010  # image names here have no newlines
  NUMIMAGES=$(ls | grep -Ei '\.jpg$|\.jpeg$|\.png$|\.gif$|\.bmp$' 2> /dev/null | wc -l)

  if [ "$inFolderAbove" = "true" ]
  then
    NUMPAGES=$(exiftool -T -PageCount -s3 "../$pdfName.pdf")
  else
    NUMPAGES=$(exiftool -T -PageCount -s3 "$pdfName.pdf")
  fi

  if [ "$NUMPAGES" -eq "$NUMIMAGES" ] && [ "$NUMIMAGES" -gt 0 ]
  then
    echo "Success!"
    echo "Number of Pages: $NUMPAGES. Number of images: $NUMIMAGES"
    echo ""
  else
    echo "Something failed."
    echo "Number of Pages: $NUMPAGES. Number of images: $NUMIMAGES"
    echo ""
  fi
  checkContinue
}

createPdfInLocation()
{
  # The images in number order, kept whole even when their names have spaces
  local images=() image
  while IFS= read -r image; do
    images+=("$image")
  done < <(
    # shellcheck disable=SC2010  # image names here have no newlines
    ls | grep -Ei "\.jpg$|\.jpeg$|\.png$|\.gif$|\.bmp$" | sort -n
  )
  echo "Do you want the PDF to be saved in the folder above this one?"
  echo "Enter 'y' to use above folder"
  echo "Otherwise, it will be saved in the current folder"
  while true; do
    read -p "Answer: " yn
    case "$yn" in
        [yY] )
          inFolderAbove='true';
          convert "${images[@]}" ../"$pdfName".pdf;
          break;;
        * )
          inFolderAbove='false';
          convert "${images[@]}" "$pdfName".pdf;
          break;;
    esac
  done

  echo "Created $pdfName.pdf"
  echo ""
  checkNumPagesInPDF
}

getNewPdfName()
{
  pdfName=${PWD##*/}
  echo "What will be the name of the PDF?"
  echo "Enter 'y' to use the existing value of: $pdfName"
  echo "Otherwise, enter the new name"
  while true; do
    read -p "Answer: " yn
    case "$yn" in
        [yY] ) break;;
        * ) pdfName="$yn"; break;;
    esac
  done
  echo "  pdfName=$pdfName"
  echo ""
  createPdfInLocation
}

getFolderPath()
{
  read -p "What is the path of the directory? " folderPath
  cd "$folderPath" || exit
  getNewPdfName
}

startScript()
{
  echo "startScript..."
  getFolderPath
}

echo "Start of script..."
startScript
echo "End of script..."
