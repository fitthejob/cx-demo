# ---------------------------------------------------------------
# Hours of Operation & Holiday Schedules — dev environment
# ---------------------------------------------------------------
# HOW TO ADD A SCHEDULE
#   1. Add a new entry to the hours_of_operation map below.
#   2. Open a PR. CI will plan the change and show the new schedule
#      resource in the plan output.
#   3. Merge. The apply creates the schedule in Connect.
#
# HOW TO ADD A COMPANY-SPECIFIC CLOSURE
#   Add an entry to holiday_closures below. US federal holidays are
#   computed automatically by the daily Lambda — only add company-
#   specific closures here (shutdown days, office moves, etc.).
#
# FIELD REFERENCE — hours_of_operation
#   Key           Unique identifier (lowercase, hyphens only)
#   name          Display name
#   description   Plain-text description
#   time_zone     IANA time zone (e.g. America/New_York)
#   config        List of day/time entries: [{day, start_hour, start_minute, end_hour, end_minute}]
#
# FIELD REFERENCE — holiday_closures
#   date          ISO 8601 date (YYYY-MM-DD)
#   name          Holiday name
#   schedule_keys List of schedule keys this applies to, or ["ALL"]
# ---------------------------------------------------------------

hours_of_operation = {

  standard-business = {
    name        = "standard-business"
    description = "Monday-Friday 08:00-18:00 ET — standard business hours"
    time_zone   = "America/New_York"
    config = [
      { day = "MONDAY",    start_hour = 8, start_minute = 0, end_hour = 18, end_minute = 0 },
      { day = "TUESDAY",   start_hour = 8, start_minute = 0, end_hour = 18, end_minute = 0 },
      { day = "WEDNESDAY", start_hour = 8, start_minute = 0, end_hour = 18, end_minute = 0 },
      { day = "THURSDAY",  start_hour = 8, start_minute = 0, end_hour = 18, end_minute = 0 },
      { day = "FRIDAY",    start_hour = 8, start_minute = 0, end_hour = 18, end_minute = 0 },
    ]
  }

  extended = {
    name        = "extended"
    description = "Monday-Saturday 07:00-21:00 ET — extended hours"
    time_zone   = "America/New_York"
    config = [
      { day = "MONDAY",    start_hour = 7, start_minute = 0, end_hour = 21, end_minute = 0 },
      { day = "TUESDAY",   start_hour = 7, start_minute = 0, end_hour = 21, end_minute = 0 },
      { day = "WEDNESDAY", start_hour = 7, start_minute = 0, end_hour = 21, end_minute = 0 },
      { day = "THURSDAY",  start_hour = 7, start_minute = 0, end_hour = 21, end_minute = 0 },
      { day = "FRIDAY",    start_hour = 7, start_minute = 0, end_hour = 21, end_minute = 0 },
      { day = "SATURDAY",  start_hour = 7, start_minute = 0, end_hour = 21, end_minute = 0 },
    ]
  }

  twenty-four-seven = {
    name        = "twenty-four-seven"
    description = "24/7 — always open"
    time_zone   = "America/New_York"
    config = [
      { day = "MONDAY",    start_hour = 0, start_minute = 0, end_hour = 23, end_minute = 59 },
      { day = "TUESDAY",   start_hour = 0, start_minute = 0, end_hour = 23, end_minute = 59 },
      { day = "WEDNESDAY", start_hour = 0, start_minute = 0, end_hour = 23, end_minute = 59 },
      { day = "THURSDAY",  start_hour = 0, start_minute = 0, end_hour = 23, end_minute = 59 },
      { day = "FRIDAY",    start_hour = 0, start_minute = 0, end_hour = 23, end_minute = 59 },
      { day = "SATURDAY",  start_hour = 0, start_minute = 0, end_hour = 23, end_minute = 59 },
      { day = "SUNDAY",    start_hour = 0, start_minute = 0, end_hour = 23, end_minute = 59 },
    ]
  }

}

# ---------------------------------------------------------------
# Company-specific closure dates
# ---------------------------------------------------------------
# US federal holidays are computed automatically by the daily Lambda.
# Only add company-specific closures here (shutdown days, office moves, etc.)

holiday_closures = []
