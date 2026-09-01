# 二开说明
- 本地agent=mavis, 项目不支持
- 改代码, memoryproxy里的session-key.ts里加了一行`c.req.header("x-mavis-session-id")??`
- 运行前, 先手动关闭pm2 stop 0
- 正式运行, deploy/global-images/start-all.sh启动所有, 然后手动docker stop memory-proxy, 关闭此应用
- 手动pm2 start 0, 恢复启动本地改过代码的应用
