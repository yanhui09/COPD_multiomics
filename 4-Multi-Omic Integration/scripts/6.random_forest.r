# files required:
# 1) "4_MetaG.MetaB.modules.linked.txt": resulting data generated from script "4_MetaG.MetaB.link.r"
# 2) "4_MetaB.HostT.modules.linked.txt": resulting data generated from script "4_MetaB.HostT.link.r"
# 3) "meta.mediation.NUE.txt": meta data containing clinical variable NEU
# 4) "1_metaG-combined.gct": MetaG module abundance generated by ssGSEA2 
# 5) "1_metaB.module_eigengene.txt": MetaB module abundance generated by WGCNA
# 6) "1_hostT.module_eigengene.txt": HostT module abundance generated by WGCNA

# output:
# "Output/6_NEU_prediction.performance_byLinks.rf.txt": prediction performance of MetaG-MetaB-HostT links to predict clinical variable NEU

source("functions/rf_MetaG.MetaB.HostT.links.R")
source("functions/io.R")

library(data.table)
library(dplyr)

library("tidymodels")
library(tidyverse)
library("workflows")
library("tune")
library(ranger)


# organize MetaB data into a dataframe with rownames being modules and colnames being samples
MetaB.Mod.dat <- fread("1_DimReduction/metaB.module_eigengene.txt",data.table = F)  # %>%
 # dplyr::filter(!grepl("#",`#NAME`,fixed=T)) 
MetaB.Mod.dat[-1] <- sapply(MetaB.Mod.dat[-1], as.numeric)
MetaB.Mod.dat <- MetaB.Mod.dat %>% tibble::column_to_rownames("V1")
MetaB.Mod.dat <- MetaB.Mod.dat %>% t() %>% as.data.frame()
colnames(MetaB.Mod.dat) <- sapply(colnames(MetaB.Mod.dat), 
                                  function(x)if(grepl("^\\d",x,perl = T) ) paste("X",x,sep = "") else x)
grep("^\\d",colnames(MetaB.Mod.dat))
rownames(MetaB.Mod.dat) <- sub("MetaB_","",rownames(MetaB.Mod.dat))

# organize HostT data into a dataframe with rownames being modules and colnames being samples
HostT.Mod.dat <- fread("1_DimReduction/hostT.module_eigengene.txt",data.table = F) #%>%
 # dplyr::filter(!grepl("#",`#NAME`,fixed=T)) 
HostT.Mod.dat[-1] <- sapply(HostT.Mod.dat[-1], as.numeric)
HostT.Mod.dat <- HostT.Mod.dat %>% tibble::column_to_rownames("V1")
HostT.Mod.dat <- HostT.Mod.dat %>% t() %>% as.data.frame()
colnames(HostT.Mod.dat) <- sapply(colnames(HostT.Mod.dat), 
                                  function(x)if(grepl("^\\d",x,perl = T) ) paste("X",x,sep = "") else x)
grep("^\\d",colnames(HostT.Mod.dat))
rownames(HostT.Mod.dat) <- sub("HostT_","",rownames(HostT.Mod.dat))


# first identify the MetaG-MetaB-HostT  links ---------


# version2,跟v1的输出格式不同
if(T){
  MetaG.MetaB.links <- 
    fread("3_Biological_Links/final/4_MetaG.MetaB.modules.NEU.linked.txt", data.table = F )%>%
    mutate(MetaG.module = sapply(strsplit(module_pair, "_", fixed = T), "[[", 1),
           MetaB.module = sapply(strsplit(module_pair, "_", fixed = T), "[[", 2)) %>%
    select(module_pair, MetaG.module,MetaB.module) %>%
    unique()
  colnames(MetaG.MetaB.links)[1] <- "V1"
  
  
  MetaB.HostT.links <- fread("3_Biological_Links/final/4_MetaB.HostT.modules.NEU.linked.txt", data.table = F ) %>%
    mutate(MetaB.module = sapply(strsplit(MetaB.HostT_modulePair, "_", fixed = T), "[[", 1),
           HostT.module = sapply(strsplit(MetaB.HostT_modulePair, "_", fixed = T), "[[", 2)) %>%
    select(MetaB.HostT_modulePair, MetaB.module, HostT.module) %>%
    unique() 
  colnames(MetaB.HostT.links)[1] <- "V1"
  
  
  MetaG.MetaB.HostT.links <- NULL
  for(i in c(1:nrow(MetaG.MetaB.links)) ){
    
    gb.pair = MetaG.MetaB.links$V1[i]
    
    bm = strsplit(gb.pair, "_", fixed = T)[[1]][2]
    
    bt.pairs <- MetaB.HostT.links$V1[which(MetaB.HostT.links$MetaB.module == bm)] 
    
    tmp <- expand.grid(gb.pair, bt.pairs)
    
    MetaG.MetaB.HostT.links <- bind_rows(MetaG.MetaB.HostT.links, tmp)
    
  } 
  
  MetaG.MetaB.HostT.links <- MetaG.MetaB.HostT.links %>%
    mutate(Var1 = as.character(Var1), Var2 = as.character(Var2)) %>%
    mutate(MetaG = sapply( strsplit(Var1,"_",fixed = T), "[[", 1) ,
           MetaB = sapply( strsplit(Var1,"_",fixed = T), "[[", 2) , 
           HostT = sapply( strsplit(Var2,"_",fixed = T), "[[", 2))
  
}






# then create a predicted variable data frame ----- 
meta <- fread("source.data/meta.mediation.NEU.txt") %>% select(SampleID, NEU) 
meta$SampleID[grepl("^\\d", meta$SampleID, perl=T)] <- paste("X", meta$SampleID[grepl("^\\d", meta$SampleID, perl=T)], sep="" )



# last, perform random forest analysis -----------

##  Import data      
log.file = "rf_by.links.log"
cat(paste("\n\n",as.character(Sys.time()), '\n'),  file=log.file, append=T)
cat("Importing data : \n", file=log.file, append=T)


# metagenomic data ------
m1 <- parse.gctx("1_metagenome-combined.gct")@mat %>% t() %>% data.frame()

#colnames(m1) <- paste("MetaG.", colnames(m1),sep = "")

# metabolomic data -----
m2 = MetaB.Mod.dat
feature.abb_df1 <- cbind.data.frame(feature = rownames(m2),
                                    abb = paste("feature",seq(1,nrow(m2),1),sep = ""),
                                    stringsAsFactors = F)
rownames(m2) <- sapply(rownames(m2), function(x) feature.abb_df1$abb[which(feature.abb_df1$feature == x)])
m2 <- t(m2) %>% as.data.frame(stringsAsFactors=F)
colnames(m2) <- sapply(colnames(m2), function(x) feature.abb_df1$feature[which(feature.abb_df1$abb == x)])

#colnames(m2) <- paste("MetaB.", colnames(m2),sep = "")


# host transcriptomic data -----
m3 = HostT.Mod.dat
feature.abb_df1 <- cbind.data.frame(feature = rownames(m3),
                                    abb = paste("feature",seq(1,nrow(m3),1),sep = ""),
                                    stringsAsFactors = F)
rownames(m3) <- sapply(rownames(m3), function(x) feature.abb_df1$abb[which(feature.abb_df1$feature == x)])
m3 <- t(m3) %>% as.data.frame(stringsAsFactors=F)
colnames(m3) <- sapply(colnames(m3), function(x) feature.abb_df1$feature[which(feature.abb_df1$abb == x)])

#colnames(m3) <- paste("HostT.", colnames(m3),sep = "")


# clinical variable of interest -------


Predicted.dat <- meta
Y = colnames(Predicted.dat)[colnames(Predicted.dat) != "SampleID"] 
colnames(Predicted.dat)[which(colnames(Predicted.dat) == Y)] <- "Y"
head(Predicted.dat)

# match rows of all the data frames ------
completeSps <- intersect(intersect(intersect(rownames(m1), rownames(m2)), rownames(m3)), Predicted.dat$SampleID)
m1 <- m1[match(completeSps, rownames(m1)),]
m2 <- m2[match(completeSps, rownames(m2)),]
m3 <- m3[match(completeSps, rownames(m3)),]
Predicted.dat <- Predicted.dat[match(completeSps, Predicted.dat$SampleID),]



# MetaG.MetaB.HostT.link -------
link.df <- MetaG.MetaB.HostT.links


## ############################################################################
##                                                                           ## 
##         integrate data for random forest                                  ## 
##                                                                           ## 
## ############################################################################

cat("Performing random forest modeling : \n", file=log.file, append=T)


Performance <- NULL
for(i in c(1:nrow(link.df))){ # nrow(link.df)
  # i=1
  
  if(i %% 100 == 0) cat(paste("----progress: predicting ", Y, "with link ", i ," out of the total ", nrow(link.df), " links ----------", sep = "") , file=log.file, append=T )
  
  Gm <- sub("MetaG\\.","", link.df$MetaG[i])
  Bm <- sub("MetaB\\.","",link.df$MetaB[i])
  Tm <- sub("HostT\\.", "", link.df$HostT[i])
  
  rf_dat <- cbind.data.frame(SampleID = rownames(m1), 
                             MetaG = m1[,Gm], 
                             MetaB = m2[,Bm],
                             HostT = m3[,Tm],
                             Y = Predicted.dat$Y,
                             stringsAsFactors=F)
  
  rf_dat <- rf_dat[complete.cases(rf_dat),]
  
  # split the data into traing and testing sets 
  GZ.sp <-meta$SampleID[!grepl("^Z", meta$SampleID)] 
  Training.samples = GZ.sp
  
  set.seed(100)
  if( is.null(Training.samples) ){
    rf_dat <- rf_dat[,-which(colnames(rf_dat) == "SampleID")]
    my_split <- initial_split(rf_dat,  prop = 2/4, strata = Y) 
    my_train <- training(my_split)
    my_test <- testing(my_split)
  }else {
    tmp.ids <- unlist(sapply(Training.samples, function(x) which(rf_dat$SampleID == x))) 
    
    rf_dat <- rf_dat[,-which(colnames(rf_dat) == "SampleID")]
    
    my_split <- initial_split(rf_dat) 
    my_split$in_id <- unname(tmp.ids)  # manually adjust training sample ids 
    my_train <- training(my_split)
    my_test <- testing(my_split)
    
  }
  
  
  # create a cross validation version of the training set for parameter tuning
  my_cv <- vfold_cv(my_train, v = 5)
  
  # define the recipe
  my_recipe <- 
    # which consists of the formula (outcome ~ predictors)
    recipe(Y ~ ., data = rf_dat)  # %>%
  #step_knnimpute(all_predictors()) # missing value
  
  
  # Specify the model --------------------------------------
  PredictionType = "regression" 
  
  rf_model <- 
    # specify that the model is a random forest
    rand_forest() %>%  # ?rand_forest shows the tunable parameters
    # specify that the `mtry` parameter needs to be tuned
    set_args(mtry = tune(), trees=tune(),min_n=10) %>%
    # select the engine/package that underlies the model
    set_engine("ranger", importance = "impurity") %>% # if to examine the variable importance of your final model need to set importance = 
    # choose either the continuous regression or binary classification mode
    set_mode(PredictionType) 
  
  
  
  #  Put it all together in a workflow -----------------------------------
  # set the workflow
  rf_workflow <- workflow() %>%
    # add the recipe
    add_recipe(my_recipe) %>%
    # add the model
    add_model(rf_model) 
  
  
  # Tune the parameters ----------------------------------
  # specify which values eant to try
  rf_grid <- expand.grid(mtry = c(1,2,3), trees=c(500,1000,1500,2000,2500)) 
  # extract results
  if(PredictionType == "regression"){
    rf_tune_results <- rf_workflow %>%
      tune_grid(resamples = my_cv, #CV object
                grid = rf_grid, # grid of values to try
                metrics = metric_set(rmse) # metrics we care about
      )
    resultSelect = "rmse"
  }else{
    rf_tune_results <- rf_workflow %>%
      tune_grid(resamples = my_cv, #CV object
                grid = rf_grid, # grid of values to try
                metrics = metric_set(accuracy, roc_auc) # metrics we care about
      )
    resultSelect = "accuracy"
  }
  
  # autoplot(rf_tune_results)
  
  # print results
  results_df <- rf_tune_results %>%
    collect_metrics()
  
  # Finalize the workflow ------------------------------------------
  
  param_final <- rf_tune_results %>%
    select_best(metric = resultSelect) 
  param_final
  
  rf_workflow <- rf_workflow %>%
    finalize_workflow(param_final) 
 
  
  # Evaluate the model on the test set --------------------------------
  rf_fit <- rf_workflow %>%
    # fit on the training set and evaluate on test set
    last_fit(my_split) # train the training dataset and evaluate the test dataset
  
  
  
  # check performance
  performance <- rf_fit %>% collect_metrics()
  performance  
  
  if(PredictionType == "regression"){
    # manually calculate mae
    predictions <- rf_fit %>% collect_predictions()
    MAE <- predictions %>% mae(Y,`.pred` )
    
    # bind MAE
    performance <- bind_rows(performance,MAE ) 
  }
  
  
  # bind MAE and transfer performance to wide 
  performance <- performance %>% select(-`.estimator`, -`.config`) # %>%
   # as.data.frame() %>%
   # reshape2::dcast(0 ~ `.metric`) %>%
   # select(-`0`)
  
  performance$MetaG.MetaB.HostT.link = paste(Gm, Bm, Tm, sep = "_")
  performance$mtry = param_final$mtry
  performance$trees = param_final$trees
  
  performance <- performance  %>% 
    relocate(MetaG.MetaB.HostT.link, mtry, trees)
  
  Performance <- bind_rows(Performance, performance)
  
  
}

write.table(Performance, file = "Output/6_NEU_prediction.performance_byLinks.rf.txt", sep = "\t", quote = F, row.names = F)



