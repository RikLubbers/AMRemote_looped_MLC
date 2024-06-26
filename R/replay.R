#!/bin/Rscript

# Load accessmod environment -----------------
source("global.R")
source("/batch/functions.R")
options(warn=-1)

# Define paths and config
pathConfig <- "/batch/config.json"
pathProject <- "/batch/project.am5p"
pathRegions <- "/batch/regions.json"

# Parse config.json
conf <- amAnalysisReplayParseConf(pathConfig)

# # Get passed arguments
# args <- commandArgs(trailingOnly = TRUE)

# Cluster
hpc <- as.logical(commandArgs(trailingOnly=TRUE)[1])
if (hpc) {
  # Was necessary when we had the issue related to the writing file with gdal in a binded folder
  # pathOut <- "/tmp"
  pathOut <- "/batch/out"
} else {
  pathOut <- "/batch/out"
}

# Only used in hpc (folders to be copied; see replay function in functions.R)
pathDirOuts <- NULL

# Get travel time now; if job array based on travel times it will be replaced
maxTravelTime <- as.numeric(unlist(strsplit(commandArgs(trailingOnly = TRUE)[6], " ")))

# Split by region ?
split <- as.logical(commandArgs(trailingOnly = TRUE)[7])

# If cluster, check if job array and get parameters
# Three options: split/multiple times - split - multiple times
# When multiple times, we replace the maxTravelTime by the JOB ID corresponding to one single maximum travel time
if (hpc) {
  # This parameter is not empty if job array
  taskID <- as.numeric(commandArgs(trailingOnly = TRUE)[30])
  if (!is.na(taskID)) {
    # Read the table create in array.sh where we have the correspondence between the array indices and a code that contains information about
    # the region index and/or the travel time.
    idTable <- read.table(file.path(pathOut, "ids.txt"), header = FALSE, col.names = c("id", "codeId"), colClasses = c("numeric", "character"))
    codeId <- idTable$codeId[idTable$id == taskID]
    if (length(codeId) > 0) {
      # We have an array based on region and travel time (no zonal stat possible)
      if (nchar(codeId) == 10) {
        # convert the number to a string and split it into two substrings
        sub1 <- substr(codeId, 1, 5)
        sub2 <- substr(codeId, 6, 10)
        # convert each substring back to an integer and subtract 10000
        maxTravelTime <- as.integer(sub1) - 10000
        ind <- as.integer(sub2) - 10000
      } else {
        # If less than 10 character either is region ID or travel time ID
        if (split) {
          ind <- as.numeric(codeId)
        } else {
          maxTravelTime <- as.numeric(codeId)
        }
      }
    }
  }
}
  
# If Zonal stat we keep set the time for modelling the travel time raster to 0
# Zonal stat can be true only if analysis is "accessibility"
# If Zonal stat, no job array; maxTravelTime could not have been replaced
zonalStat <- as.logical(commandArgs(trailingOnly = TRUE)[9])
if (zonalStat) {
  timeThr <- 0
} else {
  # If HPC and multiple travel times, maxTravelTime has been replaced by only one travel time (unique job)
  timeThr <- maxTravelTime
}

# Import project
print("Importing the project...")
importProject(pathProject, conf)

mergedLCLabels <- c() # Provide the list of merged land cover labels to be used in the loop

# We can keep the loop; when HPC and array based on travel times,
# maxTravelTime (timeThr) length is 1
for (tt in timeThr) {
  if (! split) {
    for (i in 1:length(mergedLCLabels)) {
      confi <- conf
      confi$args$inputMerged <- paste0("rLandCoverMerged__", mergedLCLabels[i])
      pathOuti <- paste0(pathOut, "/", mergedLCLabels[i])
      replay(confi, tt, pathOuti)

            # If Zonal Stat (no split possible, neither job array)
      if (zonalStat) {
        message("Zonal statistics...")
        inputTravelTime <- confi$args$outputTravelTime
        popLabel <- commandArgs(trailingOnly = TRUE)[10]
        zoneLabel <- commandArgs(trailingOnly = TRUE)[11]
        inputPop <- paste0("rPopulation__", popLabel)
        inputZone <- paste0("vZone__", zoneLabel)
        timeCumCosts <- maxTravelTime
        zoneIdField <- commandArgs(trailingOnly = TRUE)[12]
        zoneLabelField <- commandArgs(trailingOnly = TRUE)[13]
        amGrassNS(
          location = conf$location,
          mapset = conf$mapset,
          {
            res <- zonalAnalysis(
              inputTravelTime,
              inputPop,
              inputZone,
              timeCumCosts,
              zoneIdField,
              zoneLabelField
            )
          }
        )
        zonalStatDir <- file.path(pathOuti, "zonalStat")
        mkdirs(zonalStatDir) 
        write.csv(res, file.path(zonalStatDir, paste0("zonalStat__", mergedLCLabels[i], ".csv")), row.names = FALSE)
}

    }
  } else {
    if (hpc) {
      # Parse regions.json
      regions <- fromJSON(pathRegions)
      hfDf <- regions$hfDf
      byRegion(hfDf, ind, conf, pathOut, tt)
    } else {
      # If regular server
      colName <- commandArgs(trailingOnly = TRUE)[8]
      amGrassNS(
        location = conf$location,
        mapset = conf$mapset,
        {
          vect <- readVECT(conf$args$inputHf)
          df <- vect@data
          hfCat <- df[, "cat"]
          hfRegion <- df[, colName]
          hfIndex <- as.numeric(as.factor(hfRegion))
          hfDf <- data.frame(cat = hfCat, region = hfRegion, index = hfIndex)
          index <- unique(hfIndex)
        }
      )
      for (ind in index) {
        byRegion(hfDf, ind, conf, pathOut, tt)
      }
    }
  }
}


# # Was necessary when we had the issue related to the writing file with gdal in a binded folder
# if (hpc) {
#   for (outF in pathDirOuts) {
#     message(paste("Exporting", outF))
#     system2("cp", c("-r", outF, "/batch/out"))
#   }
# }

# End message
amTimeStamp("Finished")
