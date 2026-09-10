.PHONY: project test build clean icons

# Generate SendToRemarkable.xcodeproj from project.yml (and the app icon set).
project: icons
	xcodegen generate

# Unit tests for the Swift package (parser, clients, PDF rendering).
test:
	swift test --package-path Packages/RemarkableKit

# Build the app and the embedded share extension without signing.
build: project
	xcodebuild -project SendToRemarkable.xcodeproj -scheme SendToRemarkable -configuration Debug \
		-derivedDataPath build CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY="" build

# Render the app icon set with Pillow (pip3 install pillow).
icons:
	python3 scripts/make-icons.py

clean:
	rm -rf build Packages/RemarkableKit/.build SendToRemarkable.xcodeproj
