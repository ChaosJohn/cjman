# cjman
A SDK Manager for Cangjie Language. [Cangjie](https://cangjie-lang.cn)

Inspired by:
- Node Version Manager [nvm-sh/nvm](https://github.com/nvm-sh/nvm)
- Go Version Manager [moovweb/gvm](https://github.com/moovweb/gvm)
- Simple Python Version Management [pyenv/pyenv](https://github.com/pyenv/pyenv)
- The Software Development Kit Manager [sdkman/sdkman-cli](https://github.com/sdkman/sdkman-cli)
- ...

# Features
- Support multiple platforms:
  - Linux: **amd64** / **arm64**
  - macOS: **Intel** / **Apple Silicon**
- SDK downloaded from official website

# Installing
To install:
```bash
bash < <(curl -s -S -L https://raw.githubusercontent.com/ChaosJohn/cjman/master/cjman-installer)
```
> If you encounter network problem when accessing Github, switch to Gitcode instead. 
> ```bash
> export GIT_PROVIDER=gitcode.com;
> bash < <(curl -s -S -L https://raw.gitcode.com/ChaosJohn/cjman/raw/master/cjman-installer)
> ```

# Usage
```bash
$ cjman
Usage: cjman [command]

Description: 
  A SDK Manager for Cangjie Language

Commands:
  list    - list all remote versions (prints ✔ if installed)
  install - install specified version, e.g., `cjman install 1.0.0`
  use     - activate specified version, e.g., `cjman use 1.0.0`
```