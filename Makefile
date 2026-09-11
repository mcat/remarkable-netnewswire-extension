.PHONY: project test build clean icons

# Optional local settings, kept out of git. Example line:
#   DEVELOPMENT_TEAM=ABCDE12345
-include local.mk
export DEVELOPMENT_TEAM

# With a team, sign the app and the extension and let xcodebuild create the
# certificate and app group as needed. Without one (CI), build unsigned.
ifeq ($(strip $(DEVELOPMENT_TEAM)),)
SIGNING = CODE_SIGNING_ALLOWED=NO CODE_SIGN_IDENTITY=""
else
SIGNING = -allowProvisioningUpdates
endif

# Generate SendToRemarkable.xcodeproj from project.yml (and the app icon set).
project: icons
	xcodegen generate

# Unit tests for the Swift package (parser, clients, PDF rendering).
test:
	swift test --package-path Packages/RemarkableKit

# Build the app and the embedded share extension (signed when DEVELOPMENT_TEAM is set).
build: project
	xcodebuild -project SendToRemarkable.xcodeproj -scheme SendToRemarkable -configuration Debug \
		-derivedDataPath build $(SIGNING) build

# Render the app icon set with Pillow (pip3 install pillow).
icons:
	python3 scripts/make-icons.py

clean:
	rm -rf build Packages/RemarkableKit/.build SendToRemarkable.xcodeproj
