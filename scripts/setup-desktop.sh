#!/bin/bash
# Apply the desktop preferences for the lean XFCE session.
#
# The session is started by start-xfce.sh without xfce4-session: the window
# manager, xfsettingsd and xfce4-panel run directly, and feh paints the
# wallpaper once.  Everything here is idempotent and safe to re-run.
set -Eeuo pipefail

export HOME="${HOME:-/home/desktop}"
export DISPLAY="${DISPLAY:-:1}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/1000}"
WALLPAPER_PNG="/usr/share/backgrounds/desktop.png"

set_prop() {
    local channel="$1" prop="$2" type="$3" value="$4"
    if xfconf-query -c "$channel" -p "$prop" >/dev/null 2>&1; then
        xfconf-query -c "$channel" -p "$prop" -s "$value" >/dev/null 2>&1 || true
    else
        xfconf-query -c "$channel" -p "$prop" -n -t "$type" -s "$value" >/dev/null 2>&1 || true
    fi
}

# Wait for xfconfd (started on demand by the first xfconf-query call).
for _ in $(seq 1 60); do
    if xfconf-query -c xfwm4 -l >/dev/null 2>&1; then
        break
    fi
    sleep 0.5
done

# --- Window manager: no compositor, no animations, no shadows --------------
set_prop xfwm4 /general/use_compositing bool false
set_prop xfwm4 /general/box_move bool false
set_prop xfwm4 /general/box_resize bool false
set_prop xfwm4 /general/cycle_draw_frame bool false
set_prop xfwm4 /general/show_frame_shadow bool false
set_prop xfwm4 /general/show_popup_shadow bool false
set_prop xfwm4 /general/snap_to_border bool false
set_prop xfwm4 /general/snap_to_window bool false
set_prop xfwm4 /general/workspace_count int 1
set_prop xfwm4 /general/title_font string "Noto Sans Bold 10"
set_prop xfwm4 /general/title_alignment string "left"
# Double-click the title bar: maximise.  Middle-click: shade.
set_prop xfwm4 /general/double_click_action string "maximize"
set_prop xfwm4 /general/middle_click_action string "shade"

# --- GTK / Xsettings: flat, dark and animation-free ------------------------
set_prop xsettings /Gtk/EnableAnimations bool false
set_prop xsettings /Net/ThemeName string "Adwaita-dark"
set_prop xsettings /Net/IconThemeName string "Adwaita"
set_prop xsettings /Gtk/FontName string "Noto Sans 10"
set_prop xsettings /Gtk/MonospaceFontName string "Noto Sans Mono 10"
set_prop xsettings /Xft/Antialias int 1
set_prop xsettings /Xft/Hinting int 1
set_prop xsettings /Xft/HintStyle string "hintslight"
set_prop xsettings /Xft/RGBA string "none"
set_prop xsettings /Net/EnableEventSounds bool false
set_prop xsettings /Net/EnableInputFeedbackSounds bool false

# --- Screensaver and power: off -------------------------------------------
set_prop xfce4-screensaver /saver/enabled bool false
set_prop xfce4-screensaver /lock/enabled bool false
set_prop xfce4-power-manager /xfce4-power-manager/blank-on-ac int 0
set_prop xfce4-power-manager /xfce4-power-manager/dpms-enabled bool false
set_prop xfce4-power-manager /xfce4-power-manager/inactivity-on-ac int 0

# Arabic + US keyboard, toggled with Alt+Shift.
if command -v setxkbmap >/dev/null 2>&1; then
    setxkbmap -layout us,ara -option grp:alt_shift_toggle >/dev/null 2>&1 || true
fi

# No screen blanking or DPMS: a remote desktop should not go black.
if command -v xset >/dev/null 2>&1; then
    xset s off -dpms >/dev/null 2>&1 || true
fi

# Wallpaper: painted once on the root window.  feh exits immediately, so there
# is no backdrop daemon to keep alive or restart.
if command -v feh >/dev/null 2>&1 && [ -f "$WALLPAPER_PNG" ]; then
    feh --no-fehbg --bg-fill "$WALLPAPER_PNG" >/dev/null 2>&1 || true
fi

# Persist the flat GTK look for GTK3 and GTK4 applications.
install -d "$HOME/.config/gtk-3.0" "$HOME/.config/gtk-4.0"
for gtk_dir in "$HOME/.config/gtk-3.0" "$HOME/.config/gtk-4.0"; do
    cat > "$gtk_dir/settings.ini" <<'EOF'
[Settings]
gtk-enable-animations=0
gtk-theme-name=Adwaita-dark
gtk-icon-theme-name=Adwaita
gtk-font-name=Noto Sans 10
gtk-application-prefer-dark-theme=1
EOF
done

# A light terminal with a sensible scrollback and no cursor blink.
install -d "$HOME/.config/xfce4/terminal"
cat > "$HOME/.config/xfce4/terminal/terminalrc" <<'EOF'
[Configuration]
FontName=Noto Sans Mono 10
MiscAlwaysShowTabs=FALSE
MiscShowUnsafePasteDialog=FALSE
MiscCursorBlinks=FALSE
ScrollingLines=2000
EOF

# Google Chrome is the default browser.
if command -v xdg-settings >/dev/null 2>&1; then
    xdg-settings set default-web-browser google-chrome.desktop >/dev/null 2>&1 || true
fi
if command -v xdg-mime >/dev/null 2>&1; then
    for mime in x-scheme-handler/http x-scheme-handler/https text/html; do
        xdg-mime default google-chrome.desktop "$mime" >/dev/null 2>&1 || true
    done
fi

# Start Chrome once per session with the local welcome page, unless disabled.
if [ "${CHROME_AUTOSTART:-1}" = "1" ]; then
    if ! pgrep -u "${USER:-desktop}" -x chrome >/dev/null 2>&1; then
        (setsid google-chrome --disable-dev-shm-usage --disable-gpu \
            --renderer-process-limit=3 --disable-background-networking \
            --new-window file:///opt/desktop/welcome.html >/dev/null 2>&1 &) &
    fi
fi

echo "Desktop configuration applied for ${USER:-desktop}."
