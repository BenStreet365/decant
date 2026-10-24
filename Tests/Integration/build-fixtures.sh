#!/bin/zsh
# Builds test disk images for VM testing.
set -euo pipefail
S=${1:-${0:A:h}/.build}
F=$S/fixtures; rm -rf $F; mkdir -p $F/src
cd $F

cat > src/main.swift <<'SW'
import Foundation
// Stays running so "app is running" handling can be exercised.
while true { sleep(1) }
SW
swiftc -O -o src/TestApp src/main.swift

make_app() { # name version bundleid dir
  local app="$4/$1.app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp src/TestApp "$app/Contents/MacOS/TestApp"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $3" -c "Add :CFBundleExecutable string TestApp" \
    -c "Add :CFBundlePackageType string APPL" -c "Add :CFBundleShortVersionString string $2" \
    -c "Add :CFBundleVersion string $2" -c "Add :LSUIElement bool true" "$app/Contents/Info.plist" >/dev/null
  echo "resource $2" > "$app/Contents/Resources/data.txt"
}
make_dmg() { # name srcdir
  hdiutil create -quiet -fs APFS -format UDZO -volname "$1" -srcfolder "$2" -ov "$F/$1.dmg"
}
layout() { mkdir -p "$1"; ln -s /Applications "$1/Applications"; mkdir -p "$1/.background"; echo bg > "$1/.background/bg.png"; }

for v in 1.0 2.0; do
  d=stage-v$v; layout $d; make_app TestApp $v com.example.testapp $d; codesign -s - --force --deep $d/TestApp.app; make_dmg testapp-$v $d
done

d=stage-unsigned; layout $d; make_app TestApp 3.0 com.example.testapp $d; make_dmg unsigned $d

d=stage-tampered; layout $d; make_app TestApp 3.0 com.example.testapp $d; codesign -s - --force $d/TestApp.app
echo tampered >> $d/TestApp.app/Contents/Resources/data.txt; make_dmg tampered $d

d=stage-pkg; layout $d; mkdir -p pkgroot; echo hi > pkgroot/hi.txt
pkgbuild --quiet --root pkgroot --identifier com.example.pkg --version 1 --install-location /tmp $d/Example.pkg; make_dmg pkg $d

d=stage-installer; layout $d; make_app "Install TestApp" 1.0 com.example.testapp.installer $d; codesign -s - --force "$d/Install TestApp.app"; make_dmg installer $d

d=stage-multi; layout $d; make_app TestApp 1.0 com.example.testapp $d; make_app Other 1.0 com.example.other $d
codesign -s - --force $d/TestApp.app; codesign -s - --force $d/Other.app; make_dmg multi $d

d=stage-extras; layout $d; make_app TestApp 1.0 com.example.testapp $d; codesign -s - --force $d/TestApp.app; mkdir $d/Plugins; make_dmg extras $d

d=stage-conflict; layout $d; make_app TestApp 1.0 com.example.impostor $d; codesign -s - --force $d/TestApp.app; make_dmg conflict $d

d=stage-caffeine; layout $d; ditto /Applications/Caffeine.app $d/Caffeine.app; echo "Drag to Applications" > "$d/Read Me.txt"; make_dmg caffeine $d

d=stage-enc; layout $d; make_app TestApp 1.0 com.example.testapp $d; codesign -s - --force $d/TestApp.app
printf 'secret' | hdiutil create -quiet -fs APFS -encryption AES-128 -stdinpass -format UDZO -volname enc -srcfolder $d -ov $F/encrypted.dmg

rm -rf stage-* pkgroot src
ls -la $F
