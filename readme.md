# about this:
This userchrome / config
* Brings back compact mode (Firefox 89)
* Removes Unified extensions menu (thing firefox copied from google... a bit late)
* Hide Firefox login (email address)
* Default search engine = DuckDuckGo (enforced via policies.json, stops reverting)
* Preinstalls uBlock Origin (removable; set `force_installed` in policies.json to lock it)
* Hides the Firefox View button from the tab bar
* Drops the spacers left/right of the urlbar (urlbar stretches instead)
* Puts the search engine box directly right of the url address bar

# shoutout
https://www.userchrome.org/firefox-89-styling-proton-ui.html#compactmode  
https://ffprofile.com/ - https://github.com/allo-/firefox-profilemaker  
https://github.com/arkenfox/user.js  
https://github.com/AveYo/fox   
https://github.com/yokoffing/Betterfox  
https://github.com/Endor8/userChrome.js  
https://github.com/black7375/Firefox-UI-Fix  
https://gitlab.com/postmarketOS/mobile-config-firefox/-/tree/master  
and few more resources im trying to remember  

# install:

## linux
```bash
cd firefox-userchrome-theme
./install.sh
```

## windows
double-click `install.bat` (or run `install.ps1` in powershell)

pick a profile when asked, then restart firefox. done.

## what the installer does
* copies `chrome/` (userChrome.css) and `user.js` into your profile
* backs up any existing `chrome/` and `user.js` as `*.bak-<timestamp>`
* installs `autoconfig.js` + `mozilla.cfg` into the firefox install dir
  (asks for admin/root) - this is needed for the locked new-tab-page prefs
  since `user.js` only supports `user_pref()`
* installs `policies.json` into `<firefox install dir>/distribution/`
  - default search engine = DuckDuckGo (enforced, survives updates)
  - auto-installs uBlock Origin (`normal_installed` - you can still remove it;
    change to `"force_installed"` in the file to make it permanent)
  - if you already have your own `policies.json` it gets backed up first
* flatpak / snap: the install-dir part is skipped (read-only there);
  the theme and `user.js` still work fully, but duckduckgo default +
  uBlock preinstall + locked new-tab prefs must be set up manually

## toolbar notes
* fully quit Firefox (not just close its windows) before installing. while it is
  running, the installer skips navbar tidying with a warning; quit and rerun.
* once per install, the installer edits the profile's own saved toolbar state in
  `prefs.js`: removes flexible spacers and inserts the search box directly after
  the urlbar if the search box is absent. an existing search box stays in place.
* before changing `prefs.js`, it copies it to `prefs.js.bak-<timestamp>`.
  absent customization state is skipped silently; fresh profiles get the search
  box through `browser.search.widget.inNavBar` in `user.js`.
* Linux requires `python3` for this step; if unavailable, it warns and skips it.
* these are saved customization changes, not CSS ordering rules or a toolbar
  state frozen in `user.js`. you can still customize the toolbar afterwards.
  rerunning the installer removes newly added spacers again.
* Firefox View is hidden through `browser.tabs.firefox-view` in `user.js`.
* uninstall leaves `prefs.js` and its backups untouched. to roll back the toolbar
  change manually, fully quit Firefox and copy the desired backup over `prefs.js`.

options:
```
./install.sh -p <profile-name>     # pick profile non-interactively
./install.sh -u                    # uninstall (restores latest backup)
./install.sh -y                    # never prompt
```
```
install.ps1 -TargetProfile <name>  # same on windows
install.ps1 -Uninstall
install.ps1 -Yes
```

## uninstall
`./install.sh --uninstall` (linux) or `install.ps1 -Uninstall` (windows).
removes `chrome/` + `user.js` and restores your latest backup if one exists.

## manual install (fallback)
about:profiles

find default profile, on Root Directory find open folder button, add files which this repo provides (`chrome/` and `user.js` into the profile root folder).

restart firefox.
