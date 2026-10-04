# Reference for the tightened question check. A message asks for input when, after removing
# fenced code, inline code spans, URLs and heading lines, any line holds a "?" that ends a
# sentence (followed by whitespace, end of line, or one of * _ ) ]), or the last paragraph
# holds one of the ask phrases as whole words.
def strip: gsub("```[\\s\\S]*?```"; "") | gsub("`[^`\\n]*`"; "") | gsub("(https?|mailto):[^\\s)>\\]]+"; "")
  | [splits("\n") | select(test("^\\s*#{1,6}\\s") | not)] | join("\n");
def paras: [splits("\n\\s*\n") | select(test("\\S"))];
def qline: [splits("\n") | select(test("\\?([\\s*_)\\]]|$)"))] | (last // null);
def phrase: [match("(^|[^A-Za-z0-9_])(let me know|should i|do you want|would you like|which (one|option)|your call|pick one)([^A-Za-z0-9_]|$)"; "i").captures[1].string] | (first // null);
def verdict: strip as $s | ($s | qline) as $q | (($s | paras | last // "") | phrase) as $p
  | if $q != null then "qmark" elif $p != null then "phrase:" + ($p | ascii_downcase) else "none" end;
