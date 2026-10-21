#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

SDK="$HOME/theos/sdks/iPhoneOS16.5.sdk"
LDID=/usr/local/bin/ldid
CC=clang
CFLAGS="-arch arm64 -isysroot $SDK -miphoneos-version-min=15.0 -fobjc-arc -O2"
BUILD=build

rm -rf "$BUILD" Pin120.ipa
mkdir -p "$BUILD/Payload/Pin120.app/PlugIns/Pin120Broadcast.appex"

echo "== compile app =="
$CC $CFLAGS App/main.m App/AppDelegate.m App/ViewController.m \
    -framework UIKit -framework ReplayKit -framework CoreGraphics \
    -o "$BUILD/Payload/Pin120.app/Pin120"

echo "== compile broadcast extension =="
$CC $CFLAGS Extension/main.m Extension/SampleHandler.m \
    -framework Foundation -framework ReplayKit \
    -o "$BUILD/Payload/Pin120.app/PlugIns/Pin120Broadcast.appex/Pin120Broadcast"

echo "== copy Info.plists =="
cp App/Info.plist "$BUILD/Payload/Pin120.app/Info.plist"
cp Extension/Info.plist "$BUILD/Payload/Pin120.app/PlugIns/Pin120Broadcast.appex/Info.plist"

echo "== codesign (ldid) =="
$LDID -S "$BUILD/Payload/Pin120.app/Pin120"
$LDID -S "$BUILD/Payload/Pin120.app/PlugIns/Pin120Broadcast.appex/Pin120Broadcast"

echo "== package ipa =="
(cd "$BUILD" && zip -qry ../Pin120.ipa Payload)

echo "OK: $(pwd)/Pin120.ipa"
ls -la Pin120.ipa
