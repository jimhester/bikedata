#' Filter a trip matrix by date and/or time
#'
#' @param bikedb A string containing the path to the SQLite3 database.
#' If no directory specified, it is presumed to be in \code{tempdir()}.
#' @param ... Additional arguments including start_time, end_time, start_date,
#' end_date, and weekday
#'
#' @return A modified version of the \code{trips} table from \code{bikedb},
#' filtered by the specified times
#'
#' @noRd
filter_bike_tripmat <- function (bikedb, ...)
{
    # NOTE that this approach is much more efficient than the `dplyr::filter`
    # command, because that can only be applied to the entire datetime field:
    # dplyr::filter (trips, start_time > "2014-07-07 00:00:00",
    #                       start_time < "2014-07-10 23:59:59")
    # ... and there is no direct way to filter based on distinct dates AND
    # times, nor can the SQL `date` and `time` functions be applied through
    # dplyr.
    x <- as.list (...)
    qryargs <- c()
    qry <- paste("SELECT s1.stn_id AS start_station_id,",
                 "s2.stn_id AS end_station_id, iq.numtrips",
                 "FROM stations s1, stations s2 LEFT OUTER JOIN",
                 "(SELECT start_station_id, end_station_id,",
                 "COUNT(*) as numtrips FROM trips")

    qry_dt <- NULL
    if ('start_date' %in% names (x)) {
      qry_dt <- c (qry_dt, "stop_time >= ?")
      qryargs <- c (qryargs, paste(x$start_date, '00:00:00'))
    }
    if ('end_date' %in% names (x)) {
      qry_dt <- c (qry_dt, "start_time <= ?")
      qryargs <- c (qryargs, paste(x$end_date, '23:59:59'))
    }
    if ('start_time' %in% names (x)) {
      qry_dt <- c (qry_dt, "time(stop_time) >= ?")
      qryargs <- c (qryargs, x$start_time)
    }
    if ('end_time' %in% names (x)) {
      qry_dt <- c (qry_dt, "time(start_time) <= ?")
      qryargs <- c (qryargs, x$end_time)
    }

    qry_wd <- NULL
    if ('weekday' %in% names (x))
    {
        qry_wd <- "strftime('%w', start_time) IN "
        qry_wd <- paste0(qry_wd, " (",
                         paste (rep("?", times = length(x$weekday)),
                                collapse = ", "), ")")
        qry_dt <- c (qry_dt, qry_wd)
        qryargs <- c (qryargs, x$weekday)
    }

    qry_demog <- NULL
    if ('member' %in% names (x))
    {
        qry_demog <- c (qry_demog, "user_type = ?")
        qryargs <- c (qryargs, x$member)
    }
    if ('birth_year' %in% names (x))
    {
        if (length (x$birth_year) == 1)
        {
            qry_demog <- c (qry_demog, "birth_year = ?")
            qryargs <- c (qryargs, x$birth_year)
        } else
        {
            qry_demog <- c (qry_demog, "birth_year >= ?", "birth_year <= ?")
            qryargs <- c (qryargs, min (x$birth_year), max (x$birth_year))
        }
    }
    if ('gender' %in% names (x))
    {
        qry_demog <- c (qry_demog, "gender = ?")
        qryargs <- c (qryargs, x$gender)
    }
    qry_dt <- c (qry_dt, qry_demog)

    qry <- paste (qry, "WHERE", paste (qry_dt, collapse = " AND "))
    qry <- paste (qry, "GROUP BY start_station_id, end_station_id) iq",
                  "ON s1.stn_id = iq.start_station_id AND",
                  "s2.stn_id = iq.end_station_id")

    if ('city' %in% names (x))
    {
        qry <- paste (qry, "WHERE s1.city = ? AND s2.city = ?")
        qryargs <- c (qryargs, rep (x$city, 2))
    }

    qry <- paste (qry, "ORDER BY s1.stn_id, s2.stn_id")

    qryres <- RSQLite::dbSendQuery (bikedb, qry)
    RSQLite::dbBind(qryres, as.list(qryargs))
    trips <- RSQLite::dbFetch(qryres)
    RSQLite::dbClearResult(qryres)

    return(trips)
}

#' Calculation station weights for standardising trip matrix by operating
#' durations of stations
#'
#' @param bikedb A string containing the path to the SQLite3 database.
#' If no directory specified, it is presumed to be in \code{tempdir()}.
#' @param city City for which standarisation is desired
#'
#' @return A vector of weights for each station of designated city. Weights are
#' standardised to sum to nstations, so overall numbers of trips remain the
#' same.
#'
#' @noRd
bike_tripmat_standardisation <- function (bikedb, city)
{
    dates <- bike_station_dates (bikedb, city = 'ch')
    wt <- 1 / dates$ndays # shorter durations are weighted higher
    wt <- wt * nrow (dates) / sum (wt)
    names (wt) <- dates$station

    return (wt)
}


#' Extract station-to-station trip matrix or data.frame from SQLite3 database
#'
#' @param bikedb A string containing the path to the SQLite3 database.
#' If no directory specified, it is presumed to be in \code{tempdir()}.
#' @param city City for which tripmat is to be aggregated
#' @param start_date If given (as year, month, day) , extract only those records
#' from and including this date
#' @param end_date If given (as year, month, day), extract only those records to
#' and including this date
#' @param start_time If given, extract only those records starting from and
#' including this time of each day
#' @param end_time If given, extract only those records ending at and including
#' this time of each day
#' @param weekday If given, extract only those records including the nominated
#' weekdays. This can be a vector of numeric, starting with Sunday=1, or
#' unambiguous characters, so "sa" and "tu" for Saturday and Tuesday.
#' @param member If given, extract only trips by registered members
#' (\code{member = 1} or \code{TRUE}) or not (\code{member = 0} or \code{FASE}).
#' @param birth_year If given, extract only records for trips by registered
#' using giving birth_years within stated values (either single value or
#' continuous range).
#' @param gender If given, extract only records for trips by registered
#' using giving the specified genders (\code{f/m/.} or \code{2/1/0}).
#' @param standardise If TRUE, numbers of trips are standardised to the
#' operating durations of each stations, so trip numbers are increased for
#' stations that have only operated a short time, and vice versa.
#' @param long If FALSE, a square tripmat of (num-stations, num_stations) is
#' returns; if TRUE, a long-format matrix of (stn-from, stn-to, ntrips) is
#' returned.
#' @param quiet If FALSE, progress is displayed on screen
#'
#' @return If \code{long = FALSE}, a square matrix of numbers of trips between
#' each station, otherwise a long-form data.frame with three columns of of
#' (start_station, end_station, num_trips)
#'
#' @note The \code{city} parameter should be given for databases containing data
#' from multiple cities, otherwise most of the resultant trip matrix is likely
#' to be empty.  Both dates and times may be given either in numeric or
#' character format, with arbitrary (or no) delimiters between fields. Single
#' numeric times are interpreted as hours, with 24 interpreted as day's end at
#' 23:59:59.
#'
#' @export
bike_tripmat <- function (bikedb, city, start_date, end_date,
                          start_time, end_time, weekday,
                          member, birth_year, gender,
                          standardise = FALSE,
                          long = FALSE, quiet = FALSE)
{
    if (dirname (bikedb) == '.')
        bikedb <- file.path (tempdir (), bikedb)

    db_cities <- bike_cities_in_db (bikedb)
    if (missing (city) & length (db_cities) > 1)
    {
        db_cities <- paste (db_cities, collapse = ' ')
        message ('Calls to tripmat should specify city; cities in current ',
                 'database are [', db_cities, ']')
    } else if (!missing (city))
        if (!city %in% bike_cities_in_db (bikedb))
            stop ('city ', city, ' not represented in database')

    db <- RSQLite::dbConnect (RSQLite::SQLite(), bikedb, create = FALSE)

    x <- NULL
    if (!missing (city))
        x <- c (x, 'city' = city)
    if (!missing (start_date))
        x <- c (x, 'start_date' = paste (lubridate::ymd (start_date)))
    if (!missing (end_date))
        x <- c (x, 'end_date' = paste (lubridate::ymd (end_date)))
    if (!missing (start_time))
        x <- c (x, 'start_time' = convert_hms (start_time))
    if (!missing (end_time))
        x <- c (x, 'end_time' = convert_hms (end_time))
    if (!missing (weekday))
        x <- c (x, 'weekday' = list (convert_weekday (weekday)))

    if ( (!missing (member) | !missing (birth_year) | !missing (gender)) &
        (!any (c ('bo', 'ch', 'ny') %in% db_cities)))
        stop ('Only Boston, Chicago, and New York provide demographic data')
    if (!missing (member))
    {
        if (!is.logical (member) | !(member %in% 0:1))
            stop ('member must be TRUE/FALSE or 1/0')
        if (!member)
            member <- 0
        else if (member)
            member <- 1
        x <- c (x, 'member' = member)
    }
    if (!missing (birth_year))
    {
        if (!is.numeric (birth_year))
            stop ('birth_year must be numeric')
        x <- c (x, 'birth_year' = birth_year)
    }
    if (!missing (gender))
    {
        if (!(is.numeric (gender) | is.character (gender)))
            stop ('gender must be numeric or character')
        if (is.character (gender))
        {
            gender <- tolower (substring (gender, 1, 1))
            if (gender == 'f')
                gender <- 2
            else if (gender == 'm')
                gender <- 1
            else if (is.numeric (gender))
                gender <- 0
        }
        x <- c (x, 'gender' = gender)
    }

    if ( (missing (city) & length (x) > 0) |
        (!missing (city) & length (x) > 1) )
    {
        trips <- filter_bike_tripmat (db, x)
    } else
    {
        qry <- paste("SELECT s1.stn_id AS start_station_id,",
                     "s2.stn_id AS end_station_id, iq.numtrips",
                     "FROM stations s1, stations s2 LEFT OUTER JOIN",
                     "(SELECT start_station_id, end_station_id,",
                     "COUNT(*) as numtrips FROM trips",
                     "GROUP BY start_station_id, end_station_id) iq",
                     "ON s1.stn_id = iq.start_station_id AND",
                     "s2.stn_id = iq.end_station_id")
        if (!missing (city))
            qry <- paste0 (qry, " WHERE s1.city = '", city,
                           "' AND s2.city = '", city, "'")
        qry <- paste (qry, "ORDER BY s1.stn_id, s2.stn_id")
        trips <- RSQLite::dbGetQuery (db, qry)
    }

    RSQLite::dbDisconnect(db)

    if (standardise)
    {
        wts <- bike_tripmat_standardisation (bikedb, city)
        wts_start <- wts [match (trips$start_station_id, names (wts))]
        wts_end <- wts [match (trips$end_station_id, names (wts))]
        trips$numtrips <- trips$numtrips *
            do.call (pmin, data.frame (wts_start, wts_end) [-1])
        # Then round to 3 places
        trips$numtrips <- round (trips$numtrips, digits = 3)
    }

    if (!long)
    {
        trips <- reshape2::dcast (trips, start_station_id ~ end_station_id,
                                  value.var = "numtrips", fill = 0)
        row.names (trips) <- trips$start_station_id
        trips$start_station_id <- NULL
        trips <- as.matrix (trips)
    } else
    {
        trips$numtrips <- ifelse (is.na (trips$numtrips) == TRUE, 0,
                                  trips$numtrips)
    }

    return (trips)
}
