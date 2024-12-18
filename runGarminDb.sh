#!/bin/bash
set -e # Exit with nonzero exit code if anything fails
set -o pipefail
set -o errexit
set -x

dockerGarminDB='garmindb'
dbBranch="db"
db="HealthData/DBs"
tempDB="$(mktemp -d)"

buildGarminDB() {
  docker build --tag "$dockerGarminDB" --pull --file garminDB.Dockerfile .
}

garminDB() {

config="$(mktemp)"
trap "rm $config 2>/dev/null || true" RETURN

jq -n --arg user "$GARMIN_USERNAME" --arg pass "$GARMIN_PASSWORD" '
  {
      "garmin": {
          "domain": "garmin.com"
      },
      "credentials": {
          "user"                          : $user,
          "secure_password"               : false,
          "password"                      : $pass
      },
      "data": {
          "weight_start_date"             : "11/30/2015",
          "sleep_start_date"              : "11/30/2015",
          "rhr_start_date"                : "11/30/2015",
          "monitoring_start_date"         : "11/30/2015",
          "download_latest_activities"    : 50,
          "download_all_activities"       : 12000
      },
      "copy": {
          "mount_dir"                     : "/Volumes/GARMIN"
      },
      "enabled_stats": {
          "monitoring"                    : true,
          "steps"                         : true,
          "itime"                         : true,
          "sleep"                         : true,
          "rhr"                           : true,
          "weight"                        : true,
          "activities"                    : true
      },
      "course_views": {
          "steps"                         : []
      },
      "modes": {
      },
      "activities": {
          "display"                       : []
      },
      "settings": {
          "metric"                        : true,
          "default_display_activities"    : ["walking", "running", "cycling"]
      },
      "checkup": {
          "look_back_days"                : 90
      }
  }
  ' > "$config"

  docker run \
    -v"$(pwd):/wd" \
    -v"$(pwd)/HealthData:/root/HealthData" \
    -e username="$GARMIN_USERNAME" \
    -e password="$GARMIN_PASSWORD" \
    -w /wd \
    -v "$config":/root/.GarminDb/GarminConnectConfig.json \
    "$dockerGarminDB" \
    "$@"
}

commitData() {

  mv "$db" "$tempDB"
  
  git config user.name "Automated"
  git config user.email "actions@users.noreply.github.com"
  git add -A
  timestamp=$(date -u)
  git commit -m "Latest data: ${timestamp}" || true
  git push

  git branch -D "$dbBranch" || true
  git checkout --orphan "$dbBranch"
  rm -rf *
  mv "$tempDB" "$db"
  tar -cvzf "$db.tar.gz" "$db"
  split -b 99M "$db.tar.gz" "$db.tar.gz.part"
  git add "$db.tar.gz.part*"
  git commit "$db.tar.gz.part*" -m "push db parts"
  git add "$db"
  git commit "$db" -m "push db"
  git push origin "$dbBranch" -f
}

getDBs() {
  local db="$1"
  git fetch origin "$dbBranch"
  git ls-tree -r --name-only "origin/$dbBranch" |
    sort |
    xargs -I % -n1 git show "origin/$dbBranch:%" |
    tar -zxf - || return 0
}

buildGarminDB
getDBs || true

garminDB "$@"
commitData
