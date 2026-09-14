#!/usr/bin/env bash
# Build the Ahnengalerie image ON a ZimaOS host from a local production build.
#
#   npm run build                                   # produces dist/
#   deploy/zimaos/build-on-host.sh <ssh-user>@<host> [tag]
#
# What it does, in order:
#   1. rsync dist/ + Dockerfile to <host>:/DATA/AppData/ahnengalerie/src/
#      (additive — no --delete; see the maintainer's rule on delete flags)
#   2. docker build -t ahnengalerie:<tag> there (default tag: local)
#   3. pre-create the bind-mount directories the compose expects, including the
#      four sub-directories the image ships under /app/cache — a bind mount on an
#      empty directory hides what the image has there (ZIMAOS-KNOWLEDGE §60)
#   4. print the image id + the next command (zimapp install)
#
# Needs: ssh access as a user in the `docker` group (measured on the target with
# `docker info`, not assumed), rsync on both ends. No sudo, no secrets.
#
# Rebuilds: for a locally built image the safe order is
#   rebuild → uninstall → install   (KB §27.6 — uninstall deletes the image the
#   running container was created from, by id; a rebuild first moves the tag
#   to a new id so the uninstall hits the old, dangling one)
# or, in place: docker compose -p ahnengalerie up -d --force-recreate web celery
set -euo pipefail

target="${1:?usage: build-on-host.sh <ssh-user>@<host> [tag]}"
tag="${2:-local}"
app_dir="/DATA/AppData/ahnengalerie"
repo="$(cd "$(dirname "$0")/../.." && pwd)"

if [[ ! -f "$repo/dist/index.html" ]]; then
  echo "dist/index.html missing — run 'npm run build' first" >&2
  exit 1
fi

# DOCKER_CONFIG: on ZimaOS a non-root shell must not use /DATA/.docker (KB §2.3/§3.6)
remote_docker='export DOCKER_CONFIG=/tmp/dc-$USER; mkdir -p "$DOCKER_CONFIG";'

echo "== 1/4 docker access on $target"
ssh "$target" "$remote_docker docker info --format '{{.ServerVersion}} {{.Architecture}}'" \
  || { echo "docker not usable as this user on $target" >&2; exit 1; }

echo "== 2/4 rsync dist/ + Dockerfile → $target:$app_dir/src/"
ssh "$target" "mkdir -p $app_dir/src"
rsync -az --info=stats1 "$repo/dist/" "$target:$app_dir/src/dist/"
rsync -az "$repo/Dockerfile" "$target:$app_dir/src/Dockerfile"

echo "== 3/4 docker build -t ahnengalerie:$tag"
ssh "$target" "$remote_docker cd $app_dir/src && docker build -t ahnengalerie:$tag . 2>&1 | tail -3"

echo "== 4/4 bind-mount directories"
ssh "$target" "mkdir -p $app_dir/{users,index,thumbnail_cache,cache/reports,cache/export,cache/request_cache,cache/persistent_cache,secret,db,media,tmp} && ls $app_dir"

echo
echo "image:"
ssh "$target" "$remote_docker docker images ahnengalerie:$tag --format '{{.Repository}}:{{.Tag}} {{.ID}} {{.Size}} {{.CreatedSince}}'"
echo
echo "next: python3 ~/dev/zimapp/zimapp.py install $repo/deploy/zimaos/ahnengalerie.yml --host <ip> --user <zimaos-user>"
