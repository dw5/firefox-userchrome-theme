# about this:
This userchrome / config
* Brings back compact mode (Firefox 89)
* Removes Unified extensions menu (thing firefox copied from google... a bit late)
* Hide Firefox login (email address)

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
* flatpak / snap: the autoconfig part is skipped (read-only install dir);
  the theme and `user.js` still work fully

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
