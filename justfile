app := "build/RadialRingMenu.app"
installed := "/Applications/RadialRingMenu.app"

# With only the Command Line Tools installed, swift-testing lives outside the
# default search paths.
clt_frameworks := "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
test_flags := if path_exists(clt_frameworks / "Testing.framework") == "true" {
    "-Xswiftc -F" + clt_frameworks + " -Xlinker -F" + clt_frameworks + " -Xlinker -rpath -Xlinker " + clt_frameworks
} else { "" }

default:
    @just --list

# Build build/RadialRingMenu.app
app:
    swift build -c release
    rm -rf "{{app}}"
    mkdir -p "{{app}}/Contents/MacOS"
    cp "$(swift build -c release --show-bin-path)/RadialRingMenu" "{{app}}/Contents/MacOS/"
    cp Support/Info.plist "{{app}}/Contents/Info.plist"
    # A stable identity keeps permissions like Accessibility across rebuilds;
    # ad-hoc signing makes every build look like a new app to macOS.
    identity="$(security find-identity -v -p codesigning | grep -o '"Apple Development[^"]*"' | head -1 | tr -d '"')"; codesign --force --sign "${identity:--}" "{{app}}"

# Build, replace the copy in /Applications and restart it
install: app stop
    rm -rf "{{installed}}"
    ditto "{{app}}" "{{installed}}"
    open "{{installed}}"

# Build and run from build/ without installing
run: app stop
    open "{{app}}"

# Quit the running app, wherever it was started from
stop:
    -pkill -x RadialRingMenu
    for _ in $(seq 50); do pgrep -x RadialRingMenu > /dev/null || exit 0; sleep 0.1; done; echo "RadialRingMenu didn't quit" >&2; exit 1

test:
    swift test {{test_flags}}

# Validate the config and list the apps it resolves to
check:
    swift run RadialRingMenu --check

clean:
    rm -rf .build build
