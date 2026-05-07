std = "ngx_lua"
unused_args = false
redefined = false
max_line_length = 120

globals = {
  "_KONG",
  "kong",
  "ngx.IS_CLI",
}

include_files = {
  "kong/**/*.lua",
  "spec/**/*.lua",
}

exclude_files = {
  "**/.luarocks/**",
}
