#!/bin/bash
# chmod +x colours_and_formatting.sh

# Original Reference: https://misc.flogisoft.com/bash/tip_colors_and_formatting

allCombinations() {
    echo "ALL MAIN COMBINATIONS:"
    echo
    echo "<Esc>]<FormattingOption>;<ColourBackground>;<ColourForeground>m"
    echo
    #Background
    for clbg in {40..47} {100..107} 49 ; do
        #Foreground
        echo "Background: ${clbg}"
        echo " Default        | Bold           | Dim            | Underlined     | Blink          | Inverted       | Hidden"
        for clfg in {30..37} {90..97} 39 ; do
            #Formatting
            for attr in 0 1 2 4 5 7 ; do
                #Print the result
                echo -en "\x1b[${attr};${clbg};${clfg}m <Esc>[${attr};${clbg};${clfg}m \x1b[0m"
            done
            echo #Newline
        done
    done
    echo
    echo
}

colourNumbers() {
    echo "COLOUR NUMBERS:"
    echo
    echo "For using one of the 256 colors on the foreground (text color), the control sequence is “<Esc>[38;5;<ColorNumber>m” where ColorNumber is one of the following colors"
    echo "For using one of the 256 colors on the background, the control sequence is “<Esc>[48;5;<ColorNumber>m” where ColorNumber is one of the following colors"
    for fgbg in 38 48 ; do # Foreground / Background
        for color in {0..255} ; do # Colors
            # Display the color
            printf "\x1b[${fgbg};5;%sm  %3s  \x1b[0m" $color $color
            # Display 6 colors per lines
            if [ $((($color + 1) % 6)) == 4 ] ; then
                echo # New line
            fi
        done
        echo # New line
    done
    echo
}

dimmingOptions() {
    echo "DIMMING OPTIONS:"
    echo
    for i in {16..21} {21..16} ; do echo -en "\x1b[38;5;${i}m#\x1b[0m" ; done ; echo

    for i in {16..21} {21..16} ; do echo -en "\x1b[48;5;${i}m \x1b[0m" ; done ; echo
    echo
    echo
}

formattingOptions() {
    echo "FORMATTING OPTIONS:"
    echo
    echo -e "<Esc>[1m Bold: \x1b[1mExample\x1b[21m <Esc>[21m: Reset"
    echo -e "<Esc>[2m Dim: \x1b[2mExample\x1b[22m <Esc>[22m: Reset"
    echo -e "<Esc>[4m Underlined: \x1b[4mExample\x1b[24m <Esc>[24m: Reset"
    echo -e "<Esc>[5m Blink: \x1b[5mExample\x1b[25m <Esc>[25m: Reset"
    echo -e "<Esc>[7m Inverted: \x1b[7mExample\x1b[27m <Esc>[27m: Reset"
    echo -e "<Esc>[8m Hidden: \x1b[8mExample\x1b[28m <Esc>[28m: Reset"
    echo
    echo -e "<Esc>[0m \e[0m Reset all attributes"
    echo
    echo
}

printAllOptions() {
    allCombinations
    colourNumbers
    dimmingOptions
    formattingOptions

    echo "ESCAPE CHARACTER:"
    echo
    echo -e "<Esc>: \ e  or \ 033  or  \ x1B   (without space after \)"
}

printHelp() {
    echo -e "colours_and_formatting.sh usage:"
    echo -e "  colours_and_formatting.sh {OPTIONS}"
    echo -e ""
    echo -e "-a      prints all options"
    echo -e "-h      prints help"
    echo -e ""
}

if [ $# -eq 0 ]
  then
    echo "Invalid option: No arguments supplied"
    echo
    printHelp
fi

while getopts ":ah" opt; do
  case $opt in
    a)
      printAllOptions
      ;;
    h)
      printHelp
      ;;
    \?)
      echo "Invalid option: -$OPTARG" >&2
      echo
      printHelp
      ;;
  esac
done

exit 0
