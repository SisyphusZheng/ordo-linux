#!/bin/sh
set -eu
bundle=$(CDPATH= cd -- "$(dirname "$0")" && pwd)
cd "$bundle"
echo 'Ordo Linux · M2 MacBook Air'
echo '正在验证候选版签名及安装文件，请保持此窗口打开。'
/usr/bin/ssh-keygen -Y verify -f definition/config/release/allowed_signers \
    -I ordo-preview -n ordo-release -s SHA256SUMS.sig < SHA256SUMS
/usr/bin/shasum -a 256 --quiet -c SHA256SUMS
export PATH="$bundle/tools:/usr/bin:/bin:/usr/sbin:/sbin"
export PYTHONNOUSERSITE=1 PYTHONDONTWRITEBYTECODE=1
unset PYTHONHOME PYTHONPATH DYLD_LIBRARY_PATH DYLD_INSERT_LIBRARIES
exec "$bundle/runtime/bin/python3" -E -s -B "$bundle/definition/dev/release/macos_install.py" "$@"
