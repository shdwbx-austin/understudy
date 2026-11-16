# Releasing Understudy

Push a tag `vX.Y.Z` and GitHub Actions builds, signs, notarizes and publishes the release:

- `Understudy-X.Y.Z.pkg`: the installer (to /Applications), for a first install.
- NDI is added afterwards on this Mac (below).
- `Understudy-X.Y.Z-macos.zip`: the app, which installed copies download as an update.
- `appcast.xml`: the update feed. Understudy checks
  `https://github.com/shdwbx-austin/understudy/releases/latest/download/appcast.xml` once a day
  (and from Understudy › Check for Updates…), so releases must be full releases, not pre-releases.

```bash
echo 0.3.0 > VERSION && git commit -am "0.3.0" && git tag v0.3.0 && git push && git push --tags
```

The build number (CFBundleVersion) is the commit count, so every release is newer than the last.

## NDI (added on this Mac)

The NDI library comes from the NDI SDK, whose license lets it ship inside the app but not be
posted on its own, so it isn't in the repo or on GitHub's builders. Releases get it here, on
a Mac with the NDI SDK for Apple installed:

```bash
scripts/release-add-ndi.sh v0.4.0
```

Run it after the tag's GitHub build has finished. It downloads that release's app (universal),
adds `libndi.dylib` to `Contents/Frameworks`, signs it again, rebuilds the installer, signs a
new `appcast.xml` with the Sparkle key in your keychain (macOS may ask to allow that), checks the
signature, and replaces the release's zip, pkg and feed. `--dry-run` does everything but upload,
keeping the files in `dist/release-<version>/`.

Once Developer ID signing is set up, GitHub's build is signed and notarized; adding NDI after
that changes the app, so then either run this with `SIGN_IDENTITY` set (and notarize again), or
give GitHub the library through the `NDI_LIB_URL` secret instead.

## One-time setup (secrets)

Signing, notarization and the update feed each switch on when their secrets exist. Add them in
GitHub › Settings › Secrets and variables › Actions. Without them, CI still builds, unsigned.

### 1. Developer ID certificates (team TV3DLPJNC8)

1. In Xcode › Settings › Accounts (or developer.apple.com › Certificates), create a
   **Developer ID Application** and a **Developer ID Installer** certificate.
2. In Keychain Access, select both (with their private keys) › Export Items… › one `.p12` with a password.
3. Secrets:
   - `MACOS_CERTIFICATES_P12`: the file as base64 (`base64 -i Certificates.p12 | pbcopy`)
   - `MACOS_CERTIFICATES_PASSWORD`: its password

### 2. Notarization (App Store Connect API key)

1. App Store Connect › Users and Access › Integrations › App Store Connect API › Team Keys › +
   (Access: Developer). Download the `.p8` (once only).
2. Secrets:
   - `NOTARY_API_KEY`: the `.p8` as base64 (`base64 -i AuthKey_XXXX.p8 | pbcopy`)
   - `NOTARY_API_KEY_ID`: the key's ID
   - `NOTARY_API_ISSUER`: the Issuer ID shown above the keys

### 3. Update signing key (Sparkle)

Updates are checked against a public key built into the app.

```bash
curl -LO https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-2.10.1.tar.xz
mkdir sparkle && tar -xf Sparkle-2.10.1.tar.xz -C sparkle
./sparkle/bin/generate_keys          # makes the key in your login keychain, prints the PUBLIC key
./sparkle/bin/generate_keys -x sparkle_private_key   # exports the PRIVATE key to a file
```

- Secret `SPARKLE_PRIVATE_KEY`: the contents of `sparkle_private_key` (then delete the file; the
  key stays in your keychain).
- Variable (not secret) `SPARKLE_PUBLIC_KEY`: the public key it printed. Also put it in
  `Resources/sparkle-public-key.txt` so local builds can update too.

Keep the private key safe: losing it means installed copies can't verify updates until reinstalled.

## Notes

- Copies installed before signing (0.2.0 and earlier, ad-hoc signed, no update key) can't update
  themselves: install the first signed `.pkg` once by hand. Every release after that arrives by itself.
- The installer hands the app to the user who installed it, so updates don't ask for an admin password.
- Local builds: `scripts/build-app.sh` then `scripts/build-installer.sh` (unsigned unless
  `SIGN_IDENTITY` / `INSTALLER_IDENTITY` name identities in your keychain).
