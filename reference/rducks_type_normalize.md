# Normalize an Rducks type token

Character input is limited to scalar aliases. Composite, DECIMAL, ENUM,
and UNION types are represented by constructed `rducks_type` objects
rather than quoted type strings.

## Usage

``` r
rducks_type_normalize(x)
```

## Arguments

- x:

  Character scalar scalar-type token or a `rducks_type` object.

## Value

Canonical scalar token for character input, or the object's wire token
for a `rducks_type`.
