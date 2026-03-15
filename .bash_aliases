if command -v coreutils >/dev/null 2>&1; then
    coreutils=(
        b2sum base32 base64 basename basenc cat cksum comm cp csplit cut
        date dd df dir dircolors dirname du echo env expand expr factor
        false fmt fold hashsum head join link ln ls md5sum mkdir mktemp more
        mv nl numfmt od paste pr printenv printf ptx pwd readlink realpath rm
        rmdir seq sha1sum sha224sum sha256sum sha384sum sha512sum shred shuf
        sleep sort split sum tac tail tee test touch tr true truncate tsort
        unexpand uniq nlink vdir wc yes
    )

    for cmd in "${coreutils[@]}"; do
        alias "$cmd"="coreutils $cmd"
    done
    unset cmd coreutils
fi

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
