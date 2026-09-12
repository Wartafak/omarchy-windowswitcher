#!/usr/bin/env python3
"""List all open windows across workspaces and focus the picked one.

Uses hyprctl + omarchy-menu-select (Quickshell). Safe: out-of-process,
no compositor plugin, survives Hyprland updates.
"""
import json
import os
import subprocess
import sys


def get_clients():
    out = subprocess.run(
        ["hyprctl", "clients", "-j"], capture_output=True, text=True, check=True
    ).stdout
    return json.loads(out)


def desktop_entries():
    """Index .desktop files: basename and StartupWMClass -> Icon value."""
    by_wmclass = {}
    by_id = {}
    dirs = (
        os.path.expanduser("~/.local/share/applications"),
        "/usr/local/share/applications",
        "/usr/share/applications",
        "/var/lib/flatpak/exports/share/applications",
        os.path.expanduser("~/.local/share/flatpak/exports/share/applications"),
    )
    for d in dirs:
        try:
            files = os.listdir(d)
        except OSError:
            continue
        for f in files:
            if not f.endswith(".desktop"):
                continue
            base = f[: -len(".desktop")].lower()
            icon = None
            wmclass = None
            try:
                with open(os.path.join(d, f), encoding="utf-8", errors="replace") as fh:
                    for line in fh:
                        if line.startswith("Icon=") and icon is None:
                            icon = line[5:].strip()
                        elif line.startswith("StartupWMClass=") and wmclass is None:
                            wmclass = line[15:].strip().lower()
                        if icon is not None and wmclass is not None:
                            break
            except OSError:
                continue
            if not icon:
                continue
            by_id.setdefault(base, icon)
            if wmclass:
                by_wmclass.setdefault(wmclass, icon)
    return by_wmclass, by_id


def icon_for(cls, by_wmclass, by_id):
    """Original app icon (Icon= value) for a Hyprland window class.

    Falls back to the class name itself so the icon theme can resolve it
    even without a matching .desktop file. Returns '' only when unknown.
    """
    c = (cls or "").lower()
    if not c:
        return ""
    if c in by_wmclass:
        return by_wmclass[c]
    if c in by_id:
        return by_id[c]
    for base, icon in by_id.items():
        if c.startswith(base) or base.startswith(c):
            return icon
    # Strip common suffixes/prefixes (e.g. brave-origin -> brave) and retry.
    for sep in (".", "-", "_"):
        if sep in c:
            short = c.split(sep)[0]
            if short in by_id:
                return by_id[short]
    # Last resort: let the icon theme try the class name directly.
    return cls.strip()


def glyph_for(cls):
    """Fallback Nerd Font glyph for windows with no .desktop icon."""
    c = (cls or "").lower()
    for keys, glyph in (
        (("brave", "chromium", "chrome", "firefox", "zen", "edge", "browser"), ""),
        (("foot", "kitty", "alacritty", "ghostty", "wezterm", "terminal"), ""),
        (("org.omarchy.agent", "agent"), "󰚩"),
        (("nautilus", "nemo", "dolphin", "thunar", "files"), ""),
        (("code", "cursor", "zed", "nvim", "neovim", "sublime", "helix"), ""),
        (("spotify", "music"), ""),
        (("signal", "discord", "telegram", "whatsapp"), ""),
        (("thunderbird", "mail"), ""),
        (("steam", "heroic", "lutris", "bottles", "game"), ""),
        (("vlc", "mpv", "video"), ""),
        (("loupe", "eog", "image", "photo"), ""),
        (("obsidian", "notes"), "󰎞"),
        (("calc",), ""),
        (("setting",), ""),
    ):
        if any(k in c for k in keys):
            return glyph
    return ""


def main():
    try:
        clients = get_clients()
    except Exception as e:
        print(f"hyprctl failed: {e}", file=sys.stderr)
        sys.exit(1)

    # Only mapped (real) windows; sort by workspace then recent focus
    clients = [c for c in clients if c.get("mapped")]
    clients.sort(
        key=lambda c: (
            c.get("workspace", {}).get("id", 99),
            -(c.get("focusHistoryID", 0)),
        )
    )

    if not clients:
        subprocess.run(["omarchy-notification-send", "No open windows"])
        return

    options = []
    by_wmclass, by_id = desktop_entries()
    for c in clients:
        ws = c.get("workspace", {}).get("name", "?")
        cls = (c.get("class") or "?")[:24].replace("\t", " ")
        title = (
            (c.get("title") or "").strip().replace("\n", " ").replace("\t", " ")
        )
        title = title[:40] + "…" if len(title) > 40 else title
        title = title or cls
        addr = c["address"]
        float_mark = "＋" if c.get("floating") else ""
        label = f"[ws {ws}]{float_mark} {cls} — {title}"
        # Stock omarchy.menu only supports 3 fields for picker rows:
        # "<glyph><TAB><label><TAB><subtext>" (its parser joins any extra
        # fields into the subtext, and it never displays row icons for
        # picker rows). So send glyph/label/address only; the address comes
        # back as the subtext. Real app icons live in the top-bar widget,
        # which resolves them via Quickshell directly.
        options.append(f"{glyph_for(cls)}\t{label}\t{addr}")

    try:
        sel = subprocess.run(
            ["omarchy-menu-select", "Windows", *options, "--", "--width", "550"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
    except subprocess.CalledProcessError:
        sys.exit(1)  # user cancelled

    # Selection is "label<TAB>address". Find the 0x field robustly
    # (older 4-field rows returned "label<TAB>addr<TAB>icon").
    parts = sel.split("\t")
    addr = next((p.strip() for p in parts if p.strip().startswith("0x")), "")
    if not addr:
        print(f"could not parse selection: {sel!r}", file=sys.stderr)
        sys.exit(1)

    # Hyprland 0.56+: `hyprctl dispatch X Y` builds invalid Lua
    # (`hl.dispatch(X Y)`), so execute via eval with a dispatcher object.
    # This focuses the window and switches to its workspace.
    lua = f'hl.dispatch(hl.dsp.focus({{window = "address:{addr}"}}))'
    r = subprocess.run(["hyprctl", "eval", lua])
    if r.returncode != 0:
        print(f"focus failed for {addr}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
