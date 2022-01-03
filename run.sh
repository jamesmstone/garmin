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

function addAllActivity() {
    local db=${1}

    find "$downloadDir" -name '*summary.json' -exec jq . -c {} + |
      sql-utils insert "$db" "summary" - \
       --flatten \
       --alter \
       --pk=activityId \
       --replace \
       --nl

    find "$downloadDir" -name '*details.json' -exec jq . -c {} + |
      sql-utils insert "$db" "details" - \
       --flatten \
       --alter \
       --pk=activityId \
       --replace \
       --nl

}

makeDB() {
  local db="$1"
  rm -rf "$db" || true
  addAllActivity "$db"
  sql-utils create-index --if-not-exists "$db" summary activityTypeDTO_typeKey
  sql-utils add-foreign-key "$db" details activityId summary activityId --ignore
  sql-utils "$db" 'create table activityDetailMetrics as
                   select d.activityId as activityId,
                          s.activityTypeDTO_typeKey as activityTypeDTO_typeKey,
                          json_extract(
                                  m.value,
                                  '\''$.metrics'\'') as activityDetailMetric,
                          d.metricDescriptors,
                          datetime(
                                      json_extract(
                                              m.value,
                                              '\''$.metrics['\'' || (
                                                  select json_extract(m.value, '\''$.metricsIndex'\'')
                                                  from details di,
                                                       json_each(di.metricDescriptors) m
                                                  where di.activityId = d.activityId
                                                    and json_extract(m.value, '\''$.key'\'') = '\''directTimestamp'\''
                                              ) || '\'']'\''
                                          ) / 1000,
                                      '\''unixepoch'\''
                              )                as "directTimestamp",
                          json_extract(
                                  m.value,
                                  '\''$.metrics['\'' || (
                                      select json_extract(m.value, '\''$.metricsIndex'\'')
                                      from details di,
                                           json_each(di.metricDescriptors) m
                                      where di.activityId = d.activityId
                                        and json_extract(m.value, '\''$.key'\'') = '\''directLongitude'\''
                                  ) || '\'']'\''
                              )                as "directLongitude",
                          json_extract(
                                  m.value,
                                  '\''$.metrics['\'' || (
                                      select json_extract(m.value, '\''$.metricsIndex'\'')
                                      from details di,
                                           json_each(di.metricDescriptors) m
                                      where di.activityId = d.activityId
                                        and json_extract(m.value, '\''$.key'\'') = '\''directLatitude'\''
                                  ) || '\'']'\''
                              )                as "directLatitude",
                          json_extract(
                                  m.value,
                                  '\''$.metrics['\'' || (
                                      select json_extract(m.value, '\''$.metricsIndex'\'')
                                      from details di,
                                           json_each(di.metricDescriptors) m
                                      where di.activityId = d.activityId
                                        and json_extract(m.value, '\''$.key'\'') = '\''directSpeed'\''
                                  ) || '\'']'\''
                              )                as "directSpeed"
                   from summary s
                            inner join details d on d.activityId = s.activityId,
                        json_each(activitydetailmetrics) m
                   order by 5'
  sql-utils create-index --if-not-exists "$db" activityDetailMetrics activityId
  sql-utils create-index --if-not-exists "$db" activityDetailMetrics activityTypeDTO_typeKey
  sql-utils create-index --if-not-exists "$db" activityDetailMetrics directTimestamp
  sql-utils create-index --if-not-exists "$db" activityDetailMetrics --  -directSpeed activityTypeDTO_typeKey
  sql-utils add-foreign-key "$db" activityDetailMetrics activityId summary activityId --ignore
  sql-utils index-foreign-keys "$db"
  sql-utils optimize "$db"
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

}

buildDocker

run "$@"
