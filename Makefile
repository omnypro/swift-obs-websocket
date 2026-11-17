build:
	swift build

test:
	swift test

lint:
	swift format lint --strict --recursive Sources Tests Package.swift

format:
	swift format --in-place --recursive Sources Tests Package.swift

clean:
	rm -rf .build
