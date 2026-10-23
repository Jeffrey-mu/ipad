#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

SDK="$HOME/theos/sdks/iPhoneOS16.5.sdk"
LDID=/usr/local/bin/ldid
CC=clang
CFLAGS="-arch arm64 -isysroot $SDK -miphoneos-version-min=15.0 -fobjc-arc -O2"
BUILD=build

rm -rf "$BUILD" Pin120.ipa
mkdir -p "$BUILD/Payload/Pin120.app"

# 说明：原来的 ReplayKit 广播扩展已经移除。
# 广播/录屏只会把别的 App 的画面抓走，并不会让它们跑 120fps，
# 在 60Hz 的 iPad Pro 2018 上更是完全无效，所以不再打包。

echo "== compile app =="
$CC $CFLAGS App/main.m App/AppDelegate.m App/ViewController.m \
    -framework UIKit -framework QuartzCore -framework CoreGraphics \
    -o "$BUILD/Payload/Pin120.app/Pin120"

echo "== copy Info.plist =="
cp App/Info.plist "$BUILD/Payload/Pin120.app/Info.plist"

echo "== codesign (ldid) =="
$LDID -S "$BUILD/Payload/Pin120.app/Pin120"

echo "== package ipa =="
(cd "$BUILD" && zip -qry ../Pin120.ipa Payload)

echo "OK: $(pwd)/Pin120.ipa"
ls -la Pin120.ipa
