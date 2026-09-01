//此文件用于pm2启动.手动指定interceptor=node22, 此项目需要22版本
module.exports = {
  apps: [{
    name: 'tdai-proxy',
    script: 'src/index.ts',
    interpreter: '/root/.nvm/versions/node/v22.23.2/bin/node',
    node_args: '--import tsx/esm',
    args: '--config ./config.yaml',
    cwd: '/data/git/TencentDB-Agent-Memory/MemoryProxy',
    autorestart: true,
    max_restarts: 10,
    max_memory_restart: '1G',
    log_date_format: 'YYYY-MM-DD HH:mm:ss Z',
    env: { NODE_ENV: 'production' },
    out_file: '/root/.pm2/logs/tdai-proxy-out.log',
    error_file: '/root/.pm2/logs/tdai-proxy-error.log'
  }]
};
