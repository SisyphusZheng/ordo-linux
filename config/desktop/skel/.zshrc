# Ordo zsh 配置（无框架）

HISTFILE="$HOME/.zsh_history"
HISTSIZE=10000
SAVEHIST=10000
setopt SHARE_HISTORY          # 多终端共享历史
setopt HIST_IGNORE_ALL_DUPS   # 去重
setopt HIST_REDUCE_BLANKS     # 去多余空格

setopt AUTO_CD                # 输目录名直接 cd
setopt AUTO_PUSHD             # cd 自动压栈
setopt PUSHD_IGNORE_DUPS

autoload -Uz compinit && compinit
zstyle ':completion:*' menu select                  # 方向键选补全
zstyle ':completion:*' matcher-list 'm:{a-zA-Z}={A-Za-z}'  # 大小写不敏感
zstyle ':completion:*' list-colors "${(s.:.)LS_COLORS}"

# ---- 键位（emacs 风格）----
bindkey -e
bindkey '^[[1;5C' forward-word   # Ctrl+→
bindkey '^[[1;5D' backward-word  # Ctrl+←

[[ -e /usr/share/gentoo-zsh-completions ]] && fpath=(/usr/share/gentoo-zsh-completions $fpath)

[[ -r /usr/share/zsh/site-functions/zsh-syntax-highlighting.zsh ]] && \
  source /usr/share/zsh/site-functions/zsh-syntax-highlighting.zsh

[[ -r /usr/share/zsh/site-functions/zsh-autosuggestions.zsh ]] && \
  source /usr/share/zsh/site-functions/zsh-autosuggestions.zsh

command -v starship >/dev/null && eval "$(starship init zsh)"

# zoxide 必须在别名前初始化
command -v zoxide >/dev/null && eval "$(zoxide init zsh)"

# 工具不存在时别名不生效，原命令照常工作
if command -v eza >/dev/null; then
    alias ls='eza --icons --group-directories-first'
    alias ll='eza -l --icons --git --group-directories-first'
    alias la='eza -la --icons --git --group-directories-first'
    alias lt='eza --tree --level=2 --icons'
fi

if command -v bat >/dev/null; then
    alias cat='bat --style=plain --paging=never'
    alias catn='bat --style=numbers,header --paging=never'
fi

command -v rg  >/dev/null && alias grep='rg'
command -v fd  >/dev/null && alias find='fd'
command -v btop >/dev/null && alias top='btop'

# 别名只影响交互式 shell，脚本里的 sudo 仍会失败，所以直接报错指路
sudo() {
    printf '\033[1;33mOrdo 使用 doas，不是 sudo\033[0m\n' >&2
    printf '  请改用: doas %s\n' "$*" >&2
    printf '  （需要 root shell: doas -s）\n' >&2
    return 1
}

# ---- 别名 ----
alias ..='cd ..'
alias ...='cd ../..'
alias ordo-doctor='ordo doctor'
alias ordo-snap='doas ordo snap'

# 强制覆盖：/etc/profile 会先设 EDITOR=/bin/nano，${EDITOR:-nvim} 不会覆盖它
export EDITOR=nvim
export VISUAL=nvim
export PAGER="${PAGER:-less}"
export LESS='-R'

