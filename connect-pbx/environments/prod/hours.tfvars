# Production baseline mirrors dev until business-specific hours are finalized.

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

holiday_closures = []
