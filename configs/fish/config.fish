set -g fish_greeting
# Homebrew and ~/bin (cberry, musicplayer, sysviz) on PATH.
for brew_bin in /opt/homebrew/bin /usr/local/bin
    if test -x $brew_bin/brew
        fish_add_path -g (path dirname $brew_bin)/bin (path dirname $brew_bin)/sbin
        break
    end
end
fish_add_path -g $HOME/bin
zoxide init fish --cmd cd | source
if status is-interactive
clear
fastfetch
alias cleanup='clear; mole'
alias cat='bat'
alias ls='lsd'
alias st='speedtest'
alias info='fastfetch'
alias am='musicplayer'
alias q='exit'
alias c='fish'
alias grep='rg'
end
