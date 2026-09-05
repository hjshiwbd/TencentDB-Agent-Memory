# === 1. 配 upstream(只一次;已配会报已存在,跳过) ===
git remote add upstream https://github.com/Tencent/TencentDB-Agent-Memory.git
git remote -v   # 确认:应看到 origin + upstream 两行

# === 2. 拉 upstream ===
git fetch upstream
# 当前分支拉到最新
git pull

# === 3. 看 upstream 都有什么分支(决定 merge 哪个) ===
git branch -r | grep '^  upstream/'

# === 4. 切到你的 mavis 分支(已在上面就跳过) ===
git checkout minimax-mavis-support

# === 5. 预览 merge(只看不写) ===
git merge --no-commit --no-ff upstream/feat/server_team
git status
# 看完:不想继续 → git merge --abort

# === 6. 真正 merge(写历史) ===
git merge --no-ff upstream/feat/server_team

# === 7. 有冲突时 ===
# 1) 打开冲突文件,搜 <<<<<<< 标记
# 2) 解决后:
git add <已解决的文件>
git commit
# 放弃回到 5 之前:git merge --abort

# === 8. 验证 + 推 ===
git log --oneline --graph -10
git push origin minimax-mavis-support