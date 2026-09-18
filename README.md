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
- 不使用 expect 自动代输账号密码。
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

启动后直接进入 Futu OpenD 原生交互流程。

按照屏幕提示输入：

1. 富途账号 / 手机号 / 邮箱
2. 登录密码
3. 是否记住密码
4. 如触发设备锁验证，再完成手机验证码验证

启动时 Docker 会先读取一次非敏感的账号标识；手机号默认按中国区号 `+86` 组合，因此交互登录时可以只输入手机号。
如果通过 `FUTU_LOGIN_ACCOUNT` 预填非敏感账号，支持 `13800138000`、`+86 13800138000`
等手机号形式；邮箱若误带 `+86` 前缀会自动去掉，普通邮箱和富途 ID 不会加区号。
密码和验证码仍由 OpenD 原生交互流程接收，不写入镜像、Volume、命令日志或环境文件。

登录成功后，不要用 Ctrl+C 退出。

使用：

~~~text
Ctrl+P
Ctrl+Q
~~~

即可从容器终端 detach，OpenD 会继续在后台运行。

以后重新进入 OpenD 控制台：

~~~bash
docker attach futu-opend
~~~

查看日志：

~~~bash
docker logs -f futu-opend
~~~

容器 `healthy` 同时要求 API `11111` 和 WSS `33333` 在容器内监听；这比只检查 API
端口更能避免“端口已开但登录/WSS 尚未就绪”的假健康状态。OpenD 返回的账号、密码、
手机验证码、设备锁和网络错误仍以原生提示为准，Docker 只保留非敏感的启动失败状态。

## 3. 手机验证码

Futu 官方的手机验证码验证通过 OpenD 运维命令完成。

如果首次登录提示需要手机验证码，在另一个终端执行：

~~~bash
docker exec -it futu-opend nc 127.0.0.1 22222
~~~

请求验证码：

~~~text
req_phone_verify_code
~~~

等短信真正收到以后，再输入：

~~~text
input_phone_verify_code -code=123456
~~~

把 123456 换成实际收到的验证码。

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
