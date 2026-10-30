# doc_check.awk: documentation rules for src/.
#   - Every file starts with a // comment that says what it is for.
#   - Every function definition in a .c file has a // comment right above it.
#   - Every top-level declaration in a .h file has a // comment right above it.
# Usage: awk -f scripts/doc_check.awk src/*.c src/*/*.[ch]

# Removes string and char literals and trailing comments, so braces inside
# them do not count.
function strip(s) {
  gsub(/\\./, "", s)
  gsub(/"[^"]*"/, "", s)
  gsub(/'[^']*'/, "", s)
  sub(/\/\/.*/, "", s)
  return s
}

FNR == 1 {
  depth = 0
  prev = ""
  if ($0 !~ /^\/\//) {
    printf "%s:1: start the file with a // comment that says what it is for\n",
           FILENAME
    bad = 1
  }
}

{
  code = strip($0)
  if (depth == 0 && $0 ~ /^[A-Za-z_]/) {
    header = FILENAME ~ /\.h$/
    definition = code ~ /\(/ && code !~ /;[[:space:]]*$/ && code !~ /=/
    if ((header || definition) && prev !~ /^\/\//) {
      printf "%s:%d: add a // comment above this %s\n", FILENAME, FNR,
             header ? "declaration" : "function"
      bad = 1
    }
  }
  depth += gsub(/{/, "{", code) - gsub(/}/, "}", code)
  prev = $0
}

END { exit bad }
