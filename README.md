# Send to reMarkable — a NetNewsWire share extension

A macOS Share extension that sends the article you are reading in
[NetNewsWire](https://netnewswire.com) to a reMarkable tablet. Pick an
article, click **Share**, choose **Send to reMarkable**, and a few seconds later
the article is on the tablet as a document you can read and annotate: text,
headings, lists, quotes, code and **images**, laid out for the device's screen.

```
NetNewsWire ─▶ Share menu ─▶ Send to reMarkable ─▶ PDF sized for the tablet ─▶ reMarkable cloud (or USB)
```

The repository contains:

| Path | What it is |
| --- | --- |
| `Packages/RemarkableKit` | Swift package: HTML → document parser, image fetching, PDF renderer, reMarkable cloud and USB clients. Unit-tested. |
| `App/` | "Send to reMarkable" macOS app (SwiftUI). Hosts the extension and holds the settings: pairing, page size, image options. |
| `Extension/` | The Share extension (`com.apple.share-services`) that appears in NetNewsWire's Share menu. |
| `project.yml` | [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec that generates `SendToRemarkable.xcodeproj`. |

## Requirements

- macOS 13 Ventura or later, Xcode 15 or later.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) and Python 3 with Pillow for the icon.
- An Apple development team. The app and the extension share the pairing
  through an app group, and app groups only work in signed builds. A free
  Apple ID team is enough for local use.
- A reMarkable account (for the cloud transport) or a tablet with the USB
  web interface enabled (for the USB transport).

## Build and install

```sh
brew install xcodegen
pip3 install pillow                        # only for rendering the app icon
DEVELOPMENT_TEAM=YOURTEAMID make project   # renders the icon set, then runs xcodegen
open SendToRemarkable.xcodeproj
```

`make project` runs `scripts/make-icons.py` (which draws the app icon into
`App/Assets.xcassets/AppIcon.appiconset`) and then `xcodegen generate`. Both
outputs are generated files and are not checked in.

To build from the command line with the same team, put
`DEVELOPMENT_TEAM=YOURTEAMID` in an untracked `local.mk` next to the Makefile.
`make build` then signs the app and the extension, and lets `xcodebuild`
create the development certificate and register the app group. Without a
team it builds unsigned, which is what CI does. A signed build is what makes
the pairing shared between the app and the extension; an unsigned build keeps
the token in the login keychain, where only the app can read it without a
prompt. Both targets carry the App Groups and Keychain Sharing entitlements:
on macOS the data-protection keychain also needs the application identifier
that only an embedded provisioning profile provides, and Keychain Sharing is
what makes Xcode embed one. If the first signed build stops with "Build input
file cannot be found: ... .provisionprofile", the profile was created but not
yet installed; run `make build` again.

In Xcode select the **SendToRemarkable** scheme and **Product › Run**. The app
window opens; the extension is embedded in the app bundle. macOS registers
Share extensions automatically for apps that live in `/Applications` or have
been launched once, so run it from Xcode at least once, or archive it and
copy `Send to reMarkable.app` to `/Applications`.

Run the unit tests with `make test` (this only needs the Swift toolchain, no
project generation).

## Pair with your reMarkable account

1. Launch **Send to reMarkable**.
2. Click **Get a code…** (or open <https://my.remarkable.com/device/browser/connect>)
   and sign in. reMarkable shows an eight-character one-time code.
3. Paste the code into the app and click **Pair**.

The device token reMarkable returns is stored in your keychain and is shared
with the share extension. Nothing else is stored on any server other than
reMarkable's own cloud. **Unpair this Mac** removes the token; you can also
remove the device under *Devices* on my.remarkable.com.

Prefer to stay offline? Switch **Send via** to *USB / Wi-Fi web interface*,
enable *USB web interface* on the tablet (Settings › Storage) and connect it
with a cable. Uploads then go straight to `http://10.11.99.1/upload`.

## Use it from NetNewsWire

1. Select an article in NetNewsWire.
2. Click the **Share** toolbar button (or right-click the article › Share).
3. Choose **Send to reMarkable**.

A small panel shows progress: preparing, downloading images, laying out pages,
sending. The document appears at the top level of *My files* on the tablet,
named after the article's title (optionally prefixed with the site name).

If the entry is missing from the Share menu, choose **Edit Extensions…** at
the bottom of that menu and enable *Send to reMarkable* under *Sharing*.

The extension also works from Safari and any other app that shares a URL,
HTML or plain text. For URL-only shares it downloads the page and keeps the
`<article>`/`<main>` region.

## What arrives on the tablet

NetNewsWire hands the extension the article's original feed HTML plus title,
author, link and date (its `com.ranchero.article` pasteboard type). The
extension:

- parses the HTML into paragraphs, headings, nested lists, block quotes,
  captions, code blocks and images, and resolves relative links;
- downloads the images (up to 40 per article), downsizes them to the tablet's
  native width and converts them to grayscale (both configurable);
- lays everything out with TextKit on pages that match the device's screen
  exactly (reMarkable 1/2/Paper Pure, Paper Pro, Paper Pro Move, or A4), with a
  title block, byline and page numbers;
- uploads the resulting PDF with the same "simple upload" endpoint the
  official *Read on reMarkable* browser extension uses.

**About "Notebook":** the document lands in your library as a PDF that you can
mark up with the pen like any notebook page. It is not a native `.rm`
notebook. reMarkable's notebook format is undocumented, changes between
firmware releases and cannot hold raster images, so a PDF is the only format
that reliably delivers text *and* images and stays editable on the device.

## Settings

| Setting | Effect |
| --- | --- |
| Send via | reMarkable Cloud (paired account) or the tablet's USB web interface. |
| Page size | reMarkable 1/2/Paper Pure (default), Paper Pro, Paper Pro Move, A4. |
| Include images / grayscale | Whether to download images and whether to convert them to 8-bit gray. |
| Text size | Scales every font from 80 % to 160 %. |
| Prefix the document name | Names documents `site – Title` instead of `Title`. |

**Save test PDF…** renders the built-in sample page to disk so you can check
the layout without a tablet. **Send a test page** sends it to the tablet.

## How the pieces fit together

```
Extension/ShareViewController      ── UI in the share sheet, drives the pipeline
Extension/ShareInputReader         ── NSItemProvider → SharedInput (article / html / url / text)
RemarkableKit/SendPipeline         ── input → ArticleDocument → images → PDF → upload
RemarkableKit/HTMLTokenizer        ── forgiving HTML tokenizer with entity decoding
RemarkableKit/HTMLDocumentBuilder  ── tokens → [Block]
RemarkableKit/NetNewsWireArticle   ── decodes NetNewsWire's pasteboard dictionary
RemarkableKit/WebPageExtractor     ── whole pages → article region + metadata
RemarkableKit/ImageFetcher         ── concurrent image download with limits
RemarkableKit/PDFRenderer          ── TextKit pagination into a CGPDFContext
RemarkableKit/RemarkableCloudClient── pairing, user tokens, doc/v2/files upload
RemarkableKit/RemarkableUSBClient  ── multipart upload to the tablet's web UI
RemarkableKit/KeychainTokenStore   ── tokens in the data-protection keychain, shared via the app group
```

The reMarkable cloud API is not documented by reMarkable. The endpoints used
here are the ones established by [rmapi](https://github.com/ddvk/rmapi) and
[rmapi-js](https://github.com/erikbrinkman/rmapi-js): device registration at
`webapp-prod.cloud.remarkable.engineering/token/json/2/device/new`, user
tokens at `…/token/json/2/user/new`, and uploads at
`internal.cloud.remarkable.com/doc/v2/files` with an `rm-meta` header.

## Troubleshooting

- **"This Mac is not paired"** in the share sheet: open the app and pair. If
  the app says it is paired but the extension disagrees, the build is missing
  a development team (the app group is what lets the two processes share the
  keychain item). Set the team in *Signing & Capabilities* for both targets.
- **Nothing happens after choosing the extension**: look at Console.app for
  `SendToRemarkableExtension`. Share extensions run in their own process.
- **Images missing**: some sites block non-browser downloads or use lazy-load
  markup the parser does not recognise. Text is still sent.
- **Upload rejected with HTTP 401/403**: the device token was revoked; unpair
  and pair again.

## License

MIT. See `LICENSE`.
