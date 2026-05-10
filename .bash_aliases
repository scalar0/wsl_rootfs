# if command -v coreutils >/dev/null 2>&1; then
#     coreutils=$(coreutils --list)
#     for cmd in "${coreutils[@]}"; do
#         alias "$cmd"="coreutils $cmd"
#     done
#     unset cmd coreutils
# fi

if [ -x /usr/bin/dircolors ]; then
    test -r "$HOME/.dircolors" && eval "$(dircolors -b "$HOME/.dircolors")" || eval "$(dircolors -b)"
    alias ls='coreutils ls --color=auto'
    alias dir='coreutils dir --color=auto'
    alias vdir='coreutils vdir --color=auto'
    alias grep='grep --color=auto'
    alias fgrep='fgrep --color=auto'
    alias egrep='egrep --color=auto'
fi

alias ll='ls -alF'
alias la='ls -A'
alias l='ls -CF'
alias rg='rg --pretty --smart-case --follow'