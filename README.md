# publik clean Mac check

Downloads the public macOS files of publik apps on a clean GitHub macOS runner, the way a browser does (quarantine flag on), installs each one to /Applications and opens it. Records the Gatekeeper and staple results and whether the app sends its first usage event to a local listener. publikhq.com is blocked on the runner, so a test never reaches production. It holds no secrets and no app code.
