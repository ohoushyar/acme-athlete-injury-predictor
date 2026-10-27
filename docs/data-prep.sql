-- Data-prep templates for the morning score and the Sunday training job.
-- Bind parameters are written as :name. Postgres. No application code.
--
-- Dates are local dates. daily_aggregates.metric_date is already the session
-- start date, so these queries do not convert time zones.
--
-- The 7 and 28 day windows are the local dates before :as_of_date. For Monday
-- 10 March 2025 the 7-day window is 3 March through 9 March. A day with no
-- session contributes 0 to the sums and is skipped by coverage_7d.
--
-- Scoring builds a new rolling_features row from daily_aggregates.
-- Training must read revision 1 of rolling_features. It must not rebuild
-- features from daily_aggregates: a late dock replaces the daily row, and
-- rebuilding would learn from workload the 06:00 score did not have.
-- For 10 March, revision 1 keeps load_7d 2950. Revision 2, after Sunday's
-- second half arrives, is 3150. The Sunday 23 March job reads 2950.

-- ---------------------------------------------------------------------------
-- Scoring. One row per athlete for :as_of_date.
--
-- :as_of_date            date    morning being predicted
-- :feature_set_version   int     must match the production model
-- :athlete_ids           uuid[]  null scores every active athlete (the 06:00
--                                run). Otherwise only these athletes (the
--                                correction after a late dock).
--
-- next_revision is 1 when this morning has not been scored yet. A correction
-- inserts that number and leaves revision 1 in place. The scorer writes
-- band insufficient_data when coverage_7d is under 0.7.
-- The caller hashes the feature columns into feature_hash before insert.
-- ---------------------------------------------------------------------------

WITH RECURSIVE params AS (
    SELECT
        :as_of_date::date AS as_of_date,
        :feature_set_version::integer AS feature_set_version,
        :athlete_ids::uuid[] AS athlete_ids
),
scope AS (
    SELECT a.athlete_id, a.position
    FROM athletes AS a
    CROSS JOIN params AS p
    WHERE a.active
      AND (p.athlete_ids IS NULL OR a.athlete_id = ANY (p.athlete_ids))
),
span AS (
    SELECT
        s.athlete_id,
        s.position,
        LEAST(
            COALESCE(
                (
                    SELECT min(d.metric_date)
                    FROM daily_aggregates AS d
                    WHERE d.athlete_id = s.athlete_id
                      AND d.metric_date < p.as_of_date
                ),
                p.as_of_date - 28
            ),
            p.as_of_date - 28
        ) AS start_date,
        p.as_of_date - 1 AS end_date,
        p.as_of_date
    FROM scope AS s
    CROSS JOIN params AS p
),
series AS (
    SELECT
        sp.athlete_id,
        sp.position,
        sp.as_of_date,
        day::date AS metric_date,
        day::date >= sp.as_of_date - 7 AS in_7d,
        day::date >= sp.as_of_date - 28 AS in_28d,
        COALESCE(d.accel_load, 0) AS accel_load,
        COALESCE(d.distance_m, 0) AS distance_m,
        COALESCE(d.high_speed_distance_m, 0) AS high_speed_distance_m,
        d.coverage,
        d.athlete_id IS NOT NULL AS had_session
    FROM span AS sp
    CROSS JOIN LATERAL generate_series(sp.start_date, sp.end_date, interval '1 day') AS day
    LEFT JOIN daily_aggregates AS d
        ON d.athlete_id = sp.athlete_id
       AND d.metric_date = day::date
),
ordered AS (
    SELECT
        athlete_id,
        metric_date,
        accel_load,
        row_number() OVER (PARTITION BY athlete_id ORDER BY metric_date) AS n
    FROM series
),
ewma AS (
    SELECT
        athlete_id,
        metric_date,
        n,
        accel_load AS ewma_7d,
        accel_load AS ewma_28d
    FROM ordered
    WHERE n = 1

    UNION ALL

    SELECT
        o.athlete_id,
        o.metric_date,
        o.n,
        (0.25 * o.accel_load) + (0.75 * e.ewma_7d),
        ((2.0 / 29.0) * o.accel_load) + ((1.0 - (2.0 / 29.0)) * e.ewma_28d)
    FROM ordered AS o
    JOIN ewma AS e
        ON e.athlete_id = o.athlete_id
       AND o.n = e.n + 1
),
latest_ewma AS (
    SELECT DISTINCT ON (athlete_id)
        athlete_id,
        ewma_7d,
        ewma_28d
    FROM ewma
    ORDER BY athlete_id, metric_date DESC
),
rolled AS (
    SELECT
        s.athlete_id,
        s.as_of_date,
        s.position,
        sum(s.accel_load) FILTER (WHERE s.in_7d) AS load_7d,
        sum(s.accel_load) FILTER (WHERE s.in_28d) AS load_28d,
        sum(s.distance_m) FILTER (WHERE s.in_7d) AS distance_7d,
        sum(s.distance_m) FILTER (WHERE s.in_28d) AS distance_28d,
        sum(s.high_speed_distance_m) FILTER (WHERE s.in_7d) AS hsd_7d,
        sum(s.high_speed_distance_m) FILTER (WHERE s.in_28d) AS hsd_28d,
        avg(s.accel_load) FILTER (WHERE s.in_7d) AS mean_load_7d,
        stddev_pop(s.accel_load) FILTER (WHERE s.in_7d) AS sd_load_7d,
        avg(s.coverage) FILTER (WHERE s.in_7d AND s.had_session) AS coverage_7d
    FROM series AS s
    GROUP BY s.athlete_id, s.as_of_date, s.position
),
last_session AS (
    SELECT d.athlete_id, max(d.metric_date) AS metric_date
    FROM daily_aggregates AS d
    JOIN params AS p ON d.metric_date < p.as_of_date
    GROUP BY d.athlete_id
),
prior_injury AS (
    SELECT
        i.athlete_id,
        max(i.occurred_on) AS occurred_on,
        bool_or(i.occurred_on >= p.as_of_date - 90) AS prior_injury_90d
    FROM injuries AS i
    CROSS JOIN params AS p
    WHERE i.time_loss
      AND i.occurred_on < p.as_of_date
    GROUP BY i.athlete_id
)
SELECT
    r.athlete_id,
    r.as_of_date,
    p.feature_set_version,
    COALESCE(
        (
            SELECT max(f.revision)
            FROM rolling_features AS f
            WHERE f.athlete_id = r.athlete_id
              AND f.as_of_date = r.as_of_date
              AND f.feature_set_version = p.feature_set_version
        ),
        0
    ) + 1 AS next_revision,
    r.load_7d,
    r.load_28d,
    e.ewma_7d AS ewma_load_7d,
    e.ewma_28d AS ewma_load_28d,
    e.ewma_7d / NULLIF(e.ewma_28d, 0) AS acwr_ewma,
    r.distance_7d,
    r.distance_28d,
    r.hsd_7d,
    r.hsd_28d,
    r.mean_load_7d / NULLIF(r.sd_load_7d, 0) AS monotony_7d,
    r.load_7d * (r.mean_load_7d / NULLIF(r.sd_load_7d, 0)) AS strain_7d,
    (r.as_of_date - ls.metric_date) AS days_since_session,
    r.coverage_7d,
    (r.as_of_date - pi.occurred_on) AS days_since_injury,
    COALESCE(pi.prior_injury_90d, false) AS prior_injury_90d,
    r.position,
    COALESCE(r.coverage_7d, 0) >= 0.7 AS coverage_ok
FROM rolled AS r
CROSS JOIN params AS p
LEFT JOIN latest_ewma AS e ON e.athlete_id = r.athlete_id
LEFT JOIN last_session AS ls ON ls.athlete_id = r.athlete_id
LEFT JOIN prior_injury AS pi ON pi.athlete_id = r.athlete_id;

-- ---------------------------------------------------------------------------
-- Training. One row per closed athlete-morning.
--
-- :training_date          date         a Sunday. The 9 March 2025 job is the
--                                      one that produced the model used on
--                                      10 March. The 10 March morning itself
--                                      is first included on Sunday 23 March.
-- :training_started_at    timestamptz  when this job started. An injury row
--                                      entered after that is not a label yet.
-- :feature_set_version    int
--
-- A morning is closed when its 7 label days are finished. For as_of_date
-- 10 March those days are 10 March through 16 March, so the morning is closed
-- on 17 March and waits for the Sunday job on 23 March.
-- The holdout is the last 56 closed dates, ending at the newest closed
-- morning. Older closed mornings are the fit. Mornings with coverage_7d
-- under 0.7 are left out, matching the mornings the scorer refuses.
-- ---------------------------------------------------------------------------

WITH params AS (
    SELECT
        :training_date::date AS training_date,
        :training_started_at::timestamptz AS training_started_at,
        :feature_set_version::integer AS feature_set_version
),
closed AS (
    SELECT f.*
    FROM rolling_features AS f
    CROSS JOIN params AS p
    WHERE f.feature_set_version = p.feature_set_version
      AND f.revision = 1
      AND f.as_of_date <= p.training_date - 7
      AND f.coverage_7d >= 0.7
),
bounds AS (
    SELECT
        max(as_of_date) AS latest_as_of,
        max(as_of_date) - 55 AS holdout_start
    FROM closed
),
labeled AS (
    SELECT
        c.athlete_id,
        c.as_of_date,
        c.feature_set_version,
        c.load_7d,
        c.load_28d,
        c.ewma_load_7d,
        c.ewma_load_28d,
        c.acwr_ewma,
        c.distance_7d,
        c.distance_28d,
        c.hsd_7d,
        c.hsd_28d,
        c.monotony_7d,
        c.strain_7d,
        c.days_since_session,
        c.coverage_7d,
        c.days_since_injury,
        c.prior_injury_90d,
        c.position,
        c.feature_hash,
        EXISTS (
            SELECT 1
            FROM injuries AS i
            CROSS JOIN params AS p
            WHERE i.athlete_id = c.athlete_id
              AND i.time_loss
              AND i.occurred_on BETWEEN c.as_of_date AND c.as_of_date + 6
              AND i.recorded_at < p.training_started_at
        ) AS injured,
        CASE
            WHEN c.as_of_date >= b.holdout_start THEN 'holdout'
            ELSE 'fit'
        END AS split
    FROM closed AS c
    CROSS JOIN bounds AS b
)
SELECT
    athlete_id,
    as_of_date,
    feature_set_version,
    split,
    CASE WHEN injured THEN 1 ELSE 0 END AS label,
    load_7d,
    load_28d,
    ewma_load_7d,
    ewma_load_28d,
    acwr_ewma,
    distance_7d,
    distance_28d,
    hsd_7d,
    hsd_28d,
    monotony_7d,
    strain_7d,
    days_since_session,
    coverage_7d,
    days_since_injury,
    prior_injury_90d,
    position,
    feature_hash
FROM labeled
ORDER BY as_of_date, athlete_id;
