.PHONY: build test app run xcode clean

build:
	swift build

test:
	swift test

app:
	scripts/bundle.sh release

run: app
	open build/Focus.app

# Generates Focus.xcodeproj (requires `brew install xcodegen`).
xcode:
	xcodegen generate
	open Focus.xcodeproj

clean:
	rm -rf .build build Focus.xcodeproj
