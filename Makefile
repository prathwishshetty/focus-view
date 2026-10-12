.PHONY: build test app run xcode clean

build:
	swift build

test:
	swift test

app:
	scripts/bundle.sh release

run: app
	open build/Focus.app

xcode:
	open Focus.xcodeproj

clean:
	rm -rf .build build
