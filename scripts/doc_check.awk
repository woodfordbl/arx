# doc_check.awk: documentation rules for the Zig sources.
#   - Every file starts with a //! comment that says what it is for.
#   - Every function, and every pub declaration, has a /// comment right
#     above it. Functions inside test blocks are exempt, and so is a pub
#     const that only re-exports another file's declaration.
# Usage: awk -f scripts/doc_check.awk src/*.zig src/*/*.zig build.zig

FNR == 1 {
  in_test = 0
  prev = ""
  if ($0 !~ /^\/\/!/) {
    printf "%s:1: start the file with a //! comment that says what it is for\n",
           FILENAME
    bad = 1
  }
}

{
  line = $0
  sub(/^[ \t]+/, "", line)
  if ($0 ~ /^test "/ || $0 ~ /^test \{/) in_test = 1
  if (in_test && $0 ~ /^\}/) in_test = 0
  needs = 0
  if (!in_test && line ~ /^(pub )?(inline )?fn [A-Za-z_]/) needs = 1
  if (line ~ /^pub (const|var) [A-Za-z_]+ *[:=]/) {
    reexport = line ~ /= *[A-Za-z_][A-Za-z_0-9]*\.[A-Za-z_][A-Za-z_0-9.]*;$/ ||
               line ~ /= *@import\(/
    if (!reexport) needs = 1
  }
  if (needs && prev !~ /^\/\/\//) {
    printf "%s:%d: add a /// comment above this declaration\n", FILENAME, FNR
    bad = 1
  }
  prev = line
}

END { exit bad }
