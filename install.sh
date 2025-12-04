#!/bin/bash

set -eo pipefail  # 增强错误处理：管道错误退出
# set -x             # 可选：执行时输出每个命令（方便调试，取消注释即可）

# ======================== 配置区（统一管理地址/参数）========================
# 阿里云 Codeup 镜像地址
CODEUP_REGISTRY="https://packages.aliyun.com/5eb3e37038076f00011bcd4a/npm/npm-registry/"
# fnm 安装地址（优先 jsdelivr 镜像，失败回退官方）
FNM_INSTALL_URL_MIRROR="https://cdn.jsdelivr.net/gh/Schniz/fnm@master/.ci/install.sh"
FNM_INSTALL_URL_OFFICIAL="https://fnm.vercel.app/install"
# Node.js LTS 源地址
NODE_LTS_SETUP_URL="https://deb.nodesource.com/setup_lts.x"

# 跳过参数默认值（false=不跳过）
SKIP_ALIAS=false
SKIP_FNM=false
SKIP_APT_UPDATE=false
SKIP_NODE=false
SKIP_NPM_TOOLS=false
SKIP_NPM_REGISTRY=false
SKIP_NPM_LOGIN=false
SKIP_YARN_LOGIN=false
SKIP_GUPO_TOOLS=false
SKIP_GIT_CONFIG=false
SKIP_SSH_KEY=false
SKIP_PROXY=false

# 别名清单
declare -A ALIAS_MAP=(
  ["gp"]="git push - 推送代码到远程仓库"
  ["gll"]="git pull - 拉取远程仓库代码到本地"
  ["gl"]="git clone - 克隆远程仓库到本地"
  ["gc"]="git checkout - 切换分支或恢复工作区文件"
  ["glog"]="git log simplify - 美化显示提交日志（含分支图、作者、时间）"
  ["gk"]="git cherry-pick - 选择性合并指定提交记录"
  ["ys"]="yarn dev | yarn serve - 启动 yarn 开发/预览服务（根据项目配置生效）"
  ["code"]="cursor - 用 Cursor 编辑器打开当前目录"
  ["gg"]="gupo-deploy -a -p - 执行 gupo-deploy 部署命令（全量部署 + 保持参数）"
)
# ================================================================================

# ======================== 工具函数（简化重复逻辑）========================
# 检测命令是否存在
command_exists() {
  command -v "$1" &> /dev/null
}

# 验证工具安装
verify_tool() {
  local tool=$1
  if command_exists "$tool"; then
    local version=$("$tool" --version 2>&1 | head -n 1 | cut -d ' ' -f 2 | cut -d ',' -f 1)
    echo "  ✅ $tool：$version"
  else
    echo "  ❌ $tool：未安装成功"
  fi
}

# 提示用户确认（可选继续）
confirm_continue() {
  local msg="$1"
  read -p "$msg（y/N）：" choice
  case "$choice" in
    [Yy]* ) return 0;;
    * ) echo "❌ 用户取消，退出脚本"; exit 1;;
  esac
}
# ================================================================================

# ======================== 参数解析（处理跳过选项）========================
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skipAlias) SKIP_ALIAS=true; shift;;
    --skipFnm) SKIP_FNM=true; shift;;
    --skipAptUpdate) SKIP_APT_UPDATE=true; shift;;
    --skipNode) SKIP_NODE=true; shift;;
    --skipNpmTools) SKIP_NPM_TOOLS=true; shift;;
    --skipNpmRegistry) SKIP_NPM_REGISTRY=true; shift;;
    --skipNpmLogin) SKIP_NPM_LOGIN=true; shift;;
    --skipYarnLogin) SKIP_YARN_LOGIN=true; shift;;
    --skipGupoTools) SKIP_GUPO_TOOLS=true; shift;;
    --skipGitConfig) SKIP_GIT_CONFIG=true; shift;;
    --skipSshKey) SKIP_SSH_KEY=true; shift;;
    --skipProxy) SKIP_PROXY=true; shift;;
    *) echo "❌ 未知参数：$1"; exit 1;;
  esac
done

# 输出跳过配置摘要
echo "📋 脚本执行配置（跳过以下步骤）："
[ "$SKIP_ALIAS" = true ] && echo "  - 跳过 .bashrc 别名配置"
[ "$SKIP_FNM" = true ] && echo "  - 跳过 fnm 安装"
[ "$SKIP_APT_UPDATE" = true ] && echo "  - 跳过 apt-get 更新"
[ "$SKIP_NODE" = true ] && echo "  - 跳过 Node.js 安装"
[ "$SKIP_NPM_TOOLS" = true ] && echo "  - 跳过全局 npm 工具安装"
[ "$SKIP_NPM_REGISTRY" = true ] && echo "  - 跳过 npm registry 镜像配置"
[ "$SKIP_NPM_LOGIN" = true ] && echo "  - 跳过 npm 登录"
[ "$SKIP_YARN_LOGIN" = true ] && echo "  - 跳过 yarn 登录"
[ "$SKIP_GUPO_TOOLS" = true ] && echo "  - 跳过 gupo 工具安装"
[ "$SKIP_GIT_CONFIG" = true ] && echo "  - 跳过 Git 配置"
[ "$SKIP_SSH_KEY" = true ] && echo "  - 跳过 SSH 密钥配置"
[ "$SKIP_PROXY" = true ] && echo "  - 跳过 WSL 代理配置"
echo "========================================================================"

# ======================== 核心步骤（带跳过逻辑）========================
# 1. .bashrc 别名配置（--skipAlias 跳过）
if [ "$SKIP_ALIAS" = false ]; then
  echo -e "\n🔧 开始 .bashrc 配置..."
  # 备份原有 .bashrc
  BACKUP_FILE="$HOME/.bashrc.bak.$(date +%Y%m%d%H%M%S)"
  cp "$HOME/.bashrc" "$BACKUP_FILE"
  echo "✅ 已备份原有 .bashrc 到：$BACKUP_FILE"

  # 写入自定义配置
  cat << EOF > "$HOME/.bashrc.tmp"
echo "welcome $USER"

alias gp="git push"
alias gll="git pull"
alias gl="git clone"
alias gc="git checkout"
alias glog="git log --graph --pretty=format:'%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset' --abbrev-commit -- | less"
alias gk="git cherry-pick"
alias ys="yarn dev | yarn serve"
alias code="cursor"
alias gg="gupo-deploy -a -p"

# 端口转发函数：动态获取 172 开头的 WSL IP（无需指定网卡名）
port-add() {
  if [ -z "\$1" ]; then
    echo "❌ 请指定端口号（示例：port-add 23355）"
    return 1
  fi
  local PORT="\$1"
  local WSL_IP=\$(ip addr | grep -E 'inet\s' | awk '{print \$2}' | cut -d '/' -f 1 | grep '^172\.' | head -n 1)
  if [ -z "\$WSL_IP" ]; then
    echo "❌ 无法获取 172 开头的 WSL 内网 IP"
    return 1
  fi
  echo "✅ 已获取 WSL IP：\$WSL_IP，转发端口：\$PORT"
  powershell.exe -Command 'Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command ""netsh interface portproxy add v4tov4 listenport='\$PORT' listenaddress=0.0.0.0 connectport='\$PORT' connectaddress='\$WSL_IP'; echo === 转发创建完成 ===; netsh interface portproxy show v4tov4 listenport='\$PORT'"""'
}

# 端口删除函数
port-del() {
  if [ -z "\$1" ]; then
    echo "❌ 请指定端口号（示例：port-del 23355）"
    return 1
  fi
  local PORT="\$1"
  echo "🗑️ 正在删除端口转发：\$PORT"
  powershell.exe -Command 'Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command ""netsh interface portproxy delete v4tov4 listenport='\$PORT' listenaddress=0.0.0.0; echo === 转发已删除 ===; netsh interface portproxy show v4tov4"""'
}

# 端口重置函数
port-reset() {
  echo "🗑️ 正在重置端口转发"
  powershell.exe -Command 'Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command ""netsh interface portproxy reset"""'
}
EOF

  # 拼接原有 .bashrc 内容，替换原文件并修复权限
  cat "$HOME/.bashrc" >> "$HOME/.bashrc.tmp"
  mv -f "$HOME/.bashrc.tmp" "$HOME/.bashrc"
  chmod 644 "$HOME/.bashrc"
  echo "✅ 已更新 .bashrc 配置（自定义配置在最前面）"
else
  echo -e "\n⚠️  已跳过 .bashrc 别名配置"
fi

# 2. fnm 安装（--skipFnm 跳过）
if [ "$SKIP_FNM" = false ]; then
  echo -e "\n🔧 开始 fnm 安装..."
  # 检测 unzip/curl，缺失则安装
  if ! command_exists "unzip"; then
    echo "⚠️  未检测到 unzip，正在安装..."
    sudo apt-get update &> /dev/null
    sudo apt-get install -y unzip &> /dev/null || {
      echo "❌ unzip 安装失败！请检查网络"
      exit 1
    }
  fi
  if ! command_exists "curl"; then
    echo "⚠️  未检测到 curl，正在安装..."
    sudo apt-get install -y curl &> /dev/null || {
      echo "❌ curl 安装失败！请检查网络"
      exit 1
    }
  fi
  echo "✅ fnm 依赖（unzip + curl）已就绪"

  # 安装 fnm（镜像优先）
  if curl -fsSL "$FNM_INSTALL_URL_MIRROR" | bash; then
    echo "✅ fnm 镜像地址安装成功"
  elif curl -fsSL "$FNM_INSTALL_URL_OFFICIAL" | bash; then
    echo "✅ fnm 官方地址安装成功"
  else
    echo "❌ fnm 安装失败！是否跳过？"
    confirm_continue "继续执行其他步骤"
  fi

  # 配置环境变量
  if ! grep -q 'eval "$(fnm env --use-on-cd --shell bash)"' "$HOME/.bashrc"; then
    echo 'eval "$(fnm env --use-on-cd --shell bash)"' >> "$HOME/.bashrc"
  fi
  echo "✅ fnm 配置完成"
else
  echo -e "\n⚠️  已跳过 fnm 安装"
fi

# 统一更新 apt 源（后续步骤依赖）
if [ "$SKIP_APT_UPDATE" = false ]; then
  echo -e "\n🔧 正在更新 apt-get 软件源..."
  sudo apt-get update &> /dev/null || {
    echo "❌ apt 源更新失败！请检查网络"
    exit 1
  }
  echo "✅ apt 源更新完成"
fi

# 3. Node.js 安装（--skipNode 跳过）
if [ "$SKIP_NODE" = false ]; then
  echo -e "\n🔧 开始 Node.js LTS 安装..."
  # 卸载旧版
  if command_exists "node"; then
    echo "⚠️  检测到已安装 Node，正在卸载旧版..."
    sudo apt-get remove -y nodejs npm &> /dev/null
  fi

  # 安装新版
  if curl -fsSL "$NODE_LTS_SETUP_URL" | sudo -E bash - && sudo apt-get install -y nodejs; then
    NODE_VERSION=$(node -v)
    NPM_VERSION=$(npm -v)
    echo "✅ Node.js 安装成功："
    echo "  - Node：$NODE_VERSION"
    echo "  - npm：$NPM_VERSION"
  else
    echo "❌ Node.js 安装失败！是否跳过？"
    confirm_continue "继续执行其他步骤"
  fi
else
  echo -e "\n⚠️  已跳过 Node.js 安装"
fi

# 4. 全局 npm 工具安装（--skipNpmTools 跳过）
if [ "$SKIP_NPM_TOOLS" = false ] && command_exists "npm"; then
  echo -e "\n🔧 开始全局 npm 工具安装..."
  if sudo npm install -g pnpm yarn yrm typescript git-open; then
    echo "✅ 全局工具安装完成（pnpm/yarn/yrm/typescript/git-open）"
  else
    echo "❌ 全局工具安装失败！是否跳过？"
    confirm_continue "继续执行其他步骤"
  fi
elif [ "$SKIP_NPM_TOOLS" = true ]; then
  echo -e "\n⚠️  已跳过全局 npm 工具安装"
else
  echo -e "\n⚠️  未检测到 npm，跳过全局工具安装"
fi

# 5. npm registry 镜像配置（--skipNpmRegistry 跳过）
if [ "$SKIP_NPM_REGISTRY" = false ] && command_exists "yrm"; then
  echo -e "\n🔧 开始 npm registry 镜像配置..."
  yrm add codeup "$CODEUP_REGISTRY" --yes || echo "⚠️ Codeup 镜像已存在"
  if yrm use codeup; then
    echo "✅ yrm 切换到 Codeup 镜像：$(yrm current)"
  else
    echo "❌ yrm 配置失败！是否跳过？"
    confirm_continue "继续执行其他步骤"
  fi
elif [ "$SKIP_NPM_REGISTRY" = true ]; then
  echo -e "\n⚠️  已跳过 npm registry 镜像配置"
else
  echo -e "\n⚠️  未检测到 yrm，跳过镜像配置"
fi

# 6. npm 登录（--skipNpmLogin 跳过）
if [ "$SKIP_NPM_LOGIN" = false ] && command_exists "npm"; then
  echo -e "\n🔐 开始 npm 登录（Codeup 账号）..."
  if npm login --registry="$CODEUP_REGISTRY"; then
    echo "✅ npm 登录成功"
  else
    echo "❌ npm 登录失败！是否跳过？"
    confirm_continue "继续执行其他步骤"
  fi
elif [ "$SKIP_NPM_LOGIN" = true ]; then
  echo -e "\n⚠️  已跳过 npm 登录"
else
  echo -e "\n⚠️  未检测到 npm，跳过登录"
fi

# 7. yarn 登录（--skipYarnLogin 跳过）
if [ "$SKIP_YARN_LOGIN" = false ] && command_exists "yarn"; then
  echo -e "\n🔐 开始 yarn 登录（与 npm 账号一致）..."
  if yarn login --registry="$CODEUP_REGISTRY"; then
    echo "✅ yarn 登录成功"
  else
    echo "❌ yarn 登录失败！是否跳过？"
    confirm_continue "继续执行其他步骤"
  fi
elif [ "$SKIP_YARN_LOGIN" = true ]; then
  echo -e "\n⚠️  已跳过 yarn 登录"
else
  echo -e "\n⚠️  未检测到 yarn，跳过登录"
fi

# 8. gupo 工具安装（--skipGupoTools 跳过）
if [ "$SKIP_GUPO_TOOLS" = false ] && command_exists "npm"; then
  echo -e "\n🔧 开始 gupo 工具安装..."
  if npm install -g gupo-deploy gupo-cli gupo-imagemin @gupo-admin/cli --registry="$CODEUP_REGISTRY"; then
    echo "✅ gupo 工具安装完成"
  else
    echo "❌ gupo 工具安装失败！是否跳过？"
    confirm_continue "继续执行其他步骤"
  fi
elif [ "$SKIP_GUPO_TOOLS" = true ]; then
  echo -e "\n⚠️  已跳过 gupo 工具安装"
else
  echo -e "\n⚠️  未检测到 npm，跳过 gupo 工具安装"
fi

# 9. Git 配置（--skipGitConfig 跳过）
if [ "$SKIP_GIT_CONFIG" = false ]; then
  echo -e "\n🔧 开始 Git 配置..."
  # 安装 Git（未安装则安装）
  if ! command_exists "git"; then
    echo "⚠️  未检测到 Git，正在安装..."
    sudo apt-get install -y git || {
      echo "❌ Git 安装失败！"
      exit 1
    }
  fi

  # 配置用户信息
  read -p "请输入 Git 用户名（中文名字）：" GIT_USER_NAME
  while [ -z "$GIT_USER_NAME" ]; do
    echo "❌ 用户名不能为空！"
    read -p "重新输入：" GIT_USER_NAME
  done

  read -p "请输入 Git 邮箱（与云效一致或者你常用的）：" GIT_USER_EMAIL
  while [ -z "$GIT_USER_EMAIL" ] || ! echo "$GIT_USER_EMAIL" | grep -E '@'; do
    echo "❌ 邮箱格式不合法！"
    read -p "重新输入：" GIT_USER_EMAIL
  done

  # 应用 Git 配置
  git config --global core.autocrlf input
  git config --global user.name "$GIT_USER_NAME"
  git config --global user.email "$GIT_USER_EMAIL"
  git config --global core.quotepath false
  git config --global core.ignorecase false

  # npm 配置
  sed -i -e '/save-prefix=/d' -e '/always-auth=/d' ~/.npmrc &> /dev/null
  echo 'always-auth=true' >> ~/.npmrc
  echo 'save-prefix=""' >> ~/.npmrc

  echo "✅ Git 配置完成"
  git config --global --list | grep -E 'user.name|user.email|core.autocrlf'
else
  echo -e "\n⚠️  已跳过 Git 配置"
fi

# 10. SSH 密钥配置（--skipSshKey 跳过）
if [ "$SKIP_SSH_KEY" = false ]; then
  echo -e "\n🔑 开始配置 SSH 密钥（用于 Git 仓库免密访问）..."
  SSH_KEY_ED25519="$HOME/.ssh/id_ed25519.pub"
  SSH_KEY_RSA="$HOME/.ssh/id_rsa.pub"
  ACTIVE_SSH_KEY=""

  # 检测已有密钥
  if [ -f "$SSH_KEY_ED25519" ]; then
    echo "✅ 已检测到 ed25519 类型 SSH 密钥"
    ACTIVE_SSH_KEY="$SSH_KEY_ED25519"
  elif [ -f "$SSH_KEY_RSA" ]; then
    echo "✅ 已检测到 rsa 类型 SSH 密钥"
    ACTIVE_SSH_KEY="$SSH_KEY_RSA"
  else
    # 生成新密钥
    echo "⚠️  未检测到 SSH 密钥，正在生成 ed25519 类型密钥（更安全）..."
    ssh-keygen -t ed25519 -C "$GIT_USER_EMAIL" -N "" -f "$HOME/.ssh/id_ed25519" &> /dev/null
    echo "✅ SSH 密钥生成完成！"
    ACTIVE_SSH_KEY="$SSH_KEY_ED25519"
  fi

  # 输出公钥
  echo -e "\n📋 你的 SSH 公钥（复制到 Codeup）："
  echo "----------------------------------------------------------------------"
  cat "$ACTIVE_SSH_KEY"
  echo "----------------------------------------------------------------------"
  echo "💡 提示：公钥已保存到 $ACTIVE_SSH_KEY，可随时通过 'cat $ACTIVE_SSH_KEY' 查看"
else
  echo -e "\n⚠️  已跳过 SSH 密钥配置"
fi

# 11. WSL 代理配置（--skipProxy 跳过）
if [ "$SKIP_PROXY" = false ]; then
  echo -e "\n🌐 开始 WSL 代理配置..."
  # 获取 Windows IP（host.docker.internal）
  WINDOWS_IP=$(ping -c 1 host.docker.internal | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)
  if [ -z "$WINDOWS_IP" ] || ! echo "$WINDOWS_IP" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    read -p "请输入 Windows 局域网 IP（例如：192.168.1.100）：" WINDOWS_IP
    while ! echo "$WINDOWS_IP" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; do
      echo "❌ IP 格式不合法（必须是 x.x.x.x 四段）！"
      read -p "请重新输入 Windows 局域网 IP：" WINDOWS_IP
    done
  fi

  # 获取 Clash 端口
  read -p "请输入 Windows Clash 的 Socks5 端口（默认 7890，直接回车使用默认值）：" CLASH_PORT
  CLASH_PORT=${CLASH_PORT:-7890}

  # 定义代理地址
  PROXY_SOCKS5="socks5://$WINDOWS_IP:$CLASH_PORT"
  PROXY_HTTP="http://$WINDOWS_IP:$CLASH_PORT"

  # 写入 .bashrc
  cat << EOF >> "$HOME/.bashrc"

# -------------------------- WSL 代理配置（Clash）--------------------------
PROXY_SOCKS5="$PROXY_SOCKS5"
PROXY_HTTP="$PROXY_HTTP"
export ALL_PROXY=\$PROXY_HTTP  # 优先用 HTTP 代理，兼容性更好
export HTTP_PROXY=\$PROXY_HTTP
export HTTPS_PROXY=\$PROXY_HTTP
export SOCKS_PROXY=\$PROXY_SOCKS5

# 国内域名/IP 不走代理（优化访问速度，避免冲突）
export NO_PROXY="localhost,127.0.0.1,172.0.0.0/8,192.168.0.0/16,.aliyun.com,.aliyuncs.com,.codeup.aliyun.com,.gupo.com.cn,packages.aliyun.com"

proxy-on() {
  export ALL_PROXY=\$PROXY_HTTP
  export HTTP_PROXY=\$PROXY_HTTP
  export HTTPS_PROXY=\$PROXY_HTTP
  export SOCKS_PROXY=\$PROXY_SOCKS5
  echo "✅ 代理已开启（\$PROXY_SOCKS5）"
}

proxy-off() {
  unset ALL_PROXY HTTP_PROXY HTTPS_PROXY SOCKS_PROXY
  echo "✅ 代理已关闭"
}

proxy-test() {
  echo -e "\n正在测试代理连通性（访问 Google 验证）..."
  echo "  Windows IP：$WINDOWS_IP"
  echo "  代理地址：\$PROXY_SOCKS5"
  echo "  超时时间：5 秒"

  # 输出关键连接日志，方便排查
  curl -v --connect-timeout 5 https://www.google.com 2>&1 | grep -E 'Connected|Failed|timeout|refused'
  if curl -s --connect-timeout 5 https://www.google.com &> /dev/null; then
    echo "✅ 代理测试成功！可正常访问外网"
  else
    echo "❌ 代理测试失败！请检查："
    echo "  1. Windows Clash 是否已启动并开启「允许局域网连接」"
    echo "  2. Clash 端口（$CLASH_PORT）是否与配置一致"
    echo "  3. Windows 防火墙是否放行 $CLASH_PORT 端口"
    echo "  4. Clash 节点是否可用（浏览器访问 Google 验证）"
  fi
}
# --------------------------------------------------------------------------
EOF

  echo "✅ 代理配置完成（$PROXY_SOCKS5）"
  proxy-test
else
  echo -e "\n⚠️  已跳过 WSL 代理配置"
fi

# ======================== 收尾验证（汇总结果）========================
echo -e "\n========================================================================"
echo "📋 工具安装验证结果："
verify_tool "git"
verify_tool "node"
verify_tool "npm"
verify_tool "pnpm"
verify_tool "yarn"
verify_tool "yrm"
verify_tool "tsc"
verify_tool "git-open"
verify_tool "fnm"
verify_tool "gupo-deploy"

echo -e "\n📋 自定义别名清单："
for alias_key in "${!ALIAS_MAP[@]}"; do
  echo "  - $alias_key：${ALIAS_MAP[$alias_key]}"
done

echo -e "\n⚙️ 常用命令说明："
echo "  - 端口转发：port-add <端口> | port-del <端口> | port-reset"
echo "  - 代理控制：proxy-on | proxy-off | proxy-test"
echo "  - fnm 命令：fnm install <版本> | fnm use <版本>"
echo "  - 镜像切换：yrm use <镜像名>"

echo -e "\n🎉 所有操作完成！重启终端或执行 'source ~/.bashrc' 即可使用所有配置～"
echo "📌 关键信息汇总："
echo "  - 镜像源：$(yrm current)（$CODEUP_REGISTRY）"
echo "  - npm/yarn 已登录 Codeup 镜像"
echo "  - Git 用户名：$GIT_USER_NAME，邮箱：$GIT_USER_EMAIL"
echo "  - SSH 公钥路径：$ACTIVE_SSH_KEY（已在上文输出，可复制到代码平台）"
echo "  - WSL 代理配置：$PROXY_SOCKS5（Clash 需保持启动并开启局域网连接）"
echo "  - 所有别名、函数、配置已生效，可直接使用"
echo "========================================================================"
