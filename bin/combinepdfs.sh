#!/bin/bash
# Create a pdf a combination of other pdfs in a folder
# Needs ghostscript (gs) and exiftool
# chmod +x combinepdfs.sh

NUMPDFS=0
NUMPAGESCOUNTED=0
folderPath=''
folderName=''
prescript=''
pdfs=()

outputName()
{
  if [ "${#prescript}" -gt 0 ]
  then
    echo "$prescript"
  else
    echo "$folderName"
  fi
}

checkNumPagesInPDF()
{
  echo "checkNumPagesInPDF..."
  NUMPAGES=$(exiftool -T -PageCount -s3 "$(outputName).pdf")

  if [ "$NUMPAGES" -eq "$NUMPAGESCOUNTED" ] && [ "$NUMPAGESCOUNTED" -gt 0 ]
  then
    echo "Success!"
    echo "Combined PDFs: $NUMPDFS. Total number of pages: $NUMPAGESCOUNTED. Merged number of pages: $NUMPAGES"
    echo ""

    checkContinue
  else
    echo "Something failed."
    echo "Combined PDFs: $NUMPDFS. Total number of pages: $NUMPAGESCOUNTED. Merged number of pages: $NUMPAGES"
    echo ""
    exit
  fi
}

createPdf()
{
  echo "createPdf..."
  printf '%s\n' "${pdfs[@]}"
  gs -q -dNOPAUSE -dBATCH -sDEVICE=pdfwrite -dPDFSETTINGS=/prepress -sOutputFile="$(outputName).pdf" "${pdfs[@]}"
  checkNumPagesInPDF
}

getPDFs()
{
  echo "getPDFs..."

  if [ -e "$(outputName).pdf" ]
  then
    echo "Already have $(outputName).pdf"
    return
  fi

  NUMPDFS=0
  NUMPAGESCOUNTED=0
  pdfs=()
  while IFS= read -r name; do
    echo "$name"
    pageCount=$(exiftool -T -PageCount -s3 "$name")
    NUMPDFS=$(($NUMPDFS+1))
    NUMPAGESCOUNTED=$(($NUMPAGESCOUNTED+$pageCount))
    pdfs+=("$name")
  done < <(find . -maxdepth 1 -name "$prescript*.pdf" | sort -u | cut -c3-)

  createPdf
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

getFolderPath()
{
  echo "What is the path of the directory the PDFs are in?"
  echo "Enter 'y' to use the existing value of: $folderPath"
  echo "Otherwise, enter the new path"
  while true; do
    read -p "Answer: " yn
    case "$yn" in
        [yY] ) break;;
        * ) folderPath="$yn"; break;;
    esac
  done
  cd "$folderPath"
  echo "  folderPath=$folderPath"
  echo ""

  echo "Combine all PDFs in folder $folderPath?"
  echo "Enter 'y' to combine all PDFs"
  echo "Otherwise, enter the start of the names of the PDFs to combine"
  folderName=''
  prescript=''
  while true; do
    read -p "Answer: " yn
    case "$yn" in
        [yY] ) folderName="${PWD##*/}"; break;;
        * ) prescript="$yn"; break;;
    esac
  done
  echo "  folderName=$folderName, prescript=$prescript"
  echo ""

  getPDFs
}

startScript()
{
  echo "startScript..."
  getFolderPath
}

echo "Start of script..."
startScript
echo "End of script..."
