#!/usr/bin/env bash
# Source this (do not execute it) before running the ops/ drill scripts on macOS:
#     source setup/macos-gnu-path.sh
# It puts the GNU versions of date/sed/etc. (installed by install-macos.sh) ahead of the BSD ones for this shell only.
if command -v brew >/dev/null 2>&1; then
  _brew_prefix="$(brew --prefix)"
elif [ -x /opt/homebrew/bin/brew ]; then
  _brew_prefix=/opt/homebrew
else
  _brew_prefix=/usr/local
fi
for _d in "$_brew_prefix/opt/coreutils/libexec/gnubin" "$_brew_prefix/opt/gnu-sed/libexec/gnubin"; do
  [ -d "$_d" ] && PATH="$_d:$PATH"
done
export PATH
unset _brew_prefix _d
