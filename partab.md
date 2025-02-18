# Demo: Multilevel int partitioning in kdb+

kdb+ has [four](https://code.kx.com/q/kb/partition/) allowable partition column types: date, month, year, and long. 

Partitioning by long (AKA int partitioning) is the most flexible of the four, since it has arbitrary granularity and no timeseries dependency. The only requirement is that each table row in the database can be encoded as a non-negative long integer number.

For example, when writing to an intraday database (IDB), TorQ's `partbyenum` write mode encodes the values of each table's `p#` column (typically `sym`) as integers according to their index in the `sym` enumeration file. As a result, no extra sorting is needed when moving the IDB to a new date partition at the end of the day - the `p#` attribute is assured by simply concatenating the int partitions.

Some database file structures like Parquet support multiple partition levels, e.g. `database/sym=x/year=2025/month=1/file.parquet`. Although more partitions generally means more disk storage cost, there are two big benefits:
1. Simple "lookup" queries (i.e. those with minimal aggregation across partitions, like `select from table where...`) can be quickly directed to a small number of small partitions, so these queries can be much faster, especially if they filter on every partition dimension.
2. Likewise, updates to on-disk data can target a small number of small partitions, thereby minimizing redundant rewrites.

Unfortunately kdb+ currently does not support loading directory structures with multiple levels of partitioning - i.e. it is possible to load a directory with a file structure like `database/12/table/`, but not `database/12/34/table/`.

However, this does not mean that kdb+ does not support multiple levels of partitioning. After all, a single integer can encode information from multiple columns, an approach used in [IoT applications](https://dataintellect.com/blog/kdb-iot/).

This document demonstrates a simple, **generalizable** approach to multilevel int partitioning in kdb+. It boils down to:

1. Choose the table column(s) to partition;
2. Derive all unique combinations of these column values as a (small) separate table, `partab`;
3. For each combination, splay the table rows with these values to an int partition equal to the `partab` row index;
4. Save `partab` to the root database directory, e.g. beside the `sym` file (it can be enumerated and given attributes if desired);
5. When querying the int partitioned table, use `partab` to decode the `int` column.

## Test data

Create a `trade` table representing one day's worth of data, with 1M rows and `p#` and `g#` attributes on the `sym`, `src`, and `side` columns.

The `sym`, `src`, and `side` columns will be the "partition columns" that get encoded as integer partitions.

In this example all the partition columns are symbol columns, but in general they don't have to be!

Note: Some `sym` and `src` values are weighted to appear more frequently than others, so int partitions will not be uniform in size.

``` q
q)n:1000000

q)trade:update `p#sym, `g#src, `g#side from `sym`time xasc ([]
    time:  .z.D+n?0D;
    sym:   n?{raze(1+til count x)#'x}`AMD`AIG`AAPL`DELL`DOW`GOOG`HPQ`INTC`IBM`MSFT;
    price: n?100f;
    size:  n?1000i;
    src:   n?{raze(1+til count x)#'x}`BARX`GETGO`SUN`DB;
    side:  n?`buy`sell
    )

q)5#trade
time                          sym  price    size src   side
-----------------------------------------------------------
2025.02.14D00:00:00.423071533 AAPL 97.6393  634  SUN   sell
2025.02.14D00:00:01.457405090 AAPL 72.10399 70   GETGO buy 
2025.02.14D00:00:02.119541913 AAPL 86.1831  818  SUN   sell
2025.02.14D00:00:02.567477524 AAPL 90.65411 273  DB    sell
2025.02.14D00:00:07.531300932 AAPL 61.72395 392  GETGO buy

q)meta trade
c    | t f a
-----| -----
time | p    
sym  | s   p
price| f    
size | i    
src  | s   g
side | s   g
```

## Writing as a simple splayed table

Enumerate the symbol columns to `idb/sym` and splay the table to `idb/trade/`:

``` q
q)`:idb/trade/ set .Q.en[`:idb] trade
`:idb/trade/
```

This splayed table will be used to benchmark query performance on the int partitioned version.

To see the effect on disk space, also splay a version without `g#` attributes:

``` q
q)`:idb/tradenogattr/ set update `#src, `#side from trade
`:idb/tradenogattr/
```

## Writing as a multilevel int partitioned table

Get the unique combinations of `sym`, `src`, and `side` values as a table, which we will call `partab`.

This table maps each combination to a single integer index (i.e. a row number) and therefore represents the enumeration domain.

``` q
q)count partab:select distinct sym, src, side from trade
80

q)5#partab
sym  src   side
---------------
AAPL SUN   sell
AAPL GETGO buy 
AAPL DB    sell
AAPL BARX  buy 
AAPL SUN   buy
```

For each row of `partab`, extract the rows from `trade` with the corresponding `sym`, `src`, and `side` values, and splay the result to `idb/partitioned/[row index]/trade/`.

When enumerating, use the same `idb/sym` file as used for the simple splayed table.

Also, since each partition will have a single value per partition column, it is possible to apply `p#` to all of these columns. This may not seem like much of a benefit, but it actually does speed up grouping queries (although they are still not as fast as on a simple splayed table - see the [grouping query example](#select-max-size-by-sym-from-trade) below).

``` q
q)count partitions:{
    (` sv .Q.par[`:idb/partitioned;y;`trade],`) set .Q.en[`:idb]
      update `p#sym, `p#src, `p#side from select from trade where sym=x`sym, src=x`src, side=x`side
    }'[partab;til count partab]
80
q)2#partitions
`:idb/partitioned/0/trade/`:idb/partitioned/1/trade/
```

Also save down `partab`, since it will be needed for converting integer partitions back to partition column values.

Technically `partab` can be derived from `trade`, but it's small enough that even as a flat kdb+ table it doesn't take up much space.

As a bonus, it can be enumerated with the same `sym` file as `trade` and it can even have the same attributes.

``` q
q)update `p#`sym$sym, `g#`sym$src, `g#`sym$side from `partab
`partab

q)meta partab
c   | t f a
----| -----
sym | s   p
src | s   g
side| s   g

q)`:idb/partab set partab
`:idb/partab
```

## Disk space comparison

The int partitioned version of the table uses more more disk space than the splayed version _without_ `g#` attributes, but less than the splayed version _with_ `g#` attributes.

Also, in this example at least, the serialized `partab` object is no larger than the `sym` file.

``` bash
$ du -sh idb/*
4.0K    idb/partab
45M     idb/partitioned
4.0K    idb/sym
58M     idb/trade
42M     idb/tradenogattr
```

Due to some partition column value combinations being more frequent than others, individual partition sizes vary from to `64K` to `1.6M`:

``` bash
$ du -sh idb/partitioned/*/trade/

372K    idb/partitioned/0/trade/        660K    idb/partitioned/27/trade/       988K    idb/partitioned/45/trade/       724K    idb/partitioned/63/trade/
264K    idb/partitioned/1/trade/        196K    idb/partitioned/28/trade/       988K    idb/partitioned/46/trade/       968K    idb/partitioned/64/trade/
196K    idb/partitioned/10/trade/       352K    idb/partitioned/29/trade/       264K    idb/partitioned/47/trade/       636K    idb/partitioned/65/trade/
264K    idb/partitioned/11/trade/       152K    idb/partitioned/3/trade/        1.1M    idb/partitioned/48/trade/       1.3M    idb/partitioned/66/trade/
352K    idb/partitioned/12/trade/       196K    idb/partitioned/30/trade/       856K    idb/partitioned/49/trade/       1.3M    idb/partitioned/67/trade/
108K    idb/partitioned/13/trade/       352K    idb/partitioned/31/trade/       264K    idb/partitioned/5/trade/        660K    idb/partitioned/68/trade/
108K    idb/partitioned/14/trade/       812K    idb/partitioned/32/trade/       856K    idb/partitioned/50/trade/       352K    idb/partitioned/69/trade/
196K    idb/partitioned/15/trade/       416K    idb/partitioned/33/trade/       308K    idb/partitioned/51/trade/       152K    idb/partitioned/7/trade/
152K    idb/partitioned/16/trade/       616K    idb/partitioned/34/trade/       1.1M    idb/partitioned/52/trade/       968K    idb/partitioned/70/trade/
176K    idb/partitioned/17/trade/       220K    idb/partitioned/35/trade/       572K    idb/partitioned/53/trade/       352K    idb/partitioned/71/trade/
196K    idb/partitioned/18/trade/       240K    idb/partitioned/36/trade/       308K    idb/partitioned/54/trade/       1.2M    idb/partitioned/72/trade/
108K    idb/partitioned/19/trade/       416K    idb/partitioned/37/trade/       592K    idb/partitioned/55/trade/       1.6M    idb/partitioned/73/trade/
504K    idb/partitioned/2/trade/        812K    idb/partitioned/38/trade/       1.1M    idb/partitioned/56/trade/       416K    idb/partitioned/74/trade/
108K    idb/partitioned/20/trade/       616K    idb/partitioned/39/trade/       1.4M    idb/partitioned/57/trade/       1.6M    idb/partitioned/75/trade/
64K     idb/partitioned/21/trade/       396K    idb/partitioned/4/trade/        1.5M    idb/partitioned/58/trade/       812K    idb/partitioned/76/trade/
64K     idb/partitioned/22/trade/       724K    idb/partitioned/40/trade/       724K    idb/partitioned/59/trade/       1.2M    idb/partitioned/77/trade/
152K    idb/partitioned/23/trade/       504K    idb/partitioned/41/trade/       504K    idb/partitioned/6/trade/        812K    idb/partitioned/78/trade/
660K    idb/partitioned/24/trade/       504K    idb/partitioned/42/trade/       1.1M    idb/partitioned/60/trade/       416K    idb/partitioned/79/trade/
504K    idb/partitioned/25/trade/       748K    idb/partitioned/43/trade/       372K    idb/partitioned/61/trade/       264K    idb/partitioned/8/trade/
484K    idb/partitioned/26/trade/       264K    idb/partitioned/44/trade/       372K    idb/partitioned/62/trade/       352K    idb/partitioned/9/trade/
```

## Loading comparison

For the int partitioned table, in addition to the `sym` file, it's necessary to load `partab` to decode the `int` column.

<style>
    table {
        width: 100%;
    }
</style>

<table>
<tr>
<th>Simple splayed table with `p#sym, `g#src, `g#side</th>
<th>Same table int partitioned on sym, src, side</th>
</tr>
<tr>
<td>

``` q
q)load `:idb/trade
`trade

q)load `:idb/sym
`sym




q)count trade
1000000

q)meta trade
c    | t f a
-----| -----
time | p    
sym  | s   p
price| f    
size | i    
src  | s   g
side | s   g

```
</td>
<td>

``` q
q)\l idb/partitioned/


q)load `:../sym
`sym

q)load `:../partab
`partab

q)count trade
1000000

q)meta trade
c    | t f a
-----| -----
int  | j    
time | p    
sym  | s   p
price| f    
size | i    
src  | s   p
side | s   p
```
</td>
</tr>
</table>

## Query comparison

### select from trade where sym=x, src=y, side=z

This query pattern, where we filter all of the partition column values to a single value, is where the int partitioned table performs best, since we quickly narrow down the search to a single partition on disk.

<table>
<tr>
<th>Simple splayed table with `p#sym, `g#src, `g#side</th>
<th>Same table int partitioned on sym, src, side</th>
</tr>
<tr>
<td>

``` q
q)count select from trade where sym=`MSFT, src=`DB, side=`buy
36570


q)\ts:100 select from trade where sym=`MSFT, src=`DB, side=`buy
134 4457440


















```
</td>
<td>

``` q
q)count select from trade where sym=`MSFT, src=`DB, side=`buy
36570

q)// slow because no filter on int column
q)\ts:100 select from trade where sym=`MSFT, src=`DB, side=`buy
1608 6864208

q)// equivalent where clause on int column
q)count select from trade where int=partab?`sym`src`side!`MSFT`DB`buy
36570

q)\ts:100 select from trade where int=partab?`sym`src`side!`MSFT`DB`buy
26 526896

q)// alternative syntax
q)count select from trade where int in exec i from partab where sym=`MSFT, src=`DB, side=`buy
36570

q)\ts:100 select from trade where int in exec i from partab where sym=`MSFT, src=`DB, side=`buy
25 527408

q)// number of partitions being queried
q)count select from partab where sym=`MSFT, src=`DB, side=`buy
1
```
</td>
</tr>
</table>

### select from trade where sym=x

Filtering on a subset of partition columns is slower because results from multiple partitions are returned.

<table>
<tr>
<th>Simple splayed table with `p#sym, `g#src, `g#side</th>
<th>Same table int partitioned on sym, src, side</th>
</tr>
<tr>
<td>

``` q
q)count select from trade where sym=`MSFT
181968

q)\ts:100 select from trade where sym=`MSFT
78 11534976


















```
</td>
<td>

``` q
q)count select from trade where sym=`MSFT
181968

q)\ts:100 select from trade where sym=`MSFT
1977 29015344

q)// equivalent where clause on int column*
q)count select from trade where int in where partab[`sym]=`MSFT
181968

q)\ts:100 select from trade where int in where partab[`sym]=`MSFT
329 18093776

q)// alternative syntax
q)count select from trade where int in exec i from partab where sym=`MSFT
181968

q)\ts:100 select from trade where int in exec i from partab where sym=`MSFT
342 18093904

q)// number of partitions being queried
q)count select from partab where sym=`MSFT
8
```
</td>
</tr>
</table>

*Note: performance is slightly improved when the int partitioned table does not have `p#` attributes:

``` q
q)\ts:100 select from trade where int in where partab[`sym]=`MSFT
284 15998224
```

### select from trade where sym in x, src=y

The fewer the number of partitions being queried, the better the performance.

<table>
<tr>
<th>Simple splayed table with `p#sym, `g#src, `g#side</th>
<th>Same table int partitioned on sym, src, side</th>
</tr>
<tr>
<td>

``` q
q)count select from trade where sym in `MSFT`AMD, src=`DB
79770

q)\ts:100 select from trade where sym in `MSFT`AMD, src=`DB
181 6816592


















```
</td>
<td>

``` q
q)count select from trade where sym in `MSFT`AMD, src=`DB
79770

q)\ts:100 select from trade where sym in `MSFT`AMD, src=`DB
1426 14105184

q)// equivalent where clause on int column*
q)count select from trade where int in where (partab[`sym] in `MSFT`AMD) and partab[`src]=`DB
99791

q)\ts:100 select from trade where int in where (partab[`sym] in `MSFT`AMD) and partab[`src]=`DB
157 8982848

q)// alternative syntax
q)count select from trade where int in exec i from partab where sym in `MSFT`AMD, src=`DB
99791

q)\ts:100 select from trade where int in exec i from partab where sym in `MSFT`AMD, src=`DB
138 8982752

q)// number of partitions being queried
q)count select from partab where sym in `MSFT`AMD, src=`DB
4
```
</td>
</tr>
</table>

*Note: performance is slightly improved when the int partitioned table does not have `p#` attributes:

``` q
q)\ts:100 select from trade where int in where (partab[`sym] in `MSFT`AMD) and partab[`src]=`DB
115 7934080
```

### select max size by sym from trade

Grouping by a partition column (even with a `p#` attribute) is slower than grouping by a splayed column with a `p#` attribute.

<table>
<tr>
<th>Simple splayed table with `p#sym, `g#src, `g#side</th>
<th>Same table int partitioned on sym, src, side</th>
</tr>
<tr>
<td>

``` q
q)select max size by sym from trade
sym | size
----| ----
AAPL| 999 
AIG | 999 
AMD | 999 
DELL| 999 
DOW | 999 
GOOG| 999 
HPQ | 999 
IBM | 999 
INTC| 999 
MSFT| 999

q)\ts:100 select max size by sym from trade
22 1408




```
</td>
<td>

``` q
q)select max size by sym from trade
sym | size
----| ----
AAPL| 999 
AIG | 999 
AMD | 999 
DELL| 999 
DOW | 999 
GOOG| 999 
HPQ | 999 
IBM | 999 
INTC| 999 
MSFT| 999

q)\ts:100 select max size by sym from trade
468 21936

q)// equivalent by clause on int column
q)\ts:100 select max size by sym from select max size, first sym by int from trade
447 32576
```
</td>
</tr>
</table>

Note: performance of the `by sym` query is worse when the int partitioned table does not have `p#` attribute on `sym` (but similar for the `by int` query):

``` q
q)\ts:100 select max size by sym from trade
1002 541952

q)\ts:100 select max size by sym from select max size, first sym by int from trade
480 32576
```

### select max size by sym, src, side from trade

Grouping by the single `int` column is faster than grouping by the corresponding splayed columns, even if they have attributes.

<table>
<tr>
<th>Simple splayed table with `p#sym, `g#src, `g#side</th>
<th>Same table int partitioned on sym, src, side</th>
</tr>
<tr>
<td>

``` q
q)\ts:100 select max size by sym, src, side from trade
1525 50332992




```
</td>
<td>

``` q
q)\ts:100 select max size by sym, src, side from trade
2406 3179680

q)// equivalent by clause on int column
q)\ts:100 select max size, first sym, first src, first side by int from trade
837 40848
```
</td>
</tr>
</table>

### select vwap:size wavg price by sym from trade

A map-reduce approach on the `int` column can be used to improve the performance of certain calculations, but a simple splayed table with attributes is better optimized for these types of queries.

<table>
<tr>
<th>Simple splayed table with `p#sym, `g#src, `g#side</th>
<th>Same table int partitioned on sym, src, side</th>
</tr>
<tr>
<td>

``` q
q)select vwap:size wavg price by sym from trade
sym | vwap    
----| --------
AAPL| 49.97457
AIG | 49.90854
AMD | 49.89297
DELL| 50.04895
DOW | 49.99549
GOOG| 49.75117
HPQ | 50.14153
IBM | 49.97071
INTC| 50.1727 
MSFT| 50.08773

q)\ts:100 select vwap:size wavg price by sym from trade
365 19793808


















```
</td>
<td>

``` q
q)select vwap:size wavg price by sym from trade
sym | vwap    
----| --------
AAPL| 49.97457
AIG | 49.90854
AMD | 49.89297
DELL| 50.04895
DOW | 49.99549
GOOG| 49.75117
HPQ | 50.14153
IBM | 49.97071
INTC| 50.1727 
MSFT| 50.08773

q)\ts:100 select vwap:size wavg price by sym from trade
1213 1859872

q)// map-reduce method using int column
q)select vwap:(sum num)%sum size by sym from select num:sum price*size, sum size, first sym by int from trade
sym | vwap    
----| --------
AAPL| 49.97457
AIG | 49.90854
AMD | 49.89297
DELL| 50.04895
DOW | 49.99549
GOOG| 49.75117
HPQ | 50.14153
IBM | 49.97071
INTC| 50.1727 
MSFT| 50.08773

q)\ts:100 select vwap:(sum num)%sum size by sym from select num:sum price*size, sum size, first sym by int from trade
945 1068736
```
</td>
</tr>
</table>

## Query translation

As can be seen in the examples above, the optimized methods of querying the int partitioned `trade` table rely on doing a "pre-query" to get a list of `int` values from  `partab`, then applying the main query on just those int partitions.

To make queries on the int partitioned table more seamless, the `translate.q` script defines a function `translate` that takes a qSQL functional select statement, finds any `=` or `in` filters in the `where` clause that target partition columns, and replaces them with an equivalent filter on `int` column values.

More complex conditions, like those using `fby`, are unaffected.

``` q
q)\l idb/partitioned/
q)load `:../sym
q)load `:../partab
q)\l ../../translate.q

q)query:"select from trade where sym in `MSFT`AMD, src=`DB, size>500"

q)parse query
?
`trade
,((in;`sym;,`MSFT`AMD);(=;`src;,`DB);(>;`size;500))
0b
()

q)translate query
?
`trade
((in;`int;17 18 73 75);(>;`size;500))
0b
()

q)\ts:100 value query
1514 7077040

q)\ts:100 value translate query
145 7032432

q)query:"select from trade where size>0.99*(max;size) fby sym"

q)count value query
10056

q)parse query
?
`trade
,,(>;`size;(*;0.99;(k){$[(#x 1)=#y;@[(#y)#x[0]0#x 1;g;:;x[0]'x[1]g:.=y];'`length]};(enlist;max;`size);`sym)))
0b
()

q)translate query
?
`trade
,(>;`size;(*;0.99;(k){$[(#x 1)=#y;@[(#y)#x[0]0#x 1;g;:;x[0]'x[1]g:.=y];'`length]};(enlist;max;`size);`sym)))
0b
()

q)ts:100 value query
2182 1915904

q)\ts:100 value translate query
2221 1915456
```

## Extensions

### Hybrid approach

Rather than int partitioning all three columns, it is also possible to int partition just one or two of them, and apply a `p#` or `g#` attribute to the others.

This would bring the performance of certain grouping queries in line with a simple splayed table, but would also result in fewer disk partitions (i.e. a less granular storage structure).

For example, int partitioning on `sym` and `src` and applying `p#` on `side`:

``` q
q)count symsrctab:update `p#`sym$sym, `g#`sym$src from select distinct sym, src from trade
40

q)count {
    (` sv .Q.par[`:idb/partitioned;y;`trade],`) set .Q.en[`:idb]
      update `p#sym, `p#src, `p#side from `side xasc select from trade where sym=x`sym, src=x`src
    }'[symsrctab;til count symsrctab]
40

q)`:idb/symsrctab set symsrctab
```

For another example, int partitioning on `sym` and applying `p#` on `src` and `g#` on `side`:

``` q
q)count symtab:update `p#`sym$sym from select distinct sym from trade
10

q)count {
    (` sv .Q.par[`:idb/partitioned;y;`trade],`) set .Q.en[`:idb]
      update `p#sym, `p#src, `g#side from `src xasc select from trade where sym=x`sym
    }'[symtab;til count symtab]
10

q)`:idb/symtab set symtab
```

Int-partitioning on a single column like in the above example is very similar to the WDB `partbyenum` approach, except the integer encoding is handled by a new `symtab` object rather than by the existing `sym` file.

### Recovering a partab

Unlike the `sym` file, if `partab` gets lost or corrupted, it can be re-derived from any table (or set of tables) containing the full enumeration domain of the necessary partition columns:

``` q
partab:value select first sym, first src, first side by int from trade
```

### Multiple partabs and multiple tables

Theoretically, an int partitioned database could have multiple `partab`s, each representing a different set of partition columns, for partitioning many different tables. Obviously, each `partab` would need a unique name, preferably one that describes the columns it represents, e.g. `symsrcsidetab`.

There would also need to be some sort of meta dictionary which maps each partitioned table in the database to the `partab` it uses - each table could only have one `partab`, but one `partab` could encode multiple tables, as long as it represented the enumeration domain of _all_ its tables.

For example, if the same `partab` were to be responsible for encoding both `trade` and `quote` tables, it could be derived like this:

``` q
q)partab:update `p#`sym$sym, `g#`sym$src, `g#`sym$side from `sym xasc distinct raze (
    select distinct sym, src, side from trade;
    select distinct sym, src, side from quote
    )
```

With multiple `partab`s, the total number of int partitions in the database would be the count of the largest `partab`, and tables with smaller `partab`s would be empty for large partition values.

### Updating a partab

Ideally, a `partab` would contain the full set of past, present, and future combinations of partition column values from all the tables it encodes, and would never change.

This is because, once int partitions are written, the `partab` should not be re-sorted, otherwise the mapping between partition column values and row indexes would change. The same partition column value would therefore get written to multiple int partitions, and tables would no longer be partitioned correctly.

In general, imposing this condition is not realistic because some partition column values may not be known in advance. If the `sym` file is allowed to grow dynamically, then the `partab` would have be allowed to grow as well, particularly if it contained enumerated columns.

As a result, if a `partab` is allowed to grow dynamically, each new combination of partition column values should get added as a new row at the _bottom_ of the `partab`, thereby creating a new int partition with no risk of affecting existing partitions.

The only downside is that the `partab` will no longer be sorted and `p#` can no longer be applied, but since the `partab` should always be small, this is unlikely to matter.
