# Futu OpenD Docker（Ubuntu 24.04）

这是一个尽量精简的 Futu OpenD Docker 镜像。

镜像：

~~~text
ghcr.io/lqepoch/futu_api_docker:latest
ghcr.io/lqepoch/futu_api_docker:<OpenD版本>
~~~

核心原则：

- Docker 只负责安装并运行官方 Futu OpenD。
- 账号、登录密码、验证码全部走 OpenD 自己的登录流程。
- 不在环境变量里保存富途登录密码。
- 默认不自动代输验证码；手机验证码可在同一终端输入后由容器转发给 OpenD。
- 可选通过安全 OTP 文件启用一次性自动提交：设置 `FUTU_LOGIN_OTP_FILE`，文件必须由容器内
  `futu` 用户（UID 10001）所有、owner 可读且 group/other 无权限（建议使用 `0400` 或 `0600`）、是非符号链接的普通文件，且所在
  目录允许 unlink。容器读取后立即删除；任一校验、读取或删除失败都会 fail closed。验证码绝不
  写入日志、环境变量或镜像。未设置该变量时仍由用户手动输入。
- 可在宿主机使用 `expect scripts/futu-opend-auto-attach.expect futu-opend` 自动 attach；helper
  等待固定 `FUTU_LOGIN_READY_MARKER` 后发送 Ctrl-P/Ctrl-Q，只结束 attach，不停止容器或 OpenD。
  未看到 marker 的已有 healthy 容器不会触发 detach。
- 不维护自定义验证码状态机。
- OpenD 设备状态持久化到 Docker Volume。
- 跨机器 WebSocket 默认启用 WSS/SSL。
- 远程 API 所需的 RSA 私钥自动生成并持久化。
- GitHub Actions 每天检查官方 OpenD 新版本并自动重新构建镜像。

## 1. 拉取镜像

~~~bash
docker pull ghcr.io/lqepoch/futu_api_docker:latest
~~~

创建持久化 Volume：

~~~bash
docker volume create futu-opend-data
~~~

## 2. 首次启动

~~~bash
docker run -it \
  --name futu-opend \
  --restart unless-stopped \
  -p 127.0.0.1:11111:11111 \
  -p 33333:33333 \
  -v futu-opend-data:/home/futu/.com.futunn.FutuOpenD \
  ghcr.io/lqepoch/futu_api_docker:latest
~~~

启动后先显示容器登录提示，然后进入 Futu OpenD 原生交互流程：

~~~text
[futu-docker] 登录提示：请输入富途账号、手机号或邮箱（手机号默认 +86）。
~~~

按照屏幕提示输入：

1. 富途账号 / 手机号 / 邮箱
2. 登录密码
3. 是否记住密码
4. 如触发设备锁验证，在同一个终端直接输入手机验证码

Docker 不会在 OpenD 之前重复读取账号；上面的命令只进入一次 Futu OpenD 原生交互流程。
手机号默认按中国区号 `+86` 组合，因此在 OpenD 的账号提示处可以直接输入手机号。
如果通过 `FUTU_LOGIN_ACCOUNT` 提供非敏感账号，支持 `13800138000`、`+86 13800138000`
等手机号形式；邮箱若误带 `+86` 前缀会自动去掉，普通邮箱和富途 ID 不会加区号。
密码仍由 OpenD 原生交互流程接收。默认情况下，容器会在 OpenD 输出手机验证码提示后，
在同一个终端读取验证码并立即转发到容器内部的 OpenD Telnet 端口；验证码不写入镜像、
Volume、环境变量或日志。若需要关闭同终端转发，可设置：

~~~bash
-e FUTU_LOGIN_DIRECT_OTP=false
~~~

登录成功后，不要用 Ctrl+C 退出。

使用：

~~~text
Ctrl+P
Ctrl+Q
~~~

即可从容器终端 detach，OpenD 会继续在后台运行。

### 宿主机自动 attach/detach

需要自动等待登录完成时，在宿主机安装 `expect` 和 Docker CLI，然后执行：

~~~bash
expect scripts/futu-opend-auto-attach.expect futu-opend
~~~

这个宿主机 helper 只执行 `docker attach`，等待容器输出固定的
`FUTU_LOGIN_READY_MARKER`，再向 attach 会话发送精确的 Ctrl-P/Ctrl-Q。它只结束当前
attach，不会停止或重启容器，也不会停止 OpenD。未看到 marker 时（包括一个已经显示
`healthy` 但尚未输出 marker 的容器）不会发送 detach；等待超时返回退出码 `124`。

可通过 `FUTU_LOGIN_AUTO_ATTACH_TIMEOUT` 设置等待秒数，必须是正整数，默认 `300`；参数错误
返回 `64`。helper 运行在宿主机，不需要也不应该把 Docker socket 挂载到容器内。安全示例：

~~~bash
FUTU_LOGIN_AUTO_ATTACH_TIMEOUT=300 \
  expect scripts/futu-opend-auto-attach.expect futu-opend
~~~

手动使用 `docker attach futu-opend` 时仍然按 Ctrl-P、Ctrl-Q detach；Ctrl+C 不用于 detach。

以后重新进入 OpenD 控制台：

~~~bash
docker attach futu-opend
~~~

如果容器是用 `-d -it` 后台启动，桥接层会等待第一次 `docker attach`，然后在当前终端显示
上面的登录提示并启动 OpenD 原生流程；这样启动期间的提示不会丢失。attach 后桥接层会同步
终端尺寸到 OpenD，不会把账号或密码当成空输入。登录后使用 Ctrl-P、Ctrl-Q 可以让容器继续
在后台运行。

查看日志：

~~~bash
docker logs -f futu-opend
~~~

容器 `healthy` 同时要求 API `11111` 和 WSS `33333` 在容器内监听；这比只检查 API
端口更能避免“端口已开但登录/WSS 尚未就绪”的假健康状态。OpenD 返回的账号、密码、
手机验证码、设备锁和网络错误仍以原生提示为准，Docker 只保留非敏感的启动失败状态。

## 3. 手机验证码

默认启动命令不需要额外打开命令行。OpenD 请求验证码后，同一个终端会显示：

~~~text
[futu-docker] 请输入手机验证码:
~~~

直接输入短信验证码并回车即可。容器内部仍然使用官方运维命令
`input_phone_verify_code -code=验证码` 转发，不改变 OpenD 的认证协议。

### 可选 OTP file 自动提交

默认仍然手动输入验证码。只有显式设置 `FUTU_LOGIN_OTP_FILE` 时，容器才会读取一次性验证码
文件。文件必须满足全部条件：

- 容器内所有者是 `futu` 用户 UID `10001`；
- owner 必须可读，且 group/other 不得有权限（建议使用 `0400` 或 `0600`）；
- 是非 symlink 的 regular file；
- 所在目录允许容器用户 unlink 文件。

容器读取后立即删除文件；校验、读取或删除任一失败都会 fail closed，不提交验证码，也不会
输出验证码。验证码绝不写入日志、环境变量或镜像。推荐把宿主机目录以可写 bind mount 挂入，
而不是把单个文件以只读方式挂载（只读挂载通常无法完成读取后的 unlink）：

~~~bash
otp_dir="$(mktemp -d)"
read -r -s -p 'OTP: ' otp
printf '\n'
printf '%s\n' "$otp" > "$otp_dir/code"
unset otp
sudo chown 10001:10001 "$otp_dir" "$otp_dir/code"
sudo chmod 0700 "$otp_dir"
sudo chmod 0400 "$otp_dir/code"

docker run -it \
  --name futu-opend \
  --restart unless-stopped \
  -p 127.0.0.1:11111:11111 \
  -p 33333:33333 \
  -v futu-opend-data:/home/futu/.com.futunn.FutuOpenD \
  --mount "type=bind,src=$otp_dir,dst=/run/futu-otp,rw" \
  -e FUTU_LOGIN_OTP_FILE=/run/futu-otp/code \
  ghcr.io/lqepoch/futu_api_docker:latest
~~~

bind mount 的宿主机目录也必须允许 UID 10001 删除文件；不要把 Docker socket 挂进容器，也不要
把验证码放进 `-e`、镜像层、Volume 或日志。若目录权限或 owner 不匹配，登录会安全失败并保留
必要的非敏感失败提示。

就绪标记不是单次端口探测：`FUTU_LOGIN_READY_MARKER` 固定不变，只有 API 和 WSS 都可用并
连续通过 3 次检查后才输出。`FUTU_LOGIN_READY_TIMEOUT` 默认 `60` 秒，`FUTU_LOGIN_READY_HOST`
默认 `127.0.0.1`；两个端口默认分别为 API `11111`、WSS `33333`。超时会停止该登录流程，
不会输出 marker。

如果关闭了 `FUTU_LOGIN_DIRECT_OTP`，再使用旧的 Telnet 方式：

~~~bash
docker exec -it futu-opend nc 127.0.0.1 22222
~~~

请求验证码和提交验证码是两个独立动作，不做自动延时提交。

Futu 官方限制手机验证码请求频率为每 60 秒最多 1 次。

## 4. 跨机器 WebSocket / WSS

默认配置：

~~~text
WebSocket 监听地址：0.0.0.0
WebSocket 端口：33333
SSL：开启
WebSocket 鉴权：开启
~~~

Futu OpenD 在 WebSocket 监听非本地地址时需要 SSL。

容器首次启动会自动创建并持久化：

~~~text
/home/futu/.com.futunn.FutuOpenD/docker-security/wss/server.crt
/home/futu/.com.futunn.FutuOpenD/docker-security/wss/server.key
/home/futu/.com.futunn.FutuOpenD/docker-security/wss/auth.key
~~~

其中：

- server.crt：WSS 证书
- server.key：无密码私钥
- auth.key：WebSocket 原始鉴权密钥
- OpenD 配置文件里写入的是 auth.key 的 32 位 MD5

查看 WebSocket 鉴权密钥：

~~~bash
docker exec futu-opend \
  cat /home/futu/.com.futunn.FutuOpenD/docker-security/wss/auth.key
~~~

### 默认自签证书

没有提供外部证书时，容器自动生成自签证书。

这足以让 OpenD 的跨机器 WebSocket 以 WSS 模式启动。

如果远程客户端严格校验证书主机名，需要让证书 SAN 包含实际服务器域名或 IP。

首次创建一个全新的 Volume 时，可以指定：

~~~bash
docker run -it \
  --name futu-opend \
  --restart unless-stopped \
  -p 127.0.0.1:11111:11111 \
  -p 33333:33333 \
  -e FUTU_WEBSOCKET_TLS_CN=opend.example.com \
  -e FUTU_WEBSOCKET_TLS_SAN=DNS:opend.example.com \
  -v futu-opend-data:/home/futu/.com.futunn.FutuOpenD \
  ghcr.io/lqepoch/futu_api_docker:latest
~~~

如果使用服务器 IP：

~~~bash
-e FUTU_WEBSOCKET_TLS_CN=203.0.113.10 \
-e FUTU_WEBSOCKET_TLS_SAN=IP:203.0.113.10
~~~

### 使用正式证书

互联网环境、浏览器或需要完整证书校验的客户端，可以直接挂载已有证书：

~~~bash
docker run -it \
  --name futu-opend \
  --restart unless-stopped \
  -p 127.0.0.1:11111:11111 \
  -p 33333:33333 \
  -v futu-opend-data:/home/futu/.com.futunn.FutuOpenD \
  -v /path/server.crt:/run/futu/server.crt:ro \
  -v /path/server.key:/run/futu/server.key:ro \
  -e FUTU_WEBSOCKET_CERT_FILE=/run/futu/server.crt \
  -e FUTU_WEBSOCKET_PRIVATE_KEY_FILE=/run/futu/server.key \
  -e FUTU_WEBSOCKET_AUTH_KEY='你的WebSocket鉴权密钥' \
  ghcr.io/lqepoch/futu_api_docker:latest
~~~

证书和私钥必须同时配置，私钥不能设置密码。

## 5. API TCP 与 RSA 加密

OpenD API 默认监听容器端口：

~~~text
11111
~~~

示例命令仅把它映射到宿主机：

~~~text
127.0.0.1:11111
~~~

适合自动交易机器人和 OpenD 在同一台服务器的部署方式。

容器首次启动还会生成持久化的 PKCS#1 1024-bit RSA 私钥：

~~~text
/home/futu/.com.futunn.FutuOpenD/docker-security/api-rsa.pem
~~~

远程机器连接 OpenD 并使用交易接口时，需要按 Futu API 的协议加密规则配置同一份私钥。

导出：

~~~bash
docker cp \
  futu-opend:/home/futu/.com.futunn.FutuOpenD/docker-security/api-rsa.pem \
  ./futu-api-rsa.pem

chmod 600 ./futu-api-rsa.pem
~~~

如果确实需要让另一台机器直连 TCP 11111，可以把端口映射改成：

~~~bash
-p 11111:11111
~~~

同时用云安全组或防火墙只允许指定策略服务器访问。

## 6. 持久化

Docker Volume：

~~~text
futu-opend-data
~~~

挂载位置：

~~~text
/home/futu/.com.futunn.FutuOpenD
~~~

这里会保存：

- Futu OpenD 设备身份
- Device.dat
- 登录状态
- WSS 证书和私钥
- WebSocket 鉴权密钥
- API RSA 私钥

同一个 Volume 不要同时复制给多台正在运行的 OpenD 使用，否则可能触发设备锁重复验证。

## 7. 端口

| 服务 | 容器端口 | 默认宿主机暴露方式 |
| --- | ---: | --- |
| Futu API TCP | 11111 | 127.0.0.1:11111 |
| WebSocket / WSS | 33333 | 0.0.0.0:33333 |
| OpenD 运维端口 | 22222 | 仅容器内部 |

22222 默认不发布到公网。

## 8. 升级

拉取最新版：

~~~bash
docker pull ghcr.io/lqepoch/futu_api_docker:latest
~~~

删除旧容器：

~~~bash
docker stop futu-opend
docker rm futu-opend
~~~

然后重新执行上面的 docker run 命令，并继续挂载：

~~~text
futu-opend-data
~~~

登录状态、设备状态、WSS 和 RSA 文件都会保留。

## 9. GitHub Actions 自动更新

工作流：

~~~text
.github/workflows/docker-publish.yml
~~~

每天自动：

1. 获取 Futu 官方最新 Ubuntu OpenD 安装包。
2. 解析真实 OpenD 版本号。
3. 计算官方包 SHA-256。
4. 与仓库 VERSION 和 UPSTREAM_SHA256 对比。
5. 官方版本或文件发生变化时重新构建 Ubuntu 24.04 镜像。
6. 发布：
   - ghcr.io/lqepoch/futu_api_docker:latest
   - ghcr.io/lqepoch/futu_api_docker:<OpenD版本>
7. 生成 SBOM、provenance 和 attestation。
8. 注销 GHCR 登录后重新匿名 pull，验证镜像确实可以公开拉取。
9. 发布成功后更新 VERSION 和 UPSTREAM_SHA256。

部署服务器只需要 pull 和 run，不需要 clone 仓库，也不需要自己 build。

## 10. 官方文档

Futu OpenD 命令行配置：

https://openapi.futunn.com/futu-api-doc/opend/opend-cmd.html

OpenD 运维命令：

https://openapi.futunn.com/futu-api-doc/opend/opend-operate.html

OpenD 常见问题：

https://openapi.futunn.com/futu-api-doc/qa/opend.html

API 协议加密：

https://openapi.futunn.com/futu-api-doc/ftapi/protocol.html
