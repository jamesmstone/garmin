#!/bin/bash
set -e # Exit with nonzero exit code if anything fails
set -o pipefail
set -o errexit
set -x

downloadDir="data/garmin"
dockerSQLUtil="sqlite-utils"
dockerGarpy="garpy"
dockerDatasette="datasette"

TZ=UTC

function buildDatasette(){
      docker build --tag "$dockerDatasette" --pull --file datasette.Dockerfile .
}

function datasette() {
  docker run \
    -v"$(pwd):/wd" \
    -w /wd \
    "$dockerDatasette" \
    "$@"
}

function buildGarpy(){
    docker build --tag "$dockerGarpy" .
}

function garpy(){
    docker run -i  --user "$(id -u):$(id -g)" -v "$(pwd):/wd" -w /wd "$dockerGarpy" "$@"
}

function buildSQLUtils() {
  docker build --tag "$dockerSQLUtil" --file sqlite-utils.Dockerfile .
}

function sql-utils() {
  docker run \
    -i \
    -u"$(id -u):$(id -g)" \
    -v"$(pwd):/wd" \
    -w /wd \
    "$dockerSQLUtil" \
    "$@"
}

function buildDocker() {
    buildGarpy &
    buildSQLUtils &
    buildDatasette &
    wait
}


function ensureDownloadDir() {
  mkdir -p "$downloadDir"
}


function downloadAll() {
    ensureDownloadDir
    garpy download --username "$GARMIN_USERNAME" --password "$GARMIN_PASSWORD" "$downloadDir"
}

function addActivity(){
    local db=$1
    local activitySummaryJSON=$2
    local activityDetailsJSON=${activitySummaryJSON/summary/details}
    sql-utils insert "$db" "summary" "$activitySummaryJSON" --flatten --alter --pk=activityId --replace
    sql-utils insert "$db" "details" "$activityDetailsJSON" --alter --pk=activityId --replace
}

function addAllActivity() {
    local db=${1}
    local N=4
    for f in $(find "$downloadDir" -name '*summary.json' );do
        i=$((i%N))
        ((i++==0)) && wait
        addActivity "$db" $f &
    done
    wait
}

makeDB() {
  local db="$1"
  # rm -rf "$db" || true
  addAllActivity "$db"
}

commitDB() {
  local dbBranch="db"
  local db="$1"
  local tempDB="$(mktemp)"
  git branch -D "$dbBranch" || true
  git checkout --orphan "$dbBranch"
  mv "$db" "$tempDB"
  rm -rf *
  mv "$tempDB" "$db"
  git add "$db"
  git commit "$db" -m "push db"
  git push origin "$dbBranch" -f
}
commitData() {
  git config user.name "Automated"
  git config user.email "actions@users.noreply.github.com"
  git add -A
  timestamp=$(date -u)
  git commit -m "Latest data: ${timestamp}" || exit 0
  git push
}


function publishDB() {
    datasette publish vercel "$db" --token "$VERCEL_TOKEN" --project=garminlog --install=datasette-vega
}
function run() {
  local db="garmin.db"

  downloadAll
  commitData

  makeDB "$db"
  publishDB "$db"
  commitDB "$db"

}

buildDocker

run "$@"
