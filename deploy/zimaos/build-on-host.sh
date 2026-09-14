#!/usr/bin/env bash
# Build the Ahnengalerie image ON a ZimaOS host from a local production build.
#
#   npm run build                                   # produces dist/
#   deploy/zimaos/build-on-host.sh <ssh-user>@<host> [tag]
#
# What it does, in order:
#   1. rsync dist/ + Dockerfile to <host>:/DATA/AppData/ahnengalerie-build/
#      (additive — no --delete; and NOT inside /DATA/AppData/ahnengalerie, which
#      a ZimaOS uninstall removes wholesale)
#   2. docker build there, tag as 127.0.0.1:5000/ahnengalerie:<tag>
#   3. push it into the host-local registry on 127.0.0.1:5000 and PULL IT BACK
#      as the counter-check — that pull is exactly what the ZimaOS installer does.
#      Measured 2026-09-14 on ZimaOS v1.7.1-beta1: the app installer always pulls
#      through its mirror orchestrator (image_pull_orchestrator.go) and a tag that
#      exists only in the local daemon fails with "Repository existiert nicht".
#      A registry that listens on localhost only is the way past that.
#   4. pre-create the bind-mount directories the compose expects, including the
#      four sub-directories the image ships under /app/cache — a bind mount on an
#      empty directory hides what the image has there (ZIMAOS-KNOWLEDGE §60)
#   5. print the image id + the next command (zimapp install)
#
# Needs: ssh access as a user in the `docker` group (measured on the target with
# `docker info`, not assumed), rsync on both ends. No sudo, no secrets.
#
# Registry: any registry:2 container published on 127.0.0.1:5000 is reused; if
# none answers, one is started as `ahnengalerie-registry` with its data under
# /DATA/AppData/ahnengalerie-registry. Localhost is in Docker's default
# insecure-registry set, so no daemon config is touched.
#
# Updates of a running install: rebuild+push with this script, then on the host
#   cd /var/lib/casaos/apps/ahnengalerie && sudo docker compose up -d --force-recreate web celery
# — never "uninstall + install" through ZimaOS: uninstall deletes
# /DATA/AppData/ahnengalerie including the tree, media and user accounts.
set -euo pipefail

target="${1:?usage: build-on-host.sh <ssh-user>@<host> [tag]}"
tag="${2:-local}"
app_dir="/DATA/AppData/ahnengalerie"
build_dir="/DATA/AppData/ahnengalerie-build"
registry="127.0.0.1:5000"
image="$registry/ahnengalerie:$tag"
repo="$(cd "$(dirname "$0")/../.." && pwd)"

if [[ ! -f "$repo/dist/index.html" ]]; then
  echo "dist/index.html missing — run 'npm run build' first" >&2
  exit 1
fi

# DOCKER_CONFIG: on ZimaOS a non-root shell must not use /DATA/.docker (KB §2.3/§3.6)
remote_docker='export DOCKER_CONFIG=/tmp/dc-$USER; mkdir -p "$DOCKER_CONFIG";'

echo "== 1/5 docker access on $target"
ssh "$target" "$remote_docker docker info --format '{{.ServerVersion}} {{.Architecture}}'" \
  || { echo "docker not usable as this user on $target" >&2; exit 1; }

echo "== 2/5 rsync dist/ + Dockerfile → $target:$build_dir/"
ssh "$target" "mkdir -p $build_dir"
rsync -az --info=stats1 "$repo/dist/" "$target:$build_dir/dist/"
rsync -az "$repo/Dockerfile" "$target:$build_dir/Dockerfile"

echo "== 3/5 docker build -t $image"
ssh "$target" "$remote_docker cd $build_dir && docker build -t $image . 2>&1 | tail -3"

echo "== 4/5 registry on $registry: push, then pull back (the installer's own path)"
ssh "$target" "$remote_docker
  if ! curl -s -m5 -o /dev/null -w '%{http_code}' http://$registry/v2/ | grep -q 200; then
    echo 'no registry answering on $registry — starting ahnengalerie-registry'
    mkdir -p /DATA/AppData/ahnengalerie-registry
    docker run -d --name ahnengalerie-registry --restart unless-stopped \
      -p $registry:5000 -v /DATA/AppData/ahnengalerie-registry:/var/lib/registry registry:2 >/dev/null
    sleep 3
  fi
  curl -s -m5 -o /dev/null -w 'registry /v2/: HTTP %{http_code}\n' http://$registry/v2/
  docker push $image 2>&1 | tail -1
  docker rmi $image >/dev/null
  docker pull $image 2>&1 | tail -1
  curl -s http://$registry/v2/ahnengalerie/tags/list"
echo

echo "== 5/5 bind-mount directories"
ssh "$target" "mkdir -p $app_dir/{users,index,thumbnail_cache,cache/reports,cache/export,cache/request_cache,cache/persistent_cache,secret,db,media,tmp} && ls $app_dir"

echo
echo "image:"
ssh "$target" "$remote_docker docker images $image --format '{{.Repository}}:{{.Tag}} {{.ID}} {{.Size}} {{.CreatedSince}}'"
echo
echo "next: python3 ~/dev/zimapp/zimapp.py install $repo/deploy/zimaos/ahnengalerie.yml --host <ip> --user <zimaos-user>"
