#!/bin/bash
# Create a pdf from images in a folder
# chmod +x createallpdfs.sh

parentPath=''
pdfName=''
NUMPAGES=0
NUMIMAGES=0
isInsideFolder='false'
createdNonFolderPdf='false'

checkNumPagesInPDF()
{
  echo "checkNumPagesInPDF..."
  NUMPAGES=$(exiftool -T -PageCount -s3 "../$pdfName.pdf")
  NUMIMAGES=$(ls | grep -Ei '\.jpg$|\.jpeg$|\.png$|\.gif$|\.bmp$' 2> /dev/null | wc -l)

  if [ "$NUMPAGES" -eq "$NUMIMAGES" ] && [ "$NUMIMAGES" -gt 0 ]
  then
    echo "Success!"
    echo "Number of Pages: $NUMPAGES. Number of images: $NUMIMAGES"
    echo ""
  else
    echo "Something failed."
    echo "Number of Pages: $NUMPAGES. Number of images: $NUMIMAGES"
    echo ""
    exit
  fi

  if [ "$isInsideFolder" = "false" ]
  then
    createdNonFolderPdf='true'
  else
    cd ..
  fi
}

createPdf()
{
  echo "createPdf..."
  pdfName="${PWD##*/}"

  if [ -a "../$pdfName.pdf" ]
  then
    echo "$pdfName.pdf already exists"
  else
    ls | grep -Ei "\.jpg$|\.jpeg$|\.png$|\.gif$|\.bmp$" | sort -n | sed -e 's/^/"/' | sed -e 's/$/"/' | convert @- -quality 100 "../$pdfName.pdf"
    
    checkNumPagesInPDF
  fi
}

getFolders()
{
  echo "getFolders..."

  for f in *
  do
    if [ -d "$f" ]
    then
      cd "$f"
      echo "In folder: ${PWD##*/}"
      isInsideFolder='true'
      createPdf
    else
      isInsideFolder='false'
      if [ "$createdNonFolderPdf" = "false" ]
      then
        createPdf
      fi
    fi
  done

  checkContinue
}

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

getParentFolderPath()
{
  read -p "What is the path of the parent directory? " parentPath
  cd "$parentPath"
  getFolders
}

startScript()
{
  echo "startScript..."
  createdNonFolderPdf='false'
  getParentFolderPath
}

echo "Start of script..."
startScript
echo "End of script..."




