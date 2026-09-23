
# Packages are provided by mt-climate-office/actions/setup-geospatial in CI;
# duckdb and duckplyr come through the workflow's `extra-r-packages`.
#
# duckplyr is deliberately *not* attached: `library(duckplyr)` would route every
# dplyr verb in this script through DuckDB. Its verbs are called with the
# `duckplyr::` prefix on the one input that needs them (the Farm Payment Files
# read), and dplyr dispatches on the duckdb-backed frame from there.

library(magrittr)
library(tidyverse)
library(arrow)

source("R/s3-archive.R")

# SFSA_DRY_RUN=1 runs the whole analysis and renders the README without
# touching AWS, for local verification.
publish <- !nzchar(Sys.getenv("SFSA_DRY_RUN"))
if (publish) s3_preflight()
s3_bucket_name <- Sys.getenv("S3_BUCKET", unset = "sustainable-fsa")
s3_prefix      <- Sys.getenv("S3_PREFIX", unset = "fsa-lfp-payments-derived")

## ---- Inputs ----------------------------------------------------------
## Everything is read over HTTPS from companion archives; no credentials.

URL_BASE <- "https://data.sustainable-fsa.com"
URLS <- list(
  `fsa-lfp-eligibility-derived` =
    file.path(URL_BASE, "fsa-lfp-eligibility-derived/fsa-lfp-eligibility-derived.parquet"),
  `fsa-lfp-eligibility-derived/_manifest.txt` =
    file.path(URL_BASE, "fsa-lfp-eligibility-derived/_manifest.txt"),
  `fsa-lfp-eligibility` =
    file.path(URL_BASE, "fsa-lfp-eligibility/fsa-lfp-eligibility.parquet"),
  `fsa-normal-grazing-period` =
    file.path(URL_BASE, "fsa-normal-grazing-period/fsa-normal-grazing-period.parquet"),
  `fsa-counties-dd22` =
    file.path(URL_BASE, "fsa-counties-dd22/fsa-counties-dd22.parquet"),
  `fsa-payment-files/_manifest.txt` =
    file.path(URL_BASE, "fsa-payment-files/_manifest.txt")
)

# The four USDM county aggregations the derived archive carries. Three drive
# the attribution below; the Census-2020 aggregation is carried for reference.
SOURCES <- c("usdm-counties", "usdm-counties-census-2020",
             "usdm-counties-fsa-lfp", "usdm-counties-reported")

LFP_PROGRAMS <- c(
  "LIVESTOCK FORAGE PROGRAM",
  "LIVESTOCK FORAGE DISASTER PROGRAM",
  "LIVESTOCK FORAGE DISASTER PROGRAM (COF)"
)

DISCREPANCY_TYPES    <- c("None", "Type 1", "Type 2", "Type 3", "Multiple")
DISCREPANCY_SUBTYPES <- c("Overpaid", "Cap-consistent", "Unexplained",
                          "Not determined")
SCENARIOS <- c("Boundary (Type 1)", "Threshold (Type 2)",
               "Payment Months (Type 3)", "All Issues (Sum of Types)",
               "All Issues (Census)")
TYPE_SCENARIOS <- c(`Type 1` = "Boundary (Type 1)",
                    `Type 2` = "Threshold (Type 2)",
                    `Type 3` = "Payment Months (Type 3)")

# Fail with the count and a sample, so a CI log alone identifies the cause.
assert_empty <- function(offenders, what) {
  if (nrow(offenders) == 0L) {
    return(invisible(NULL))
  }
  stop("Validation failed — ", what, ": ", nrow(offenders), " record(s).\n",
       paste(
         utils::capture.output(print(utils::head(offenders, 10L), width = 200)),
         collapse = "\n"
       ),
       call. = FALSE)
}

# HEAD an input for the provenance record. The ETag is what the workflow's
# precheck compares against the published provenance.json.
http_head <- function(url) {
  res <- curl::curl_fetch_memory(url, handle = curl::new_handle(nobody = TRUE))
  hdr <- curl::parse_headers_list(res$headers)
  list(url = url,
       status = res$status_code,
       etag = hdr[["etag"]] %||% NA_character_,
       last_modified = hdr[["last-modified"]] %||% NA_character_)
}

provenance_inputs <- purrr::imap(URLS, \(url, name) c(list(name = name), http_head(url)))

## ---- FSA's determinations (FOIA) ------------------------------------
## `Payment Factor` is the payable number of monthly payments:
## min(Drought Factor, Maximum Eligible Payment Months). Fire rows carry no
## Payment Factor and are not drought determinations, so they are dropped.

fsa_lfp_eligibility <-
  arrow::read_parquet(URLS$`fsa-lfp-eligibility`) |>
  dplyr::filter(`Disaster Type` == "Drought") |>
  dplyr::transmute(
    `FSA FIPS` = stringr::str_c(`FIPS State Code`, `FIPS County Code`),
    `FSA County` = stringr::str_c(`FSA State Code`, `FSA County Code`),
    `Program Year` = as.integer(`Program Year`),
    `Pasture Type`,
    `FSA Drought Factor` = as.integer(`Drought Factor`),
    `FSA Maximum Eligible Payment Months` =
      as.integer(`Maximum Eligible Payment Months`),
    `FSA Payment Factor` = as.integer(`Payment Factor`)
  )

# The program years in scope are the years FSA has determined. The derived
# archive runs a year ahead (it computes the current season weekly); those rows
# have nothing to be compared against yet and are held back until the FOIA
# archive catches up.
program_years <- range(fsa_lfp_eligibility$`Program Year`)
in_scope <- function(year) dplyr::between(year, program_years[1], program_years[2])

assert_empty(
  fsa_lfp_eligibility |>
    dplyr::count(`FSA County`, `Program Year`, `Pasture Type`) |>
    dplyr::filter(n > 1L),
  "duplicate (FSA county, Program Year, Pasture Type) keys in FSA's determinations"
)
assert_empty(
  fsa_lfp_eligibility |>
    dplyr::filter(is.na(`FSA Payment Factor`) |
                    nchar(`FSA County`) != 5L | nchar(`FSA FIPS`) != 5L),
  "FSA drought determinations with a missing Payment Factor or malformed county code"
)
assert_empty(
  fsa_lfp_eligibility |>
    dplyr::filter(!is.na(`FSA Maximum Eligible Payment Months`),
                  `FSA Payment Factor` !=
                    pmin(`FSA Drought Factor`, `FSA Maximum Eligible Payment Months`)),
  "FSA Payment Factor not equal to min(Drought Factor, Maximum Eligible Payment Months)"
)

## ---- Months earned under each USDM county aggregation ---------------
## The derived archive is at event grain and keeps only escalating events, so
## the highest drought factor in a group is the months that season earned.

lfp_eligibility_derived <-
  arrow::read_parquet(URLS$`fsa-lfp-eligibility-derived`) |>
  dplyr::mutate(dplyr::across(dplyr::where(is.factor), as.character),
                `Program Year` = as.integer(`Program Year`)) |>
  dplyr::filter(in_scope(`Program Year`))

derived_months <-
  lfp_eligibility_derived |>
  dplyr::group_by(FIPS, `FSA County`, source, `Program Year`, `Pasture Type`) |>
  dplyr::summarise(Months = max(`Drought Factor`), .groups = "drop") |>
  tidyr::pivot_wider(names_from = source, values_from = Months)

if (!all(SOURCES %in% names(derived_months))) {
  stop("The derived archive is missing an aggregation: ",
       paste(setdiff(SOURCES, names(derived_months)), collapse = ", "),
       call. = FALSE)
}

## ---- The universe: Normal Grazing Periods on both county keys -------
## An LFP determination needs an FSA county (which sets the grazing period) and
## a Census county (which the USDM is aggregated to). The two do not nest, so
## the crosswalk join is many-to-many and the pair is carried unreduced — the
## same construction the derived archive uses. See README.

fsa_county_crosswalk <-
  arrow::read_parquet(URLS$`fsa-counties-dd22`,
                      col_select = c("FSA_STCOU", "FIPS_C")) |>
  dplyr::transmute(`FSA County` = FSA_STCOU, FIPS = FIPS_C) |>
  dplyr::distinct()

fsa_normal_grazing_period_raw <-
  arrow::read_parquet(URLS$`fsa-normal-grazing-period`) |>
  dplyr::transmute(
    `Program Year` = as.integer(`Program Year`),
    `FSA County` = stringr::str_c(`State FSA Code`, `County FSA Code`),
    `Pasture Type`,
    `Grazing Period Start Date`,
    `Grazing Period End Date`
  ) |>
  dplyr::filter(in_scope(`Program Year`))

assert_empty(
  fsa_normal_grazing_period_raw |>
    dplyr::distinct(`FSA County`) |>
    dplyr::anti_join(fsa_county_crosswalk, by = "FSA County"),
  "FSA counties in the Normal Grazing Period archive absent from dd22"
)

universe <-
  fsa_normal_grazing_period_raw |>
  dplyr::inner_join(fsa_county_crosswalk,
                    by = "FSA County",
                    relationship = "many-to-many") |>
  # The briefing's convention: months as days / 30, so the cap test below
  # reads "the grazing period is shorter than one more whole month".
  dplyr::mutate(
    `Grazing Months` =
      as.numeric(`Grazing Period End Date` - `Grazing Period Start Date`) / 30
  ) |>
  dplyr::select(FIPS, `FSA County`, `Program Year`, `Pasture Type`,
                `Grazing Period Start Date`, `Grazing Period End Date`,
                `Grazing Months`)

assert_empty(
  universe |>
    dplyr::count(`Program Year`, FIPS, `FSA County`, `Pasture Type`) |>
    dplyr::filter(n > 1L),
  "duplicate (Program Year, FIPS, FSA county, Pasture Type) grazing periods"
)

## ---- Actual LFP disbursements, aggregated to FSA county and year ----
## The Farm Payment Files archive is served over HTTPS via CloudFront, which
## has no directory listing, so the archive publishes `_manifest.txt`: every
## file URL, regenerated on each data update. DuckDB's httpfs extension reads
## those URLs directly, with no credentials.
##
## The archive is hive-partitioned by state and program year, so subsetting the
## manifest is the cheapest form of partition pruning: excluded partitions are
## never fetched. Keeping the years in scope also drops the `0`, `9999` and
## `__HIVE_DEFAULT_PARTITION__` partitions that hold malformed source years.

invisible(duckplyr::db_exec("INSTALL httpfs; LOAD httpfs;"))

payment_files <-
  readLines(URLS$`fsa-payment-files/_manifest.txt`) |>
  stringr::str_subset(
    seq(program_years[1], program_years[2]) |>
      paste(collapse = "|") |>
      sprintf(fmt = "Accounting%%20Program%%20Year=(%s)/")
  )

# Because the URLs are percent-encoded, the hive partition columns surface
# encoded — hence the backtick-quoted `Accounting%20Program%20Year`, renamed
# once the aggregate is small. Columns stored inside the Parquet files keep
# their plain names. The filter and sum run in DuckDB, which reads only the
# three columns it needs from each remote file; the aggregate is all that
# comes back to R.
lfp_payments <-
  payment_files |>
  duckplyr::read_parquet_duckdb(
    options = list(hive_partitioning = TRUE),
    prudence = "lavish"
  ) |>
  dplyr::filter(`Accounting Program Description` %in% LFP_PROGRAMS) |>
  dplyr::summarise(
    `Disbursement Amount` = sum(`Disbursement Amount`, na.rm = TRUE),
    .by = c(`FSA Code`, `Accounting%20Program%20Year`)
  ) |>
  tibble::as_tibble() |>
  dplyr::transmute(
    `FSA County` = as.character(`FSA Code`),
    `Program Year` = as.integer(`Accounting%20Program%20Year`),
    `Disbursement Amount` = round(`Disbursement Amount`, 2)
  ) |>
  dplyr::arrange(`FSA County`, `Program Year`)

assert_empty(
  lfp_payments |>
    dplyr::filter(is.na(`FSA County`) | nchar(`FSA County`) != 5L |
                    !in_scope(`Program Year`)),
  "LFP disbursements with a malformed FSA county code or an out-of-scope year"
)
assert_empty(
  lfp_payments |>
    dplyr::count(`FSA County`, `Program Year`) |>
    dplyr::filter(n > 1L),
  "duplicate (FSA county, Program Year) disbursement aggregates"
)

## ---- Records: months warranted vs months paid -----------------------
## One record per Census county, FSA county, program year and pasture type.
##
## Inside the universe, absence means zero: a county-pasture-year with no
## qualifying event in an aggregation earned 0 months under it, and one FSA
## never listed as eligible was paid 0 months. Zero-filling is what lets the
## "warranted but never determined" and "paid where no aggregation supports
## it" cases appear in the data at all. Records outside the universe — FSA
## determinations with no published grazing period — keep their NAs, receive
## no discrepancy type, and are enumerated in the QA report.

KEYS <- c("FIPS", "FSA County", "Program Year", "Pasture Type")

# Warranted-to-paid ratio. Agreement is 1 whatever the level; a zero on either
# side leaves no disbursement to scale (paid = 0) or would claim a full
# clawback (warranted = 0), and neither is estimated here — those records are
# counted in the QA report instead.
payment_ratio <- function(warranted, paid) {
  dplyr::case_when(
    is.na(warranted) | is.na(paid) ~ NA_real_,
    warranted == paid ~ 1,
    warranted == 0L | paid == 0L ~ NA_real_,
    .default = warranted / paid
  )
}

records <-
  universe |>
  dplyr::full_join(derived_months, by = KEYS) |>
  dplyr::full_join(fsa_lfp_eligibility,
                   by = c("FSA County", "Program Year", "Pasture Type"),
                   relationship = "many-to-one") |>
  dplyr::mutate(
    FIPS = dplyr::coalesce(FIPS, `FSA FIPS`),
    `In Universe` = !is.na(`Grazing Period Start Date`),
    dplyr::across(dplyr::all_of(SOURCES),
                  \(x) dplyr::if_else(`In Universe` & is.na(x), 0L, x)),
    `FSA Payment Factor` =
      dplyr::if_else(`In Universe` & is.na(`FSA Payment Factor`),
                     0L, `FSA Payment Factor`)
  ) |>
  dplyr::select(!`FSA FIPS`) |>
  dplyr::mutate(
    # Attribute each record to at most one issue. Type 1: only the boundary
    # file changes the class. Type 2: the reported class departs from a
    # recomputation on NDMC's own boundary file. Type 3: the drought record
    # and the determination agree on the class but not on the months paid.
    # "Multiple" marks records where the authoritative recomputation and the
    # determination differ but no single issue accounts for it.
    `Discrepancy Type` =
      dplyr::case_when(
        !`In Universe` ~ NA_character_,
        (`usdm-counties` != `usdm-counties-fsa-lfp`) &
          (`usdm-counties-fsa-lfp` == `usdm-counties-reported`) &
          (`usdm-counties-reported` == `FSA Payment Factor`) ~ "Type 1",
        (`usdm-counties-fsa-lfp` != `usdm-counties-reported`) &
          (`usdm-counties-reported` == `FSA Payment Factor`) ~ "Type 2",
        (`usdm-counties-fsa-lfp` == `usdm-counties-reported`) &
          (`usdm-counties-reported` != `FSA Payment Factor`) ~ "Type 3",
        `usdm-counties` != `FSA Payment Factor` ~ "Multiple",
        .default = "None"
      ),
    # Within Type 3: paid more than the class supports; paid less and the
    # months paid equal the whole-month floor of the grazing period (the
    # undocumented cap); paid less with a grazing period long enough to carry
    # more months (nothing documented explains these); or never determined.
    `Discrepancy Subtype` =
      dplyr::case_when(
        is.na(`Discrepancy Type`) | `Discrepancy Type` != "Type 3" ~ NA_character_,
        `FSA Payment Factor` == 0L ~ "Not determined",
        `FSA Payment Factor` > `usdm-counties-reported` ~ "Overpaid",
        `Grazing Months` < `FSA Payment Factor` + 1 ~ "Cap-consistent",
        .default = "Unexplained"
      ),
    `Discrepancy Payment Ratio` =
      dplyr::case_when(
        `Discrepancy Type` == "Type 1" ~
          payment_ratio(`usdm-counties`, `FSA Payment Factor`),
        `Discrepancy Type` == "Type 2" ~
          payment_ratio(`usdm-counties-fsa-lfp`, `FSA Payment Factor`),
        `Discrepancy Type` == "Type 3" ~
          payment_ratio(`usdm-counties-reported`, `FSA Payment Factor`),
        `Discrepancy Type` == "None" ~ 1,
        .default = NA_real_
      ),
    # The all-in comparison: the authoritative-boundary recomputation against
    # FSA's determination, whatever the reason for the difference.
    `Census Payment Ratio` = payment_ratio(`usdm-counties`, `FSA Payment Factor`)
  ) |>
  dplyr::select(
    dplyr::all_of(KEYS), dplyr::all_of(SOURCES),
    `FSA Drought Factor`, `FSA Maximum Eligible Payment Months`,
    `FSA Payment Factor`, `Grazing Months`,
    `Discrepancy Type`, `Discrepancy Subtype`,
    `Discrepancy Payment Ratio`, `Census Payment Ratio`,
    `In Universe`
  ) |>
  dplyr::arrange(FIPS, `FSA County`, `Program Year`, `Pasture Type`)

## ---- Validation: records --------------------------------------------

assert_empty(
  records |> dplyr::count(dplyr::across(dplyr::all_of(KEYS))) |> dplyr::filter(n > 1L),
  "duplicate record keys"
)
assert_empty(
  records |> dplyr::filter(dplyr::if_any(dplyr::all_of(KEYS), is.na)),
  "records with a missing key"
)
assert_empty(
  records |>
    dplyr::filter(`In Universe`) |>
    dplyr::filter(dplyr::if_any(c(dplyr::all_of(SOURCES), `FSA Payment Factor`,
                                  `Grazing Months`, `Discrepancy Type`), is.na)),
  "in-universe records with a missing months, grazing or discrepancy value"
)
assert_empty(
  records |> dplyr::filter(!`In Universe`, !is.na(`Discrepancy Type`)),
  "out-of-universe records that were classified"
)
assert_empty(
  records |>
    dplyr::filter(`Discrepancy Type` == "None",
                  is.na(`Discrepancy Payment Ratio`) | `Discrepancy Payment Ratio` != 1),
  "records with no discrepancy but a ratio other than 1"
)
assert_empty(
  records |>
    dplyr::filter(dplyr::if_any(c(`Discrepancy Payment Ratio`, `Census Payment Ratio`),
                                \(x) !is.na(x) & (!is.finite(x) | x <= 0))),
  "non-finite or non-positive payment ratios"
)
assert_empty(
  records |>
    dplyr::filter(xor(`Discrepancy Type` %in% "Type 3", !is.na(`Discrepancy Subtype`))),
  "discrepancy subtype present or absent inconsistently with Type 3"
)
assert_empty(
  records |>
    dplyr::filter(`Discrepancy Type` %in% names(TYPE_SCENARIOS),
                  `FSA Payment Factor` > 0L,
                  is.na(`Discrepancy Payment Ratio`),
                  dplyr::case_when(
                    `Discrepancy Type` == "Type 1" ~ `usdm-counties`,
                    `Discrepancy Type` == "Type 2" ~ `usdm-counties-fsa-lfp`,
                    `Discrepancy Type` == "Type 3" ~ `usdm-counties-reported`
                  ) > 0L),
  "attributed records with both sides positive but no ratio"
)

## ---- County-years: scaling actual disbursements ---------------------
## Counties carry several pasture types, and an FSA office may cover several
## Census counties, each with its own ratio; the payment files break
## disbursements out by neither. The smallest and largest ratio among the
## affected records in an FSA county-year therefore bracket the estimate
## rather than pretending to a point value.

scenario_records <-
  dplyr::bind_rows(
    records |>
      dplyr::filter(`Discrepancy Type` %in% names(TYPE_SCENARIOS)) |>
      dplyr::transmute(`FSA County`, `Program Year`,
                       Scenario = unname(TYPE_SCENARIOS[`Discrepancy Type`]),
                       Ratio = `Discrepancy Payment Ratio`),
    records |>
      dplyr::filter(!is.na(`Census Payment Ratio`), `Census Payment Ratio` != 1) |>
      dplyr::transmute(`FSA County`, `Program Year`,
                       Scenario = "All Issues (Census)",
                       Ratio = `Census Payment Ratio`)
  ) |>
  dplyr::filter(!is.na(Ratio))

county_years <-
  scenario_records |>
  dplyr::group_by(`FSA County`, `Program Year`, Scenario) |>
  dplyr::summarise(
    Records = dplyr::n(),
    `Minimum Payment Ratio` = min(Ratio),
    `Maximum Payment Ratio` = max(Ratio),
    .groups = "drop"
  ) |>
  dplyr::left_join(lfp_payments, by = c("FSA County", "Program Year")) |>
  dplyr::mutate(
    `Minimum Additional Disbursement` =
      round((`Minimum Payment Ratio` - 1) * `Disbursement Amount`, 2),
    `Maximum Additional Disbursement` =
      round((`Maximum Payment Ratio` - 1) * `Disbursement Amount`, 2),
    Scenario = factor(Scenario, levels = SCENARIOS)
  ) |>
  dplyr::select(`FSA County`, `Program Year`, Scenario, Records,
                `Disbursement Amount`,
                `Minimum Payment Ratio`, `Maximum Payment Ratio`,
                `Minimum Additional Disbursement`,
                `Maximum Additional Disbursement`) |>
  dplyr::arrange(`FSA County`, `Program Year`, Scenario)

assert_empty(
  county_years |>
    dplyr::count(`FSA County`, `Program Year`, Scenario) |>
    dplyr::filter(n > 1L),
  "duplicate county-year scenario keys"
)
assert_empty(
  county_years |>
    dplyr::filter(`Minimum Payment Ratio` > `Maximum Payment Ratio` |
                    `Minimum Additional Disbursement` > `Maximum Additional Disbursement`),
  "county-years whose minimum exceeds their maximum"
)

## ---- Annual summary -------------------------------------------------
## "All Issues (Sum of Types)" adds the three attributed scenarios; a
## county-year touched by more than one issue is counted once.

annual_paid <-
  lfp_payments |>
  dplyr::group_by(`Program Year`) |>
  dplyr::summarise(`Disbursement Amount` = sum(`Disbursement Amount`),
                   .groups = "drop")

annual <-
  dplyr::bind_rows(
    county_years,
    county_years |>
      dplyr::filter(Scenario %in% TYPE_SCENARIOS) |>
      dplyr::mutate(Scenario = factor("All Issues (Sum of Types)",
                                      levels = SCENARIOS))
  ) |>
  dplyr::group_by(`Program Year`, Scenario) |>
  dplyr::summarise(
    `County Years` = dplyr::n_distinct(`FSA County`, `Program Year`),
    `Minimum Additional Disbursement` =
      sum(`Minimum Additional Disbursement`, na.rm = TRUE),
    `Maximum Additional Disbursement` =
      sum(`Maximum Additional Disbursement`, na.rm = TRUE),
    .groups = "drop"
  ) |>
  tidyr::complete(
    `Program Year` = seq(program_years[1], program_years[2]),
    Scenario = factor(SCENARIOS, levels = SCENARIOS),
    fill = list(`County Years` = 0L,
                `Minimum Additional Disbursement` = 0,
                `Maximum Additional Disbursement` = 0)
  ) |>
  dplyr::left_join(annual_paid, by = "Program Year") |>
  dplyr::mutate(
    `Disbursement Amount` = tidyr::replace_na(`Disbursement Amount`, 0),
    dplyr::across(c(`Minimum Additional Disbursement`,
                    `Maximum Additional Disbursement`),
                  \(x) round(x, 2))
  ) |>
  dplyr::select(`Program Year`, Scenario, `Disbursement Amount`, `County Years`,
                `Minimum Additional Disbursement`,
                `Maximum Additional Disbursement`) |>
  dplyr::arrange(`Program Year`, Scenario)

# The annual table must reproduce the county-year table scenario by scenario.
assert_empty(
  county_years |>
    dplyr::group_by(Scenario) |>
    dplyr::summarise(lo = sum(`Minimum Additional Disbursement`, na.rm = TRUE),
                     hi = sum(`Maximum Additional Disbursement`, na.rm = TRUE),
                     .groups = "drop") |>
    dplyr::inner_join(
      annual |>
        dplyr::group_by(Scenario) |>
        dplyr::summarise(lo_a = sum(`Minimum Additional Disbursement`),
                         hi_a = sum(`Maximum Additional Disbursement`),
                         .groups = "drop"),
      by = "Scenario"
    ) |>
    dplyr::filter(abs(lo - lo_a) > 0.01 | abs(hi - hi_a) > 0.01),
  "annual totals that do not reproduce the county-year table"
)

## ---- QA report ------------------------------------------------------

usd <- function(x) {
  if (is.na(x)) return("NA")
  if (abs(x) >= 1e9) sprintf("$%.2fB", x / 1e9)
  else if (abs(x) >= 1e6) sprintf("$%.1fM", x / 1e6)
  else sprintf("$%s", formatC(round(x), format = "d", big.mark = ","))
}
num <- function(x) formatC(x, format = "d", big.mark = ",")

# Detail tables as indented CSV; a tibble's print wraps wide frames across
# several blocks.
qa_detail <- function(x) {
  if (nrow(x) == 0L) {
    return(character(0))
  }
  paste0("  ", strsplit(readr::format_csv(x), "\n", fixed = TRUE)[[1]])
}

type_counts <- records |>
  dplyr::filter(`In Universe`) |>
  dplyr::count(`Discrepancy Type`) |>
  dplyr::mutate(`Discrepancy Type` = factor(`Discrepancy Type`, DISCREPANCY_TYPES)) |>
  dplyr::arrange(`Discrepancy Type`)
subtype_counts <- records |>
  dplyr::filter(`Discrepancy Type` %in% "Type 3") |>
  dplyr::count(`Discrepancy Subtype`) |>
  dplyr::mutate(`Discrepancy Subtype` = factor(`Discrepancy Subtype`, DISCREPANCY_SUBTYPES)) |>
  dplyr::arrange(`Discrepancy Subtype`)

headline <- annual |>
  dplyr::group_by(Scenario) |>
  dplyr::summarise(
    `County Years` = sum(`County Years`),
    Low = sum(`Minimum Additional Disbursement`),
    High = sum(`Maximum Additional Disbursement`),
    .groups = "drop"
  )
paid_total <- sum(annual_paid$`Disbursement Amount`)

qa_unscalable <- records |>
  dplyr::filter(`Discrepancy Type` %in% names(TYPE_SCENARIOS),
                is.na(`Discrepancy Payment Ratio`)) |>
  dplyr::mutate(Reason = dplyr::if_else(`FSA Payment Factor` == 0L,
                                        "FSA paid 0 months",
                                        "aggregation warrants 0 months")) |>
  dplyr::count(`Discrepancy Type`, Reason)

qa_outside_universe <- records |>
  dplyr::filter(!`In Universe`) |>
  dplyr::select(dplyr::all_of(KEYS), `FSA Payment Factor`, dplyr::all_of(SOURCES))

qa_derived_outside_universe <- qa_outside_universe |>
  dplyr::filter(dplyr::if_any(dplyr::all_of(SOURCES), \(x) !is.na(x)))

qa_no_disbursement <- county_years |>
  dplyr::filter(is.na(`Disbursement Amount`)) |>
  dplyr::distinct(`FSA County`, `Program Year`)

qa_paid_undetermined <- lfp_payments |>
  dplyr::anti_join(records |> dplyr::filter(`FSA Payment Factor` > 0L),
                   by = c("FSA County", "Program Year"))

qa_paid_unknown_county <- lfp_payments |>
  dplyr::anti_join(fsa_county_crosswalk, by = "FSA County") |>
  dplyr::group_by(`FSA County`) |>
  dplyr::summarise(Years = dplyr::n(),
                   `Disbursement Amount` = sum(`Disbursement Amount`),
                   .groups = "drop")

qa_negative <- lfp_payments |> dplyr::filter(`Disbursement Amount` < 0)

qa_report <- c(
  "FSA LFP payments, derived — QA report",
  "",
  "Grain: one record per Census county (FIPS), FSA county, program year and",
  "pasture type, carrying the months earned under each USDM county aggregation",
  "and the months FSA paid. Dollar estimates are at FSA county and program year,",
  "the grain of the Farm Payment Files.",
  "",
  paste0("Program years: ", program_years[1], "-", program_years[2],
         " (the latest year is still being disbursed)"),
  paste0("Records: ", num(nrow(records)),
         " (", num(sum(records$`In Universe`)), " with a published grazing period)"),
  paste0("County-year scenario rows: ", num(nrow(county_years))),
  paste0("Annual rows: ", num(nrow(annual))),
  paste0("FSA county-years with LFP disbursements: ", num(nrow(lfp_payments))),
  paste0("LFP disbursed, ", program_years[1], "-", program_years[2], ": ",
         usd(paid_total)),
  "",
  "Invariants enforced (the run aborts on any violation):",
  "  * FSA determinations unique on (FSA county, program year, pasture type),",
  "    with Payment Factor = min(Drought Factor, Maximum Eligible Payment Months)",
  "  * exactly one grazing period per (program year, Census county, FSA county,",
  "    pasture type), every FSA county resolving against dd22",
  "  * unique record keys; no missing months, grazing or discrepancy values on",
  "    records with a published grazing period",
  "  * ratios finite and positive; agreement is exactly 1; a subtype on Type 3",
  "    records only; a ratio present wherever both sides are positive",
  "  * county-year minimums never exceed maximums; annual totals reproduce the",
  "    county-year table",
  "",
  "Records by discrepancy type",
  qa_detail(type_counts),
  "",
  "Type 3 records by subtype",
  qa_detail(subtype_counts),
  "",
  "Estimated additional disbursements by scenario (low-high, all years)",
  qa_detail(headline |>
              dplyr::mutate(Low = purrr::map_chr(Low, usd),
                            High = purrr::map_chr(High, usd))),
  "",
  paste0("Attributed records with no ratio (a zero on one side): ",
         num(sum(qa_unscalable$n))),
  "  These are classified and counted above but scale no disbursement: with",
  "  FSA paying 0 months there is nothing to scale, and an aggregation",
  "  warranting 0 months would claim a full clawback this archive does not",
  "  estimate.",
  qa_detail(qa_unscalable),
  "",
  paste0("FSA determinations with no published grazing period: ",
         num(nrow(qa_outside_universe) - nrow(qa_derived_outside_universe))),
  "  Kept with their Payment Factor, no months under any aggregation, and no",
  "  discrepancy type.",
  paste0("Derived records with no published grazing period: ",
         num(nrow(qa_derived_outside_universe))),
  "  Expected to be zero: the derived archive is built from the same grazing",
  "  periods. A non-zero count means the two archives read different vintages.",
  qa_detail(qa_outside_universe),
  "",
  paste0("County-years with an attributed discrepancy but no LFP disbursement: ",
         num(nrow(qa_no_disbursement))),
  "  Their ratios are published; their additional-disbursement columns are NA.",
  "",
  paste0("Disbursement county-years with no positive FSA determination: ",
         num(nrow(qa_paid_undetermined)), " (",
         usd(sum(qa_paid_undetermined$`Disbursement Amount`)), ")"),
  "  Payments recorded where the FOIA archive lists no eligible pasture type",
  "  that year — late-paid prior-year claims, appeals, or county-code drift.",
  "",
  paste0("Disbursement FSA county codes absent from dd22: ",
         num(nrow(qa_paid_unknown_county))),
  qa_detail(qa_paid_unknown_county),
  "",
  paste0("County-years with a net negative disbursement: ", num(nrow(qa_negative))),
  "",
  "Two county keys",
  "",
  "  Dollars are estimated at FSA county grain because that is how the Farm",
  "  Payment Files record them. Every Census county an FSA office covers",
  "  contributes its ratio to that office's minimum and maximum, and a Census",
  "  county administered by several offices contributes to each office's own",
  "  disbursement separately, so nothing is double counted. The `Records`",
  "  column counts the records bracketing each county-year.",
  ""
)

writeLines(qa_report, "qa-report.txt")
message(paste(qa_report, collapse = "\n"))

## ---- Outputs --------------------------------------------------------
## Mirrored CSV and Parquet, identical records. CSV carries no types, so codes
## like "01001" read back as 1001 in careless readers; Parquet keeps them
## character.

records_out <-
  records |>
  dplyr::select(!`In Universe`) |>
  dplyr::mutate(
    `Grazing Months` = round(`Grazing Months`, 4),
    `Pasture Type` = factor(`Pasture Type`),
    `Discrepancy Type` = factor(`Discrepancy Type`, levels = DISCREPANCY_TYPES),
    `Discrepancy Subtype` = factor(`Discrepancy Subtype`, levels = DISCREPANCY_SUBTYPES)
  )

write_pair <- function(x, stem) {
  readr::write_csv(x, paste0(stem, ".csv"), na = "")
  arrow::write_parquet(x, sink = paste0(stem, ".parquet"),
                       version = "latest",
                       compression = "zstd",
                       compression_level = 13,
                       use_dictionary = TRUE)
}

write_pair(records_out, "fsa-lfp-payments-derived")
write_pair(county_years, "fsa-lfp-payments-derived-county-years")
write_pair(annual, "fsa-lfp-payments-derived-annual")

## ---- Browser-optimized JSON -----------------------------------------
## Column-oriented and dictionary-coded, in the layout of the LFP eligibility
## archives' payload ("fsa-lfp-eligibility/1"), with three record blocks
## because the tables have different grains. Frozen contract
## "fsa-lfp-payments-derived/1": fields may be added; existing ones are never
## renamed or reordered without bumping the schema.

web_types    <- sort(unique(records_out$`Pasture Type` |> as.character()), method = "radix")
web_counties <- sort(unique(c(records_out$`FSA County`, county_years$`FSA County`)),
                     method = "radix")
web_fips     <- sort(unique(records_out$FIPS), method = "radix")
web_year0    <- program_years[1]

web_records <-
  records_out |>
  dplyr::transmute(
    type     = match(as.character(`Pasture Type`), web_types) - 1L,
    county   = match(`FSA County`, web_counties) - 1L,
    fips     = match(FIPS, web_fips) - 1L,
    year     = `Program Year` - web_year0,
    m_census     = `usdm-counties`,
    m_census2020 = `usdm-counties-census-2020`,
    m_lfp        = `usdm-counties-fsa-lfp`,
    m_reported   = `usdm-counties-reported`,
    m_paid   = `FSA Payment Factor`,
    m_cap    = `FSA Maximum Eligible Payment Months`,
    gm       = round(`Grazing Months`, 2),
    disc     = match(as.character(`Discrepancy Type`), DISCREPANCY_TYPES) - 1L,
    sub      = match(as.character(`Discrepancy Subtype`), DISCREPANCY_SUBTYPES) - 1L,
    r_disc   = `Discrepancy Payment Ratio`,
    r_census = `Census Payment Ratio`
  ) |>
  dplyr::arrange(type, county, fips, year)

web_county_years <-
  county_years |>
  dplyr::transmute(
    county   = match(`FSA County`, web_counties) - 1L,
    year     = `Program Year` - web_year0,
    scenario = match(as.character(Scenario), SCENARIOS) - 1L,
    k        = Records,
    paid     = `Disbursement Amount`,
    rmin     = `Minimum Payment Ratio`,
    rmax     = `Maximum Payment Ratio`,
    lo       = `Minimum Additional Disbursement`,
    hi       = `Maximum Additional Disbursement`
  ) |>
  dplyr::arrange(county, year, scenario)

web_annual <-
  annual |>
  dplyr::transmute(
    year     = `Program Year` - web_year0,
    scenario = match(as.character(Scenario), SCENARIOS) - 1L,
    paid     = `Disbursement Amount`,
    k        = `County Years`,
    lo       = `Minimum Additional Disbursement`,
    hi       = `Maximum Additional Disbursement`
  ) |>
  dplyr::arrange(year, scenario)

# Nulls land only where the tables document them.
stopifnot(
  !anyNA(web_records[c("type", "county", "fips", "year", "m_paid")]),
  identical(is.na(web_records$m_census), is.na(web_records$disc)),
  identical(is.na(web_records$sub), web_records$disc != 3L | is.na(web_records$disc)),
  !anyNA(web_county_years[c("county", "year", "scenario", "k", "rmin", "rmax")]),
  identical(is.na(web_county_years$lo), is.na(web_county_years$paid)),
  !anyNA(web_annual)
)

block <- function(x) c(list(n = jsonlite::unbox(nrow(x))), as.list(x))

jsonlite::write_json(
  list(
    schema      = jsonlite::unbox("fsa-lfp-payments-derived/1"),
    dataset     = jsonlite::unbox("fsa-lfp-payments-derived"),
    license     = jsonlite::unbox("CC0-1.0"),
    year0       = jsonlite::unbox(web_year0),
    years       = program_years,
    types       = web_types,
    counties    = web_counties,
    fips_codes  = web_fips,
    discrepancy_types    = DISCREPANCY_TYPES,
    discrepancy_subtypes = DISCREPANCY_SUBTYPES,
    scenarios   = SCENARIOS,
    records      = block(web_records),
    county_years = block(web_county_years),
    annual       = block(web_annual)
  ),
  "fsa-lfp-payments-derived.json",
  auto_unbox = FALSE, digits = NA, na = "null"
)

## ---- Provenance -----------------------------------------------------
## What was read and what came out. No timestamp, so the file changes only
## when an input or a result does; the workflow's precheck compares the
## upstream ETags recorded here against the live archives.

provenance_rows <- c(
  `fsa-lfp-eligibility-derived` = nrow(lfp_eligibility_derived),
  `fsa-lfp-eligibility` = nrow(fsa_lfp_eligibility),
  `fsa-normal-grazing-period` = nrow(fsa_normal_grazing_period_raw),
  `fsa-counties-dd22` = nrow(fsa_county_crosswalk),
  `fsa-payment-files/_manifest.txt` = length(payment_files)
)

jsonlite::write_json(
  list(
    dataset = "fsa-lfp-payments-derived",
    schema = "fsa-lfp-payments-derived/1",
    program_years = program_years,
    inputs = purrr::map(unname(provenance_inputs), \(x) {
      x$rows <- unname(provenance_rows[x$name])
      if (is.na(x$rows)) x$rows <- NULL
      x
    }),
    rows = list(records = nrow(records_out),
                county_years = nrow(county_years),
                annual = nrow(annual)),
    disbursed = paid_total,
    additional = headline |>
      dplyr::transmute(scenario = as.character(Scenario),
                       county_years = `County Years`, low = Low, high = High)
  ),
  "provenance.json",
  pretty = TRUE, auto_unbox = TRUE, digits = NA, na = "null"
)

## ---- Directory listing infrastructure -------------------------------

PUBLISHED <- c(
  "fsa-lfp-payments-derived.csv", "fsa-lfp-payments-derived.parquet",
  "fsa-lfp-payments-derived-county-years.csv",
  "fsa-lfp-payments-derived-county-years.parquet",
  "fsa-lfp-payments-derived-annual.csv",
  "fsa-lfp-payments-derived-annual.parquet",
  "fsa-lfp-payments-derived.json",
  "provenance.json",
  "qa-report.txt"
)

content_type <- function(file) {
  switch(tools::file_ext(file),
         csv = "text/csv",
         parquet = "application/vnd.apache.parquet",
         json = "application/json",
         txt = "text/plain",
         "application/octet-stream")
}

generate_tree_flat <- function(files, output_file = "manifest.json") {
  entries <- lapply(sort(files), function(f) {
    info <- fs::file_info(f)
    list(path = f,
         size = info$size,
         mtime = format(info$modification_time, "%Y-%Om-%d %H:%M:%S"))
  })
  jsonlite::write_json(entries, output_file, pretty = TRUE, auto_unbox = TRUE)
  message("✅ Wrote ", length(entries), " entries to ", output_file)
}

generate_tree_flat(PUBLISHED)

## ---- Publish to S3 --------------------------------------------------

if (publish) {
  for (f in c(PUBLISHED, "manifest.json")) {
    s3_put(s3_bucket_name, paste0(s3_prefix, "/", f), f,
           content_type = content_type(f),
           cache_control = "max-age=3600")
  }
  s3_write_manifest(s3_bucket_name, s3_prefix)
  cf_invalidate(paste0("/", s3_prefix, "/",
                       c(PUBLISHED, "manifest.json", "_manifest.txt")))
  cf_wait_manifest(
    paste0(URL_BASE, "/", s3_prefix, "/manifest.json"),
    "manifest.json"
  )
} else {
  message("SFSA_DRY_RUN set; skipping S3 publish.")
}

## ---- Render the README ----------------------------------------------
# Regenerates README.md and the example figure from the freshly written
# tables; the workflow commits these back to git.
rmarkdown::render("README.Rmd")
