build:
	swift build

test:
	swift test

format:
	swift-format -i Sources/**/*.swift
	swift-format -i Tests/**/*.swift

clean:
	rm -rf .build
