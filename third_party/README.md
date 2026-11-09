# Third-party files (pinned, reviewed)

The build uses these local copies instead of downloading code at build time.
`chroot/customize.sh` refuses to continue if `SHA256SUMS` doesn't match.

| File | Source | Licence | Used for |
|---|---|---|---|
| `papirus-folders` | PapirusDevelopmentTeam/papirus-folders, tag v1.14.0 | MIT | Recolour Papirus folder icons green (only re-points symlinks under the icon theme; no network) |
| `plasma-applet-tiledmenu-21c8540.tar.gz` | Zren/plasma-applet-tiledmenu, commit 21c8540 (Oct 2025; v46 + Plasma 6.6 FavoritesModel fix) | GPL-2.0+ | Windows 10-style start menu (QML widget, Plasma 6) |

To update: download the new tagged release, review it, replace the file and regenerate `SHA256SUMS`
(`sha256sum papirus-folders plasma-applet-tiledmenu-*.tar.gz > SHA256SUMS`).
