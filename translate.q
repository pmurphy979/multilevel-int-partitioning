// Functions to translate qSQL queries on partition columns to queries on the int column
// Very simplistic; only works on certain query patterns

// Assume partab is loaded
parcols:cols partab

// Replace simple where clause conditions on parcols with int versions
addintwc:{[wc]
  // "Translatable" conditions include e.g. sym=`foo, src in `bar`baz
  istranslatable:(wc[;0] in (=;in)) and wc[;1] in parcols;
  // Don't do any modification if where clause is not translatable
  if[not any istranslatable;:wc];
  // Apply them to partab instead: exec i from partab where...
  ints:?[`partab;wc where istranslatable;();`i];
  // Add int condition to start of non-translatable conditions
  enlist[(in;`int;ints)], wc where not istranslatable
  }

// Modify a query string or parse tree to include an int where clause
translate:{[x]
  // Convert query to parse tree if it is a string
  parsed:0b; if[10h=type x;x:parse x; parsed:1b];
  // Don't do any modification if query is not a functional select
  if[not (?;5)~(first x;count x);:x];
  // Using parse seems to give the where clause an unwanted extra level of nesting
  if[parsed;x[2]:first x[2]];
  // Modify the where clause
  @[x;2;addintwc]
  }
