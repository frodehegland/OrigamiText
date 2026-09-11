# EPUB Quick Look extension — target setup (one-time, in Xcode)

The two Swift files in this folder are the whole extension. They are
self-contained (own zip reader, no app code) and sit outside LiquidView
on purpose, so they never join the app target. What remains is creating
the extension target, which only Xcode should do:

1. **File ▸ New ▸ Target… ▸ macOS ▸ Quick Look Preview Extension.**
   Name it `EPUBQuickLook`. Embed in the LiquidView (macOS) app target.
   Activate the scheme if Xcode offers.

2. **Delete the template's generated source** (`PreviewViewController.swift`
   or `PreviewProvider.swift`, and its .xib if any) from the new target —
   choose "Move to Trash".

3. **Add this folder's two files to the new target**: drag
   `EPUBQuickLook/PreviewProvider.swift` and
   `EPUBQuickLook/EPUBPreviewBuilder.swift` into the target's group and
   tick ONLY the `EPUBQuickLook` target's membership.

4. **Info.plist of the extension** — two keys:
   - `QLSupportedContentTypes` (under `NSExtension ▸ NSExtensionAttributes`):
     one entry, `org.idpf.epub-container`.
   - `QLIsDataBasedPreview` (same place): Boolean `YES` — this tells the
     system the principal class is a data-based `QLPreviewProvider`.
   If the template generated a view-controller principal class, set
   `NSExtensionPrincipalClass` to `$(PRODUCT_MODULE_NAME).PreviewProvider`.

5. **Build and run the app once** so macOS registers the extension.
   Then in Finder: select any `.epub` and press space. If the old system
   preview shows instead, check System Settings ▸ ... ▸ Extensions ▸
   Quick Look, or run `qlmanage -r` to reset the Quick Look cache.

Testing from the command line without Finder:

    qlmanage -p "~/Desktop/HT26 EPUBs — author columns/3800935.3830833.epub"
