# Sample data

One athlete, one device, and the morning of Monday 10 March 2025. Short ids stand in for the uuids in [data-model.md](data-model.md). Timezone is `America/New_York`. Risk numbers are illustrative, so the links can be checked without a trained model.

Sam trains on Sunday 9 March, 10:00 to 11:30. The device records 540,000 inertial samples. Only the first half has been uploaded when the 06:00 score runs on Monday. The rest arrives at 14:12. Sam's injury on Wednesday 12 March is the label for that Monday morning.

## Who and what

| team_id | name | tz |
| --- | --- | --- |
| team_east | Eastside | America/New_York |

| athlete_id | team_id | display_name | position | active |
| --- | --- | --- | --- | --- |
| athlete_sam | team_east | Sam | striker | true |

| device_id | serial | firmware |
| --- | --- | --- |
| device_d100 | D-100 | 4.2.1 |

The device is not Sam's. This row says Sam was wearing it on Sunday morning:

| assignment_id | device_id | athlete_id | valid_from | valid_to | tz | reason |
| --- | --- | --- | --- | --- | --- | --- |
| assign_sun9 | device_d100 | athlete_sam | 2025-03-09 09:00 | 2025-03-09 12:00 | America/New_York | pre_session |

A sample belongs to Sam when `device_id` is `device_d100` and `local_ts` is at or after 09:00 and before 12:00. The raw file has no `athlete_id`.

## The Sunday session and its two uploads

| session_id | device_id | started_at | ended_at | tz | expected_imu_rows | metric_date |
| --- | --- | --- | --- | --- | --- | --- |
| session_sun9 | device_d100 | 2025-03-09 10:00 | 2025-03-09 11:30 | America/New_York | 540000 | 2025-03-09 |

`metric_date` is the date part of `started_at`. Both chunks are stored under that date.

| batch_id | session_id | device_id | received_at (UTC) | local_ts_start | local_ts_end | tz | utc_offset_minutes | status | imu_rows |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| batch_sun9_a | session_sun9 | device_d100 | 2025-03-09 22:10 | 2025-03-09 10:00 | 2025-03-09 10:45 | America/New_York | -240 | aggregated | 270000 |
| batch_sun9_b | session_sun9 | device_d100 | 2025-03-10 18:12 | 2025-03-09 10:45 | 2025-03-09 11:30 | America/New_York | -240 | aggregated | 270000 |

S3 keys. The folder date is `metric_date`, not the arrival date. The second chunk arrives on Monday and still sits under 9 March:

```text
s3://injury-raw/imu/dt=2025-03-09/device_id=device_d100/batch_id=batch_sun9_a.parquet
s3://injury-raw/imu/dt=2025-03-09/device_id=device_d100/batch_id=batch_sun9_b.parquet
s3://injury-raw/gps/dt=2025-03-09/device_id=device_d100/batch_id=batch_sun9_a.parquet
```

Two inertial rows from the first file. There is no athlete column. Sam is found later, from `assign_sun9`.

| local_ts | tz | seq | ax | ay | az | gx | gy | gz |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 2025-03-09 10:00:00.000 | America/New_York | 1 | 0.12 | 0.04 | 9.81 | 0.01 | -0.02 | 0.00 |
| 2025-03-09 10:00:00.010 | America/New_York | 2 | 0.18 | 0.07 | 9.77 | 0.02 | -0.01 | 0.01 |

In UTC those instants are 14:00. The stored time and the folder stay on 9 March.

An evening session on another day shows the case that crosses UTC midnight. Saturday 8 March 19:00 to 23:30 in New York is 23:00 UTC on the 8th through 03:30 UTC on the 9th. The folder is still the local start date. These two rows are not extra load. Saturday's total is already the 800 in `daily_aggregates`.

```text
s3://injury-raw/imu/dt=2025-03-08/device_id=device_d100/batch_id=batch_sat8.parquet
```

| local_ts | tz | seq |
| --- | --- | --- |
| 2025-03-08 19:00:00.000 | America/New_York | 1 |
| 2025-03-08 23:30:00.000 | America/New_York | 5400000 |

## minute_metrics

Each row is one local minute for one athlete. These four are samples of Sunday's session, not the whole 90 minutes. At 06:00 on Monday only `batch_sun9_a` has arrived, so the table holds the 45 minutes from 10:00 through 10:44. Their `accel_load` values sum to the Sunday daily total of 200. After 14:12 the minutes from 10:45 through 11:29 are added, and the 90 minutes sum to 400.

| athlete_id | minute_ts | tz | session_date | distance_m | high_speed_distance_m | sprint_count | accel_load | impact_count | max_speed_mps | duration_s | coverage | metric_version |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| athlete_sam | 2025-03-09 10:00 | America/New_York | 2025-03-09 | 80 | 20 | 0 | 4.6 | 0 | 5.4 | 60 | 1.0 | 1 |
| athlete_sam | 2025-03-09 10:44 | America/New_York | 2025-03-09 | 70 | 10 | 0 | 4.2 | 1 | 4.8 | 60 | 1.0 | 1 |
| athlete_sam | 2025-03-09 10:45 | America/New_York | 2025-03-09 | 90 | 30 | 1 | 5.1 | 0 | 6.6 | 60 | 1.0 | 1 |
| athlete_sam | 2025-03-09 11:29 | America/New_York | 2025-03-09 | 60 | 0 | 0 | 3.4 | 0 | 4.1 | 60 | 1.0 | 1 |

`session_date` is the date part of `minute_ts`. The 10:45 and 11:29 rows do not exist yet at 06:00. A minute with a gap would have `coverage` below 1 and `duration_s` below 60. These four minutes are complete.

## daily_aggregates

One row per athlete per session-start date. The 06:00 score on Monday uses days before Monday. Sunday is only half uploaded at that moment, so its load is 200, its duration is 2,700 seconds, and its coverage is 0.5. Tuesday is a rest day and has no row. `metric_version` 1 is the accel-load formula. `updated_at` is UTC.

| athlete_id | metric_date | team_id | distance_m | high_speed_distance_m | sprint_count | accel_load | impact_count | max_speed_mps | duration_s | session_count | coverage | metric_version | updated_at |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| athlete_sam | 2025-03-03 | team_east | 8000 | 1200 | 8 | 400 | 4 | 7.6 | 5400 | 1 | 1.0 | 1 | 2025-03-10 10:00 |
| athlete_sam | 2025-03-05 | team_east | 9000 | 1400 | 10 | 500 | 6 | 8.1 | 5400 | 1 | 1.0 | 1 | 2025-03-10 10:00 |
| athlete_sam | 2025-03-06 | team_east | 8500 | 1100 | 7 | 450 | 5 | 7.4 | 5400 | 1 | 1.0 | 1 | 2025-03-10 10:00 |
| athlete_sam | 2025-03-07 | team_east | 10000 | 1600 | 12 | 600 | 8 | 8.4 | 5400 | 1 | 1.0 | 1 | 2025-03-10 10:00 |
| athlete_sam | 2025-03-08 | team_east | 11000 | 2200 | 15 | 800 | 11 | 8.9 | 5400 | 1 | 1.0 | 1 | 2025-03-10 10:00 |
| athlete_sam | 2025-03-09 | team_east | 3500 | 800 | 4 | 200 | 3 | 6.6 | 2700 | 1 | 0.5 | 1 | 2025-03-10 10:00 |

After `batch_sun9_b` lands, only the Sunday row is replaced. Coverage is 270000 + 270000 divided by 540000. The same `metric_date` stays 9 March.

| athlete_id | metric_date | team_id | distance_m | high_speed_distance_m | sprint_count | accel_load | impact_count | max_speed_mps | duration_s | session_count | coverage | metric_version | updated_at |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| athlete_sam | 2025-03-09 | team_east | 7000 | 1600 | 8 | 400 | 6 | 7.8 | 5400 | 1 | 1.0 | 1 | 2025-03-10 18:17 |

## rolling_features

`as_of_date` is the day being predicted. The daily rows above are the inputs. Monday's own session is not one of them. Revision 1 is what existed at 06:00. Revision 2 is the same morning after Sunday's second half arrived. Training on Sunday 23 March reads revision 1 only.

`load_7d` at 06:00 is 400 + 500 + 450 + 600 + 800 + 200 = 2950. The rest day adds nothing. `coverage_7d` is (1 + 1 + 1 + 1 + 1 + 0.5) / 6 = 0.92. The prior 21 days, not listed here, add 6,300 of load, so `load_28d` is 9250. The same prior days add 120,000 m and 20,000 high-speed metres.

`ewma_load_7d` applies weight 0.25 to each new day, seeded at Monday's 400: 400, 300, 350, 375, 431.3, 523.4, then 442.6 when Sunday is 200. `ewma_load_28d` is carried in at 300 through Saturday, then one step at weight 2/29 for Sunday. `monotony_7d` is the mean of the seven daily loads divided by their standard deviation. `strain_7d` is `load_7d` times that monotony. `days_since_session` is 1 because Sunday is the latest session. There is no time-loss injury before this morning.

| athlete_id | as_of_date | feature_set_version | revision | load_7d | load_28d | ewma_load_7d | ewma_load_28d | acwr_ewma | distance_7d | distance_28d | hsd_7d | hsd_28d |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| athlete_sam | 2025-03-10 | 3 | 1 | 2950 | 9250 | 442.6 | 293.1 | 1.51 | 50000 | 170000 | 8300 | 28300 |
| athlete_sam | 2025-03-10 | 3 | 2 | 3150 | 9450 | 492.6 | 306.9 | 1.61 | 53500 | 173500 | 9100 | 29100 |

| athlete_id | as_of_date | feature_set_version | revision | monotony_7d | strain_7d | days_since_session | coverage_7d | days_since_injury | prior_injury_90d | position | feature_hash |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| athlete_sam | 2025-03-10 | 3 | 1 | 1.74 | 5133 | 1 | 0.92 | — | false | striker | h_2950 |
| athlete_sam | 2025-03-10 | 3 | 2 | 2.00 | 6300 | 1 | 1.00 | — | false | striker | h_3150 |

The two tables are the same two rows, split so the columns fit. Revision 2 replaces Sunday's 200 with 400, so `load_7d` becomes 3150 and `distance_7d` becomes 53,500. Revision 1 is left as it was. `days_since_injury` is empty because Sam has no earlier time-loss injury. The injury on 12 March is still in the future.

## Injury label for that morning

| injury_id | athlete_id | occurred_on | time_loss | days_lost |
| --- | --- | --- | --- | --- |
| injury_hamstring | athlete_sam | 2025-03-12 | true | 10 |

The Monday 10 March row is a training example on Sunday 23 March, because 10 March through 16 March are over by then. The Sunday job on 16 March does not include it, because the 16th is not over yet. The label is 1 because 12 March falls inside those seven days. An injury on 18 March would leave this row a 0.

## Scores the coach sees

| model_version | feature_set_version | stage |
| --- | --- | --- |
| lgbm-3 | 3 | production |

| score_run_id | trigger | model_version | as_of_date | started_at (UTC) |
| --- | --- | --- | --- | --- |
| run_0600 | scheduled | lgbm-3 | 2025-03-10 | 2025-03-10 10:00 |
| run_1417 | late_data | lgbm-3 | 2025-03-10 | 2025-03-10 18:17 |

06:00 in New York is 10:00 UTC. The second run waits a few minutes after the 14:12 upload so one dock becomes one correction. 14:17 local is 18:17 UTC.

| score_id | score_run_id | athlete_id | as_of_date | feature_revision | feature_hash | risk | band | is_current |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| score_r1 | run_0600 | athlete_sam | 2025-03-10 | 1 | h_2950 | 0.22 | low | false |
| score_r2 | run_1417 | athlete_sam | 2025-03-10 | 2 | h_3150 | 0.27 | moderate | true |

The 06:00 row has no change-log entry. The afternoon row points at both scores:

| change_id | athlete_id | as_of_date | prev_score_id | new_score_id | prev_risk | new_risk | reason_code | batch_ids | summary |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| change_1417 | athlete_sam | 2025-03-10 | score_r1 | score_r2 | 0.22 | 0.27 | late_data | {batch_sun9_b} | Sunday's session finished uploading at 14:12. Load for that day went from 200 to 400. Seven-day load went from 2950 to 3150. Risk went from 0.22 to 0.27. |

## What links to what

- `batch_sun9_a` and `batch_sun9_b` share `session_sun9`. The S3 folder `dt=2025-03-09` is `session_sun9.metric_date`.
- A raw row at `2025-03-09 10:00` on `device_d100` matches `assign_sun9`, so the load is added to `athlete_sam`.
- Sunday's `daily_aggregates` row is `metric_date` 2025-03-09. At 06:00 its `accel_load` is 200. After the second batch it is 400.
- `rolling_features` revision 1 for `as_of_date` 2025-03-10 sums the daily rows from 3 March through 9 March and produces `h_2950`.
- `score_r1` stores that same hash and `feature_revision` 1. `run_0600.model_version` is `lgbm-3`, whose `feature_set_version` is 3, the same version as the feature row.
- `change_1417.prev_score_id` is `score_r1` and `new_score_id` is `score_r2`. `batch_ids` names the chunk that changed Sunday.
- `injury_hamstring.occurred_on` is 12 March. That makes the Monday 10 March training label 1. It does not change the 06:00 features.
