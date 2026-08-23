set -euo pipefail

wallpaper_directory="$HOME/Pictures/paper"

until awww query >/dev/null 2>&1; do
  sleep 1
done

while true; do
  wallpaper="$(find "$wallpaper_directory" -type f -print | shuf -n 1)"
  awww img "$wallpaper" \
    --resize crop \
    --transition-type fade \
    --transition-duration 1.2 \
    --transition-fps 60
  sleep 300
done
