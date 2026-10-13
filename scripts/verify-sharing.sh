#!/bin/zsh
set -euo pipefail
app="${1:?Pass the built Noodle.app path}"
team="$(codesign -dv --verbose=4 "$app" 2>&1 | awk -F= '/^TeamIdentifier=/ { print $2 }')"
bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist")"
expected="$team.$bundle_identifier.sharing"
# The Share extension and the widgets read the shared group and nothing else.
extensions=("$app/Contents/PlugIns/NoodleShare.appex:NoodleShareExtension" "$app/Contents/PlugIns/NoodleWidgets.appex:NoodleWidgetsExtension")
for bundle in "$app" "${extensions[@]%%:*}"; do
    codesign --verify --strict "$bundle"
    group="$(/usr/libexec/PlistBuddy -c 'Print :NoodleSharedGroup' "$bundle/Contents/Info.plist")"
    [[ "$group" == "$expected" ]] || { print -u2 "Share group does not match the signing team in ${bundle:t}"; exit 1; }
    signed="$(codesign -d --entitlements - "$bundle" 2>/dev/null)"
    print -r -- "$signed" | grep -Fq "$expected" || { print -u2 "Missing signed share-group entitlement in ${bundle:t}"; exit 1; }
done
for entry in "${extensions[@]}"; do
    extension="${entry%%:*}" executable="${entry##*:}"
    extension_entitlements="$(codesign -d --entitlements :- "$extension" 2>/dev/null | tr -d '[:space:]')"
    count="$(print -r -- "$extension_entitlements" | grep -o '<key>' | wc -l | tr -d '[:space:]')"
    [[ "$count" == "2" ]] || { print -u2 "${extension:t} must have only sandbox and app-group entitlements"; exit 1; }
    print -r -- "$extension_entitlements" | grep -q '<key>com.apple.security.app-sandbox</key><true/>'
    if otool -L "$extension/Contents/MacOS/$executable" | grep -Eq '/opt/homebrew|/usr/local'; then
        print -u2 "${extension:t} depends on a mutable external library"
        exit 1
    fi
done
print "Sharing and widget signature and sandbox checks passed"
