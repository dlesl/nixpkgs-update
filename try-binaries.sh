#! /usr/bin/env bash
set -euxo pipefail

RESULT_PATH=$1
EXPECTED_VERSION=$2
LOG_FILE=~/.nix-update/try-binaries-log.tmp

rm -f $LOG_FILE

function try_binary_help()
{
    if timeout 5 $1 $2 2>/dev/null 1>/dev/null
    then
        echo "- ran \`$1 $2\` got 0 exit code" >> $LOG_FILE
    fi
}

function try_version_type()
{
    if timeout 5 $1 $2 2>&1 | grep $EXPECTED_VERSION >/dev/null
    then
        echo "- ran \`$1 $2\` and found version $EXPECTED_VERSION" >> $LOG_FILE
    fi
}

function try_binary() {

    try_binary_help "$1" "-h"
    try_binary_help "$1" "--help"
    try_binary_help "$1" "help"

    try_version_type "$1" "-V"
    try_version_type "$1" "-v"
    try_version_type "$1" "--version"
    try_version_type "$1" "version"
    try_version_type "$1" "-h"
    try_version_type "$1" "--help"
    try_version_type "$1" "help"

}

BINARIES=$(find $RESULT_PATH/bin -type f || true)

for b in $BINARIES
do
    try_binary $b
done

if grep -r "$EXPECTED_VERSION" $RESULT_PATH >/dev/null
then
    echo "- found $EXPECTED_VERSION with grep in $RESULT_PATH" >> $LOG_FILE
fi

if find $RESULT_PATH | grep -r "$EXPECTED_VERSION" >/dev/null
then
    echo "- found $EXPECTED_VERSION in filename of file in $RESULT_PATH" >> $LOG_FILE
fi

cat $LOG_FILE || true
