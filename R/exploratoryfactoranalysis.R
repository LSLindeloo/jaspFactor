#
# Copyright (C) 2013-2018 University of Amsterdam
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.	See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.	If not, see <http://www.gnu.org/licenses/>.
#

exploratoryFactorAnalysis <- function(jaspResults, dataset, options, ...) {
  jaspResults$addCitation("Revelle, W. (2018) psych: Procedures for Personality and Psychological Research, Northwestern University, Evanston, Illinois, USA, https://CRAN.R-project.org/package=psych Version = 1.8.12.")

  # Read dataset
  dataset <- .efaReadData(dataset, options)
  ready   <- length(options$variables) > 1

  if (ready)
    .efaCheckErrors(dataset, options)

  options(mc.cores = 1) # prevent the fa.parallel function using mutlitple cores by default

  modelContainer <- .efaModelContainer(jaspResults)

  # output functions
  .efaKMOtest(           modelContainer, dataset, options, ready)
  .efaBartlett(          modelContainer, dataset, options, ready)
  .efaMardia(            modelContainer, dataset, options, ready)
  .efaGoFTable(          modelContainer, dataset, options, ready)
  .efaLoadingsTable(     modelContainer, dataset, options, ready)
  .efaStructureTable(    modelContainer, dataset, options, ready)
  .efaEigenTable(        modelContainer, dataset, options, ready)
  .efaCorrTable(         modelContainer, dataset, options, ready)
  .efaAdditionalFitTable(modelContainer, dataset, options, ready)
  .efaPATable(           modelContainer, dataset, options, ready)
  .efaScreePlot(         modelContainer, dataset, options, ready)
  .efaPathDiagram(       modelContainer, dataset, options, ready)

  # data saving
  # .efaAddComponentsToData(jaspResults, modelContainer, options, ready)
}

# Preprocessing functions ----
# Modification here: "column" to "column.as.numeric" - so that JASP can pass ordinal variables as numeric as well
# this will be necessary if we wish to use polychoric/tetrachoric correlations down the line
.efaReadData <- function(dataset, options) {
  if (!is.null(dataset)) return(dataset)

  if (options[["missingValues"]] == "listwise") {
    return(.readDataSetToEnd(columns.as.numeric = unlist(options$variables), exclude.na.listwise = unlist(options$variables)))
  } else {
    return(.readDataSetToEnd(columns.as.numeric = unlist(options$variables)))
  }
}

.efaCheckErrors <- function(dataset, options) {
  customChecksEFA <- list(
    function() {
      if (length(options$variables) > 0 && options$factorMethod == "manual" &&
          options$numberOfFactors > length(options$variables)) {
        return(gettextf("Too many factors requested (%i) for the amount of included variables", options$numberOfFactors))
      }
    },
    function() {
      if(nrow(dataset) < 3){
        return(gettextf("Not enough valid cases (%i) to run this analysis", nrow(dataset)))
      }
    },
    # check whether all row variance == 0
    function() {
      varianceZero <- 0
      for (i in 1:nrow(dataset)){
        if(sd(dataset[i,], na.rm = TRUE) == 0) varianceZero <- varianceZero + 1
      }
      if(varianceZero == nrow(dataset)){
        return(gettext("Data not valid: variance is zero in each row"))
      }
    },
    # Check for correlation anomalies
    function() {
      P <- ncol(dataset)
      # the checks below also fail when n < p but this provides a more accurate error message
      if (ncol(dataset) > nrow(dataset))
        return(gettext("Data not valid: there are more variables than observations"))

      # check whether a variable has too many missing values to compute the correlations
      Np <- colSums(!is.na(dataset))
      error_variables <- .unv(names(Np)[Np < P])
      if (length(error_variables) > 0) {
        return(gettextf("Data not valid: too many missing values in variable(s) %s.",
                        paste(error_variables, collapse = ", ")))
      }

      S <- cor(dataset)
      if (all(S == 1)) {
        return(gettext("Data not valid: all variables are collinear"))
      }
    }
  )
  error <- .hasErrors(dataset = dataset, type = c("infinity", "variance"), custom = customChecksEFA,
                      exitAnalysisIfErrors = TRUE)
  return()
}

.efaModelContainer <- function(jaspResults, options) {
  if (!is.null(jaspResults[["modelContainer"]])) {
    modelContainer <- jaspResults[["modelContainer"]]
  } else {
    modelContainer <- createJaspContainer()
    modelContainer$dependOn(c("rotationMethod", "orthogonalSelector", "obliqueSelector", "variables", "factorMethod",
                              "eigenValuesBox", "numberOfFactors", "missingValues", "basedOn", "fitmethod",
                              "parallelMethod"))
    jaspResults[["modelContainer"]] <- modelContainer
  }

  return(modelContainer)
}


# Results functions ----
# Modification here: added "cor" argument to the fa function.
# If basedOn == mixed, the fa will be performed computing a tetrachoric or polychoric correlation matrix,
# depending on the number of response categories of the ordinal variables.
.efaComputeResults <- function(modelContainer, dataset, options, ready) {
  baseOn <- switch(options[["basedOn"]],
                   correlation = "cor",
                   covariance  = "cov",
                   mixed       = "mixed")

  efaResult <- try(
    psych::fa(
      r        = dataset,
      nfactors = .efaGetNComp(dataset, options),
      rotate   = ifelse(options$rotationMethod == "orthogonal", options$orthogonalSelector, options$obliqueSelector),
      scores   = TRUE,
      covar    = options$basedOn == "covariance",
      cor      = baseOn,
      fm       = options$fitmethod
    )
  )

  if (isTryError(efaResult)) {
    errtxt <- .extractErrorMessage(efaResult)
    errcodes <- c("L-BFGS-B needs finite values of 'fn'", "missing value where TRUE/FALSE needed",
                  "reciprocal condition number = 0", "infinite or missing values in 'x'")
    if (errtxt %in% errcodes) {
      errmsg <- gettextf("Estimation failed. Internal error message: %s. %s", .extractErrorMessage(efaResult),
                         "Try basing the analysis on a different type of matrix or change the factoring method.")
    } else {
      errmsg <- gettextf("Estimation failed. Internal error message: %s", .extractErrorMessage(efaResult))
    }

    modelContainer$setError(errmsg)
  }

# Modification here: if the estimation of the polychoric/tetrachoric correlation matrix fails with this specific error,
# JASP replaces the internal error message with a more informative one.
  if (isTryError(efaResult) && options[["basedOn"]] == "mixed" && (.extractErrorMessage(efaResult) == "missing value where TRUE/FALSE needed"
                                || .extractErrorMessage(efaResult) == "attempt to set 'rownames' on an object with no dimensions")) {
    errmsgPolyCor <- gettextf(
      "Unfortunately, the estimation of the polychoric/tetrachoric correlation matrix failed.
      This might be due to a small sample size or variables not containing all response categories.
      Internal error message: %s", .extractErrorMessage(efaResult))
    modelContainer$setError(errmsgPolyCor)
  }

  modelContainer[["model"]] <- createJaspState(efaResult)
  return(efaResult)
}

.efaGetNComp <- function(dataset, options) {
  if (options$factorMethod == "manual") return(options$numberOfFactors)

  # Modification here:
  # If the "basedOn == mixed" option is selected, then compute a polychoric/tetrachoric correlation matrix
  # to base the Parallel Analysis on.
  # If "basedOn == mixed" is not selected (i.e., correlation/covariance matrix are selected), then analysis carries on
  # as usual.

  if (options[["basedOn"]] == "mixed") {
    polyTetraCor <- psych::mixedCor(dataset)
    set.seed(options[["parallelSeed"]])
    parallelResult <- try(psych::fa.parallel(polyTetraCor$rho,
                                 plot = FALSE,
                                 fa = options$parallelMethod,
                                 n.obs = nrow(dataset)))
  }
  else {
    set.seed(options[["parallelSeed"]])
    parallelResult <- try(psych::fa.parallel(dataset, plot = FALSE, fa = options$parallelMethod))
  }
  if (isTryError(parallelResult)) return(1)
  if (options$factorMethod == "parallelAnalysis") {
    if (options$parallelMethod == "pc") {
      return(max(1, parallelResult$ncomp))
    } else { # parallelmethod is fa
      return(max(1, parallelResult$nfact))
    }
  }
  if (options$factorMethod == "eigenValues") {
    ncomp <- sum(parallelResult$pc.values > options$eigenValuesBox)
    # I can use stop() because it's caught by the try and the message is put on
    # on the modelcontainer.
    if (ncomp == 0)
      stop(
        gettext("No factors with an eigenvalue > "), options$eigenValuesBox, ". ",
        gettext("Maximum observed eigenvalue equals "), round(max(parallelResult$fa.values), 3)
      )
    return(ncomp)
  }
}


# Output functions ----
.efaKMOtest <- function(modelContainer, dataset, options, ready) {
  if (!options[["kmotest"]] || !is.null(modelContainer[["kmoTab"]])) return()

  kmoTab <- createJaspTable(gettext("Kaiser-Meyer-Olkin test"))
  kmoTab$dependOn("kmotest")
  kmoTab$addColumnInfo(name = "col", title = "", type = "string")
  kmoTab$addColumnInfo(name = "val", title = "MSA", type = "number", format = "dp:3")
  kmoTab$position <- -1
  modelContainer[["kmoTab"]] <- kmoTab

  if (!ready) return()

  # Modification here:
  # If a polychoric/tetrachoric-correlation-based FA is requested, then compute the KMO values
  # based on said correlation matrix:
  # else: analysis carries on as usual
  if (options[["basedOn"]] == "mixed") {
    polyTetraCor <- psych::mixedCor(dataset)
    kmo <- psych::KMO(polyTetraCor$rho)
  }
  else{
    kmo <- psych::KMO(dataset)
  }

  kmoTab[["col"]] <- c(gettext("Overall MSA\n"), .unv(names(kmo$MSAi)))
  kmoTab[["val"]] <- c(kmo$MSA, kmo$MSAi)
}

.efaBartlett <- function(modelContainer, dataset, options, ready) {
  if (!options[["bartest"]] || !is.null(modelContainer[["barTab"]])) return()

  barTab <- createJaspTable(gettext("Bartlett's test"))
  barTab$dependOn("bartest")
  barTab$addColumnInfo(name = "chisq", title = "\u03a7\u00b2", type = "number", format = "dp:3")
  barTab$addColumnInfo(name = "df",    title = gettext("df"), type = "number", format = "dp:3")
  barTab$addColumnInfo(name = "pval",  title = gettext("p"), type = "number", format = "dp:3;p:.001")
  barTab$position <- 0
  modelContainer[["barTab"]] <- barTab

  if (!ready) return()

  # Modification here:
  # if "basedOn = mixed", bartlett's test is calculated
  # based on the polychoric/tetrachoric matrix.
  if (options[["basedOn"]] == "mixed") {
    polyTetraCor <- psych::mixedCor(dataset)
    bar <- psych::cortest.bartlett(polyTetraCor$rho, n = nrow(dataset))
  }
  else {
    bar <- psych::cortest.bartlett(dataset)
  }

  barTab[["chisq"]] <- bar[["chisq"]]
  barTab[["df"]]    <- bar[["df"]]
  barTab[["pval"]]  <- bar[["p.value"]]
}

# Modification here:
# Added Mardia's tests of multivariate normality for further probing of the
# multivariate normality assumption.
.efaMardia <- function(modelContainer, dataset, options, ready) {
  if (!options[["martest"]] || !is.null(modelContainer[["marTab"]])) return()

  marTab <- createJaspTable(gettext("Mardia's Test of Multivariate Normality"))
  marTab$dependOn("martest")
  marTab$addColumnInfo(name = "tests", title =  "", type = "number", format = "dp:3")
  marTab$addColumnInfo(name = "coefs", title =  gettext("Value"), type = "number", format = "dp:3")
  marTab$addColumnInfo(name = "statistics", title =  gettext("Statistic"), type = "number", format = "dp:3")
  marTab$addColumnInfo(name = "dfs", title =  gettext("df"), type = "integer")
  marTab$addColumnInfo(name = "pval",  title = gettext("p"), type = "number", format = "dp:3;p:.001")
  marTab$position <- 0.5
  modelContainer[["marTab"]] <- marTab

  if (!ready) return()

  mar <- try(psych::mardia(dataset, plot = FALSE), silent = TRUE)
  if (isTryError(mar)) {
    errmsg <- gettextf("Mardia test failed. Internal error message: %s", .extractErrorMessage(mar))
    marTab$setError(errmsg)
    return()
  }

  mardiaHead <- c("Skewness","Small Sample Skewness", "Kurtosis")

  # dfs of the skewness coefficients are calculated via Mardia's formula (1970);
  # package psych doesn't seem to provide them
  k <- length(dataset)
  mardiadfs <- (k * (k + 1) * (k + 2)) / 6

  marTab[["tests"]] <- mardiaHead
  marTab[["coefs"]] <- c(mar[["b1p"]], mar[["b1p"]], mar[["b2p"]])
  marTab[["statistics"]] <- c(mar[["skew"]], mar[["small.skew"]], mar[["kurtosis"]])
  marTab[["dfs"]] <- c(mardiadfs, mardiadfs)
  marTab[["pval"]] <- c(mar[["p.skew"]], mar[["p.small"]], mar[["p.kurt"]])

  marTab$addFootnote(message = gettext("The statistic for skewness is assumed to be Chi^2 distributed and the statistic for kurtosis standard normal."))
}

.efaGoFTable <- function(modelContainer, dataset, options, ready) {
  if (!is.null(modelContainer[["gofTab"]])) return()

  gofTab <- createJaspTable(title = gettext("Chi-squared Test"))
  gofTab$addColumnInfo(name = "model", title = "",                 type = "string")
  gofTab$addColumnInfo(name = "chisq", title = gettext("Value"),   type = "number", format = "dp:3")
  gofTab$addColumnInfo(name = "df",    title = gettext("df"),      type = "integer")
  gofTab$addColumnInfo(name = "p",     title = gettext("p"),       type = "number", format = "dp:3;p:.001")
  gofTab$position <- 1

  modelContainer[["gofTab"]] <- gofTab

  if (!ready) return()

  efaResults <- .efaComputeResults(modelContainer, dataset, options)
  if (modelContainer$getError()) return()

  gofTab[["model"]] <- "Model"
  gofTab[["chisq"]] <- efaResults$STATISTIC
  gofTab[["df"]]    <- efaResults$dof
  gofTab[["p"]]     <- efaResults$PVAL

  if (efaResults$dof < 0)
    gofTab$addFootnote(message = gettext("Degrees of freedom below 0, model is unidentified."), symbol = gettext("<em>Warning:</em>"))
}

.efaLoadingsTable <- function(modelContainer, dataset, options, ready) {

  if (!is.null(modelContainer[["loadTab"]]))
    return()

  loadTab <- createJaspTable(gettext("Factor Loadings"))
  loadTab$dependOn(c("highlightText", "factorLoadingsSort"))
  loadTab$position <- 2

  loadTab$addColumnInfo(name = "var", title = "", type = "string")

  if (!ready || modelContainer$getError()) {
    modelContainer[["loadTab"]] <- loadTab
    return()
  }

  efaResults <- modelContainer[["model"]][["object"]]
  loads <- loadings(efaResults)

  for (i in seq_len(ncol(loads)))
    loadTab$addColumnInfo(name = paste0("c", i), title = gettextf("Factor %i", i), type = "number", format = "dp:3")

  loadTab$addColumnInfo(name = "uni", title = gettext("Uniqueness"), type = "number", format = "dp:3")

  if (options[["rotationMethod"]] == "orthogonal" && options[["orthogonalSelector"]] == "none") {
    loadTab$addFootnote(message = gettext("No rotation method applied."))
  } else {
    loadTab$addFootnote(message = gettextf("Applied rotation method is %s.", options[[if(options[["rotationMethod"]] == "orthogonal") "orthogonalSelector" else "obliqueSelector"]]))
  }

  loadings <- unclass(loads)
  loadings[abs(loads) < options[["highlightText"]]] <- NA_real_

  df <- cbind.data.frame(
    var = rownames(loads),
    as.data.frame(loadings),
    uni = efaResults[["uniquenesses"]]
  )
  rownames(df) <- NULL
  colnames(df)[2:(1 + ncol(loads))] <- paste0("c", seq_len(ncol(loads)))

  # "sortByVariables" is the default output
  if (options[["factorLoadingsSort"]] == "sortByFactorSize")
    df <- df[do.call(order, c(abs(df[2:(ncol(df) - 1)]), na.last = TRUE, decreasing = TRUE)), ]

  loadTab$setData(df)
  modelContainer[["loadTab"]] <- loadTab

}

.efaStructureTable <- function(modelContainer, dataset, options, ready) {
  if (!options[["incl_structure"]] || !is.null(modelContainer[["strtab"]])) return()
  strtab <- createJaspTable(gettext("Factor Loadings (Structure Matrix)"))
  strtab$dependOn(c("highlightText", "incl_structure"))
  strtab$position <- 2.5
  strtab$addColumnInfo(name = "var", title = "", type = "string")
  modelContainer[["strtab"]] <- strtab

  if (!ready || modelContainer$getError()) return()

  efaResults <- modelContainer[["model"]][["object"]]

  if (options$rotationMethod == "orthogonal" && options$orthogonalSelector == "none") {
    strtab$addFootnote(message = gettext("No rotation method applied."))
  } else {
    strtab$addFootnote(
      message = gettextf("Applied rotation method is %s.", ifelse(options$rotationMethod == "orthogonal", options$orthogonalSelector, options$obliqueSelector))
    )
  }

  loads <- efaResults$Structure
  strtab[["var"]] <- .unv(rownames(loads))

  for (i in 1:ncol(loads)) {
    # fix weird "all true" issue
    if (all(abs(loads[, i]) < options$highlightText)) {
      strtab$addColumnInfo(name = paste0("c", i), title = gettextf("Factor %i", i), type = "string")
      strtab[[paste0("c", i)]] <- rep("", nrow(loads))
    } else {
      strtab$addColumnInfo(name = paste0("c", i), title = gettextf("Factor %i", i), type = "number", format = "dp:3")
      strtab[[paste0("c", i)]] <- ifelse(abs(loads[, i]) < options$highlightText, NA, loads[ ,i])
    }
  }
}

.efaEigenTable <- function(modelContainer, dataset, options, ready) {
  if (!is.null(modelContainer[["eigTab"]])) return()

  eigTab <- createJaspTable(gettext("Factor Characteristics"))
  eigTab$addColumnInfo(name = "comp", title = "",                         type = "string")

  # if a rotation is used, the table needs more columns
  rotate <- options[[if (options[["rotationMethod"]] == "orthogonal") "orthogonalSelector" else "obliqueSelector"]]
  if (rotate != "none") {
    overTitleA <- gettext("Unrotated solution")
    overTitleB <- gettext("Rotated solution")
    eigTab$addColumnInfo(name = "sslU", title = gettext("SumSq. Loadings"),  type = "number", overtitle = overTitleA)
    eigTab$addColumnInfo(name = "propU", title = gettext("Proportion var."), type = "number", overtitle = overTitleA)
    eigTab$addColumnInfo(name = "cumpU", title = gettext("Cumulative"),      type = "number", overtitle = overTitleA)
    eigTab$addColumnInfo(name = "sslR", title = gettext("SumSq. Loadings"),  type = "number", overtitle = overTitleB)
    eigTab$addColumnInfo(name = "propR", title = gettext("Proportion var."), type = "number", overtitle = overTitleB)
    eigTab$addColumnInfo(name = "cumpR", title = gettext("Cumulative"),      type = "number", overtitle = overTitleB)
  } else {
    eigTab$addColumnInfo(name = "sslU", title = gettext("SumSq. Loadings"),  type = "number")
    eigTab$addColumnInfo(name = "propU", title = gettext("Proportion var."), type = "number")
    eigTab$addColumnInfo(name = "cumpU", title = gettext("Cumulative"),      type = "number")
  }

  eigTab$position <- 3

  modelContainer[["eigTab"]] <- eigTab

  if (!ready || modelContainer$getError()) return()

  efaResults <- modelContainer[["model"]][["object"]]


  eigv <- efaResults$values
  eigv_init <- efaResults$e.values
  Vaccounted <- efaResults[["Vaccounted"]]
  idx <- seq_len(efaResults[["factors"]])
  eigTab[["comp"]] <- paste("Factor", idx)
  eigTab[["sslU"]] <- eigv[idx]
  eigTab[["propU"]] <- eigv[idx] / sum(eigv_init)
  eigTab[["cumpU"]] <- cumsum(eigv)[idx] / sum(eigv_init)
  if (rotate != "none") {
    eigTab[["sslR"]] <- Vaccounted["SS loadings", idx]
    eigTab[["propR"]] <- Vaccounted["Proportion Var", idx]
    eigTab[["cumpR"]] <- if (efaResults[["factors"]] == 1L) Vaccounted["Proportion Var", idx] else Vaccounted["Cumulative Var", idx]
  }
}

.efaCorrTable <- function(modelContainer, dataset, options, ready) {
  if (!options[["incl_correlations"]] || !is.null(modelContainer[["corTab"]])) return()
  corTab <- createJaspTable(gettext("Factor Correlations"))
  corTab$dependOn("incl_correlations")
  corTab$addColumnInfo(name = "col", title = "", type = "string")
  corTab$position <- 4
  modelContainer[["corTab"]] <- corTab

  if (!ready || modelContainer$getError()) return()

  efaResult <- modelContainer[["model"]][["object"]]

  if (efaResult$factors == 1 || options$rotationMethod == "orthogonal") {
    # no factor correlation matrix when rotation specified uncorrelated factors!
    cors <- diag(efaResult$factors)
  } else {
    cors <- zapsmall(efaResult$Phi)
  }

  dims <- ncol(cors)

  corTab[["col"]] <- paste("Factor", 1:dims)

  for (i in 1:dims) {
    thisname <- paste("Factor", i)
    corTab$addColumnInfo(name = thisname, title = thisname, type = "number", format = "dp:3")
    corTab[[thisname]] <- cors[,i]
  }

}

.efaAdditionalFitTable <- function(modelContainer, dataset, options, ready) {
  if (!options[["incl_fitIndices"]] || !is.null(modelContainer[["fitTab"]])) return()
  fitTab <- createJaspTable(gettext("Additional fit indices"))
  fitTab$dependOn("incl_fitIndices")
  fitTab$addColumnInfo(name = "RMSEA",   title = gettext("RMSEA"), type = "number", format = "dp:3")
  fitTab$addColumnInfo(name = "RMSEAci", title = gettextf("RMSEA 90%% confidence"),   type = "string")
  fitTab$addColumnInfo(name = "TLI",     title = gettext("TLI"),   type = "number", format = "dp:3")
  fitTab$addColumnInfo(name = "BIC",     title = gettext("BIC"),   type = "number", format = "dp:3")
  fitTab$position <- 4.5
  modelContainer[["fitTab"]] <- fitTab

  if (!ready || modelContainer$getError()) return()

  efaResults <- modelContainer[["model"]][["object"]]

  # store in obj
  rmsealo <- if (is.null(efaResults$RMSEA[2])) "." else round(efaResults$RMSEA[2], 3)
  rmseahi <- if (is.null(efaResults$RMSEA[3])) "." else round(efaResults$RMSEA[3], 3)

  fitTab[["RMSEA"]]   <- if (is.null(efaResults$RMSEA[1])) NA  else efaResults$RMSEA[1]
  fitTab[["RMSEAci"]] <- paste(rmsealo, "-", rmseahi)
  fitTab[["TLI"]]     <- if (is.null(efaResults$TLI))      NA  else efaResults$TLI
  fitTab[["BIC"]]     <- if (is.null(efaResults$BIC))      NA  else efaResults$BIC

}

# Modification here:
# Creates a table that outputs the details of the parallel analysis.
# Particularly useful for reporting the rationale of how many factors were
# retained - especially within psychometric papers.
# We are also going to be adding an asterisk aside any factor whose real data eigenvalue is above
# the 95th percentile simulated data eigenvalue
.efaPATable <- function(modelContainer, dataset, options, ready) {
  if (!options[["incl_PAtable"]] || !is.null(modelContainer[["paTab"]])) return()

  if (options[["basedOn"]] == "mixed") {
    polyTetraCor <- psych::mixedCor(dataset)
    set.seed(options[["parallelSeed"]])
    parallelResult <- try(psych::fa.parallel(polyTetraCor$rho,
                                 plot = FALSE,
                                 fa = options$parallelMethodTable,
                                 n.obs = nrow(dataset)))
  } else {
    set.seed(options[["parallelSeed"]])
    parallelResult <- try(psych::fa.parallel(dataset, plot = FALSE, fa = options$parallelMethodTable))
  }

   if (options$parallelMethodTable == "pc") {
    eigTitle <- gettext("Real data component eigenvalues")
    rowsName <- gettext("Factor")
    RealDataEigen <- parallelResult$pc.values
    ResampledEigen <- parallelResult$pc.sim
    footnote <- gettext("'*' = Factor should be retained.\nResults from PC-based parallel analysis.")
  } else { # parallelmethod is FA
    eigTitle <- gettext("Real data factor eigenvalues")
    rowsName <- gettext("Factor")
    RealDataEigen <- parallelResult$fa.values
    ResampledEigen <- parallelResult$fa.sim
    footnote <- gettext("'*' = Factor should be retained.\nResults from FA-based parallel analysis.")
  }

  paTab <- createJaspTable(gettext("Parallel Analysis"))
  paTab$dependOn(c("incl_PATable", "parallelMethodTable"))
  paTab$addColumnInfo(name = "col", title = "", type = "string")

  paTab$addColumnInfo(name = "val1", title = eigTitle, type = "number", format = "dp:3")
  paTab$addColumnInfo(name = "val2", title = gettext("Simulated data mean eigenvalues"), type = "number", format = "dp:3")
  paTab$position <- 5
  modelContainer[["paTab"]] <- paTab

  if (!ready || modelContainer$getError()) return()

  efaResult <- modelContainer[["model"]][["object"]]
  PAs <- zapsmall(as.matrix(data.frame(RealDataEigen, ResampledEigen), fix.empty.names = FALSE))
  forasterisk <- data.frame(applyforasterisk = RealDataEigen - ResampledEigen)
  dims <- nrow(PAs)

  firstcol <- data.frame()
  for (i in 1:dims) {
    if (forasterisk$applyforasterisk[i] > 0) {
      firstcol <- rbind(firstcol, paste(rowsName, " ", i,"*", sep = ""))
    } else {
      firstcol <- rbind(firstcol, paste(rowsName, i))
    }
  }

  paTab[["col"]] <- firstcol[[1]]
  paTab[["val1"]] <- c(RealDataEigen)
  paTab[["val2"]] <- c(ResampledEigen)


  paTab$addFootnote(message = footnote)
}

.efaScreePlot <- function(modelContainer, dataset, options, ready) {
  if (!options[["incl_screePlot"]] || !is.null(modelContainer[["scree"]])) return()

  scree <- createJaspPlot(title = "Scree plot", width = 480, height = 320)
  scree$dependOn(c("incl_screePlot", "screeDispParallel", "parallelMethod"))
  scree$position <- 8
  modelContainer[["scree"]] <- scree

  if (!ready || modelContainer$getError()) return()

  n_col <- ncol(dataset)

  if (options[["screeDispParallel"]]) {

    # Modification here:
    # if "BasedOn = mixed", parallel analysis here will be based on the polychoric/tetrachoric
    # correlation matrix.

    if (options[["basedOn"]] == "mixed") {
      polyTetraCor <- psych::mixedCor(dataset)
      set.seed(options[["parallelSeed"]])
      parallelResult <- try(psych::fa.parallel(polyTetraCor$rho,
                                   plot = FALSE,
                                   fa = options$parallelMethod,
                                   n.obs = nrow(dataset)))
    } else {
      set.seed(options[["parallelSeed"]])
      parallelResult <- try(psych::fa.parallel(dataset, plot = FALSE, fa = options$parallelMethod))
    }
    if (isTryError(parallelResult)) {
      errmsg <- gettextf("Screeplot not available. \nInternal error message: %s", .extractErrorMessage(parallelResult))
      scree$setError(errmsg)
      # scree$setError(.decodeVarsInMessage(names(dataset), errmsg))
      return()
    }

    if (options$factorMethod == "parallelAnalysis" && options$parallelMethod == "fa") {
      evs <- c(parallelResult$fa.values, parallelResult$fa.sim)
    } else { # in all other cases we use the initial eigenvalues for the plot, aka the pca ones
      if (anyNA(parallelResult$pc.sim)) {
        # Modification here:
        # if "BasedOn = mixed", parallel analysis here will be based on the polychoric/tetrachoric
        # correlation matrix.

        if (options[["basedOn"]] == "mixed") {
          polyTetraCor <- psych::mixedCor(dataset)
          set.seed(options[["parallelSeed"]])
          parallelResult <- try(psych::fa.parallel(polyTetraCor$rho,
                                       plot = FALSE,
                                       fa = options$parallelMethod,
                                       n.obs = nrow(dataset)))
        } else {
          set.seed(options[["parallelSeed"]])
          parallelResult <- try(psych::fa.parallel(dataset, plot = FALSE, fa = options$parallelMethod))
        }
      }
      evs <- c(parallelResult$pc.values, parallelResult$pc.sim)
    }
    tp <- rep(c(gettext("Data"), gettext("Simulated data from parallel analysis")), each = n_col)

  } else { # do not display parallel analysis
    evs <- eigen(cor(dataset, use = "pairwise.complete.obs"), only.values = TRUE)$values
    tp <- rep(gettext("Data"), each = n_col)
  }

  df <- data.frame(
    id   = rep(seq_len(n_col), 2),
    ev   = evs,
    type = tp
  )

  # basic scree plot
  plt <-
    ggplot2::ggplot(df, ggplot2::aes(x = id, y = ev, linetype = type, shape = type)) +
    ggplot2::geom_line(na.rm = TRUE) +
    ggplot2::labs(x = gettext("Factor"), y = gettext("Eigenvalue")) +
    ggplot2::geom_hline(yintercept = options$eigenValuesBox)


  # dynamic function for point size:
  # the plot looks good with size 3 when there are 10 points (3 + log(10) - log(10) = 3)
  # with more points, the size will become logarithmically smaller until a minimum of
  # 3 + log(10) - log(200) = 0.004267726
  # with fewer points, they become bigger to a maximum of 3 + log(10) - log(2) = 4.609438
  pointsize <- 3 + log(10) - log(n_col)
  if (pointsize > 0) {
    plt <- plt + ggplot2::geom_point(na.rm = TRUE, size = max(0, 3 + log(10) - log(n_col)))
  }

  # theming with special legend thingy
  plt <- plt +
    jaspGraphs::themeJaspRaw() +
    ggplot2::theme(
      legend.position      = c(0.99, 0.95),
      legend.justification = c(1, 1),
      legend.text          = ggplot2::element_text(size = 12.5),
      legend.title         = ggplot2::element_blank(),
      legend.key.size      = ggplot2::unit(18, "pt")
    )

  scree$plotObject <- plt
  modelContainer[["scree"]] <- scree
}

.efaPathDiagram <- function(modelContainer, dataset, options, ready){
  if (!options[["incl_pathDiagram"]] || !is.null(modelContainer[["path"]])) return()

  # Create plot object
  n_var <- length(options$variables)
  path <- createJaspPlot(title = gettext("Path Diagram"), width = 480, height = ifelse(n_var < 2, 300, 1 + 299 * (n_var / 5)))
  path$dependOn(c("incl_pathDiagram", "highlightText"))
  path$position <- 7
  modelContainer[["path"]] <- path
  if (!ready || modelContainer$getError()) return()

  # Get result info
  efaResult <- modelContainer[["model"]][["object"]]
  LY <- as.matrix(loadings(efaResult))
  TE <- diag(efaResult$uniqueness)
  PS <- efaResult$r.scores


  # Variable names
  xName   <- ifelse(options$rotationMethod == "orthogonal" && options$orthogonalSelector == "none", "PC", "RC")
  factors <- paste0(xName, seq_len(ncol(LY)))
  labels  <- .unv(rownames(LY))

  # Number of variables:
  nFactor    <- length(factors)
  nIndicator <- length(labels)
  nTotal     <- nFactor + nIndicator

  # Make layout:
  # For each manifest, find strongest loading:
  strongest <- apply(abs(LY), 1, which.max)
  ord       <- order(strongest)

  # Reshuffle labels and LY:
  labels <- labels[ord]
  LY     <- LY[ord,]

  # Edgelist:
  # Factor loadings
  E_loadings <- data.frame(
    from   = rep(factors, each = nIndicator),
    to     = rep(labels, nFactor),
    weight = c(LY),
    stringsAsFactors = FALSE
  )

  # Residuals:
  E_resid <- data.frame(
    from   = labels,
    to     = labels,
    weight = diag(TE)
  )

  # Factor correlations:
  if (efaResult$factors == 1) {
    E_cor <- data.frame(from = NULL, to = NULL, weight = NULL)
  } else {
    E_cor <- data.frame(
      from   = c(factors[col(PS)]),
      to     = c(factors[row(PS)]),
      weight = c(PS),
      stringsAsFactors = FALSE
    )
    E_cor <- E_cor[E_cor$from != E_cor$to, ]
  }

  # Combine everything:
  edge_df <- rbind(E_loadings, E_resid, E_cor)

  # Make the layout:
  sq <- function(x) seq(-1, 1, length.out = x + 2)[-c(1, x + 2)]

  layout_mat <- cbind(
    c(rep(-1, nFactor), rep(1, nIndicator)),
    c(sq(nFactor),      sq(nIndicator))
  )

  # Compute curvature of correlations:
  # Numeric edgelist:
  E_cor_numeric <- cbind(match(E_cor$from, factors), match(E_cor$to, factors))

  # Compute distance:
  dist <- abs(layout_mat[E_cor_numeric[,1], 2] - layout_mat[E_cor_numeric[,2], 2])
  min <- 2
  max <- 8

  # Scale to max:
  dist <- min + dist / (max(dist)) * (max - min)
  if (length(unique(dist)) == 1) {
    dist[] <- mean(c(max, min))
  }

  # Scale to plot width:
  Scale <- sqrt(path$width^2 + path$height^2) / sqrt(480^2 + 300^2)
  dist <- 1 / Scale * dist

  # Curvature:
  curve <- c(rep(0, nrow(E_loadings)), rep(0, nrow(E_resid)), dist)

  # Edge connectpoints:
  ECP <- matrix(NA, nrow(edge_df), 2)
  ECP[nrow(E_loadings) + nrow(E_resid) + seq_len(nrow(E_cor)), 1:2] <- 1.5 * pi
  ECP[seq_len(nrow(E_loadings)), 2] <- 1.5 * pi

  # Loop rotation:
  loopRotation <- 0.5*pi

  # bidirectional:
  bidir <- c(rep(FALSE, nrow(E_loadings) + nrow(E_resid)), rep(TRUE, nrow(E_cor)))

  # Shape:
  shape <- c(rep("circle", nFactor), rep("rectangle", nIndicator))

  # Size:
  size1 <- c(rep(12, nFactor), rep(30, nIndicator))
  size2 <- c(rep(12, nFactor), rep( 7, nIndicator))

  # Plot:
  label.scale.equal <- c(rep(1, nFactor),rep(2, nIndicator))

  path$plotObject <- jaspBase:::.suppressGrDevice(qgraph::qgraph(
    input               = edge_df,
    layout              = layout_mat,
    directed            = TRUE,
    bidirectional       = bidir,
    residuals           = TRUE,
    residScale	        = 10,
    labels              = c(factors,labels),
    curve               = curve,
    curveScale          = FALSE,
    edgeConnectPoints   = ECP,
    loopRotation        = loopRotation,
    shape               = shape,
    vsize               = size1,
    vsize2              = size2,
    label.scale.equal   = label.scale.equal,
    residScale          = 2,
    mar                 = c(5,10,5,12),
    normalize           = FALSE,
    label.fill.vertical = 0.75,
    cut                 = options$highlightText,
    bg                  = "transparent"
  ))

}

.efaAddComponentsToData <- function(jaspResults, modelContainer, options, ready) {
  if(!ready || !options[["addPC"]] || options[["PCPrefix"]] == "" || modelContainer$getError()) return()

  scores <- modelContainer[["model"]][["object"]][["scores"]]

  for (i in 1:ncol(scores)) {
    scorename <- paste0(options[["PCPrefix"]], "_", i)
    if (is.null(jaspResults[[scorename]])) {
      jaspResults[[scorename]] <- createJaspColumn(scorename)
      jaspResults[[scorename]]$dependOn(optionsFromObject = modelContainer)
      jaspResults[[scorename]]$setScale(scores[, i])
    }
  }
}
