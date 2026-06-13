#!/bin/bash

set -e

if (( $# < 1 )); then
		echo "Error, need to pass input file, but got $# arguments."
		exit 1
fi

INPUTFILE=$1
TRACE_PATH="./trace_$(date +%Y%m%d_%H%M%S).trace"

if [[ $# -ge 2 && "$2" == "--no-build" ]]; then
		echo "Skipped building profiling executable"
else
		echo "Building profiling executable"
		zig build -Dinclude-profile
fi

# generate entitlements for traceability on the fly
echo -e "<?xml version=\"1.0\" encoding=\"UTF-8\"?><!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://apple.com\"><plist version=\"1.0\"><dict><key>com.apple.security.get-task-allow</key><true/></dict></plist>" > Entitlements.plist

codesign -s - -f --entitlements ./Entitlements.plist ./zig-out/bin/_1brc_profile

rm Entitlements.plist # no sense in keeping it around

xcrun xctrace record --template "Time Profiler" --output "$TRACE_PATH" --launch -- ./zig-out/bin/_1brc_profile $INPUTFILE

echo "Opening traces in Instruments"

open "$TRACE_PATH"
