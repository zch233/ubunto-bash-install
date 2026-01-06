#!/bin/bash

set -eo pipefail
# set -x             # 可选：执行时输出每个命令（方便调试，取消注释即可）

# ======================== 配置区（统一管理地址/参数）========================
# 阿里云 Codeup 镜像地址
CODEUP_REGISTRY="https://packages.aliyun.com/5eb3e37038076f00011bcd4a/npm/npm-registry/"
# fnm 安装地址（优先官方，失败回退jsdelivr镜像）
FNM_INSTALL_URL_OFFICIAL="https://fnm.vercel.app/install"
FNM_INSTALL_URL_MIRROR="https://cdn.jsdelivr.net/gh/Schniz/fnm@master/.ci/install.sh"
# Node.js 源地址（自动适配 libc 版本）
NODE_LTS_SETUP_URL="https://deb.nodesource.com/setup_lts.x"
NODE_LTS_SETUP_URL_OLD="https://deb.nodesource.com/setup_16.x"

# 跳过参数默认值（false=不跳过）
SKIP_FLAG=false
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

# ======================== 集中配置定义 ========================
# 别名清单
ALIAS_CONFIG=$(cat << 'ALIAS_CONFIG_EOF'
gp:git push - 推送代码到远程仓库
gll:git pull - 拉取远程仓库代码到本地
gl:git clone - 克隆远程仓库到本地
gc:git checkout - 切换分支或恢复工作区文件
glog:git log simplify - 美化显示提交日志（含分支图、作者、时间）
gk:git cherry-pick - 选择性合并指定提交记录
ys:yarn dev | yarn serve - 启动 yarn 开发/预览服务（根据项目配置生效）
code:cursor - 用 Cursor 编辑器打开当前目录
gg:gupo-deploy -a -p - 执行 gupo-deploy 部署命令（全量部署 + 保持参数）
ALIAS_CONFIG_EOF
)

# TOOLS_CONFIG 和 COMMANDS_CONFIG 也按同样方式修改
TOOLS_CONFIG=$(cat << 'TOOLS_CONFIG_EOF'
git
node
npm
pnpm
yarn
yrm
tsc
git-open
fnm
TOOLS_CONFIG_EOF
)

COMMANDS_CONFIG=$(cat << 'COMMANDS_CONFIG_EOF'
端口转发：port-add <端口> | port-del <端口> | port-reset | port-show
代理控制：proxy-on | proxy-off | proxy-test
fnm 命令：fnm install <版本> | fnm use <版本>
镜像切换：yrm ls | yrm use <镜像名>
COMMANDS_CONFIG_EOF
)

SUMMARY_TEMPLATE=$(cat << 'SUMMARY_EOF'
📌 关键信息汇总：
  - 镜像源：{MIRROR_NAME}（{MIRROR_URL}）
  - npm/yarn 已登录 Codeup 镜像
  - Git 用户名：{GIT_USER}，邮箱：{GIT_EMAIL}
  - SSH 公钥：{SSH_KEY_INFO}
  - WSL 代理配置：已配置（Clash 需保持启动并开启局域网连接）
  - 所有别名、函数、配置已生效，可直接使用
========================================================================
SUMMARY_EOF
)

GENERATE_SUMMARY_FUNC=$(cat << 'FUNC_EOF'
generate_summary() {
  local mirror_name=$(yrm current 2>/dev/null || echo "未配置")
  local mirror_url=$(yrm ls 2>/dev/null | grep -E "^[[:space:]]*(\* |)$mirror_name" | sed -E "s/^[[:space:]]*(\* |)?$mirror_name[[:space:]]*-+[[:space:]]*//" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' || echo "$CODEUP_REGISTRY")
  local git_user=$(git config --global --get user.name 2>/dev/null || echo "未配置")
  local git_email=$(git config --global --get user.email 2>/dev/null || echo "未配置")
  local ssh_key_info=$(get_ssh_key_info)

  # 替换模板占位符（使用 | 作为分隔符，避免 URL 中的 / 字符问题）
  echo -e "$SUMMARY_TEMPLATE" | \
    sed "s|{MIRROR_NAME}|${mirror_name}|g" | \
    sed "s|{MIRROR_URL}|${mirror_url}|g" | \
    sed "s|{GIT_USER}|${git_user}|g" | \
    sed "s|{GIT_EMAIL}|${git_email}|g" | \
    sed "s|{SSH_KEY_INFO}|${ssh_key_info}|g"
}
FUNC_EOF
)

# ======================== 解析配置的函数（脚本和 install_info 共用）========================
# 解析别名配置为数组
parse_alias_config() {
  declare -A alias_map
  while IFS=':' read -r key value; do
    [[ -z "$key" || "$key" =~ ^# ]] && continue  # 跳过空行和注释
    alias_map["$key"]="$value"
  done <<< "$ALIAS_CONFIG"

  # 返回关联数组（通过全局变量或eval）
  if [[ "$1" == "--eval" ]]; then
    # 返回可eval的字符串
    declare -p alias_map
  else
    # 直接使用（需要调用者声明关联数组）
    for key in "${!alias_map[@]}"; do
      echo "  - $key：${alias_map[$key]}"
    done
  fi
}

# 解析工具配置为数组
parse_tools_config() {
  local tools=()
  while IFS= read -r tool; do
    [[ -z "$tool" || "$tool" =~ ^# ]] && continue
    tools+=("$tool")
  done <<< "$TOOLS_CONFIG"

  if [[ "$1" == "--eval" ]]; then
    declare -p tools
  else
    printf '%s\n' "${tools[@]}"
  fi
}

# 解析命令配置为数组
parse_commands_config() {
  local commands=()
  while IFS= read -r cmd; do
    [[ -z "$cmd" || "$cmd" =~ ^# ]] && continue
    commands+=("$cmd")
  done <<< "$COMMANDS_CONFIG"

  if [[ "$1" == "--eval" ]]; then
    declare -p commands
  else
    printf '%s\n' "${commands[@]}"
  fi
}

# ======================== 工具函数（简化重复逻辑）========================
# 检测命令是否存在
command_exists() {
  command -v "$1" &> /dev/null
  return $?
}

# 验证工具安装（通用版，供脚本和 install_info 命令使用）
verify_tool() {
  local tool=$1
  # 先判断工具是否存在
  if ! command_exists "$tool"; then
    echo "  ❌ $tool：未安装成功"
    return 0  # 强制返回0，避免set -e
  fi

  # 定义常见的版本查询参数（按优先级排序，覆盖绝大多数工具）
  local version_params=("--version" "-v" "version" "--info" "-V")
  local version_output=""
  local final_version="unknown"  # 默认值：unknown

  # 循环尝试版本参数
  for param in "${version_params[@]}"; do
    # 捕获版本输出，强制容错
    version_output=$("$tool" "$param" 2>/dev/null | head -n 1 || true)
    # 仅当输出非空时，尝试提取数字版本
    if [ -n "$version_output" ]; then
      # 仅匹配 数字.数字(.数字) 格式，无则保持 unknown
      final_version=$(echo "$version_output" | grep -Eo '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n 1 || true)
      # 若提取到空（非数字），重置为 unknown
      [ -z "$final_version" ] && final_version="unknown"
      break  # 找到输出就停止，不管是否提取到数字
    fi
  done

  # 输出结果：仅显示数字版本或 unknown
  echo "  ✅ $tool：$final_version"
  return 0  # 确保函数永不返回非0
}

# 提示用户确认（可选继续）
confirm_continue() {
  local msg="$1"
  # 强制使用交互式终端读取输入
  read -r -p "$msg（y/N）：" choice < /dev/tty
  case "$choice" in
    [Yy]* ) return 0;;
    * ) echo "❌ 用户取消，退出脚本"; exit 1;;
  esac
}

# 安全执行登录命令
safe_login() {
  local tool=$1
  local registry=$2
  local login_success=false

  # 第一步：校验终端是否支持交互
  if [ ! -t 0 ] || [ ! -t 1 ]; then
    echo "❌ 错误：当前终端不支持交互式输入，请在原生终端执行脚本（非管道/后台）"
    return 1
  fi

  # 第二步：清理 registry 末尾的 /（避免匹配问题）
  local clean_registry=$(echo "$registry" | sed -e 's/\/$//')
  local registry_core=$(echo "$clean_registry" | sed -e 's/^https:\/\///')

  # 第三步：适配工具命令
  case "$tool" in
    npm)
      echo -e "\n📢 【NPM 登录】请输入 Codeup 账号信息（用户名/密码/邮箱）："
      echo -e "📢 【NPM 登录】账号信息获取地址：\033[4;94mhttps://packages.aliyun.com/npm/npm-registry/guide\033[0m \n"
      # 强制设置 registry
      npm config set registry "$clean_registry" > /dev/null 2>&1
      # 直接执行登录，所有IO绑定当前终端
      npm login --registry="$clean_registry" < /dev/tty > /dev/tty 2>&1
      local exit_code=$?
      # 验证是否真的登录成功（通过读取 token）
      local token=$(npm config get "//${registry_core}/:_authToken" 2>/dev/null)
      if [ -n "$token" ] || [ $exit_code -eq 0 ]; then
        login_success=true
      fi
      ;;
    yarn)
      # 同步失败则触发交互式登录
      echo -e "\n📢 【Yarn 登录】复用 NPM 认证信息，可能需手动输入账号信息："
      echo -e "📢 【Yarn 登录】账号信息获取地址：\033[4;94mhttps://packages.aliyun.com/npm/npm-registry/guide\033[0m \n"
      yarn login < /dev/tty > /dev/tty 2>&1
      local exit_code=$?
      # 验证 token
      local yarn_token=$(yarn config get --home "//${registry_core}/:_authToken" 2>/dev/null)
      if [ -n "$yarn_token" ] || [ $exit_code -eq 0 ]; then
        login_success=true
      fi
      ;;
    *)
      echo "❌ 不支持的工具：$tool"
      return 1
      ;;
  esac

  # 返回结果
  if [ "$login_success" = true ]; then
    return 0
  else
    return 1
  fi
}

# 检测 libc6 版本，返回适配的 Node.js 源地址
get_node_setup_url() {
  # 提取 libc6 主版本号（如 2.27 → 2.27，2.31 → 2.31）
  local libc_version=$(ldd --version | grep -oP 'GLIBC \K[0-9]+\.[0-9]+' | head -n 1)
  # 对比版本（需要 bc 工具支持浮点比较）
  if command_exists "bc" && (( $(echo "$libc_version < 2.28" | bc -l) )); then
    echo "⚠️ 检测到系统 libc6 版本为 $libc_version（<2.28），将使用 Node.js 16.x 兼容版本" >&2
    echo "$NODE_LTS_SETUP_URL_OLD"
  else
    echo "$NODE_LTS_SETUP_URL"
  fi
}

# 获取 SSH 公钥信息
get_ssh_key_info() {
  if [ -f "$HOME/.ssh/id_ed25519.pub" ]; then
    echo "ed25519 类型（~/.ssh/id_ed25519.pub）"
  elif [ -f "$HOME/.ssh/id_rsa.pub" ]; then
    echo "rsa 类型（~/.ssh/id_rsa.pub）"
  else
    echo "未生成"
  fi
}

# 显示安装信息的核心函数（使用集中配置）
show_install_info() {
  echo -e "\n========================================================================"
  echo "📋 工具安装验证结果："

  # 遍历工具清单验证
  while IFS= read -r tool; do
    [[ -z "$tool" ]] && continue
    verify_tool "$tool"
  done <<< "$TOOLS_CONFIG"

  echo -e "\n📋 自定义别名清单："
  parse_alias_config

  echo -e "\n⚙️ 常用命令说明："
  while IFS= read -r cmd; do
    [[ -z "$cmd" ]] && continue
    echo "  - $cmd"
  done <<< "$COMMANDS_CONFIG"

  eval "$GENERATE_SUMMARY_FUNC"
  echo -e "\n$(generate_summary)"
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
echo "📋 脚本执行配置："
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

# 0. WSL 代理配置（--skipProxy 跳过）
if [ "$SKIP_PROXY" = false ]; then
  echo -e "\n🌐 开始 WSL 代理配置..."
  # 获取 Windows IP（host.docker.internal）
  WINDOWS_IP=$(ping -c 1 -W 2 -w 3 host.docker.internal 2>/dev/null | grep -Eo '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true)
  if [ -z "$WINDOWS_IP" ] || ! echo "$WINDOWS_IP" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo -e "\n🌐 请输入 Windows 局域网 IP，如果你不知道的话，可以在 windows 终端输入 ipconfig 查看"
    echo -e "\n🌐 哦对，还有记得打开「允许局域网链接」这个选项"
    read -r -p "例如：192.168.x.x 或者 10.x.x.x：" WINDOWS_IP < /dev/tty
    while ! echo "$WINDOWS_IP" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; do
      echo "❌ IP 格式不合法（必须是 x.x.x.x 四段）！"
      read -r -p "请重新输入 Windows 局域网 IP：" WINDOWS_IP < /dev/tty
    done
  fi

  # 2. 获取 Clash 端口（默认 7890）
  echo -e "\n🌐 请输入 Windows Clash or Proxy 的 Socks5/Http 端口"
  read -r -p "输入 0 代表没有代理，默认 7890 直接回车使用默认值：" CLASH_PORT < /dev/tty
  CLASH_PORT=${CLASH_PORT:-7890}
  if [ "$CLASH_PORT" = 0 ]; then
    echo -e "\n🤢 太拉垮了，连个代理都没有"
  else
    # 3. 定义核心配置（单一数据源，仅维护一次）
    PROXY_SOCKS5="socks5://$WINDOWS_IP:$CLASH_PORT"
    PROXY_HTTP="http://$WINDOWS_IP:$CLASH_PORT"
    NO_PROXY_LIST="localhost,127.0.0.1,172.0.0.0/8,192.168.0.0/16,.aliyun.com,.aliyuncs.com,.codeup.aliyun.com,.gupo.com.cn,packages.aliyun.com"

    # 4. 代理配置模板（仅写一次！复用给「写入.bashrc」和「脚本内加载」）
    PROXY_TEMPLATE=$(cat << 'EOF'
# -------------------------- WSL 代理配置（Clash）--------------------------
PROXY_SOCKS5="{PROXY_SOCKS5}"
PROXY_HTTP="{PROXY_HTTP}"
export ALL_PROXY=$PROXY_HTTP  # 优先用 HTTP 代理，兼容性更好
export HTTP_PROXY=$PROXY_HTTP
export HTTPS_PROXY=$PROXY_HTTP
export SOCKS_PROXY=$PROXY_SOCKS5
export NO_PROXY="{NO_PROXY_LIST}"

proxy-on() {
  export ALL_PROXY=$PROXY_HTTP
  export HTTP_PROXY=$PROXY_HTTP
  export HTTPS_PROXY=$PROXY_HTTP
  export SOCKS_PROXY=$PROXY_SOCKS5
  echo "✅ 代理已开启（$PROXY_SOCKS5）"
}

proxy-off() {
  unset ALL_PROXY HTTP_PROXY HTTPS_PROXY SOCKS_PROXY
  echo "✅ 代理已关闭"
}

proxy-test() {
  if [ -z "$ALL_PROXY" ]; then
    echo -e "\n🔌 检测到代理未开启，正在自动开启..."
    proxy-on
  else
    echo -e "\n🔌 代理已处于开启状态（当前代理：$ALL_PROXY）"
  fi

  # 开始代理连通性测试
  echo -e "\n正在测试代理连通性（访问 Google 验证）..."
  echo "  Windows IP：{WINDOWS_IP}"
  echo "  代理地址：$PROXY_SOCKS5"
  echo "  超时时间：5 秒"

  # 输出关键连接日志，方便排查
  curl -v --connect-timeout 5 https://www.google.com 2>&1 | grep -E 'Connected|Failed|timeout|refused' || true
  if curl -s --connect-timeout 5 https://www.google.com &> /dev/null; then
    echo "✅ 代理测试成功！可正常访问外网"
  else
    echo "❌ 代理测试失败！请检查："
    echo "  1. Windows Clash 是否已启动并开启「允许局域网连接」"
    echo "  2. Clash 端口（{CLASH_PORT}）是否与配置一致"
    echo "  3. Windows 防火墙是否放行 {CLASH_PORT} 端口"
    echo "  4. Clash 节点是否可用（浏览器访问 Google 验证）"
  fi
}
# --------------------------------------------------------------------------
EOF
    )
    # 5. 复用模板：写入 .bashrc（保留原功能，供后续终端使用）
    if ! grep -q "# -------------------------- WSL 代理配置（Clash）--------------------------" "$HOME/.bashrc"; then
      BACKUP_FILE="$HOME/.bashrc.bak.$(date +%Y%m%d%H%M%S)"
      cp "$HOME/.bashrc" "$BACKUP_FILE"
      echo "✅ 已备份原有 .bashrc 到：$BACKUP_FILE"
      # 替换模板占位符并写入 .bashrc（修复 sed 分隔符为 |）
      echo "$PROXY_TEMPLATE" | sed \
        -e "s|{PROXY_SOCKS5}|$PROXY_SOCKS5|g" \
        -e "s|{PROXY_HTTP}|$PROXY_HTTP|g" \
        -e "s|{NO_PROXY_LIST}|$NO_PROXY_LIST|g" \
        -e "s|{WINDOWS_IP}|$WINDOWS_IP|g" \
        -e "s|{CLASH_PORT}|$CLASH_PORT|g" >> "$HOME/.bashrc"
    else
      echo "✅ WSL 代理配置（Clash）已存在，无需重复配置"
    fi

    # 6. 复用模板：在脚本内加载（让 proxy-test 等函数直接生效）
    # 替换占位符 + 移除变量转义符，通过 eval 注入到当前脚本环境
    eval "$(echo "$PROXY_TEMPLATE" | sed \
      -e "s|{PROXY_SOCKS5}|$PROXY_SOCKS5|g" \
      -e "s|{PROXY_HTTP}|$PROXY_HTTP|g" \
      -e "s|{NO_PROXY_LIST}|$NO_PROXY_LIST|g" \
      -e "s|{WINDOWS_IP}|$WINDOWS_IP|g" \
      -e "s|{CLASH_PORT}|$CLASH_PORT|g" \
      -e "s|\\\$|\$|g")"

    # 7. 直接执行代理测试（脚本内已加载函数，可直接调用）
    echo "✅ 代理配置完成（$PROXY_SOCKS5）"
    proxy-test
  fi
else
  echo -e "\n⚠️  已跳过 WSL 代理配置"
fi

# 1. .bashrc 别名配置（--skipAlias 跳过）
if [ "$SKIP_ALIAS" = false ]; then
  echo -e "\n🔧 开始 .bashrc 别名配置..."
  # 备份原有 .bashrc（仅首次配置时备份）
  if ! grep -q "# -------------------------- 自定义别名配置 --------------------------" "$HOME/.bashrc"; then
    BACKUP_FILE="$HOME/.bashrc.bak.$(date +%Y%m%d%H%M%S)"
    cp "$HOME/.bashrc" "$BACKUP_FILE"
    echo "✅ 已备份原有 .bashrc 到：$BACKUP_FILE"
    # 自定义别名配置
    cat << EOF > "$HOME/.bashrc"

# -------------------------- 自定义别名配置 --------------------------
echo "welcome $USER"

alias gp="git push"
alias gll="git pull"
alias gl="git clone"
alias gc="git checkout"
alias glog="git log --graph --pretty=format:'%Cred%h%Creset -%C(yellow)%d%Creset %s %Cgreen(%cr) %C(bold blue)<%an>%Creset' --abbrev-commit -- | less"
alias gk="git cherry-pick"
alias ys="yarn dev | yarn serve"
alias code="cursor"
alias start="explorer.exe"
alias open="explorer.exe"
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

# 端口查看函数
port-show() {
  echo "✅ 正在查看端口转发"
  powershell.exe -Command 'Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command ""netsh interface portproxy show all; Read-Host '查看完成，按Enter关闭窗口'"""'
}
# ------------------------ 自定义别名配置结束 ------------------------

# ------------------------ Git 分支显示配置 ------------------------
# 检测当前 Git 分支的函数
parse_git_branch() {
  # 2>/dev/null 忽略非 Git 仓库的错误提示
  git branch 2>/dev/null | sed -e '/^[^*]/d' -e 's/* \(.*\)/ (\1)/'
}

# 配置终端提示符（PS1）：绿色用户名@主机名 + 蓝色目录 + 红色分支名 + $ 符号
# 颜色代码说明：\033[01;32m=绿色（加粗），\033[01;34m=蓝色（加粗），\033[01;31m=红色（加粗），\033[00m=恢复默认颜色
PS1='\[\033[01;32m\]\u@\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[01;31m\]$(parse_git_branch)\[\033[00m\]\$ '
# ------------------------ Git 分支显示配置结束 ------------------------
EOF
    echo "✅ 已更新 .bashrc 别名配置"
  else
    echo "✅ .bashrc 别名配置已存在，无需重复配置"
  fi
else
  echo -e "\n⚠️  已跳过 .bashrc 别名配置"
fi

# 2. fnm 安装（--skipFnm 跳过）
if [ "$SKIP_FNM" = false ]; then
  # 检测 fnm 是否已安装
  if command_exists "fnm"; then
    echo "✅ fnm 已安装（版本：$(fnm --version)），无需重复安装"
  else
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
    # 预处理 fnm 安装目录权限（解决 Permission denied 问题）
    FNM_INSTALL_DIR="/home/$USER/.local/share/fnm"
    mkdir -p "$FNM_INSTALL_DIR"
    chown -R "$USER:$USER" "$FNM_INSTALL_DIR"
    chmod -R 755 "$FNM_INSTALL_DIR"
    echo "✅ 已修复 fnm 安装目录权限：$FNM_INSTALL_DIR"
    # 安装 fnm（镜像优先）
    INSTALL_SUCCESS=false
    if curl -fvSL "$FNM_INSTALL_URL_OFFICIAL" | bash; then
      echo "✅ fnm 官方地址安装成功"
      INSTALL_SUCCESS=true
    elif curl -fvSL "$FNM_INSTALL_URL_MIRROR" | bash; then
      echo "✅ fnm 镜像地址安装成功"
      INSTALL_SUCCESS=true
    else
      echo "❌ fnm 安装失败！是否跳过？"
      confirm_continue "继续执行其他步骤"
    fi
  fi
  # 无论官方还是镜像安装成功，都配置环境变量（避免重复配置）
  if [ "$INSTALL_SUCCESS" = true ]; then
      if ! grep -q '# -------------------------- fnm 自动适配 --------------------------' "$HOME/.bashrc"; then
        cat << EOF >> "$HOME/.bashrc"

# -------------------------- fnm 自动适配 --------------------------
eval "\$(fnm env --use-on-cd --shell bash)"
# ------------------------ fnm 自动适配配置结束 ------------------------
EOF
        echo "✅ fnm 环境变量已配置"
      else
        echo "✅ fnm 环境变量已存在，无需重复配置"
      fi
  fi
  echo "✅ fnm 配置完成"
  source "$HOME/.bashrc"
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
  echo -e "\n🔧 开始 Node.js 安装..."

  # 检测 Node.js 是否已安装
  if command_exists "node"; then
    NODE_VERSION=$(node -v)
    NPM_VERSION=$(npm -v)
    echo "✅ Node.js 已安装（版本：$NODE_VERSION），无需重复安装"
    echo "  - Node：$NODE_VERSION"
    echo "  - npm：$NPM_VERSION"
  else
    # 获取适配的 Node.js 源地址
    NODE_SETUP_URL=$(get_node_setup_url)
    echo "✅ 将使用 Node.js 源地址：$NODE_SETUP_URL"

    # 安装新版 Node.js
    if curl -fsSL "$NODE_SETUP_URL" | sudo -E bash - && sudo apt-get install -y nodejs; then
      NODE_VERSION=$(node -v)
      NPM_VERSION=$(npm -v)
      echo "✅ Node.js 安装成功："
      echo "  - Node：$NODE_VERSION"
      echo "  - npm：$NPM_VERSION"
    else
      echo "❌ Node.js 安装失败！是否跳过？"
      confirm_continue "继续执行其他步骤"
    fi
  fi
else
  echo -e "\n⚠️  已跳过 Node.js 安装"
fi

# 4. 全局 npm 工具安装（--skipNpmTools 跳过）
if [ "$SKIP_NPM_TOOLS" = false ] && command_exists "npm"; then
  echo -e "\n🔧 开始全局 npm 工具安装..."

  # 修复 npm config 权限提示
  sudo chown -R "$USER:$(id -gn "$USER")" "$HOME/.config" 2>/dev/null || true
  # npm 全局安装权限不足，修改 npm 全局目录
  BACKUP_FILE="$HOME/.bashrc.bak.$(date +%Y%m%d%H%M%S)"
  cp "$HOME/.bashrc" "$BACKUP_FILE"
  echo "✅ 已备份原有 .bashrc 到：$BACKUP_FILE"
  if [ -f "$HOME/.npm-global" ]; then
    rm -f "$HOME/.npm-global"
    echo "⚠️ 已清理错误创建的 .npm-global 文件"
  fi
  mkdir -p "$HOME/.npm-global"
  npm config set prefix "$HOME/.npm-global"
  echo "✅ 已设置 npm 全局目录为：$HOME/.npm-global"
  # 加载刚写入的 .bashrc 配置，让 proxy-test/proxy-on/proxy-off 函数生效
  PATH_CONFIG="export PATH=\"$HOME/.npm-global/bin:\$PATH\""
  # 先检查是否已存在，避免重复添加
  if ! grep -qxF "$PATH_CONFIG" "$HOME/.bashrc"; then
    echo "$PATH_CONFIG" >> "$HOME/.bashrc"
    echo "✅ 已将 npm PATH 配置添加到 .bashrc"
  else
    echo "ℹ️ npm PATH 配置已存在，无需重复添加"
  fi
  eval "$PATH_CONFIG"
  echo "✅ 当前会话已通过 eval 立即生效 npm 全局 PATH"

  # 额外的 npm 配置
  sed -i -e '/save-prefix=/d' -e '/always-auth=/d' ~/.npmrc &> /dev/null
  echo 'always-auth=true' >> ~/.npmrc
  echo 'save-prefix=""' >> ~/.npmrc

  if npm install -g pnpm yarn yrm typescript git-open; then
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
  # 检测 codeup 镜像是否已存在
  if ! yrm ls | grep -q "codeup"; then
    yrm add codeup "$CODEUP_REGISTRY"
    echo "✅ 已添加 Codeup 镜像源"
  else
    echo "✅ Codeup 镜像源已存在，无需重复添加"
  fi

  # 切换到 codeup 镜像
  if yrm current | grep -q "codeup"; then
    echo "✅ 已使用 Codeup 镜像源"
  else
    if yrm use codeup; then
      echo "✅ yrm 切换到 Codeup 镜像：$(yrm current)"
    else
      echo "❌ yrm 配置失败！是否跳过？"
      confirm_continue "继续执行其他步骤"
    fi
  fi
elif [ "$SKIP_NPM_REGISTRY" = true ]; then
  echo -e "\n⚠️  已跳过 npm registry 镜像配置"
else
  echo -e "\n⚠️  未检测到 yrm，跳过镜像配置"
fi

# 6. npm 登录（--skipNpmLogin 跳过）
if [ "$SKIP_NPM_LOGIN" = false ] && command_exists "npm"; then
  echo -e "\n🔐 开始 npm 登录（Codeup 账号）..."

  # 检测文件是否存在
  if [ -f "$HOME/.npmrc" ]; then
    # 检测是否已登录

    if grep -qE "^//$(echo "$CODEUP_REGISTRY" | sed -e 's#^[a-zA-Z0-9]\+://##' -e 's#/npm-registry/.*$##' -e 's#\.#\\.#g' -e 's#/#\\/#g')/:_authToken=.+" "$HOME/.npmrc"; then
        echo "✅ npm 已配置 Codeup 镜像认证（无需重复登录）"
    else
      # 调用安全登录函数
      if safe_login "npm" "$CODEUP_REGISTRY"; then
        echo "✅ npm 登录成功"
      else
        echo "❌ npm 登录失败"
        confirm_continue "继续执行其他步骤"
      fi
    fi
  else
    # 文件不存在时，强制返回未匹配（退出码 1）
    echo ".npmrc 文件不存在"
  fi
elif [ "$SKIP_NPM_LOGIN" = true ]; then
  echo -e "\n⚠️  已跳过 npm 登录"
else
  echo -e "\n⚠️  未检测到 npm，跳过登录"
fi

# 7. yarn 登录（--skipYarnLogin 跳过）
if [ "$SKIP_YARN_LOGIN" = false ] && command_exists "yarn"; then
  echo -e "\n🔐 开始 yarn 登录（与 npm 账号一致）..."
  if [ -f "$HOME/.yarnrc" ]; then
    # 检测是否已登录
    if grep -qE '^[[:space:]]*email[[:space:]]+["'"'"'][^"'"'"']+["'"'"']' "$HOME/.yarnrc" && grep -qE '^[[:space:]]*username[[:space:]]+["'"'"'][^"'"'"']+["'"'"']' "$HOME/.yarnrc"; then
      echo "✅ yarn 已配置 Codeup 镜像认证（无需重复登录）"
    else
      # 调用安全登录函数
      if safe_login "yarn" "$CODEUP_REGISTRY"; then
        echo "✅ yarn 登录成功（复用 NPM 认证/手动登录）"
      else
        echo "❌ yarn 登录失败"
        confirm_continue "是否跳过 yarn 登录继续执行其他步骤？"
      fi
    fi
  else
    # 文件不存在时，强制返回未匹配（退出码 1）
    echo ".yarnrc 文件不存在"
  fi
elif [ "$SKIP_YARN_LOGIN" = true ]; then
  echo -e "\n⚠️  已跳过 yarn 登录"
else
  echo -e "\n⚠️  未检测到 yarn，跳过登录"
fi

# 8. gupo 工具安装（--skipGupoTools 跳过）
if [ "$SKIP_GUPO_TOOLS" = false ] && command_exists "npm"; then
  echo -e "\n🔧 开始 gupo 工具安装..."
  # 定义要安装的包列表
  declare -A packages=(
    ["gupo-deploy"]="gupo-deploy"
    ["gupo-cli"]="gupo-cli"
    ["@gupo-admin/cli"]="gupo-admin"
#    ["gupo-imagemin"]="gupo-imagemin"
  )

  # 记录安装成功的包数量
  success_count=0
  # 记录安装失败的包列表
  failed_packages=()

  # 遍历关联数组
  for pkg in "${!packages[@]}"; do
    cmd=${packages[$pkg]}  # 直接取命令名，无解析风险
    echo -e "\n📦 正在安装 $pkg（命令名：$cmd）..."
    # 实时输出安装日志 + 强制返回成功
    npm install -g "$pkg" --registry="$CODEUP_REGISTRY" --force 2>&1 | sed "s|^|[$pkg] |" || :

    # 检测命令是否安装成功
    if command_exists "$cmd"; then
      echo "✅ $pkg 安装完成"
      ((success_count++)) || :
    else
      echo "❌ $pkg 安装失败，自动跳过，继续安装下一个包"
      failed_packages+=("$pkg")
    fi
  done

  # 安装流程结束后，根据结果处理
  echo -e "\n📊 安装结果汇总："
  echo "✅ 成功安装：$success_count 个包"
  echo "❌ 失败跳过：${#failed_packages[@]} 个包（${failed_packages[*]:-无}）"

  # 仅当所有包都安装失败时，提示是否继续执行其他步骤
  if [ $success_count -eq 0 ]; then
    echo -e "\n❌ 所有 gupo 工具均安装失败！"
    confirm_continue "继续执行其他步骤"
  else
    echo -e "\n🎉 gupo 工具安装流程完成（部分包已跳过）"
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
  else
    echo "✅ Git 已安装（版本：$(git --version | cut -d ' ' -f 3)）"
  fi

  # 检测 Git 用户信息是否已配置
  if git config --global --get user.name &> /dev/null && git config --global --get user.email &> /dev/null; then
    echo "✅ Git 用户信息已配置："
    echo "  - 用户名：$(git config --global --get user.name)"
    echo "  - 邮箱：$(git config --global --get user.email)"
  else
    # 配置用户信息
    read -r -p "请输入 Git 用户名（中文名字）：" GIT_USER_NAME < /dev/tty
    while [ -z "$GIT_USER_NAME" ]; do
      echo "❌ 用户名不能为空！"
      read -r -p "重新输入：" GIT_USER_NAME < /dev/tty
    done

    read -r -p "请输入 Git 邮箱（与云效一致或者你常用的）：" GIT_USER_EMAIL < /dev/tty
    while [ -z "$GIT_USER_EMAIL" ] || ! echo "$GIT_USER_EMAIL" | grep -E '@'; do
      echo "❌ 邮箱格式不合法！"
      read -r -p "重新输入：" GIT_USER_EMAIL < /dev/tty
    done

    # 应用 Git 配置
    git config --global core.autocrlf input
    git config --global user.name "$GIT_USER_NAME"
    git config --global user.email "$GIT_USER_EMAIL"
    git config --global core.quotepath false
    git config --global core.ignorecase false

    echo "✅ Git 配置完成"
    git config --global --list | grep -E 'user.name|user.email|core.autocrlf'
  fi
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

# 11. 添加 install_info 命令到 .bashrc
if ! grep -q "# -------------------------- 安装信息查看命令 --------------------------" "$HOME/.bashrc"; then
  echo -e "\n🔧 添加 install_info 命令到 .bashrc..."
  BACKUP_FILE="$HOME/.bashrc.bak.$(date +%Y%m%d%H%M%S)"
    cp "$HOME/.bashrc" "$BACKUP_FILE"
    echo "✅ 已备份原有 .bashrc 到：$BACKUP_FILE"

    # 使用 base64 编码所有配置变量（避免转义问题）
    ESCAPED_GENERATE_FUNC=$(echo "$GENERATE_SUMMARY_FUNC" | base64)
    ESCAPED_SUMMARY_TEMPLATE=$(echo "$SUMMARY_TEMPLATE" | base64)
    ESCAPED_ALIAS_CONFIG=$(echo "$ALIAS_CONFIG" | base64)
    ESCAPED_TOOLS_CONFIG=$(echo "$TOOLS_CONFIG" | base64)
    ESCAPED_COMMANDS_CONFIG=$(echo "$COMMANDS_CONFIG" | base64)
    ESCAPED_CODEUP_REGISTRY=$(printf '%q' "$CODEUP_REGISTRY")

    cat << INSTALL_INFO_FUNCTION_EOF >> "$HOME/.bashrc"
# -------------------------- 安装信息查看命令 --------------------------
install_info() {
  # 复用脚本中的验证函数
    verify_tool_for_install_info() {
      local tool=\$1
      if ! command -v "\$tool" &> /dev/null; then
        echo "  ❌ \$tool：未安装"
        return 0
      fi

      local version_params=("--version" "-v" "version" "--info" "-V")
      local version_output=""
      local final_version="unknown"

      for param in "\${version_params[@]}"; do
        version_output=\$("\$tool" "\$param" 2>/dev/null | head -n 1 || true)
        if [ -n "\$version_output" ]; then
          final_version=\$(echo "\$version_output" | grep -Eo '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n 1 || true)
          [ -z "\$final_version" ] && final_version="unknown"
          break
        fi
      done

      echo "  ✅ \$tool：\$final_version"
      return 0
    }
    # SSH 信息函数
    get_ssh_key_info() {
      if [ -f \$HOME/.ssh/id_ed25519.pub ]; then
        echo "ed25519类型（\$HOME/.ssh/id_ed25519.pub）"
      elif [ -f \$HOME/.ssh/id_rsa.pub ]; then
        echo "rsa类型（\$HOME/.ssh/id_rsa.pub）"
      else
        echo "未生成"
      fi
    }

    # ======================== 集中配置定义（与脚本一致）========================
    local CODEUP_REGISTRY="${ESCAPED_CODEUP_REGISTRY}"
    local ALIAS_CONFIG=\$(echo '${ESCAPED_ALIAS_CONFIG}' | base64 -d)
    local TOOLS_CONFIG=\$(echo '${ESCAPED_TOOLS_CONFIG}' | base64 -d)
    local COMMANDS_CONFIG=\$(echo '${ESCAPED_COMMANDS_CONFIG}' | base64 -d)
    local SUMMARY_TEMPLATE=\$(echo '${ESCAPED_SUMMARY_TEMPLATE}' | base64 -d)

    # 关键：eval 还原 generate_summary 函数（只维护一份定义）
    eval "\$(echo '${ESCAPED_GENERATE_FUNC}' | base64 -d)"

    # 解析别名配置
    parse_alias_for_install_info() {
      while IFS=':' read -r key value; do
        [[ -z "\$key" || "\$key" =~ ^# ]] && continue
        echo "  - \$key：\$value"
      done <<< "\$ALIAS_CONFIG"
    }

    # 解析命令配置
    parse_commands_for_install_info() {
      while IFS= read -r cmd; do
        [[ -z "\$cmd" || "\$cmd" =~ ^# ]] && continue
        echo "  - \$cmd"
      done <<< "\$COMMANDS_CONFIG"
    }

    echo -e "\n========================================================================"
    echo "📋 工具安装验证结果："

    # 遍历工具清单验证
    while IFS= read -r tool; do
      [[ -z "\$tool" ]] && continue
      verify_tool_for_install_info "\$tool"
    done <<< "\$TOOLS_CONFIG"

    echo -e "\n📋 自定义别名清单："
    parse_alias_for_install_info

    echo -e "\n⚙️ 常用命令说明："
    parse_commands_for_install_info

    echo -e "\n🎉 所有配置已生效！"
    echo -e "\n\$(generate_summary)"
}
# ------------------------ 安装信息查看命令结束 ------------------------
INSTALL_INFO_FUNCTION_EOF
  echo "✅ install_info 命令已添加到 .bashrc"
else
  echo "✅ install_info 命令已存在，无需重复添加"
fi

# ======================== 收尾验证（汇总结果）========================
# 调用统一的 show_install_info 函数显示安装信息
show_install_info

# 输出最后提示
echo -e "\n💡 提示：你可以随时使用 'install_info' 命令查看安装状态和配置信息"
echo "🔧 重启终端或执行 'source ~/.bashrc' 即可使用所有配置～"
echo "========================================================================"
