module.exports = {
  apps: [{
    name: 'tdai-proxy',
    script: 'src/index.ts',
    interpreter: 'tsx',
    interpreter_args: '--import tsx/esm',
    args: '--config ./config.yaml',
    cwd: '/data/git/TencentDB-Agent-Memory/MemoryProxy',
    autorestart: true,
    max_restarts: 10,
    max_memory_restart: '1G',
    log_date_format: 'YYYY-MM-DD HH:mm:ss Z',
    env: { NODE_ENV: 'production' },
 out_file: '/tmp/pm2-tdai-proxy.out.log',
    error_file: '/tmp/pm2-tdai-proxy.err.log'
  }]
};