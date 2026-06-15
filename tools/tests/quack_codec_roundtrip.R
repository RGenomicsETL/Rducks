dyn.load("quack.so")
spec <- function(id, width=0L, scale=0L, array_size=0L, children=list(), enum_labels=character()) {
  list(id=as.integer(id), width=as.integer(width), scale=as.integer(scale),
       array_size=as.integer(array_size), children=children, enum_labels=enum_labels)
}
col <- function(data, valid=NULL) list(valid=valid, data=data)

types <- list(
  spec(13L),                                   # INTEGER
  spec(25L),                                   # VARCHAR
  spec(50L),                                   # HUGEINT
  spec(21L, width=12L, scale=3L),              # DECIMAL(12,3) -> int64 storage
  spec(54L),                                   # UUID
  spec(104L, enum_labels=c("lo","mid","hi")),  # ENUM
  spec(101L, children=list(child=spec(13L))),  # LIST(INTEGER)
  spec(100L, children=list(a=spec(23L), b=spec(25L))), # STRUCT(a DOUBLE, b VARCHAR)
  spec(27L),                                   # INTERVAL
  spec(26L)                                    # BLOB
)
columns <- list(
  col(c(7L, NA, -42L)),
  col(c("alpha", NA, "gamma")),
  col(c("170141183460469231731687303715884105727", "-170141183460469231731687303715884105728", NA)),
  col(c("1234567891234", "-5", NA)),
  col(c("550e8400-e29b-41d4-a716-446655440000", NA, "00000000-0000-0000-0000-000000000001")),
  col(c(1L, 3L, NA)),
  col(list(offsets=c(0, 2, 2), lengths=c(2, 0, 2),
           child=col(c(1L, 2L, 3L, 4L))),
      valid=c(TRUE, TRUE, TRUE)),
  col(list(a=col(c(1.5, NA, 3.25)), b=col(c("x", "y", NA)))),
  col(list(months=c(1L, NA, 0L), days=c(2L, NA, 30L), micros=c(5e6, NA, 0))),
  col(list(as.raw(c(1,2,3)), NULL, raw(0)))
)
payload <- .Call("RDUCKS_quack_encode_chunk", 3, types, columns)
cat("payload bytes:", length(payload), "\n")
dec <- .Call("RDUCKS_quack_decode_chunk", payload, NULL)
stopifnot(dec$rows == 3)
stopifnot(identical(dec$columns[[1]]$data, c(7L, NA, -42L)))
stopifnot(identical(dec$columns[[1]]$valid, c(TRUE, FALSE, TRUE)))
stopifnot(identical(dec$columns[[2]]$data, c("alpha", NA, "gamma")))
stopifnot(identical(dec$columns[[3]]$data, c("170141183460469231731687303715884105727", "-170141183460469231731687303715884105728", NA)))
stopifnot(identical(dec$columns[[4]]$data, c("1234567891234", "-5", NA)))
stopifnot(identical(dec$columns[[5]]$data, c("550e8400-e29b-41d4-a716-446655440000", NA, "00000000-0000-0000-0000-000000000001")))
stopifnot(identical(dec$columns[[6]]$data, c(1L, 3L, NA)))
stopifnot(identical(dec$types[[6]]$enum_labels, c("lo","mid","hi")))
lst <- dec$columns[[7]]$data
stopifnot(identical(lst$offsets, c(0, 2, 2)), identical(lst$lengths, c(2, 0, 2)))
stopifnot(identical(lst$child$data, c(1L, 2L, 3L, 4L)))
stc <- dec$columns[[8]]$data
stopifnot(identical(names(stc), c("a","b")))
stopifnot(identical(stc$a$data, c(1.5, NA, 3.25)))
stopifnot(identical(stc$b$data, c("x","y",NA)))
iv <- dec$columns[[9]]$data
stopifnot(identical(iv$months, c(1L, NA, 0L)), identical(iv$micros, c(5e6, NA, 0)))
bl <- dec$columns[[10]]$data
stopifnot(identical(bl[[1]], as.raw(c(1,2,3))), is.null(bl[[2]]), identical(bl[[3]], raw(0)))
stopifnot(identical(dec$types[[4]]$width, 12L), identical(dec$types[[4]]$scale, 3L))
# adversarial: every truncation must error, never crash
errs <- 0L
for (cut in seq_len(length(payload) - 1L)) {
  r <- tryCatch({.Call("RDUCKS_quack_decode_chunk", payload[seq_len(cut)], NULL); FALSE},
                error = function(e) TRUE)
  if (r) errs <- errs + 1L
}
stopifnot(errs == length(payload) - 1L)
cat("R glue roundtrip + truncation fuzz: OK\n")
