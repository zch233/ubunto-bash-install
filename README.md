ubunto install
===

你的第一个 WSL 开发环境。

## Installation

### Using a script

For `bash`, `zsh` and `fish` shells, there's an [automatic installation script](./install.sh).

```sh
curl -fsSL https://raw.githubusercontent.com/zch233/ubunto-bash-install/refs/heads/master/install.sh | bash -

```

or mirror

```sh
curl -fsSL https://cdn.jsdelivr.net/gh/zch233/ubunto-bash-install@master/install.sh | bash -
```

#### Parameters

`--skipAlias`

Skip appending shell specific loader to shell config file, based on the current user shell, defined in `$SHELL`. e.g. for Bash, `$HOME/.bashrc`. `$HOME/.zshrc` for Zsh. For Fish - `$HOME/.config/fish/conf.d/fnm.fish`

`--skipFnm`

Skip Fnm install.

`--skipAptUpdate`

Skip apt update.

`--skipNode`

Skip node install.

`--skipNpmTools`

Skip npm tools(pnpm/yarn/nrm/typescript/git-open) install.

`--skipNpmRegistry`

Skip npm registry(code up) set.

`--skipNpmLogin`

Skip npm registry login.

`--skipYarnLogin`

Skip yarn registry login.

`--skipGupoTools`

Skip gupo tools(gupo-deploy/gupo-cli/@gupo-admin) install.

`--skipGitConfig`

Skip git install and config.

`--skipSshKey`

Skip ssh key(ed25519) generate.

`--skipProxy`

Skip proxy set/get.

Example:

```sh
curl -fsSL https://cdn.jsdelivr.net/gh/zch233/ubunto-bash-install@master/install.sh | bash -s -- --skipNpmRegistry --skipNpmLogin --skipYarnLogin --skipGupoTools
```

## More info --help

run in shell, you can see more info & alias

```sh
install_info
```

## Contributing

PRs welcome :tada: