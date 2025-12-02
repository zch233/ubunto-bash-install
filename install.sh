#!/bin/bash

set -eo pipefail  # 增强错误处理：管道错误退出（去掉 -u，避免未定义变量报错）
# set -x             # 可选：执行时输出每个命令（方便调试，取消注释即可）

# 阿里云 Codeup 镜像地址（统一配置，方便后续修改）
CODEUP_REGISTRY="https://packages.aliyun.com/5eb3e37038076f00011bcd4a/npm/npm-registry/"

# 定义别名清单（与 .bashrc 中的 alias 对应，用于最终输出说明）
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

# 1. 备份 .bashrc（避免覆盖原有配置）
BACKUP_FILE="$HOME/.bashrc.bak.$(date +%Y%m%d%H%M%S)"
cp "$HOME/.bashrc" "$BACKUP_FILE"
echo "✅ 已备份原有 .bashrc 到：$BACKUP_FILE"

# 2. 写入自定义配置到临时文件（支持 $USER 解析，修正函数示例）
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
add-port() {
  if [ -z "$1" ]; then
    echo "❌ 请指定端口号（示例：add-port 23355）"
    return 1
  fi

  local PORT="$1"
  local WSL_IP=\$(ip addr | grep -E 'inet\s' | awk '{print \$2}' | cut -d '/' -f 1 | grep '^172\.' | head -n 1)

  if [ -z "\$WSL_IP" ]; then
    echo "❌ 无法获取 172 开头的 WSL 内网 IP"
    echo "  提示：执行 'ip addr' 查看所有 IP，确认 WSL 已分配内网地址"
    return 1
  fi

  echo "✅ 已获取 WSL IP：\$WSL_IP，转发端口：\$PORT"
  powershell.exe -Command 'Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command ""netsh interface portproxy add v4tov4 listenport='\$PORT' listenaddress=0.0.0.0 connectport='\$PORT' connectaddress='\$WSL_IP'; echo === 转发创建完成 ===; netsh interface portproxy show v4tov4 listenport='\$PORT'"""'
}

# 配套删除函数
del-port() {
  if [ -z "$1" ]; then
    echo "❌ 请指定端口号（示例：del-port 23355）"
    return 1
  fi

  local PORT="$1"
  echo "🗑️ 正在删除端口转发：\$PORT"
  powershell.exe -Command 'Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command ""netsh interface portproxy delete v4tov4 listenport='\$PORT' listenaddress=0.0.0.0; echo === 转发已删除 ===; netsh interface portproxy show v4tov4"""'
}
EOF

# 3. 拼接原有 .bashrc 内容，替换原文件并修复权限
cat "$HOME/.bashrc" >> "$HOME/.bashrc.tmp"
mv -f "$HOME/.bashrc.tmp" "$HOME/.bashrc"
chmod 644 "$HOME/.bashrc"
echo "✅ 已更新 .bashrc 配置（自定义配置在最前面）"

# 4. 安装 fnm 并配置环境变量
echo -e "\n🔧 开始安装 fnm..."
curl -fsSL https://fnm.vercel.app/install | bash || {
  echo "❌ fnm 安装失败！"
  exit 1
}
echo 'eval "$(fnm env --use-on-cd --shell bash)"' >> "$HOME/.bashrc"
echo "✅ fnm 安装完成，已配置环境变量"

# 关键修改：统一更新 apt 源（在所有 apt-get install 前执行一次）
echo -e "\n🔧 正在更新 apt 软件源缓存..."
sudo apt-get update &> /dev/null || {
  echo "❌ apt 源更新失败！请检查网络连接"
  exit 1
}
echo "✅ apt 源更新完成"

# 5. 安装 Node.js LTS（卸载旧版避免冲突）
echo -e "\n🔧 开始安装 Node.js LTS..."
if command -v node &> /dev/null; then
  echo "⚠️  检测到已安装 Node，正在卸载旧版..."
  sudo apt-get remove -y nodejs npm &> /dev/null
fi
curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash - || {
  echo "❌ 添加 Node 源失败！"
  exit 1
}
sudo apt-get install -y nodejs || {
  echo "❌ Node.js 安装失败！"
  exit 1
}

# 验证 Node/npm 基础安装
if ! command -v node &> /dev/null || ! command -v npm &> /dev/null; then
  echo "❌ Node.js/npm 安装失败！"
  exit 1
fi
NODE_VERSION=$(node -v)
NPM_VERSION=$(npm -v)
echo "✅ Node.js LTS 安装成功："
echo "  - Node 版本：$NODE_VERSION"
echo "  - npm 版本：$NPM_VERSION"

# 6. 全局安装 npm 工具包（pnpm/yarn/yrm/typescript/git-open）
echo -e "\n🔧 开始安装全局 npm 工具包..."
sudo npm install -g pnpm yarn yrm typescript git-open || {
  echo "❌ 全局工具包安装失败！"
  exit 1
}
echo "✅ 全局工具包安装完成（pnpm/yarn/yrm/typescript/git-open）"

# 7. 配置 yrm 镜像（添加 Codeup 镜像并切换）
echo -e "\n🔧 配置 yrm 镜像（Codeup 阿里云镜像）..."
# 先检查 yrm 是否安装成功
if ! command -v yrm &> /dev/null; then
  echo "❌ yrm 未安装成功，无法配置镜像！"
  exit 1
fi
# 添加 Codeup 镜像（--yes 自动确认覆盖已存在的镜像）
yrm add codeup "$CODEUP_REGISTRY" --yes || {
  echo "⚠️ Codeup 镜像已存在，跳过添加"
}
# 切换到 Codeup 镜像
yrm use codeup || {
  echo "❌ 切换到 Codeup 镜像失败！"
  exit 1
}
echo "✅ yrm 镜像配置完成，当前使用：$(yrm current)"

# 8. npm 登录（交互式输入账号密码）
echo -e "\n🔐 请进行 npm 登录（使用 Codeup 账号密码）..."
npm login --registry="$CODEUP_REGISTRY" || {
  echo "❌ npm 登录失败！请检查账号密码或网络连接"
  exit 1
}
echo "✅ npm 登录成功！"

# 9. yarn 登录（交互式输入账号密码，与 npm 账号一致）
echo -e "\n🔐 请进行 yarn 登录（使用与 npm 相同的 Codeup 账号密码）..."
yarn login --registry="$CODEUP_REGISTRY" || {
  echo "❌ yarn 登录失败！请检查账号密码或网络连接"
  exit 1
}
echo "✅ yarn 登录成功！"

# 10. 安装 gupo 系列工具（从 Codeup 镜像拉取）
echo -e "\n🔧 开始安装 gupo 系列工具..."
npm install -g gupo-deploy gupo-cli gupo-imagemin @gupo-admin/cli --registry="$CODEUP_REGISTRY" || {
  echo "❌ gupo 工具安装失败！请检查登录状态或镜像地址"
  exit 1
}
echo "✅ gupo 工具安装完成（gupo-deploy/gupo-cli/gupo-imagemin/@gupo-admin/cli）"

# 11. Git 安装与配置（新增核心步骤）
echo -e "\n🔧 开始配置 Git..."
# 检测 Git 是否安装，未安装则安装最新版
if ! command -v git &> /dev/null; then
  echo "⚠️  未检测到 Git，正在安装最新版..."
  sudo apt-get install -y git || {
    echo "❌ Git 安装失败！"
    exit 1
  }
  echo "✅ Git 安装成功！"
else
  GIT_VERSION=$(git --version | awk '{print $3}')
  echo "✅ 已检测到 Git（版本：$GIT_VERSION），跳过安装"
fi

# 交互式获取用户信息（中文提示）
echo -e "\n📝 请配置 Git 全局用户信息（与云效/Codeup 绑定信息一致）"
read -p "请输入你的中文名字（例如：张三）：" GIT_USER_NAME
# 验证名字非空
while [ -z "$GIT_USER_NAME" ]; do
  echo "❌ 名字不能为空！"
  read -p "请重新输入你的中文名字：" GIT_USER_NAME
done

read -p "请输入你的常用邮箱（需与云效/Codeup 绑定邮箱一致）：" GIT_USER_EMAIL
# 验证邮箱非空且格式合法（简单校验）
while [ -z "$GIT_USER_EMAIL" ] || ! echo "$GIT_USER_EMAIL" | grep -E '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$' &> /dev/null; do
  echo "❌ 邮箱格式不合法或为空！"
  read -p "请重新输入你的常用邮箱：" GIT_USER_EMAIL
done

# npm yarn pnpm 全局配置
# 先删除可能存在的重复项，再依次追加两个配置
sed -i -e '/save-prefix=/d' -e '/always-auth=/d' ~/.npmrc && \
echo 'always-auth=true' >> ~/.npmrc && \
echo 'save-prefix=""' >> ~/.npmrc

# 配置 Git 全局参数
echo -e "\n⚙️ 正在应用 Git 全局配置..."
git config --global core.autocrlf input  # 提交时转换为 LF，检出时不转换
git config --global user.name "$GIT_USER_NAME"  # 配置用户名
git config --global user.email "$GIT_USER_EMAIL"  # 配置邮箱
git config --global core.quotepath false  # 防止文件名变成数字编码
git config --global core.ignorecase false  # 开启大小写敏感（区分文件名大小写）

# 验证 Git 配置
echo -e "\n✅ Git 配置完成，当前全局配置："
git config --global --list | grep -E 'user.name|user.email|core.autocrlf|core.quotepath|core.ignorecase'

# 新增：SSH 密钥检测与生成（核心步骤）
echo -e "\n🔑 开始配置 SSH 密钥（用于 Git 仓库免密访问）..."
SSH_KEY_ED25519="$HOME/.ssh/id_ed25519.pub"
SSH_KEY_RSA="$HOME/.ssh/id_rsa.pub"
SSH_KEY_EXISTS=false
ACTIVE_SSH_KEY=""

# 检测是否已存在 SSH 公钥
if [ -f "$SSH_KEY_ED25519" ]; then
  echo "✅ 已检测到 ed25519 类型 SSH 密钥"
  SSH_KEY_EXISTS=true
  ACTIVE_SSH_KEY="$SSH_KEY_ED25519"
elif [ -f "$SSH_KEY_RSA" ]; then
  echo "✅ 已检测到 rsa 类型 SSH 密钥"
  SSH_KEY_EXISTS=true
  ACTIVE_SSH_KEY="$SSH_KEY_RSA"
else
  echo "⚠️  未检测到 SSH 密钥，正在生成 ed25519 类型密钥（更安全）..."
  # 生成 ed25519 密钥，注释为 Git 配置的邮箱，全程静默（无需交互）
  ssh-keygen -t ed25519 -C "$GIT_USER_EMAIL" -N "" -f "$HOME/.ssh/id_ed25519" &> /dev/null
  echo "✅ SSH 密钥生成完成！"
  SSH_KEY_EXISTS=true
  ACTIVE_SSH_KEY="$SSH_KEY_ED25519"
fi

# 输出 SSH 公钥内容（方便用户复制到 Codeup/GitHub 平台）
echo -e "\n📋 你的 SSH 公钥（请复制到 Codeup/GitHub 仓库的 SSH 密钥配置中）："
echo "----------------------------------------------------------------------"
cat "$ACTIVE_SSH_KEY"
echo "----------------------------------------------------------------------"
echo "💡 提示：公钥已保存到 $ACTIVE_SSH_KEY，可随时通过 'cat $ACTIVE_SSH_KEY' 查看"

# 12. 最终加载配置并验证所有工具
echo -e "\n🔧 加载所有配置并验证安装结果..."
source "$HOME/.bashrc"

# 验证关键工具是否可用
verify_tool() {
  local tool=$1
  if command -v "$tool" &> /dev/null; then
    local version=$("$tool" --version 2>&1 | head -n 1)
    echo "  ✅ $tool：$version"
  else
    echo "  ❌ $tool：未安装成功"
  fi
}

echo -e "\n📋 所有工具安装验证结果："
verify_tool "git"
verify_tool "pnpm"
verify_tool "yarn"
verify_tool "yrm"
verify_tool "tsc"  # typescript 命令
verify_tool "git-open"

# 13. 输出别名清单（新增核心需求）
echo -e "\n📋 自定义命令别名清单（缩写 + 完整命令 + 功能说明）："
for alias_key in "${!ALIAS_MAP[@]}"; do
  echo "  - $alias_key：${ALIAS_MAP[$alias_key]}"
done

# 补充端口转发函数说明
echo -e "\n⚙️ 常用函数说明："
echo "  - add-port [端口号]：创建 WSL 端口转发（示例：add-port 8080，让外部访问 WSL 的 8080 端口）"
echo "  - del-port [端口号]：删除指定端口转发（示例：del-port 8080）"

echo -e "\n🎉 所有操作完成！重启终端或执行 'source ~/.bashrc' 即可使用所有配置～"
echo "📌 关键信息汇总："
echo "  - 镜像源：$(yrm current)（$CODEUP_REGISTRY）"
echo "  - npm/yarn 已登录 Codeup 镜像"
echo "  - Git 用户名：$GIT_USER_NAME，邮箱：$GIT_USER_EMAIL"
echo "  - SSH 公钥路径：$ACTIVE_SSH_KEY（已在上文输出，可复制到代码平台）"
echo "  - 所有别名、函数、配置已生效，可直接使用"