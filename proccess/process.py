from garpy import Wellness, GarminClient
from sqlite_utils import Database
import pendulum
import tempfile
import zipfile
import os
import fitparse
import pytz
import datetime
import requests
import sqlite3
from memo import memo

user_agent = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/90.0.4430.93 Safari/537.36"

tz = pytz.timezone('UTC')
offset_date_time = datetime.datetime(1989, 12, 31, tzinfo=tz)
utc_offset = int(datetime.datetime.timestamp(offset_date_time))


def get_actual_timestamp(ts, ts16, is_raw=True):
    out = ts
    if not is_raw:
        out = - utc_offset

    out += (ts16 - (out & 0xFFFF)) & 0xFFFF

    return out + utc_offset


def get_all_since_date(start_date, db):
    dir = tempfile.gettempdir()
    dir = dir + "/wellness"
    os.mkdir(dir)

    username = os.environ['username']
    password = os.environ['password']

    dt = pendulum.now()
    sd = pendulum.parse(start_date)

    period = sd - dt

    with GarminClient(
            username, password, user_agent=user_agent
    ) as client:
        for dt in period:
            date_str = dt.format("YYYY-MM-DD")
            print("date: " + date_str, flush=True)
            exist = date_exists(date_str, db)
            if not exist:
                get_wellness_day(client, date_str, dir, db)


def delete_above_table(date, column, db, table):
    if has_table(table, db):
        db.query("delete from " + table + " where " + column + " > datetime('" + date + "')")


def delete_above(date, db):
    delete_above_table(date, "date", db, "missing")
    delete_above_table(date, "date", db, "wellness")
    delete_above_table(date, "datetime(unix_timestamp, 'unixepoch')", db, "activity")
    delete_above_table(date, "datetime(unix_timestamp, 'unixepoch')", db, "heart_rate")
    delete_above_table(date, "datetime(unix_timestamp, 'unixepoch')", db, "stress_level")


def transform(db):
    if not has_table("wellness", db):
        return
    db.executescript("""
create table if not exists heart_rate
(
    unix_timestamp int,
    heart_rate     int
);
create table if not exists stress_level
(
    unix_timestamp int,
    stress_level   int
);
create table if not exists activity
(
    unix_timestamp int,
    steps          int,
    distance       int,
    activity_type  text
);
insert into heart_rate(unix_timestamp, heart_rate)
select strftime('%s', datetime(actual_timestamp, 'unixepoch')) unix_timestamp, "heart_rate (bpm)"
from wellness
where "heart_rate (bpm)" is not null
  and "heart_rate (bpm)" <> 0
  and actual_timestamp is not null
order by 1 desc
on conflict do nothing;

insert into stress_level(unix_timestamp, stress_level)
select strftime('%s', datetime(stress_level_time)) unix_timestamp, stress_level_value stress_level
from wellness
where stress_level_value is not null
  and stress_level_time is not null
order by 1 desc
on conflict do nothing;

insert into activity(unix_timestamp, steps, distance, activity_type)
select strftime('%s', datetime(timestamp)) unix_timestamp,
       "steps (steps)"                     steps,
       "distance (m)"                      distance,
       activity_type
from wellness
where activity_type is not null
order by 1 desc
on conflict do nothing;

create index if not exists heart_rate_time on heart_rate (unix_timestamp, heart_rate);
create index if not exists stress_level_time on stress_level (unix_timestamp, stress_level);
create index if not exists activity_time on activity (unix_timestamp);
create index if not exists missing_time on missing (date);

drop table wellness;
vacuum main;
""")


def has_table(table, db):
    return table in db.table_names()


@memo
def get_table_dates(column, table, db):
    if not has_table(table, db):
        return list()

    query = "select distinct " + column + " as exist from " + table + ";"
    return [date["exist"] for date in db.query(query)]


def date_exists_table(date_str, column, table, db):
    try:
        dates = get_table_dates(column, table, db)
        if len(dates) == 0:
            return False
        return date_str in dates
    except sqlite3.OperationalError:
        return False


def date_exists(date_str, db):
    return date_exists_table(date_str, "date(unix_timestamp, 'unixepoch' )", 'activity', db) \
           or date_exists_table(date_str, "date(unix_timestamp, 'unixepoch' )", 'heart_rate', db) \
           or date_exists_table(date_str, 'date', 'wellness', db) \
           or date_exists_table(date_str, "date(unix_timestamp, 'unixepoch' )", 'stress_level', db) \
           or date_exists_table(date_str, 'date', 'missing', db)


def get_wellness_day(client, date, dir, db):
    d = pendulum.parse(date)
    wellness = Wellness(d)
    try:
        wellness.download(client, dir)
    except requests.exceptions.ConnectionError:
        print("FAILED FAILED FAILED: " + date, flush=True)

    if os.path.exists(dir + "/" + date + ".zip"):
        print("downloaded: " + date, flush=True)
        db["wellness"].insert_all(from_zip(date, dir), replace=True, analyze=True, alter=True, hash_id="id")
    else:
        print("MISSING date: " + date + " zip", flush=True)
        db['missing'].insert({"date": date})  # to save time next time


def from_zip(date, dir):
    with zipfile.ZipFile(dir + "/" + date + ".zip", "r") as zip_ref:
        for path in zip_ref.infolist():
            with zip_ref.open(path) as myfile:
                fitfile = fitparse.FitFile(myfile)
                fitfile.parse()
                last_timestamp = None

                for record in fitfile.get_messages():
                    timestamp_16 = None
                    rs = {'date': date}
                    for field in record:
                        if field.name == 'timestamp':
                            last_timestamp = field.value
                            last_timestamp_raw = field.raw_value
                        if field.name == 'timestamp_16':
                            timestamp_16 = field.value
                            timestamp_16_raw = field.raw_value
                        rs[field_name_with_units(field)] = field.value

                    rs['last_timestamp'] = last_timestamp
                    if timestamp_16 is not None and last_timestamp is not None:
                        rs['actual_timestamp'] = get_actual_timestamp(
                            # int(datetime.datetime.timestamp(last_timestamp)),
                            last_timestamp_raw,
                            timestamp_16_raw)

                    yield rs


def field_name_with_units(field):
    key = field.name
    if field.units:
        key += " (" + field.units + ")"
    return key


def main(
):
    start_date = os.environ['start']
    db_file = os.environ['db']
    db = Database(db_file)
    delete_after_date = pendulum.now().subtract(days=7).format("YYYY-MM-DD")
    delete_above(delete_after_date, db)
    get_all_since_date(start_date, db)
    transform(db)
    Database(db_file).vacuum()


if __name__ == '__main__':
    main()
