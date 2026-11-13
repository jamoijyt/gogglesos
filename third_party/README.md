# Third-party files (pinned, reviewed)

The build uses these local copies instead of downloading code at build time.
`chroot/customize.sh` refuses to continue if `SHA256SUMS` doesn't match.

| File | Source | Licence | Used for |
|---|---|---|---|
| `papirus-folders` | PapirusDevelopmentTeam/papirus-folders, tag v1.14.0 | MIT | Recolour Papirus folder icons green (only re-points symlinks under the icon theme; no network) |
| `plasma-applet-tiledmenu-21c8540.tar.gz` | Zren/plasma-applet-tiledmenu, commit 21c8540 (Oct 2025; v46 + Plasma 6.6 FavoritesModel fix) | GPL-2.0+ | Windows 10-style start menu (QML widget, Plasma 6) |

To update: download the new tagged release, review it, replace the file and regenerate `SHA256SUMS`
(`sha256sum papirus-folders plasma-applet-tiledmenu-*.tar.gz > SHA256SUMS`).

## Controller models (downloaded, checksum-pinned)

`webxr-controller-models.sha256` lists the controller models the GogglesXR dashboard draws: the
Quest, Rift, Index, Vive and generic models from
[WebXR Input Profiles](https://github.com/immersive-web/webxr-input-profiles) assets **1.0.20**
(MIT licence). At about 25 MB they are too big to keep here, so `chroot/apply-system.sh` downloads
each file from `cdn.jsdelivr.net/npm/@webxr-input-profiles/assets@1.0.20/` (an exact copy of the npm
package) into `/usr/share/gogglesos/gogglesxr-controllers/`, and only installs it if its SHA-256
matches. If a file can't be downloaded, the dashboard draws its own simple shapes for that
controller instead.

To update: download the new package version, check the models, change the version in
`apply-system.sh` and regenerate the list from the package's `dist/profiles` folder.
