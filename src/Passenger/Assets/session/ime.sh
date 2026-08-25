# The host's own IME, on a private bus and a private copy of its config.
# Spliced into session.sh; see Launch.ImeSection for why each half is here.
ime_home='{state}/ime'
rm -rf "$ime_home" && mkdir -p "$ime_home"
[ -d "$HOME/.config/fcitx5" ] && cp -r "$HOME/.config/fcitx5" "$ime_home/" 2>/dev/null
XDG_CONFIG_HOME="$ime_home" dbus-run-session -- {ime} >/dev/null 2>&1 &
ime_pid=$!
