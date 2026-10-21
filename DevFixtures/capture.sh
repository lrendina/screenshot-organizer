#!/bin/zsh
# Captures real simulator screenshots of pages and adds them to the booted sim's Photos.
out=${0:A:h}/shots
urls=(
  chat=http://127.0.0.1:3000/chat.html
  receipt=http://127.0.0.1:3000/receipt.html
  boarding=http://127.0.0.1:3000/boarding.html
  terminal=http://127.0.0.1:3000/terminal.html
  meme=http://127.0.0.1:3000/meme.html
  wiki=https://en.m.wikipedia.org/wiki/Pomodoro_Technique
  recipe=https://www.bbcgoodfood.com/recipes/easy-pancakes
  map=https://www.openstreetmap.org/#map=15/40.7359/-73.9911
  shop=https://www.apple.com/shop/product/MX542AM/A/airpods-pro-3
  code=https://github.com/apple/swift-algorithms/blob/main/Sources/Algorithms/Chunked.swift
)
for pair in $urls; do
  name=${pair%%=*}; url=${pair#*=}
  xcrun simctl openurl booted "$url"
  sleep 7
  xcrun simctl io booted screenshot --type=png "$out/$name.png" >/dev/null 2>&1
  echo "captured $name"
done
xcrun simctl addmedia booted $out/*.png && echo "added to Photos"
