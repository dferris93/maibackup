#!/bin/bash
set -o pipefail

if [[ -z "$1" ]]
then
        echo "Useage: mksymlinks <directory>"
        exit 1
fi

PREVIOUIS_DIR_NAME="none"
echo '#!/bin/bash'
while IFS=$'\0' read -r -d '' i
do
    OUTPUT=$(readlink $i)
    DIRNAME=$(dirname $OUTPUT)
    LINKDIRNAME=$(dirname $i)
    ISRELATIVE=$(echo $OUTPUT | cut -d '/' -f 1 | grep "\.\.")
    if [[ $ISRELATIVE == '..' || $DIRNAME == '.' ]]
    then
	if [[ $PREVIOUS_DIR_NAME != $LINKDIRNAME ]]
	then
		PREVIOUS_DIR_NAME="$LINKDIRNAME"
        	echo "cd $LINKDIRNAME"
	elif [[ $PREVIOUS_DIR_NAME == "none" ]]
	then
        	echo "cd $LINKDIRNAME"

	fi
	echo "ln -s $OUTPUT $(basename $i)"
    else
	echo "ln -s $OUTPUT $i"
    fi
done < <(find $1 -type l -print0)
unset IFS
