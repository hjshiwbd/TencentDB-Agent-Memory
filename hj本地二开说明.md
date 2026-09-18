# 新版
```shell
# 正常重启, 停止
./stop-all.sh

#启动
./start-all.sh
#或者
PULL=1; ./start-all.sh

#把要改的拿出来
docker cp tdai-proxy:/app/src/session/session-key.ts /data/session-key.ts

#修改
vim /data/session-key.ts

#覆盖回去
docker cp /data/session-key.ts tdai-proxy:/app/src/session/session-key.ts

#重启
docker restart tdai-proxy

```

# 二开说明(老版,暂不用了)
- 本地agent=mavis, 项目不支持
- 改代码, memoryproxy里的session-key.ts里加了一行`c.req.header("x-mavis-session-id")??`
- 运行前, 先手动关闭pm2 stop 0
- 正式运行, deploy/global-images/start-all.sh启动所有, 然后手动docker stop memory-proxy, 关闭此应用: docker stop $(docker ps -a|grep "memory\-proxy"|awk '{print $1}')
- 手动pm2 start 0, 恢复启动本地改过代码的应用

- 改了.env, 只重启proxy:
```bash
cd /data/git/TencentDB-Agent-Memory/deploy/global-images
PROXY_FULL_STACK=1 ./start-proxy.sh    # 重新生成 config
docker stop tdai-proxy || true         # 不需要 — docker proxy 根本没在跑
pm2 restart tdai-proxy
```

