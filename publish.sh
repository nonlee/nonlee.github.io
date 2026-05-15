
time=$(date "+%Y-%m-%d %H:%M:%S")
cd  /home/ljx/nonlee/nonlee.github.io 
git add /home/ljx/nonlee/nonlee.github.io 
git commit -m "${time}"
git push origin hexo
hexo clean 
hexo g
hexo d
cd -
