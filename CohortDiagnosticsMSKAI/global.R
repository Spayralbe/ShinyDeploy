library(magrittr)
#making other peoples results into zip files
#exportfolder<- paste0(outputFolder,"/diagnosticsExport/Results_AEMR")
#zipName <- file.path(outputFolder, paste0("diagnosticsExport/Results_AEMR.zip"))
#files <- list.files(exportfolder, pattern = ".*\\.csv$")
#oldWd <- setwd(exportfolder)
#on.exit(setwd(oldWd), add = TRUE)
#DatabaseConnector::createZipFile(zipFile = zipName, files = files)
#to merge new additional datasets
#if just doing for your own dataset and have copied across a zip,just do these steps!
#CohortDiagnostics::preMergeDiagnosticsFiles(file.path("~/DiagnosticsExplorer/data"))
#CohortDiagnostics::launchDiagnosticsExplorer(file.path("~/DiagnosticsExplorer/data"))
source("R/Tables.R")
source("R/Plots.R")
source("R/Results.R")

# shinySettings <- list(connectionDetails = DatabaseConnector::createConnectionDetails(dbms = "postgresql",
#                                              server = "localhost/ohdsi",
#                                              user = "postgres",
#                                              password = Sys.getenv("pwPostgres")),
#                       resultsDatabaseSchema =  "phenotype_library",
#                       vocabularyDatabaseSchema =  "phenotype_library")
# shinySettings <- list(dataFolder = "s:/examplePackageOutput")

# Settings when running on server:

defaultLocalDataFolder <- "data"
defaultLocalDataFile <- "PreMerged.RData"

connectionPool <- NULL
defaultServer <- Sys.getenv("phenotypeLibraryDbServer")
defaultDatabase <- Sys.getenv("phenotypeLibraryDbDatabase")
defaultPort <- Sys.getenv("phenotypeLibraryDbPort")
defaultUser <- Sys.getenv("phenotypeLibraryDbUser")
defaultPassword <- Sys.getenv("phenotypeLibraryDbPassword")
defaultResultsSchema <- Sys.getenv("phenotypeLibraryDbResultsSchema")
defaultVocabularySchema <- Sys.getenv("phenotypeLibraryDbVocabularySchema")

defaultDatabaseMode <- TRUE # Use file system if FALSE

defaultCohortBaseUrl <- "https://atlas.ohdsi.org/#/cohortdefinition/"
defaultConceptBaseUrl <- "https://athena.ohdsi.org/search-terms/terms/"

cohortDiagnosticModeDefaultTitle <- "Cohort Diagnostics"
phenotypeLibraryModeDefaultTitle <- "Phenotype Library"

if (!exists("shinySettings")) {
  writeLines("Using default settings")
  databaseMode <- defaultDatabaseMode & defaultServer != ""
  if (databaseMode) {
    connectionPool <- pool::dbPool(
      drv = DatabaseConnector::DatabaseConnectorDriver(),
      dbms = "postgresql",
      server = paste(defaultServer, defaultDatabase, sep = "/"),
      port = defaultPort,
      user = defaultUser,
      password = defaultPassword
    )
    resultsDatabaseSchema <- defaultResultsSchema
    vocabularyDatabaseSchema <- defaultVocabularySchema
  } else {
    dataFolder <- defaultLocalDataFolder
  }
  cohortBaseUrl <- defaultCohortBaseUrl
  conceptBaseUrl <- defaultCohortBaseUrl
} else {
  writeLines("Using settings provided by user")
  databaseMode <- !is.null(shinySettings$connectionDetails)
  if (databaseMode) {
    connectionDetails <- shinySettings$connectionDetails
    if (is(connectionDetails$server, "function")) {
      connectionPool <- pool::dbPool(drv = DatabaseConnector::DatabaseConnectorDriver(),
                                     dbms = "postgresql",
                                     server = connectionDetails$server(),
                                     port = connectionDetails$port(),
                                     user = connectionDetails$user(),
                                     password = connectionDetails$password(),
                                     connectionString = connectionDetails$connectionString())
    } else {
      # For backwards compatibility with older versions of DatabaseConnector:
      connectionPool <- pool::dbPool(drv = DatabaseConnector::DatabaseConnectorDriver(),
                                     dbms = "postgresql",
                                     server = connectionDetails$server,
                                     port = connectionDetails$port,
                                     user = connectionDetails$user,
                                     password = connectionDetails$password,
                                     connectionString = connectionDetails$connectionString)
    }
    resultsDatabaseSchema <- shinySettings$resultsDatabaseSchema
    vocabularyDatabaseSchema <- shinySettings$vocabularyDatabaseSchema
  } else {
    dataFolder <- shinySettings$dataFolder
  }
  cohortBaseUrl <- shinySettings$cohortBaseUrl
  conceptBaseUrl <- shinySettings$cohortBaseUrl
}

dataModelSpecifications <- read.csv("resultsDataModelSpecification.csv")
# Cleaning up any tables in memory:
suppressWarnings(rm(list = SqlRender::snakeCaseToCamelCase(dataModelSpecifications$tableName)))

if (databaseMode) {
  
  onStop(function() {
    if (DBI::dbIsValid(connectionPool)) {
      writeLines("Closing database pool")
      pool::poolClose(connectionPool)
    }
  })
  
  resultsTablesOnServer <- tolower(DatabaseConnector::dbListTables(connectionPool, schema = resultsDatabaseSchema))
  
  loadResultsTable <- function(tableName, required = FALSE) {
    if (required || tableName %in% resultsTablesOnServer) {
      tryCatch({
        table <- DatabaseConnector::dbReadTable(connectionPool, 
                                                paste(resultsDatabaseSchema, tableName, sep = "."))
      }, error = function(err) {
        stop("Error reading from ", paste(resultsDatabaseSchema, tableName, sep = "."), ": ", err$message)
      })
      colnames(table) <- SqlRender::snakeCaseToCamelCase(colnames(table))
      if (nrow(table) > 0) {
        assign(SqlRender::snakeCaseToCamelCase(tableName), dplyr::as_tibble(table), envir = .GlobalEnv)
      }
    }
  }
  
  loadResultsTable("database", required = TRUE)
  loadResultsTable("cohort", required = TRUE)
  loadResultsTable("phenotype_description")
  loadResultsTable("temporal_time_ref")
  loadResultsTable("concept_sets")
  
  # Create empty objects in memory for all other tables. This is used by the Shiny app to decide what tabs to show:
  isEmpty <- function(tableName) {
    sql <- sprintf("SELECT 1 FROM %s.%s LIMIT 1;", resultsDatabaseSchema, tableName)
    oneRow <- DatabaseConnector::dbGetQuery(connectionPool, sql)
    return(nrow(oneRow) == 0)
  }
  
  for (table in dataModelSpecifications$tableName) {
    if (table %in% resultsTablesOnServer && 
        !exists(SqlRender::snakeCaseToCamelCase(table)) &&
        !isEmpty(table)) {
      assign(SqlRender::snakeCaseToCamelCase(table), dplyr::tibble())
    }
  }

  dataSource <- createDatabaseDataSource(connection = connectionPool,
                                         resultsDatabaseSchema = resultsDatabaseSchema,
                                         vocabularyDatabaseSchema = vocabularyDatabaseSchema)
} else {
  localDataPath <- file.path(dataFolder, defaultLocalDataFile)
  if (!file.exists(localDataPath)) {
    stop(sprintf("Local data file %s does not exist.", localDataPath))
  }
  dataSource <- createFileDataSource(localDataPath, envir = .GlobalEnv)
} 

if (exists("temporalTimeRef")) {
  temporalCovariateChoices <- temporalTimeRef %>%
    dplyr::mutate(choices = paste0("Start ", .data$startDay, " to end ", .data$endDay)) %>%
    dplyr::select(.data$timeId, .data$choices) %>% 
    dplyr::arrange(.data$timeId) %>% 
    dplyr::slice_head(n = 5)
}

if (exists("covariateRef")) {
  specifications <- readr::read_csv(file = "Table1Specs.csv", 
                                    col_types = readr::cols(),
                                    guess_max = min(1e7))
  prettyAnalysisIds <- specifications$analysisId
}
