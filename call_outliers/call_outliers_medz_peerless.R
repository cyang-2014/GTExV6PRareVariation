#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly=T)
if (length(args) != 1) {
  cat("Usage: R -f call_outliers_medz_peerless.R --slave --vanilla --args PEERSuffix\n", file=stderr())
  quit(status=2)
}

dir = Sys.getenv('RAREVARDIR')

# Load libraries
library(data.table)
library(reshape2)
library(plyr)
library(doMC)

###
### Setup parallel processing
###
doMC::registerDoMC(cores=12)

############ FUNCTIONS

###
### Functions for calculating number of tissues/sample and meta-analysis z-score
###
meta.n = function(values) {
	length(values) - sum(is.na(values))
}

meta.median = function(values) {
	median(values, na.rm=T)
}

meta.analysis = function(x) {
	samples=colnames(x)[3:ncol(x)]
	y = t(x[,3:ncol(x)]) # individuals (rows) x tissues (columns)
	n = apply(y, 1, meta.n)
	m1 = apply(y, 1, meta.median)
	data.frame(sample = samples, n.tissues = n, median.z = m1)
}

## Function to pick outliers from Median Z method
## Picks only a single outlier per gene
pick_outliers <- function(xinz, counts, individs){
	outlier_indices = as.numeric(apply(abs(xinz), 1, which.max))
	return(data.frame(INDS = factor(individs[outlier_indices], levels = individs), 
		DFS = counts[cbind(1:nrow(counts), outlier_indices)], Z = xinz[cbind(1:nrow(xinz), outlier_indices)]))
}


############ MAIN

# Define arguments
PEERSuffix = args[1]

###
### Loading data
###
## Load flat file with filtered and normalized expression data
data = fread(paste(dir, '/preprocessing/gtex_2015-01-12_normalized_expression', PEERSuffix, sep = ''), header = T)

setkey(data, Gene)

## Read in sample list
individs = colnames(data)[-c(1,2)]

## Read in list of GENCODE genes with types
genes_types = read.table(paste0(dir, '/reference/gencode.v19.genes.v6p.patched_contigs_genetypes_autosomal.txt'), sep = '\t', header = F, stringsAsFactors = F)

## Filter for protein_coding and lincRNA genes
types_to_keep = c('protein_coding', 'lincRNA')
genes_types = genes_types[genes_types[, 2] %in% types_to_keep, ]
data = data[data$Gene %in% genes_types[, 1], ]

## Calculate meta-analysis test statistics
results = ddply(data, .(Gene), meta.analysis, .parallel = TRUE)

## For samples with < n tissues, set test statistics to NA
tissue_threshold = 5
indexer = results$n.tissues < tissue_threshold
results[indexer, 4:ncol(results)] = NA

## Unmelt results to yield data frames of tissue counts, meta Z scores, and p-values for Stouffer's method
counts = dcast(data = results, Gene ~ sample, value.var = 'n.tissues')
rownames(counts) = counts$Gene
counts = counts[, -1]
counts = counts[, individs]

medz = dcast(data = results, Gene ~ sample, value.var = 'median.z')
rownames(medz) = medz$Gene
medz = medz[, -1]
medz = medz[, individs]

genes = rownames(medz)


## Write out unmelted summary matrices
header = matrix(c('GENE', colnames(counts)), nrow = 1)
write.table(header, paste(dir, '/data/outliers_medz_counts', PEERSuffix, sep = ''), sep = '\t', col.names = F, row.names = F, quote = F)
write.table(header, paste(dir, '/data/outliers_medz_zscores', PEERSuffix, sep = ''), sep = '\t', col.names = F, row.names = F, quote = F)

write.table(counts, paste(dir, '/data/outliers_medz_counts', PEERSuffix, sep = ''), sep = '\t', col.names = F, row.names = T, quote = F, append = T)
write.table(medz, paste(dir, '/data/outliers_medz_zscores', PEERSuffix, sep = ''), sep = '\t', col.names = F, row.names = T, quote = F, append = T)

## Pick outliers from Xin's method
## Remove individuals with >= 50 outliers 
## Write to file
## Also write out list of individuals that pass outlier count threshold
medz_thresh = 2
medz_ind_filt = 50
medz_picked = pick_outliers(medz, counts, individs)
medz_picked$GENE = genes
medz_picked = medz_picked[, c('GENE', 'INDS', 'DFS', 'Z')]
medz_picked = medz_picked[!is.na(medz_picked$INDS),]
# subset thresholding on median z-score
medz_picked_thresh = medz_picked[abs(medz_picked$Z) >= medz_thresh, ]
medz_picked_thresh = medz_picked_thresh[order(-abs(medz_picked_thresh$Z)), ]
medz_ind_counts = table(medz_picked_thresh$INDS)
medz_ind_picked = names(medz_ind_counts)[medz_ind_counts < medz_ind_filt]
medz_picked_thresh = medz_picked_thresh[medz_picked_thresh$INDS %in% medz_ind_picked, ]
write.table(medz_picked_thresh, paste(dir, '/data/outliers_medz_picked', PEERSuffix, sep = ''), col.names = T, row.names = F, quote = F, sep = '\t')
write.table(medz_ind_picked, paste(dir, '/data/outliers_medz_picked_qc_samples', PEERSuffix, sep = ''), col.names = F, row.names = F, quote = F, sep = '\t')
write.table(medz_ind_counts, paste(dir, '/data/outliers_medz_picked_counts_per_ind', PEERSuffix, sep = ''), col.names = F, row.names = F, quote = F, sep = '\t')
# clean up the unthresholded set
medz_picked = medz_picked[medz_picked$INDS %in% medz_ind_picked, ]
medz_picked = medz_picked[order(-abs(medz_picked$Z)), ]
write.table(medz_picked, paste(dir, '/data/outliers_medz_nothreshold_picked', PEERSuffix, sep = ''), col.names = T, row.names = F, quote = F, sep = '\t')

## Filter WGS individual lists for individuals that pass the number of outlier filters
wgs.feat.inds = read.table('../preprocessing/gtex_2015-01-12_wgs_ids.txt', sep = '\t', header = F, stringsAsFactors = F)[, 1]
wgs.count.inds = read.table('../preprocessing/gtex_2015-01-12_wgs_ids_HallLabSV.txt', sep = '\t', header = F, stringsAsFactors = F)[, 1]

wgs.feat.inds = wgs.feat.inds[wgs.feat.inds %in% medz_ind_picked]
wgs.count.inds = wgs.count.inds[wgs.count.inds %in% medz_ind_picked]

write.table(wgs.feat.inds, paste(dir, '/preprocessing/gtex_2015-01-12_wgs_ids_outlier_filtered', PEERSuffix, sep = ''), quote = F, sep = '\t', col.names = F, row.names = F)
write.table(wgs.count.inds, paste(dir, '/preprocessing/gtex_2015-01-12_wgs_ids_HallLabSV_outlier_filtered', PEERSuffix, sep = ''), quote = F, sep = '\t', col.names = F, row.names = F)


