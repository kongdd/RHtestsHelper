#' get the potential reference sites
#'
#' @param st A dataframe of the sites location and covering period information,
#' with the `nrow=nsite`.
#' @param dist A distance matrix with the dimension of `[nsite, nsite]`
#' @param mat_month The monthly input data matrix, with the dimension of `[ntime, nsite]`
#'
#' @export
st_refer <- function(st, dist, mat_month) {
    sites = st$site

    st_refs = list()
    for (i in seq_along(sites)) {
        runningId(i, 100)
        disti = dist[, i]
        ind_near = which(disti <= 350) %>% setdiff(i) # in the circle buffer of 350km
        alt_t = st[i, alt]
        # |HR -HT| ≤200m if HT<2500 m; |HR -HT| ≤500m if HT≥2500 m
        alt_diffMax = ifelse(alt_t < 2500, 200, 500)

        st_ref = st[ind_near, ]
        st_ref$alt_t = alt_t
        st_ref$dist_ref = disti[ind_near]
        st_ref = st_ref[abs(alt - alt_t) <= alt_diffMax]

        period_x = st[i, c(date_begin, date_end)]
        # y = st_ref[, .(date_begin, date_end)]
        st_ref$perc_cov = period_coverage(period_x, st_ref[, .(date_begin, date_end)])
        st_ref$perc_cov_period = period_coverage(period_x, st_ref[, .(period_date_begin, period_date_end)])
        # st_ref = st_ref[!(site %in% sites_bad), ]

        ## 计算一阶导的相关系数
        ind_near2 = match(st_ref$site, sites) %>% c(i, .)
        if (length(ind_near2) == 1) {
            st_ref = NULL
        } else {
            data = mat_month[, ind_near2]
            data1 = diff(data)
            st_ref$cor <- cor(data1, use = "pairwise.complete.obs")[1, -1]
        }
        st_refs[[i]] <- st_ref
    }
    names(st_refs) <- sites
    st_refs
}

#' get the optimal reference site for each site
#'
#' @param st_refs object returned by [st_refer()]
#' @param sites_worst sites where TP is confirmed by both of monthly and yearly data
#'
#' @rdname st_refer
#' @export
st_refer_opt <- function(st_refs, sites_worst) {
    # filter bad sites out
    st_refs2 = map(st_refs, function(x) {
        if (is.null(x)) {
            return(NULL)
        } else {
            x <- x[perc_cov > 0.8 & perc_cov_period > 0.8]
            x <- x[!(site %in% sites_worst) & cor >= 0.8]
            if (nrow(x) == 0) return(NULL)

            cor_min = 0.7
            if (nrow(x[cor >= 0.90]) >= 5) cor_min = 0.90
            if (nrow(x[cor >= 0.85]) >= 5) cor_min = 0.85
            if (nrow(x[cor >= 0.80]) >= 5) cor_min = 0.80
            x <- x[cor >= cor_min, ]
            x
        }
    })
    out = map(st_refs2, function(x) {
        if (is.null(x)) {
            return(x)
        } else {
            x[which.max(perc_cov), ]
        }
    })
    nmiss <- which.isnull(out) %>% length()
    warn(sprintf("[w] %s sites have no reference site!\n", nmiss))
    out
}


#' the percentage of overlaped date period of x and y to the length of period x
#'
#' @param x A vector with `date_begin` and `date_end`.
#' @param y A data.frame with the columns of `date_begin` and `date_end`
#'
#' @export
period_coverage <- function(x, y) {
    date_begin <- pmax(x[1], y[[1]])
    date_end <- pmin(x[2], y[[2]])

    units <- "days"
    n_valid <- difftime(date_end, date_begin, units = units) %>% as.numeric()
    n_all <- difftime(x[2], x[1], units = units) %>% as.numeric()
    n_valid / n_all

    # n = 0
    # n_miss_head = difftime(x[1], date_begin, units = "days")
    # n_miss_tail = -difftime(x[2], date_begin, units = "days")
    # as.numeric(n_miss_head + n_miss_tail)
}

#' select reference sites
#'
#' @param df2 a data.frame with columns of `site`, `date`, and `varname`
#' @param sites_worst sites with significant TPs
#'
#' @import glue
#' @importFrom lubridate ymd
#' @export
find_refer <- function(df2, st, varname = "Tavg", sites_worst) {
    file = glue("OUTPUT/mete2481_{varname}_st_refer.rda")

    if (!file.exists(file)) {
        coord = st[, .(lon = deg2dec(lon), lat = deg2dec(lat))] %>% as.matrix()
        dist = rdist.earth(coord)

        date_max = max(df2$date)
        date_min = min(df2$date)
        date <- seq(ymd(date_min), ymd(date_max), by = "day")
        mat <- dcast(df2, date ~ site, value.var = varname)[, -1] %>% as.matrix()

        ## when aggregate daily to monthly scale, if more than 3 invalid values, monthly
        # value will be set to NA
        mat_month <- apply_col(mat, by = format(date, "%Y-%m-01"))
        mat_month_miss <- apply_col(is.na(mat), by = format(date, "%Y-%m-01"), colSums2)
        mat_month[mat_month_miss >= 3] <- NA_real_

        ## searching potential reference sites
        # check site names order first
        if (!isTRUE(all.equal(st$site %>% as.character(), colnames(mat)))) {
            stop("check site names order first!")
        }

        # 1. 站点长度至少大于30年（76个站点被移除）
        st_refs <- st_refer(st, dist, mat_month)
        st_refs_opt <- st_refer_opt(st_refs, sites_worst)
        d_refs <- melt_list(st_refs_opt %>% rm_empty(), "target")
        save(st_refs, st_refs_opt, d_refs, file = file)
    }
    load(file, envir = .GlobalEnv)
}
