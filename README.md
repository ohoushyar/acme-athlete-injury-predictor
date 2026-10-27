# Injury risk prediction

A design for scoring each athlete’s injury risk every morning at 06:00 local time, from wearable GPS and inertial data collected over the previous 7 and 28 days. Data that arrives after 06:00 corrects that morning’s score, and the coach can see the old number, the new number, and which workload moved.

This repository is the design. It has the design write-up, the data model, one worked example, a static demo of that example, and the SQL that builds scoring and training rows. There is no application code.

## Documents

| Document | What it contains |
| --- | --- |
| [Design](docs/design.md) | Assumptions, data volume, and the ingestion, training, and scoring paths |
| [Data model](docs/data-model.md) | Entity diagram, Postgres tables, keys, and the S3 layout for raw inertial and GPS files |
| [Sample data](docs/sample-data.md) | Sam, device D-100, and Monday 10 March 2025, from the raw file through the afternoon correction |
| [Dashboard](docs/dashboard.html) | The same morning as a coach view, including the scoring window and the training timeline for the model that scored it |
| [Data prep](docs/data-prep.sql) | Parameterized Postgres queries for the morning feature build and the Sunday training export |
| [AI notes](prompt.md) | The original brief and the decisions recorded while the design was worked out |

Open [docs/dashboard.html](docs/dashboard.html) in a browser. The toggle switches between the 06:00 score and the correction after 14:17.

## What the system does

Wearables record GPS at 10 Hz and inertial motion at up to 100 Hz during training and games. A device is often offline during the session and syncs later, in bursts, sometimes the next day. Devices are reassigned between athletes, occasionally mid-session.

Each morning the job predicts the day about to start. The inputs are the 7 and 28 local dates before that morning. The morning’s own session is not an input, because it has not happened yet. The label the model learns is whether a time-loss injury occurs on that day or any of the next 6 days.

A session stays on the local date it started. Timestamps that place a sample on a day are stored as wall-clock time, with the IANA timezone in its own column. The S3 prefix is that same local start date. `received_at` and `scored_at` stay UTC, and they are not used to choose the day.

## The Monday 10 March example

Sam trains on Sunday 9 March, 10:00 to 11:30 in `America/New_York`. Only the first half of that session has uploaded when Monday is scored.

| | 06:00 | After 14:17 |
| --- | --- | --- |
| Sunday load | 200 | 400 |
| Sunday coverage | 0.5 | 1.0 |
| Seven-day load | 2,950 | 3,150 |
| Risk | 0.22, low | 0.27, moderate |

The second half arrives at 14:12. Chunks from the same dock wait a few minutes and become one correction, so the coach sees a single change rather than one update per file.

The model that scored that morning, `lgbm-3`, was trained on Sunday 9 March. Monday 10 March is first included in a training job on Sunday 23 March. That job reads the 06:00 features, seven-day load 2,950, because those are the numbers a morning score can see. The label is 1: Sam’s time-loss injury on 12 March falls inside 10–16 March.

## How a day moves through the system

1. The dock asks FastAPI for a presigned URL, uploads the file straight to S3, then marks the batch complete. The API records the batch and publishes one queue message. It does not receive the file.
2. A worker converts device time to team local time, attributes each sample to the athlete wearing the device at that timestamp, and rebuilds minute and daily totals. Coverage is the share of the session that has arrived. Observed load is not scaled up to fill a missing half. Samples with no assignment stay listed until someone adds one.
3. At 06:00 every active athlete gets one feature row and one risk for that day. If average coverage over the session days in the last 7 days is under 0.7, the band is `insufficient_data` and the risk is left empty.
4. After 06:00, late chunks for one athlete are combined into one new feature revision, one new score, and one change-log row. Revision 1 is left as it was.
5. Every Sunday, mornings whose 7 label days have already finished are exported. The last 56 of those dates are the holdout. Older dates are what the model learns from. A person approves the package before it is used to score.

The intended stack is Python 3, FastAPI, Kubernetes on AWS, and SageMaker for training. Scoring is a batch job at 06:00, plus a later batch for athletes whose data arrived after that.
