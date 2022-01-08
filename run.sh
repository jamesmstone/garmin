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
    docker run -i  --user "$(id -u):$(id -g)" -v "$(pwd):/wd" -w /wd "$dockerGarpy" run garpy "$@"
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

remakeDB() {
  local db="$1"
  rm -rf "$db"
  addAllActivity "$db"
  sql-utils create-index --if-not-exists "$db" summary activityTypeDTO_typeKey
  sql-utils add-column "$db" summary detailsMetricDescriptors
  sql-utils add-column "$db" summary geoPolylineDTO
  sql-utils add-column "$db" summary heartRateDTOs
  sql-utils "$db" 'UPDATE summary SET detailsMetricDescriptors = (
                      SELECT metricDescriptors
                      FROM details
                      WHERE details.activityId = summary.activityId
                  );'
  sql-utils "$db" 'UPDATE summary SET heartRateDTOs = (
                      SELECT heartRateDTOs
                      FROM details
                      WHERE details.activityId = summary.activityId
                      );'
  sql-utils "$db" 'UPDATE summary SET geoPolylineDTO = (
                      SELECT json(geoPolylineDTO)
                      FROM details
                      WHERE details.activityId = summary.activityId
                  );'

  sql-utils "$db" 'create table activityDetailMetrics as
                   with query as (
                   select s.activityId as activityId,
                          s.activityTypeDTO_typeKey as activityTypeDTO_typeKey,
                          json_extract(
                                  m.value,
                                  '\''$.metrics'\'') as activityDetailMetric,
                          datetime(
                                      json_extract(
                                              m.value,
                                              '\''$.metrics['\'' || (
                                                  select json_extract(m.value, '\''$.metricsIndex'\'')
                                                  from summary smry,
                                                       json_each(smry.detailsMetricDescriptors) m
                                                    where json_extract(m.value, '\''$.key'\'') = '\''directTimestamp'\''
                                                    and s.activityId = smry.activityId
                                              ) || '\'']'\''
                                          ) / 1000,
                                      '\''unixepoch'\''
                              )                as "directTimestamp",
                          json_extract(
                                  m.value,
                                  '\''$.metrics['\'' || (
                                      select json_extract(m.value, '\''$.metricsIndex'\'')
                                      from summary smry,
                                           json_each(smry.detailsMetricDescriptors) m
                                        where json_extract(m.value, '\''$.key'\'') = '\''directLongitude'\''
                                        and s.activityId = smry.activityId
                                  ) || '\'']'\''
                              )                as "longitude",
                          json_extract(
                                  m.value,
                                  '\''$.metrics['\'' || (
                                      select json_extract(m.value, '\''$.metricsIndex'\'')
                                      from summary smry,
                                           json_each(smry.detailsMetricDescriptors) m
                                      where json_extract(m.value, '\''$.key'\'') = '\''directLatitude'\''
                                      and s.activityId = smry.activityId
                                  ) || '\'']'\''
                              )                as "latitude",
                          json_extract(
                                  m.value,
                                  '\''$.metrics['\'' || (
                                      select json_extract(m.value, '\''$.metricsIndex'\'')
                                      from summary smry,
                                           json_each(smry.detailsMetricDescriptors) m
                                        where json_extract(m.value, '\''$.key'\'') = '\''directSpeed'\''
                                        and s.activityId = smry.activityId
                                  ) || '\'']'\''
                              )                as "directSpeed"
                   from summary s
                            inner join details d on d.activityId = s.activityId,
                        json_each(d.activitydetailmetrics) m
                   )
                   select * from query order by directTimestamp desc'
  sql-utils transform "$db" activityDetailMetrics --pk activityId --pk directTimestamp
  sql-utils transform "$db" activityDetailMetrics --drop rowid
  sql-utils drop-table "$db" details
  sql-utils create-index --if-not-exists "$db" activityDetailMetrics activityId
  sql-utils create-index --if-not-exists "$db" activityDetailMetrics activityTypeDTO_typeKey
  sql-utils create-index --if-not-exists "$db" activityDetailMetrics directTimestamp
  sql-utils create-index --if-not-exists "$db" activityDetailMetrics --  -directSpeed activityTypeDTO_typeKey
  sql-utils create-index --if-not-exists "$db" activityDetailMetrics --  activityTypeDTO_typeKey -directSpeed
  sql-utils add-foreign-key "$db" activityDetailMetrics activityId summary activityId --ignore
  sql-utils index-foreign-keys "$db"
  sql-utils analyze-tables "$db" --save
  sql-utils optimize "$db"
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
    datasette \
     publish vercel \
    "$db" \
     --token "$VERCEL_TOKEN" \
     --project=garminlog \
     --install=datasette-vega \
     --install=datasette-cluster-map \
     --setting sql_time_limit_ms 4500


}
function run() {
  local db="garmin.db"

  downloadAll
  commitData

  remakeDB "$db"
  publishDB "$db"
  commitDB "$db"

}

buildDocker

run "$@"
