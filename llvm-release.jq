.tag_name as $tag
| ([
    .assets[]
    | select(.name | startswith("LLVM-") and endswith($suffix))
    | {name, url: .browser_download_url}
  ][0]) as $pkg
| ([
    .assets[]
    | select(.name == ($pkg.name + ".jsonl"))
    | .browser_download_url
  ][0]) as $bundle
| if $pkg and $bundle then
    [$tag, $pkg.name, $pkg.url, $bundle] | @tsv
  else
    empty
  end
