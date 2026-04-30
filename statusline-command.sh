#!/bin/sh
input=$(cat)
model=$(echo "$input" | jq -r '.model.display_name // "Claude"')
used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')

if [ -n "$used" ]; then
  used_int=$(printf "%.0f" "$used")
  bar_filled=$(( used_int / 5 ))
  bar_empty=$(( 20 - bar_filled ))
  bar=""
  i=0
  while [ $i -lt $bar_filled ]; do
    bar="${bar}█"
    i=$(( i + 1 ))
  done
  i=0
  while [ $i -lt $bar_empty ]; do
    bar="${bar}░"
    i=$(( i + 1 ))
  done
  if [ "$used_int" -ge 80 ]; then
    printf "\033[31m%s\033[0m  [%s] %d%%" "$model" "$bar" "$used_int"
  elif [ "$used_int" -ge 50 ]; then
    printf "\033[33m%s\033[0m  [%s] %d%%" "$model" "$bar" "$used_int"
  else
    printf "\033[32m%s\033[0m  [%s] %d%%" "$model" "$bar" "$used_int"
  fi
else
  printf "\033[32m%s\033[0m  [░░░░░░░░░░░░░░░░░░░░] -" "$model"
fi

