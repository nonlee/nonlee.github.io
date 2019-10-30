
time=$(date "+%Y-%m-%d %H:%M:%S")
cd ~/hexo/data/nonlee.github.io 
git add ~/hexo/data/nonlee.github.io/ 
git commit -m "${time}"
git push origin hexo
hexo clean 
hexo g
hexo d
cd -
